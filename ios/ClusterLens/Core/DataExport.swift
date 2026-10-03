import Foundation

enum DataExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json = "JSON", csv = "CSV"
    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
}

struct DataExportRequest: Sendable {
    static let maximumRows = 10_000
    static let maximumBytes = 50 * 1024 * 1024
    let connectionID: UUID
    let database: String
    let collection: String
    let query: FindQuery
    let format: DataExportFormat
    let rowLimit: Int

    init(connectionID: UUID, database: String, collection: String, query: FindQuery, format: DataExportFormat, rowLimit: Int) throws {
        guard (1...Self.maximumRows).contains(rowLimit) else { throw FindQuery.invalid("Choose between 1 and 10,000 export rows.") }
        guard format != .csv || !query.fields.isEmpty else { throw FindQuery.invalid("Choose CSV columns explicitly so every row has the same schema.") }
        self.connectionID = connectionID; self.database = database; self.collection = collection
        self.query = query; self.format = format; self.rowLimit = rowLimit
    }
}

struct DataExportResult: Sendable {
    let request: DataExportRequest
    let url: URL
    let rows: Int
    let bytes: Int
    let reachedRequestedLimit: Bool
    var summary: String {
        "\(rows) rows · \(bytes.formatted()) bytes. " + (reachedRequestedLimit ? "Requested row limit reached; more matching rows may exist." : "Cursor exhausted; all rows returned by this live scan were exported.")
    }
}

// One document is encoded at a time. The caller owns a bounded page, never all rows.
final class DataExportWriter {
    let request: DataExportRequest
    let url: URL
    private let handle: FileHandle
    private(set) var rows = 0
    private(set) var bytes = 0
    private var finished = false
    private let byteLimit: Int

    init(request: DataExportRequest, directory: URL = FileManager.default.temporaryDirectory, byteLimit: Int = DataExportRequest.maximumBytes) throws {
        self.request = request
        self.byteLimit = min(byteLimit, DataExportRequest.maximumBytes)
        url = directory.appendingPathComponent("ClusterLens-\(UUID().uuidString).\(request.format.fileExtension)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw FindQuery.invalid("The export file could not be created.")
        }
        do { handle = try FileHandle(forWritingTo: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        do {
            if request.format == .json { try append(Data("[\n".utf8)) }
            else { try append(Data((request.query.fields.map(Self.csvCell).joined(separator: ",") + "\r\n").utf8)) }
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
    }

    deinit {
        try? handle.close()
        if !finished { try? FileManager.default.removeItem(at: url) }
    }

    func write(_ document: JSONValue) throws {
        try Task.checkCancellation()
        guard rows < request.rowLimit else { throw FindQuery.invalid("The requested export row limit was exceeded.") }
        let data: Data
        if request.format == .json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var encoded = Data((rows == 0 ? "" : ",\n").utf8)
            encoded.append(try encoder.encode(document)); data = encoded
        } else {
            let cells = try request.query.fields.map { field -> String in
                guard let value = try Self.value(at: field, in: document) else { return "" }
                if case .string(let text) = value { return text }
                // Canonical Extended JSON objects retain explicit BSON type labels in CSV cells.
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
            }
            data = Data((cells.map(Self.csvCell).joined(separator: ",") + "\r\n").utf8)
        }
        try append(data); rows += 1
    }

    func finish(hasMore: Bool) throws -> DataExportResult {
        try Task.checkCancellation()
        if request.format == .json { try append(Data("\n]\n".utf8)) }
        try handle.close(); finished = true
        return DataExportResult(request: request, url: url, rows: rows, bytes: bytes, reachedRequestedLimit: rows == request.rowLimit && hasMore)
    }

    private func append(_ data: Data) throws {
        // Reserve the JSON suffix so the limit never leaves an apparently complete partial file.
        guard bytes + data.count <= byteLimit - 4 else {
            throw FindQuery.invalid("Export exceeded 50 MiB. The partial file was discarded. Reduce rows or selected fields.")
        }
        try handle.write(contentsOf: data); bytes += data.count
    }

    static func csvCell(_ original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let dangerous = trimmed.first.map { "=+-@".contains($0) } ?? false
        let guarded = dangerous || original.contains("\t") || original.contains("\r") || original.contains("\n") ? "'" + original : original
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func value(at path: String, in value: JSONValue) throws -> JSONValue? {
        var current = value
        for component in path.split(separator: ".") {
            if case .array = current { throw FindQuery.invalid("CSV cannot traverse an array field path. Select the whole array column or use JSON. The partial file was discarded.") }
            guard case .object(let object) = current, let next = object[String(component)] else { return nil }
            current = next
        }
        return current
    }
}
