import Foundation

enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite, abs(value) <= 9_007_199_254_740_991 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Use Extended JSON ($numberLong, $numberDouble, or $numberDecimal) for numbers outside the exact plain-number range.")
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    // Compact _id labels without serializing whole documents for collapsed rows.
    var browseLabel: String {
        switch self {
        case .string(let value): return String(value.prefix(120))
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return "null"
        case .array: return "Array identifier"
        case .object(let fields):
            for key in ["$oid", "$numberLong", "$numberInt", "$numberDouble", "$numberDecimal"] {
                if case .string(let value) = fields[key] { return String(value.prefix(120)) }
            }
            return "Object identifier · \(fields.count) fields"
        }
    }
}

// JSONDecoder stores objects in dictionaries. Reject duplicate keys before that
// conversion so raw input cannot silently lose a condition or BSON type marker.
enum StrictJSON {
    static func validate(_ text: String, maximumBytes: Int = QuerySafety.maximumInputBytes) throws {
        let bytes = Array(text.utf8)
        guard bytes.count <= maximumBytes else {
            throw QuerySafety.Violation(message: "JSON input exceeds \(maximumBytes / 1024) KiB.")
        }
        var scopes: [Set<String>?] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: scopes.append(Set<String>()) // object
            case 91: scopes.append(nil) // array
            case 125, 93: if !scopes.isEmpty { scopes.removeLast() }
            case 34:
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    index += bytes[index] == 92 ? 2 : 1
                }
                guard index < bytes.count else { return } // decoder reports malformed JSON
                var next = index + 1
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58, !scopes.isEmpty,
                   var keys = scopes[scopes.count - 1] {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard keys.insert(key).inserted else {
                        throw QuerySafety.Violation(message: "Duplicate JSON object keys are not supported. Use explicit $and conditions for repeated fields.")
                    }
                    scopes[scopes.count - 1] = keys
                }
            default: break
            }
            guard scopes.count <= 50 else { throw QuerySafety.Violation(message: "JSON nesting exceeds 50 levels.") }
            index += 1
        }
    }
}
