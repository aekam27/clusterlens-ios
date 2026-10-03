import Foundation
import Combine
import LocalAuthentication

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var connectionStates: [UUID: ConnectionStatus] = [:]
    @Published private(set) var databasesByConnection: [UUID: [DatabaseInfo]] = [:]
    @Published private(set) var history: [QueryHistoryEntry] = []
    @Published private(set) var writesUnlocked = false
    @Published private(set) var isBootstrapping = true
    @Published var globalError: String?

    private let keychain = KeychainService()
    private let legacyDefaults = UserDefaults.standard
    private let legacyProfileKey = "direct-connection-profile-v2"
    private let legacyURIAccount = "mongodb-connection-string"
    private var clients: [UUID: MongoDirectClient] = [:]
    private var didBootstrap = false
    private var connectionAttempts = ConnectionAttempts()
    private var writeAuthorizationGeneration = UUID()
    private var writeAuthorization: WriteAuthorization?

    // Never enabled in Release; fixture sessions do not read storage or open sockets.
    private(set) var isSyntheticUI = false
    #if DEBUG
    private var fixtureOffsets: [UUID: Int] = [:]
    init(syntheticUI: Bool = ProcessInfo.processInfo.arguments.contains("--synthetic-ui")) {
        isSyntheticUI = syntheticUI
    }
    #endif

    var profile: ConnectionProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    var databases: [DatabaseInfo] {
        guard let activeProfileID else { return [] }
        return databasesByConnection[activeProfileID] ?? []
    }

    var activeConnectionStatus: ConnectionStatus {
        guard let activeProfileID else { return .saved }
        return connectionStates[activeProfileID] ?? .saved
    }

    var activeHistory: [QueryHistoryEntry] {
        guard let activeProfileID else { return [] }
        return history.filter { $0.connectionID == activeProfileID }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        #if DEBUG
        if isSyntheticUI {
            let fixture = ConnectionProfile(name: "Synthetic QA", host: "Fixtures · no database", usesSRV: false)
            profiles = [fixture]
            activeProfileID = fixture.id
            await reconnect(fixture.id)
            isBootstrapping = false
            return
        }
        #endif
        history = loadHistory()

        if let stored = loadConnectionState(), !stored.profiles.isEmpty {
            profiles = stored.profiles
            activeProfileID = stored.activeProfileID.flatMap { id in
                stored.profiles.contains { $0.id == id } ? id : nil
            } ?? stored.profiles.first?.id
        } else {
            migrateLegacyConnectionIfNeeded()
        }

        if let activeProfileID {
            scopeLegacyHistory(to: activeProfileID)
        }

        for profile in profiles {
            connectionStates[profile.id] = .saved
        }
        isBootstrapping = false

        guard let activeProfileID else { return }
        await reconnect(activeProfileID)
        // Other saved profiles reconnect on demand when activated.
    }

    func connect(name: String, connectionString: String) async throws {
        guard !isSyntheticUI else { throw ClientError.mongo("Synthetic mode cannot save or open connections.") }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURI = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ClientError.invalidConnectionString }
        let summary = try MongoConnectionString.summary(for: trimmedURI)

        let id = UUID()
        let newClient = MongoDirectClient()
        try await newClient.connect(uri: trimmedURI)
        let fetchedDatabases = try await newClient.databases()
        let newProfile = ConnectionProfile(
            id: id,
            name: trimmedName,
            host: summary.host,
            usesSRV: summary.usesSRV
        )

        do {
            try keychain.save(trimmedURI, account: keychainAccount(for: id))
            profiles.append(newProfile)
            activeProfileID = id
            try saveConnectionState()
        } catch {
            profiles.removeAll { $0.id == id }
            if activeProfileID == id { activeProfileID = profiles.first?.id }
            try? keychain.delete(account: keychainAccount(for: id))
            await newClient.disconnect()
            throw error
        }

        clients[id] = newClient
        databasesByConnection[id] = fetchedDatabases
        connectionStates[id] = .connected
        lockWrites()
        globalError = nil
    }

    func activate(_ id: UUID) async {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        lockWrites()
        try? saveConnectionState()

        switch connectionStates[id] ?? .saved {
        case .connected:
            globalError = nil
        case .failed(let message):
            globalError = message
            await reconnect(id)
        case .saved:
            globalError = nil
            await reconnect(id)
        case .connecting:
            globalError = nil
        }
    }

    func reconnect(_ id: UUID) async {
        guard profiles.contains(where: { $0.id == id }) else { return }
        #if DEBUG
        if isSyntheticUI {
            lockWrites()
            clients[id] = MongoDirectClient()
            databasesByConnection[id] = [DatabaseInfo(name: "fixture_store")]
            connectionStates[id] = .connected
            globalError = nil
            return
        }
        #endif
        if case .connecting = connectionStates[id] { return }
        let attempt = connectionAttempts.begin(id)
        if activeProfileID == id { lockWrites() }
        connectionStates[id] = .connecting
        if activeProfileID == id { globalError = nil }

        do {
            guard let uri = try keychain.read(account: keychainAccount(for: id)) else {
                throw ClientError.mongo("The saved connection string is missing from this iPhone's Keychain.")
            }
            let client = MongoDirectClient()
            try await client.connect(uri: uri)
            let fetchedDatabases = try await client.databases()
            guard connectionAttempts.isCurrent(attempt, for: id), profiles.contains(where: { $0.id == id }) else {
                await client.disconnect()
                return
            }
            let previous = clients.updateValue(client, forKey: id)
            if let previous { await previous.disconnect() }
            guard connectionAttempts.isCurrent(attempt, for: id) else { return }
            databasesByConnection[id] = fetchedDatabases
            connectionStates[id] = .connected
            if activeProfileID == id { globalError = nil }
        } catch {
            guard connectionAttempts.isCurrent(attempt, for: id) else { return }
            let message = connectionHelp(for: error)
            connectionStates[id] = .failed(message)
            databasesByConnection[id] = []
            if activeProfileID == id { globalError = message }
        }
    }

    func refreshDatabases() async {
        guard let id = activeProfileID else { return }
        if isSyntheticUI { await reconnect(id); return }
        guard let client = clients[id] else {
            await reconnect(id)
            return
        }
        let expectedState = connectionStates[id]
        do {
            let fetched = try await client.databases()
            guard clients[id] === client, connectionStates[id] == expectedState else { return }
            databasesByConnection[id] = fetched
            connectionStates[id] = .connected
            if activeProfileID == id { globalError = nil }
        } catch {
            guard clients[id] === client, connectionStates[id] == expectedState else { return }
            let message = connectionHelp(for: error)
            connectionStates[id] = .failed(message)
            if activeProfileID == id { globalError = message }
        }
    }

    func fetchCollections(database: String) async throws -> [CollectionInfo] {
        #if DEBUG
        if isSyntheticUI {
            _ = try activeClient()
            return ["orders", "empty", "error", "slow"].map { CollectionInfo(name: $0, type: "collection") }
        }
        #endif
        let client = try activeClient()
        return try await client.collections(database: database)
    }

    func prepareBrowsing(database: String, collection: String, query: FindQuery? = nil) throws -> CollectionBrowseSession {
        let client = try activeClient()
        guard let connectionID = activeProfileID else { throw ClientError.notConnected }
        return CollectionBrowseSession(id: UUID(), connectionID: connectionID,
                                       database: database, collection: collection, client: client, query: query)
    }

    func loadBrowsePage(_ session: CollectionBrowseSession, start: Bool) async throws -> CollectionPage {
        guard activeProfileID == session.connectionID, clients[session.connectionID] === session.client,
              connectionStates[session.connectionID] == .connected else { throw ClientError.notConnected }
        #if DEBUG
        if isSyntheticUI {
            if let query = session.query, !query.filter.isEmpty || query.fields.contains(where: { $0.contains(".") }) {
                throw ClientError.mongo("Synthetic browsing supports the empty filter and top-level fields only. Raw/visual filter validation is tested locally; MongoDB query semantics require a fixture server.")
            }
            let offset = start ? 0 : fixtureOffsets[session.id]
            guard let offset else { throw ClientError.mongo("Synthetic cursor is closed.") }
            try await Task.sleep(for: .milliseconds(session.collection == "slow" ? 3000 : 150))
            try Task.checkCancellation()
            guard activeProfileID == session.connectionID, clients[session.connectionID] === session.client else {
                throw CancellationError()
            }
            if session.collection == "error" { throw ClientError.mongo("Synthetic read failure; no server was contacted.") }
            let count = session.collection == "empty" ? 0 : 41
            let end = min(offset + CollectionPage.maximumDocuments, count)
            let documents = (offset..<end).map { offsetIndex in
                let index = session.query?.descending == true ? count - 1 - offsetIndex : offsetIndex
                return JSONValue.object(["_id": .object(["$numberLong": .string(String(9_007_199_254_740_993 + index))]),
                                  "item": .string("Fixture order \(index + 1)"),
                                  "synthetic": .bool(true)])
            }
            fixtureOffsets[session.id] = end < count ? end : nil
            return CollectionPage(documents: documents.map { Self.fixtureProjection($0, fields: session.query?.fields ?? []) }, hasMore: end < count, elapsedMS: 150)
        }
        #endif
        let page = try await session.client.browsePage(id: session.id, database: session.database,
                                                      collection: session.collection, start: start, query: session.query)
        guard activeProfileID == session.connectionID, clients[session.connectionID] === session.client else {
            await session.client.closeBrowse(id: session.id)
            throw CancellationError()
        }
        return page
    }

    func closeBrowsing(_ session: CollectionBrowseSession) async {
        #if DEBUG
        if isSyntheticUI { fixtureOffsets[session.id] = nil; return }
        #endif
        await session.client.closeBrowse(id: session.id)
    }

    func exportData(_ request: DataExportRequest, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> DataExportResult {
        guard activeProfileID == request.connectionID else { throw ClientError.notConnected }
        let client = try activeClient()
        let result: DataExportResult
        #if DEBUG
        if isSyntheticUI {
            guard request.query.filter.isEmpty, !request.query.fields.contains(where: { $0.contains(".") }) else {
                throw ClientError.mongo("Synthetic export supports the empty filter and top-level fields only; no query semantics are simulated.")
            }
            // Dedicated detached worker avoids file encoding on the main actor.
            let worker = Task.detached {
                let writer = try DataExportWriter(request: request)
                for offset in 0..<min(41, request.rowLimit) {
                    try Task.checkCancellation()
                    let index = request.query.descending ? 40 - offset : offset
                    let document = JSONValue.object(["_id": .object(["$numberLong": .string(String(9_007_199_254_740_993 + index))]),
                                                     "item": .string("Fixture order \(index + 1)"), "synthetic": .bool(true)])
                    try writer.write(Self.fixtureProjection(document, fields: request.query.fields))
                    progress(writer.rows, writer.bytes)
                    try await Task.sleep(for: .milliseconds(30))
                }
                return try writer.finish(hasMore: request.rowLimit < 41)
            }
            result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        } else {
            result = try await client.export(request, progress: progress)
        }
        #else
        result = try await client.export(request, progress: progress)
        #endif
        guard !Task.isCancelled, activeProfileID == request.connectionID, clients[request.connectionID] === client else {
            try? FileManager.default.removeItem(at: result.url)
            throw CancellationError()
        }
        return result
    }

    #if DEBUG
    nonisolated private static func fixtureProjection(_ document: JSONValue, fields: [String]) -> JSONValue {
        // Synthetic schema has only top-level fields. Rejecting nested paths in
        // fixture UI is preferable to pretending to emulate MongoDB array projection.
        guard !fields.isEmpty, case .object(let object) = document else { return document }
        return .object(object.filter { fields.contains($0.key) })
    }
    #endif

    func prepareQuery(database: String, collection: String, operation: QueryOperation, sourceText: String) throws -> QueryRequest {
        _ = try activeClient()
        guard let connectionID = activeProfileID else { throw ClientError.notConnected }
        if operation.isWrite && !writesUnlocked {
            throw ClientError.mongo("Unlock write queries in Settings first.")
        }
        return try QueryRequest(connectionID: connectionID, authorizationID: writeAuthorization?.id,
                                database: database, collection: collection, operation: operation, sourceText: sourceText)
    }

    func runQuery(_ request: QueryRequest, writeConfirmed: Bool = false) async throws -> QueryExecution {
        guard request.connectionID == activeProfileID else {
            throw ClientError.mongo("The active connection changed. Review and run the query again.")
        }
        let client = try activeClient()
        var permit: WritePermit?
        if request.operation.isWrite {
            guard writeConfirmed, writesUnlocked, let writeAuthorization else {
                throw ClientError.mongo("Unlock writes and confirm this query before running it.")
            }
            permit = try writeAuthorization.permit(for: request)
        }
        let execution: QueryExecution
        #if DEBUG
        if isSyntheticUI {
            guard !request.operation.isWrite else { throw ClientError.mongo("Synthetic mode does not execute writes.") }
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            execution = QueryExecution(operation: request.operation.rawValue, elapsedMS: 200,
                result: .object(["synthetic": .bool(true),
                                 "notice": .string("Fixture response only; query semantics are not executed."),
                                 "operation": .string(request.operation.rawValue)]))
        } else {
            execution = try await client.runQuery(request, writePermit: permit)
        }
        #else
        execution = try await client.runQuery(request, writePermit: permit)
        #endif
        // Removing a profile while work finishes must not recreate its history.
        if !request.operation.isCollectionAction, profiles.contains(where: { $0.id == request.connectionID }) {
            let entry = QueryHistoryEntry(
                id: UUID(), connectionID: request.connectionID, date: Date(),
                database: request.database, collection: request.collection,
                operation: request.operation, input: request.sourceText, elapsedMS: execution.elapsedMS
            )
            history.insert(entry, at: 0)
            history = Array(history.prefix(100))
            saveHistory()
        }
        return execution
    }

    func unlockWrites() async throws {
        guard !isSyntheticUI else { throw ClientError.mongo("Writes stay locked in synthetic QA mode.") }
        let generation = writeAuthorizationGeneration
        guard let connectionID = activeProfileID else { throw ClientError.notConnected }
        let context = LAContext()
        context.localizedCancelTitle = "Keep Locked"
        let reason = "Authenticate to enable insert, update, and delete queries."
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            return
        }
        guard generation == writeAuthorizationGeneration, connectionID == activeProfileID else { return }
        writeAuthorization?.revoke()
        writeAuthorization = WriteAuthorization(id: generation, connectionID: connectionID)
        writesUnlocked = true
    }

    func lockWrites() {
        writeAuthorization?.revoke()
        writeAuthorization = nil
        writeAuthorizationGeneration = UUID()
        writesUnlocked = false
    }

    func clearHistory() {
        guard let activeProfileID else { return }
        history.removeAll { $0.connectionID == activeProfileID }
        saveHistory()
    }

    func disconnectSession(_ id: UUID) async {
        connectionAttempts.invalidate(id)
        let client = clients.removeValue(forKey: id)
        databasesByConnection[id] = []
        connectionStates[id] = .saved
        if activeProfileID == id {
            lockWrites()
            globalError = nil
        }
        if let client { await client.disconnect() }
    }

    func removeConnection(_ id: UUID) async {
        do {
            if !isSyntheticUI { try keychain.delete(account: keychainAccount(for: id)) }
        } catch {
            globalError = "The saved credential could not be removed. Unlock the device and try again."
            return
        }
        connectionAttempts.invalidate(id)
        let removedClient = clients.removeValue(forKey: id)
        if activeProfileID == id { lockWrites() }
        profiles.removeAll { $0.id == id }
        connectionStates[id] = nil
        databasesByConnection[id] = nil
        history.removeAll { $0.connectionID == id }
        saveHistory()

        if activeProfileID == id {
            activeProfileID = profiles.first?.id
            globalError = nil
        }
        try? saveConnectionState()

        if let removedClient { await removedClient.disconnect() }
        if let activeProfileID, clients[activeProfileID] == nil {
            await reconnect(activeProfileID)
        }
    }

    private func activeClient() throws -> MongoDirectClient {
        guard let activeProfileID,
              case .connected = connectionStates[activeProfileID],
              let client = clients[activeProfileID] else {
            throw ClientError.notConnected
        }
        return client
    }

    private func keychainAccount(for id: UUID) -> String {
        "mongodb-connection-string.\(id.uuidString.lowercased())"
    }

    private var applicationDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        var directory = base.appendingPathComponent("ClusterLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    private var connectionStateURL: URL? {
        applicationDirectory?.appendingPathComponent("saved-connections-v3.json")
    }

    private var historyURL: URL? {
        applicationDirectory?.appendingPathComponent("query-history.json")
    }

    private func loadConnectionState() -> StoredConnectionState? {
        guard let connectionStateURL,
              let data = try? Data(contentsOf: connectionStateURL) else { return nil }
        return try? JSONDecoder().decode(StoredConnectionState.self, from: data)
    }

    private func saveConnectionState() throws {
        guard !isSyntheticUI else { return }
        guard var connectionStateURL else { throw ClientError.encoding }
        let stored = StoredConnectionState(profiles: profiles, activeProfileID: activeProfileID)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: connectionStateURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? connectionStateURL.setResourceValues(values)
    }

    private func migrateLegacyConnectionIfNeeded() {
        guard let profileData = legacyDefaults.data(forKey: legacyProfileKey),
              let legacyProfile = try? JSONDecoder().decode(ConnectionProfile.self, from: profileData),
              let uri = try? keychain.read(account: legacyURIAccount) else { return }

        do {
            try keychain.save(uri, account: keychainAccount(for: legacyProfile.id))
            profiles = [legacyProfile]
            activeProfileID = legacyProfile.id
            try saveConnectionState()
            try? keychain.delete(account: legacyURIAccount)
            legacyDefaults.removeObject(forKey: legacyProfileKey)
        } catch {
            globalError = "The existing connection could not be migrated to multi-connection storage."
        }
    }

    private func loadHistory() -> [QueryHistoryEntry] {
        guard let historyURL,
              let data = try? Data(contentsOf: historyURL),
              let entries = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data) else { return [] }
        return entries
    }

    private func scopeLegacyHistory(to connectionID: UUID) {
        guard history.contains(where: { $0.connectionID == nil }) else { return }
        history = history.map { entry in
            guard entry.connectionID == nil else { return entry }
            return QueryHistoryEntry(
                id: entry.id,
                connectionID: connectionID,
                date: entry.date,
                database: entry.database,
                collection: entry.collection,
                operation: entry.operation,
                input: entry.input,
                elapsedMS: entry.elapsedMS
            )
        }
        saveHistory()
    }

    private func saveHistory() {
        guard !isSyntheticUI else { return }
        guard var historyURL,
              let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? historyURL.setResourceValues(values)
    }

    private func connectionHelp(for error: Error) -> String {
        let message = error.localizedDescription
        let lowercased = message.lowercased()
        if lowercased.contains("authentication") || lowercased.contains("auth failed") {
            return "Authentication failed. Check the username, password, authSource, and percent-encode special characters in credentials."
        }
        if lowercased.contains("certificate") || lowercased.contains("tls") || lowercased.contains("ssl") {
            return "TLS could not verify or reach the cluster. Confirm the hostname and use a server certificate issued by a trusted authority."
        }
        if lowercased.contains("server selection") || lowercased.contains("no suitable server") || lowercased.contains("timed out") {
            return "The cluster could not be reached. Add this iPhone's current public IP to Atlas Network Access and confirm the cluster is running."
        }
        if lowercased.contains("dns") || lowercased.contains("srv") {
            return "Atlas DNS discovery failed. Check the mongodb+srv hostname and try a network that allows DNS SRV lookups."
        }
        return message
    }
}

private struct StoredConnectionState: Codable {
    let profiles: [ConnectionProfile]
    let activeProfileID: UUID?
}


struct CollectionBrowseSession: Sendable {
    let id: UUID
    let connectionID: UUID
    let database: String
    let collection: String
    fileprivate let client: MongoDirectClient
    let query: FindQuery?
}
