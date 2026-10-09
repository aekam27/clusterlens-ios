import Foundation

struct FindPresetContext: Codable, Equatable, Sendable {
    let connectionID: UUID
    let database: String
    let collection: String

    func validate() throws {
        for value in [database, collection] {
            guard !value.isEmpty, value.utf8.count <= 1024, !value.contains("\0") else {
                throw FindQuery.invalid("The saved query has an invalid database or collection context.")
            }
        }
    }
}

// No connection URI, authentication settings or results are copied from a session.
// User-authored filter values may still contain sensitive information.
struct SavedFindPreset: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let context: FindPresetContext
    var name: String
    let filterJSON: String
    let fields: [String]
    let descending: Bool

    init(id: UUID = UUID(), context: FindPresetContext, name: String, query: FindQuery) throws {
        self.id = id; self.context = context
        self.name = try Self.validatedName(name)
        filterJSON = JSONValue.object(query.filter).prettyPrinted
        fields = query.fields; descending = query.descending
        _ = try validatedQuery()
    }

    func validatedQuery() throws -> FindQuery {
        try context.validate()
        guard name == (try Self.validatedName(name)) else { throw FindQuery.invalid("The saved query name is invalid.") }
        let serialized = name + filterJSON + fields.joined(separator: ",") + context.database + context.collection
        let lower = serialized.lowercased()
        guard !lower.contains("mongodb://"), !lower.contains("mongodb+srv://") else {
            throw FindQuery.invalid("Connection strings cannot be stored in saved queries. Remove credentials from the filter or name before saving.")
        }
        let query = try FindQuery(rawFilter: filterJSON, fields: fields.joined(separator: ","), descending: descending)
        guard query.fields == fields else { throw FindQuery.invalid("The saved query's columns are invalid or ambiguous.") }
        return query
    }

    static func validatedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw FindQuery.invalid("Name the saved query using 1–80 characters without control characters.")
        }
        return name
    }
}

// The app accesses this store on its main actor. Tests can inject an isolated
// directory or nil for memory-only fixtures. No storage path comes from a preset.
final class FindPresetStore {
    static let schemaVersion = 1
    static let maximumPresets = 100
    static let maximumBytes = 2 * 1024 * 1024

    private struct Envelope: Codable {
        let schemaVersion: Int
        let presets: [SavedFindPreset]
    }

    let fileURL: URL?
    private(set) var presets: [SavedFindPreset] = []
    private(set) var writesAllowed = false

    init(fileURL: URL?) { self.fileURL = fileURL }

    func load() throws {
        // Failed reloads preserve the last valid in-memory snapshot but block
        // mutation, so unreadable/future data is never replaced by an empty file.
        writesAllowed = false
        guard let fileURL else { writesAllowed = true; return }
        do {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: fileURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                presets = []; writesAllowed = true; return
            }
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw FindQuery.invalid("Saved-query storage exceeds 2 MiB.") }
            guard let text = String(data: data, encoding: .utf8) else { throw FindQuery.invalid("Saved-query storage is not valid UTF-8. The file has been preserved.") }
            try StrictJSON.validate(text, maximumBytes: Self.maximumBytes)
            // Re-encoding decoded records below validates their own stricter
            // query limits; the envelope itself has a separate 2 MiB budget.
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion else {
                throw FindQuery.invalid("This saved-query file uses an unsupported version. It has been preserved; use a compatible app version.")
            }
            try validateShape(data)
            try validate(envelope.presets)
            presets = envelope.presets
            writesAllowed = true
        } catch let error as QuerySafety.Violation { throw error }
        catch { throw FindQuery.invalid("Saved queries could not be read. The existing file has been preserved. Retry after storage is available; no presets were overwritten.") }
    }

    func list(in context: FindPresetContext) -> [SavedFindPreset] {
        presets.filter { $0.context == context }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func query(id: UUID, in context: FindPresetContext) throws -> FindQuery {
        guard let preset = presets.first(where: { $0.id == id && $0.context == context }) else {
            throw FindQuery.invalid("This saved query is unavailable in the current connection and collection.")
        }
        return try preset.validatedQuery()
    }

    @discardableResult
    func save(name: String, query: FindQuery, in context: FindPresetContext) throws -> SavedFindPreset {
        let preset = try SavedFindPreset(context: context, name: name, query: query)
        try commit(presets + [preset])
        return preset
    }

    func rename(id: UUID, in context: FindPresetContext, to name: String) throws {
        guard let index = presets.firstIndex(where: { $0.id == id && $0.context == context }) else {
            throw FindQuery.invalid("This saved query is unavailable in the current connection and collection.")
        }
        var candidate = presets
        candidate[index].name = try SavedFindPreset.validatedName(name)
        try commit(candidate)
    }

    func delete(id: UUID, in context: FindPresetContext) throws {
        guard presets.contains(where: { $0.id == id && $0.context == context }) else {
            throw FindQuery.invalid("This saved query is unavailable in the current connection and collection.")
        }
        try commit(presets.filter { $0.id != id })
    }

    func removeConnection(_ connectionID: UUID) throws {
        // A known-empty store needs no write. An unreadable file must still
        // report failure rather than silently claiming cleanup succeeded.
        guard writesAllowed else { throw FindQuery.invalid("Saved-query storage is unavailable; its file was preserved.") }
        guard presets.contains(where: { $0.context.connectionID == connectionID }) else { return }
        try commit(presets.filter { $0.context.connectionID != connectionID })
    }

    private func validateShape(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "presets"], let records = root["presets"] as? [[String: Any]] else {
            throw FindQuery.invalid("Saved-query storage contains unsupported fields. The file has been preserved.")
        }
        for record in records {
            guard Set(record.keys) == ["id", "context", "name", "filterJSON", "fields", "descending"],
                  let context = record["context"] as? [String: Any], Set(context.keys) == ["connectionID", "database", "collection"] else {
                throw FindQuery.invalid("A saved query contains unsupported fields. The file has been preserved.")
            }
        }
    }

    private func validate(_ candidate: [SavedFindPreset]) throws {
        guard candidate.count <= Self.maximumPresets, Set(candidate.map(\.id)).count == candidate.count else {
            throw FindQuery.invalid("Saved queries exceed 100 presets or contain duplicate identifiers.")
        }
        for (index, preset) in candidate.enumerated() {
            _ = try preset.validatedQuery()
            let normalized = preset.name.precomposedStringWithCanonicalMapping.lowercased()
            guard !candidate.prefix(index).contains(where: {
                $0.context == preset.context && $0.name.precomposedStringWithCanonicalMapping.lowercased() == normalized
            }) else { throw FindQuery.invalid("A saved query with this name already exists in this collection. Choose another name.") }
        }
    }

    private func commit(_ candidate: [SavedFindPreset]) throws {
        guard writesAllowed else { throw FindQuery.invalid("Saved-query storage is unavailable. Retry loading it before making changes; the existing file is preserved.") }
        try validate(candidate)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, presets: candidate))
        guard data.count <= Self.maximumBytes else { throw FindQuery.invalid("Saved queries exceed the 2 MiB storage limit. Remove an unneeded preset or shorten the filter.") }
        if let fileURL {
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var excludedDirectory = directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try excludedDirectory.setResourceValues(values)
                #if os(iOS)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
                #else
                try data.write(to: fileURL, options: .atomic)
                #endif
            } catch {
                throw FindQuery.invalid("The saved-query change could not be written. Nothing changed in the saved-query list. Check available storage and try again.")
            }
        }
        presets = candidate
    }
}
