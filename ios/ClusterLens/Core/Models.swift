import Foundation

struct ConnectionProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var usesSRV: Bool

    init(id: UUID = UUID(), name: String, host: String, usesSRV: Bool) {
        self.id = id
        self.name = name
        self.host = host
        self.usesSRV = usesSRV
    }
}

enum ConnectionStatus: Equatable {
    case saved
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var message: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct DatabaseInfo: Codable, Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct CollectionInfo: Codable, Identifiable, Hashable {
    let name: String
    let type: String
    var id: String { name }
}

struct QueryExecution: Decodable {
    let operation: String
    let elapsedMS: Double
    let result: JSONValue
}

enum QueryOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case find
    case findOne
    case aggregate
    case countDocuments
    case distinct
    case insertOne
    case updateOne
    case deleteOne
    case createCollection
    case dropCollection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .find: "Find"
        case .findOne: "Find One"
        case .aggregate: "Aggregate"
        case .countDocuments: "Count"
        case .distinct: "Distinct"
        case .insertOne: "Insert One"
        case .updateOne: "Update One"
        case .deleteOne: "Delete One"
        case .createCollection: "Create Collection"
        case .dropCollection: "Drop Collection"
        }
    }

    var symbol: String {
        switch self {
        case .find, .findOne: "magnifyingglass"
        case .aggregate: "point.3.connected.trianglepath.dotted"
        case .countDocuments: "number"
        case .distinct: "square.stack.3d.up"
        case .insertOne: "plus"
        case .updateOne: "pencil"
        case .deleteOne, .dropCollection: "trash"
        case .createCollection: "plus.rectangle.on.folder"
        }
    }

    var isWrite: Bool {
        switch self {
        case .insertOne, .updateOne, .deleteOne, .createCollection, .dropCollection: true
        default: false
        }
    }

    var isCollectionAction: Bool { self == .createCollection || self == .dropCollection }

    var template: String {
        switch self {
        case .createCollection, .dropCollection:
            "{\"confirmNamespace\": \"database.collection\"}"
        case .find:
            """
            {
              "filter": {},
              "projection": {},
              "sort": { "_id": -1 },
              "limit": 50
            }
            """
        case .findOne:
            """
            {
              "filter": {}
            }
            """
        case .aggregate:
            """
            {
              "pipeline": [
                { "$match": {} },
                { "$limit": 50 }
              ]
            }
            """
        case .countDocuments:
            """
            {
              "filter": {}
            }
            """
        case .distinct:
            """
            {
              "field": "status",
              "filter": {}
            }
            """
        case .insertOne:
            """
            {
              "document": {
                "createdAt": { "$date": "2026-01-01T00:00:00Z" }
              }
            }
            """
        case .updateOne:
            """
            {
              "filter": { "_id": { "$oid": "507f1f77bcf86cd799439011" } },
              "update": { "$set": { "status": "active" } },
              "upsert": false
            }
            """
        case .deleteOne:
            """
            {
              "filter": { "_id": { "$oid": "507f1f77bcf86cd799439011" } }
            }
            """
        }
    }
}

struct QueryHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let connectionID: UUID?
    let date: Date
    let database: String
    let collection: String
    let operation: QueryOperation
    let input: String
    let elapsedMS: Double

    init(
        id: UUID,
        connectionID: UUID? = nil,
        date: Date,
        database: String,
        collection: String,
        operation: QueryOperation,
        input: String,
        elapsedMS: Double
    ) {
        self.id = id
        self.connectionID = connectionID
        self.date = date
        self.database = database
        self.collection = collection
        self.operation = operation
        self.input = input
        self.elapsedMS = elapsedMS
    }
}

// Shared by the UI-facing coordinator and direct client so alternate callers cannot
// use an aggregation to bypass the explicit write operations.
enum QuerySafety {
    static let maximumInputBytes = 256 * 1024

    static func validate(operation: QueryOperation, input: [String: JSONValue]) throws {
        if containsJavaScript(.object(input)) { throw Violation(message: "Server-side JavaScript is not supported. Use MongoDB query operators and Extended JSON.") }
        if let filter = input["filter"], case .object = filter {} else if input["filter"] != nil {
            throw Violation(message: "Filter must be a JSON object; it will not be replaced by an empty filter.")
        }

        let allowed: Set<String>?
        switch operation {
        case .find, .findOne: allowed = ["filter", "projection", "sort", "limit"]
        case .countDocuments: allowed = ["filter"]
        case .distinct: allowed = ["filter", "field"]
        default: allowed = nil
        }
        if let allowed, !Set(input.keys).isSubset(of: allowed) {
            throw Violation(message: "Unsupported query option. Put document conditions inside the filter object; choose an operation template for its supported keys.")
        }
        if let sort = input["sort"] {
            guard case .object(let fields) = sort, fields.count <= 1 else {
                throw Violation(message: "This raw editor supports one sort field. Compound sort requires an ordered-key editor and is not supported yet.")
            }
        }
        if operation == .aggregate {
            guard case .array = input["pipeline"] else {
                throw Violation(message: "Aggregate requires a pipeline array.")
            }
            if containsWriteStage(.object(input)) {
                throw Violation(message: "Aggregation is read-only in ClusterLens. $out and $merge are not supported.")
            }
        }
        if operation == .updateOne || operation == .deleteOne {
            guard case .object(let filter) = input["filter"], !filter.isEmpty else {
                throw Violation(message: "Update and delete require a non-empty filter. Prefer a specific _id.")
            }
        }
    }

