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

enum QueryOperation: String, Codable, CaseIterable, Identifiable {
    case find
    case findOne
    case aggregate
    case countDocuments
    case distinct
    case insertOne
    case updateOne
    case deleteOne

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
        case .deleteOne: "trash"
        }
    }

    var isWrite: Bool {
        switch self {
        case .insertOne, .updateOne, .deleteOne: true
        default: false
        }
    }

    var template: String {
        switch self {
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
    let date: Date
    let database: String
    let collection: String
    let operation: QueryOperation
    let input: String
    let elapsedMS: Double
}
