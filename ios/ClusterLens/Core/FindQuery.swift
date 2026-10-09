import Foundation

struct FilterRule: Identifiable, Equatable {
    let id = UUID()
    var field = ""
    var operation: FilterOperator = .equal
    var type: FilterValueType = .string
    var value = ""

    func clause() throws -> JSONValue {
        try FindQuery.validateField(field)
        let parsed: JSONValue
        if operation == .exists {
            guard value == "true" || value == "false" else { throw FindQuery.invalid("Exists expects true or false.") }
            parsed = .bool(value == "true")
        } else if operation == .oneOf {
            parsed = try FindQuery.parse(value)
            guard case .array = parsed else { throw FindQuery.invalid("In expects a JSON array.") }
        } else {
            switch type {
            case .string: parsed = .string(value)
            case .integer:
                guard let number = Int64(value) else { throw FindQuery.invalid("Enter a whole number within Int64, or use Extended JSON.") }
                parsed = .object(["$numberLong": .string(String(number))])
            case .boolean:
                guard value == "true" || value == "false" else { throw FindQuery.invalid("Boolean values must be true or false.") }
                parsed = .bool(value == "true")
            case .null: parsed = .null
            case .extendedJSON: parsed = try FindQuery.parse(value)
            }
        }
        return .object([field: .object([operation.rawValue: parsed])])
    }
}

enum FilterOperator: String, CaseIterable, Identifiable {
    case equal = "$eq", notEqual = "$ne", greater = "$gt", atLeast = "$gte", less = "$lt", atMost = "$lte", oneOf = "$in", exists = "$exists"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .equal: "Equals"
        case .notEqual: "Does not equal"
        case .greater: "Greater than"
        case .atLeast: "At least"
        case .less: "Less than"
        case .atMost: "At most"
        case .oneOf: "In array"
        case .exists: "Exists"
        }
    }
}

enum FilterValueType: String, CaseIterable, Identifiable {
    case string = "Text", integer = "Integer", boolean = "Boolean", null = "Null", extendedJSON = "JSON / Extended JSON"
    var id: String { rawValue }
}

struct FindQuery: Equatable, Sendable {
    let filter: [String: JSONValue]
    let fields: [String]
    // A single deterministic sort avoids reordering compound keys in Dictionary.
    let descending: Bool

    init(rawFilter: String, fields: String = "", descending: Bool = false) throws {
        guard case .object(let filter) = try Self.parse(rawFilter) else {
            throw Self.invalid("A filter must be a JSON object, such as {\"status\": \"active\"}.")
        }
        try Self.validateFilter(.object(filter))
        let columns = fields.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let selected = fields.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : columns
        guard Set(selected).count == selected.count else { throw Self.invalid("Select each column only once.") }
        for column in selected { try Self.validateField(column) }
        for field in selected {
            guard !selected.contains(where: { $0 != field && $0.hasPrefix(field + ".") }) else {
                throw Self.invalid("Select either a parent field or its nested fields, not both.")
            }
        }
        self.filter = filter
        self.fields = selected
        self.descending = descending
        guard try JSONEncoder().encode(input).count <= QuerySafety.maximumInputBytes else { throw Self.invalid("Encoded query exceeds 256 KiB.") }
    }

    var input: [String: JSONValue] {
        var projection = Dictionary(uniqueKeysWithValues: fields.map { ($0, JSONValue.integer(1)) })
        if !fields.isEmpty && !fields.contains("_id") { projection["_id"] = .integer(0) }
        return ["filter": .object(filter), "projection": .object(projection), "sort": .object(["_id": .integer(descending ? -1 : 1)])]
    }

    static func build(rules: [FilterRule], any: Bool) throws -> String {
        guard rules.count <= 30 else { throw invalid("Use up to 30 visual conditions; use Raw for more complex filters.") }
        let clauses = try rules.map { try $0.clause() }
        return JSONValue.object(clauses.isEmpty ? [:] : [any ? "$or" : "$and": .array(clauses)]).prettyPrinted
    }

    static func parse(_ text: String) throws -> JSONValue {
        guard text.utf8.count <= QuerySafety.maximumInputBytes else { throw invalid("Query input exceeds 256 KiB.") }
        try StrictJSON.validate(text)
        do { return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        catch { throw invalid("Use valid JSON / Extended JSON with quoted keys. Shell code, ObjectId(...), ISODate(...), comments and /regex/ literals are not supported. Use $oid, $date and $regularExpression objects instead.") }
    }

    static func validateField(_ field: String) throws {
        guard !field.isEmpty, field.utf8.count <= 1024, !field.contains("\0"),
              field.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix("$") }) else {
            throw invalid("Enter a non-empty field path, such as customer.name. Empty segments, NUL and $-prefixed segments are not supported.")
        }
    }

    static func validateFilter(_ value: JSONValue, depth: Int = 0) throws {
        guard depth < 50 else { throw invalid("Filter nesting exceeds 50 levels.") }
        switch value {
        case .object(let object):
            guard !object.keys.contains(where: { ["$where", "$function", "$accumulator", "$code"].contains($0) }) else {
                throw invalid("Server-side JavaScript is not supported. Use MongoDB query operators.")
            }
            for nested in object.values { try validateFilter(nested, depth: depth + 1) }
        case .array(let array): for nested in array { try validateFilter(nested, depth: depth + 1) }
        default: break
        }
    }

    static func invalid(_ message: String) -> QuerySafety.Violation { .init(message: message) }
}

// Preparing a replacement may throw. Until it succeeds, the current page,
// continuation session and in-flight delivery token remain untouched.
struct FindPreviewState<Session> {
    struct Read {
        let id = UUID()
        let session: Session
        let startsCursor: Bool
    }

    private(set) var session: Session?
    private(set) var page: CollectionPage?
    private(set) var pageNumber = 0
    private var deliveryID: UUID?

    mutating func replace(preparing prepare: () throws -> Session) rethrows -> (read: Read, retired: Session?) {
        let replacement = try prepare()
        let retired = session
        session = replacement
        pageNumber = 0
        return (begin(session: replacement, startsCursor: true), retired)
    }

    mutating func next() throws -> Read {
        guard deliveryID == nil, let session, page?.hasMore == true else {
            throw FindQuery.invalid("Apply the filter again to open a new preview cursor.")
        }
        return begin(session: session, startsCursor: false)
    }

    private mutating func begin(session: Session, startsCursor: Bool) -> Read {
        let read = Read(session: session, startsCursor: startsCursor)
        page = nil // Retain only one bounded page, including while loading.
        deliveryID = read.id
        return read
    }

    @discardableResult
    mutating func accept(_ page: CollectionPage, for read: Read) throws -> Bool {
        guard deliveryID == read.id else { return false }
        try page.validate()
        self.page = page
        pageNumber += 1
        deliveryID = nil // A completion may publish only once.
        return true
    }

    @discardableResult
    mutating func fail(_ read: Read) -> Bool {
        guard deliveryID == read.id else { return false }
        _ = cancel()
        return true
    }

    // Revocation is immediate even when the native call cannot be interrupted.
    @discardableResult
    mutating func cancel() -> Session? {
        let retired = session
        deliveryID = nil
        session = nil
        page = nil
        pageNumber = 0
        return retired
    }
}