    private static func containsJavaScript(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields): return fields.keys.contains(where: { ["$where", "$function", "$accumulator", "$code"].contains($0) }) || fields.values.contains(where: containsJavaScript)
        case .array(let values): return values.contains(where: containsJavaScript)
        default: return false
        }
    }

    private static func containsWriteStage(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields):
            return fields.keys.contains("$out") || fields.keys.contains("$merge") || fields.values.contains(where: containsWriteStage)
        case .array(let values): return values.contains(where: containsWriteStage)
        default: return false
        }
    }

    struct Violation: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

// A completion may publish only while it owns the current attempt for its profile.
struct ConnectionAttempts {
    private var current: [UUID: UUID] = [:]

    mutating func begin(_ id: UUID) -> UUID {
        let token = UUID()
        current[id] = token
        return token
    }

    func isCurrent(_ token: UUID, for id: UUID) -> Bool { current[id] == token }
    mutating func invalidate(_ id: UUID) { current[id] = nil }
}

// Captured before showing confirmation. Value semantics keep editor changes from
// changing the query that the user reviews.
struct QueryRequest: Equatable, Sendable {
    let id: UUID
    let connectionID: UUID
    let authorizationID: UUID?
    let database: String
    let collection: String
    let operation: QueryOperation
    let input: [String: JSONValue]
    let sourceText: String

    init(connectionID: UUID, authorizationID: UUID?, database: String, collection: String,
         operation: QueryOperation, sourceText: String) throws {
        guard sourceText.utf8.count <= QuerySafety.maximumInputBytes else {
            throw QuerySafety.Violation(message: "Query input exceeds the 256 KiB mobile limit.")
        }
        try StrictJSON.validate(sourceText)
        let input = try JSONDecoder().decode([String: JSONValue].self, from: Data(sourceText.utf8))
        try QuerySafety.validate(operation: operation, input: input)
        guard try JSONEncoder().encode(input).count <= QuerySafety.maximumInputBytes else {
            throw QuerySafety.Violation(message: "Encoded query input exceeds the 256 KiB mobile limit.")
        }
        if operation.isCollectionAction {
            guard !database.isEmpty, !database.contains("\0"), !collection.isEmpty,
                  collection == collection.trimmingCharacters(in: .whitespacesAndNewlines),
                  collection.utf8.count <= 200, !collection.contains("\0"), !collection.contains("$"),
                  !collection.hasPrefix("system.") else {
                throw QuerySafety.Violation(message: "Use a non-empty collection name of up to 200 UTF-8 bytes, without surrounding whitespace, NUL, $, or the system. prefix.")
            }
            guard input["confirmNamespace"] == .string("\(database).\(collection)") else {
                throw QuerySafety.Violation(message: "The exact database.collection namespace must match the confirmed action.")
            }
        }
        self.id = UUID()
        self.connectionID = connectionID
        self.authorizationID = authorizationID
        self.database = database
        self.collection = collection
        self.operation = operation
        self.input = input
        self.sourceText = sourceText
    }
}

// The lock protects revocation and one-shot dispatch together. It is never held
// during a native call. Revoking prevents future dispatch, not an already-started write.
final class WriteAuthorization: @unchecked Sendable {
    let id: UUID
    let connectionID: UUID
    private let lock = NSLock()
    private var isValid = true

    init(id: UUID, connectionID: UUID) {
        self.id = id
        self.connectionID = connectionID
    }

    func revoke() { lock.withLock { isValid = false } }

    func permit(for request: QueryRequest) throws -> WritePermit {
        try lock.withLock {
            guard isValid, request.operation.isWrite, request.connectionID == connectionID,
                  request.authorizationID == id else { throw Self.expired }
            return WritePermit(request: request, authorization: self)
        }
    }

    fileprivate func consume(_ permit: WritePermit, for request: QueryRequest) throws {
        try lock.withLock {
            guard isValid, !permit.consumed, permit.request == request else { throw Self.expired }
            permit.consumed = true
        }
    }

    private static var expired: QuerySafety.Violation {
        QuerySafety.Violation(message: "Write authorization expired or the query changed. Unlock writes and confirm the query again.")
    }
}

final class WritePermit: @unchecked Sendable {
    fileprivate let request: QueryRequest
    private let authorization: WriteAuthorization
    // Accessed only under authorization's lock.
    fileprivate var consumed = false

    fileprivate init(request: QueryRequest, authorization: WriteAuthorization) {
        self.request = request
        self.authorization = authorization
    }

    func authorizeDispatch(for request: QueryRequest) throws {
        try authorization.consume(self, for: request)
    }
}


struct CollectionPage: Decodable, Sendable {
    static let maximumDocuments = 20
    static let maximumJSONBytes = 4 * 1024 * 1024
    let documents: [JSONValue]
    let hasMore: Bool
    let elapsedMS: Double

    func validate() throws {
        guard documents.count <= Self.maximumDocuments,
              !documents.isEmpty || !hasMore,
              try JSONEncoder().encode(documents).count <= Self.maximumJSONBytes else {
            throw QuerySafety.Violation(message: "The browsing page exceeds the mobile preview limits. Restart with a narrower query.")
        }
    }
}

// The window holds only the current page. Loading the next page releases it;
// session IDs prevent an old completion from replacing a restarted browse.
struct CollectionPageWindow {
    private(set) var sessionID: UUID?
    private(set) var page: CollectionPage?
    private(set) var pageNumber = 0
    private(set) var documentsSeen = 0

    mutating func begin(_ sessionID: UUID) {
        self.sessionID = sessionID
        page = nil
        pageNumber = 0
        documentsSeen = 0
    }

    mutating func releasePage() { page = nil }

    @discardableResult
    mutating func accept(_ page: CollectionPage, sessionID: UUID) throws -> Bool {
        guard self.sessionID == sessionID else { return false }
        try page.validate()
        self.page = page
        pageNumber += 1
        documentsSeen += page.documents.count
        return true
    }

    mutating func close() {
        sessionID = nil
        page = nil
    }
}
