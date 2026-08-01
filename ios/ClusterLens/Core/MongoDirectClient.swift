import Foundation

actor MongoDirectClient {
    private var handle: CLMongoClientRef?

    deinit {
        if let handle {
            cl_mongo_disconnect(handle)
        }
    }

    func connect(uri: String) async throws {
        let expanded = try await MongoConnectionString.expanded(uri)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let newHandle = expanded.withCString { pointer in
            cl_mongo_connect(pointer, &errorPointer)
        }
        guard let newHandle else {
            throw ClientError.mongo(takeError(errorPointer) ?? "MongoDB rejected the connection string.")
        }
        if let handle {
            cl_mongo_disconnect(handle)
        }
        handle = newHandle
    }

    func disconnect() {
        if let handle {
            cl_mongo_disconnect(handle)
            self.handle = nil
        }
    }

    func databases() throws -> [DatabaseInfo] {
        guard let handle else { throw ClientError.notConnected }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = cl_mongo_list_databases(handle, &errorPointer)
        return try decode(result, errorPointer: errorPointer, as: [DatabaseInfo].self)
    }

    func collections(database: String) throws -> [CollectionInfo] {
        guard let handle else { throw ClientError.notConnected }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = database.withCString { databasePointer in
            cl_mongo_list_collections(handle, databasePointer, &errorPointer)
        }
        return try decode(result, errorPointer: errorPointer, as: [CollectionInfo].self)
    }

    func runQuery(
        database: String,
        collection: String,
        operation: QueryOperation,
        input: [String: JSONValue]
    ) throws -> QueryExecution {
        guard let handle else { throw ClientError.notConnected }
        let inputData = try JSONEncoder().encode(input)
        let inputText = String(decoding: inputData, as: UTF8.self)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = database.withCString { databasePointer in
            collection.withCString { collectionPointer in
                operation.rawValue.withCString { operationPointer in
                    inputText.withCString { inputPointer in
                        cl_mongo_execute(
                            handle,
                            databasePointer,
                            collectionPointer,
                            operationPointer,
                            inputPointer,
                            &errorPointer
                        )
                    }
                }
            }
        }
        return try decode(result, errorPointer: errorPointer, as: QueryExecution.self)
    }

    private func decode<Value: Decodable>(
        _ pointer: UnsafeMutablePointer<CChar>?,
        errorPointer: UnsafeMutablePointer<CChar>?,
        as type: Value.Type
    ) throws -> Value {
        guard let pointer else {
            throw ClientError.mongo(takeError(errorPointer) ?? "MongoDB did not return a result.")
        }
        defer { cl_mongo_free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ClientError.invalidResponse
        }
    }

    private func takeError(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { cl_mongo_free(pointer) }
        return String(cString: pointer)
    }
}

enum ClientError: LocalizedError {
    case invalidConnectionString
    case invalidResponse
    case notConnected
    case mongo(String)
    case encoding

    var errorDescription: String? {
        switch self {
        case .invalidConnectionString: "The MongoDB connection string is invalid."
        case .invalidResponse: "MongoDB returned a result the app could not decode."
        case .notConnected: "Connect to a MongoDB cluster first."
        case .mongo(let message): message
        case .encoding: "The query could not be encoded."
        }
    }
}
