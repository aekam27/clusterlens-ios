import Foundation

actor MongoDirectClient {
    private var handle: CLMongoClientRef?
    private var browseID: UUID?

    deinit {
        if let handle {
            cl_mongo_disconnect(handle)
        }
    }

    func connect(uri: String) async throws {
        try Task.checkCancellation()
        let expanded = try await MongoConnectionString.expanded(uri)
        try Task.checkCancellation()
        guard let certificateStore = Bundle.main.path(forResource: "cacert", ofType: "pem") else {
            throw ClientError.missingCertificateStore
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let newHandle = expanded.withCString { uriPointer in
            certificateStore.withCString { certificateStorePointer in
                cl_mongo_connect(uriPointer, certificateStorePointer, &errorPointer)
            }
        }
        guard let newHandle else {
            throw ClientError.mongo(takeError(errorPointer) ?? "MongoDB rejected the connection string.")
        }
        if Task.isCancelled {
            cl_mongo_disconnect(newHandle)
            throw CancellationError()
        }
        if let handle {
            cl_mongo_disconnect(handle)
        }
        browseID = nil
        handle = newHandle
    }

    func disconnect() {
        browseID = nil
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

    func runQuery(_ request: QueryRequest, writePermit: WritePermit? = nil) throws -> QueryExecution {
        let database = request.database
        let collection = request.collection
        let operation = request.operation
        let input = request.input
        guard let handle else { throw ClientError.notConnected }
        try Task.checkCancellation()
        try QuerySafety.validate(operation: operation, input: input)
        let inputData = try JSONEncoder().encode(input)
        guard inputData.count <= QuerySafety.maximumInputBytes else {
            throw QuerySafety.Violation(message: "Query input exceeds the 256 KiB mobile limit.")
        }
        let inputText = String(decoding: inputData, as: UTF8.self)
        try Task.checkCancellation()
        if operation.isWrite {
            guard let writePermit else { throw ClientError.mongo("Confirm the write query before running it.") }
            try writePermit.authorizeDispatch(for: request)
        }
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
        // Release a cancelled read before allocating Swift's decoded result tree.
        // Acknowledged writes must still report their outcome.
        if !operation.isWrite && Task.isCancelled {
            if let result { cl_mongo_free(result) }
            if let errorPointer { cl_mongo_free(errorPointer) }
            throw CancellationError()
        }
        return try decode(result, errorPointer: errorPointer, as: QueryExecution.self)
    }

    func browsePage(id: UUID, database: String, collection: String, start: Bool, query: FindQuery? = nil) throws -> CollectionPage {
        try Task.checkCancellation()
        guard let handle else { throw ClientError.notConnected }
        if start {
            browseID = id
        } else if browseID != id {
            throw ClientError.mongo("This browsing session has ended. Restart browsing to continue.")
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result: UnsafeMutablePointer<CChar>?
        let queryText = String(decoding: try JSONEncoder().encode(query?.input ?? FindQuery(rawFilter: "{}").input), as: UTF8.self)
        if start {
            result = database.withCString { databasePointer in
                collection.withCString { collectionPointer in
                    queryText.withCString { queryPointer in
                        cl_mongo_browse_filtered(handle, databasePointer, collectionPointer, queryPointer, &errorPointer)
                    }
                }
            }
        } else {
            result = cl_mongo_browse_next(handle, &errorPointer)
        }
        if Task.isCancelled {
            if let result { cl_mongo_free(result) }
            if let errorPointer { cl_mongo_free(errorPointer) }
            closeBrowse(id: id)
            throw CancellationError()
        }
        do {
            if let result, strlen(result) > CollectionPage.maximumJSONBytes + 1024 {
                cl_mongo_free(result)
                if let errorPointer { cl_mongo_free(errorPointer) }
                throw ClientError.invalidResponse
            }
            let page = try decode(result, errorPointer: errorPointer, as: CollectionPage.self)
            try page.validate()
            if !page.hasMore { browseID = nil }
            return page
        } catch {
            closeBrowse(id: id)
            throw error
        }
    }

    // Synchronous actor isolation reserves the existing client/cursor for this
    // entire export. Other reads cannot replace its cursor between pages.
    func export(_ request: DataExportRequest, progress: @Sendable (Int, Int) -> Void) throws -> DataExportResult {
        let id = UUID()
        let writer = try DataExportWriter(request: request)
        defer { closeBrowse(id: id) }
        var start = true
        while true {
            try Task.checkCancellation()
            let page = try browsePage(id: id, database: request.database, collection: request.collection, start: start, query: request.query)
            start = false
            for (index, document) in page.documents.enumerated() {
                try writer.write(document)
                if writer.rows == request.rowLimit {
                    progress(writer.rows, writer.bytes)
                    return try writer.finish(hasMore: index + 1 < page.documents.count || page.hasMore)
                }
            }
            progress(writer.rows, writer.bytes)
            if !page.hasMore { return try writer.finish(hasMore: false) }
        }
    }

    func closeBrowse(id: UUID) {
        guard browseID == id else { return }
        if let handle { cl_mongo_browse_close(handle) }
        browseID = nil
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
    case missingCertificateStore
    case notConnected
    case mongo(String)
    case encoding

    var errorDescription: String? {
        switch self {
        case .invalidConnectionString: "The MongoDB connection string is invalid."
        case .invalidResponse: "MongoDB returned a result the app could not decode."
        case .missingCertificateStore: "ClusterLens could not load its TLS certificate store. Reinstall the app and try again."
        case .notConnected: "Connect to a MongoDB cluster first."
        case .mongo(let message): message
        case .encoding: "The query could not be encoded."
        }
    }
}
