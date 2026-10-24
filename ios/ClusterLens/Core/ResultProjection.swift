import Foundation

// Presentation only: never changes a MongoDB query or flattens the source document.
struct ResultCell: Equatable {
    let text: String
    let type: String
    let missing: Bool
    let truncated: Bool

    init(_ value: JSONValue?) {
        guard let value else {
            text = "Missing"; type = "No field"; missing = true; truncated = false
            return
        }
        missing = false
        let raw: String
        switch value {
        case .string(let string): raw = string; type = "Text"
        case .integer(let number): raw = String(number); type = "Integer"
        case .number(let number): raw = String(number); type = "Number"
        case .bool(let flag): raw = flag ? "true" : "false"; type = "Boolean"
        case .null: raw = "null"; type = "Null"
        case .array(let array): raw = "\(array.count) items"; type = "Array"
        case .object(let object):
            if let atom = ResultProjection.typedAtom(object) { raw = atom.text; type = atom.type }
            else { raw = "\(object.count) fields"; type = "Object" }
        }
        let prefix = String(raw.prefix(120))
        truncated = prefix.utf8.count < raw.utf8.count
        text = prefix + (truncated ? "…" : "")
    }
}

enum ResultProjection {
    static let maximumColumns = 8

    static func value(at path: String, in document: JSONValue) -> JSONValue? {
        var current = document
        for segment in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard !segment.isEmpty, case .object(let fields) = current,
                  let next = fields[String(segment)] else { return nil }
            current = next
        }
        return current
    }

    static func typedAtom(_ fields: [String: JSONValue]) -> (text: String, type: String)? {
        guard fields.count == 1 else { return nil }
        let types = ["$oid": "ObjectId", "$numberLong": "Int64", "$numberInt": "Int32",
                     "$numberDouble": "Double", "$numberDecimal": "Decimal128", "$date": "Date"]
        for (key, type) in types {
            if case .string(let value) = fields[key] { return (value, type) }
        }
        if case .object(let date) = fields["$date"], case .string(let value) = date["$numberLong"] {
            return (value + " ms since epoch", "Date")
        }
        return nil
    }

    static func suggestions(in documents: [JSONValue]) -> [String] {
        var fields = Set<String>(), remaining = 200
        func visit(_ value: JSONValue, prefix: String, depth: Int) {
            guard depth < 4, remaining > 0, case .object(let object) = value,
                  typedAtom(object) == nil else { return }
            // Sample a bounded number of keys. This is a page sample, not schema discovery.
            for key in object.keys.prefix(80).sorted() where remaining > 0 {
                remaining -= 1
                let path = prefix.isEmpty ? key : prefix + "." + key
                guard !key.contains("."), (try? FindQuery.validateField(path)) != nil else { continue }
                fields.insert(path)
                if let child = object[key] { visit(child, prefix: path, depth: depth + 1) }
            }
        }
        for document in documents.prefix(20) where remaining > 0 { visit(document, prefix: "", depth: 0) }
        return Array(fields.sorted().prefix(80))
    }

    static func initialColumns(from suggestions: [String]) -> [String] {
        let preferred = ["item", "name", "status", "quantity"] .filter { suggestions.contains($0) }
        let leaves = suggestions.filter { field in
            field != "_id" && !suggestions.contains(where: { $0.hasPrefix(field + ".") })
        }
        var result: [String] = []
        for field in preferred + leaves + suggestions where !result.contains(field) {
            result.append(field)
            if result.count == 4 { break }
        }
        return result.isEmpty ? ["_id"] : result
    }
}
