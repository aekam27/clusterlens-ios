import Foundation
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
        for profile in profiles where profile.id != activeProfileID {
            Task { await self.reconnect(profile.id) }
        }
    }

    func connect(name: String, connectionString: String) async throws {
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
        writesUnlocked = false
        globalError = nil
    }

    func activate(_ id: UUID) async {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        writesUnlocked = false
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
        if case .connecting = connectionStates[id] { return }
        connectionStates[id] = .connecting
        if activeProfileID == id { globalError = nil }

        do {
            guard let uri = try keychain.read(account: keychainAccount(for: id)) else {
                throw ClientError.mongo("The saved connection string is missing from this iPhone's Keychain.")
            }
            let client = clients[id] ?? MongoDirectClient()
            try await client.connect(uri: uri)
            let fetchedDatabases = try await client.databases()
            clients[id] = client
            databasesByConnection[id] = fetchedDatabases
            connectionStates[id] = .connected
            if activeProfileID == id { globalError = nil }
        } catch {
            let message = connectionHelp(for: error)
            connectionStates[id] = .failed(message)
            databasesByConnection[id] = []
            if activeProfileID == id { globalError = message }
        }
    }

    func refreshDatabases() async {
        guard let id = activeProfileID else { return }
        guard let client = clients[id] else {
            await reconnect(id)
            return
        }
        do {
            databasesByConnection[id] = try await client.databases()
            connectionStates[id] = .connected
            globalError = nil
        } catch {
            let message = connectionHelp(for: error)
            connectionStates[id] = .failed(message)
            globalError = message
        }
    }

    func fetchCollections(database: String) async throws -> [CollectionInfo] {
        let client = try activeClient()
        return try await client.collections(database: database)
    }

    func runQuery(
        database: String,
        collection: String,
        operation: QueryOperation,
        input: [String: JSONValue],
        sourceText: String
    ) async throws -> QueryExecution {
        if operation.isWrite && !writesUnlocked {
            throw ClientError.mongo("Unlock write queries in Settings first.")
        }
        let connectionID = activeProfileID
        let client = try activeClient()
        let execution = try await client.runQuery(
            database: database,
            collection: collection,
            operation: operation,
            input: input
        )
        let entry = QueryHistoryEntry(
            id: UUID(),
            connectionID: connectionID,
            date: Date(),
            database: database,
            collection: collection,
            operation: operation,
            input: sourceText,
            elapsedMS: execution.elapsedMS
        )
        history.insert(entry, at: 0)
        history = Array(history.prefix(100))
        saveHistory()
        return execution
    }

    func unlockWrites() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Keep Locked"
        let reason = "Authenticate to enable insert, update, and delete queries."
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            return
        }
        writesUnlocked = true
    }

    func lockWrites() {
        writesUnlocked = false
    }

    func clearHistory() {
        guard let activeProfileID else { return }
        history.removeAll { $0.connectionID == activeProfileID }
        saveHistory()
    }

    func disconnectSession(_ id: UUID) async {
        if let client = clients.removeValue(forKey: id) {
            await client.disconnect()
        }
        databasesByConnection[id] = []
        connectionStates[id] = .saved
        if activeProfileID == id {
            writesUnlocked = false
            globalError = nil
        }
    }

    func removeConnection(_ id: UUID) async {
        await disconnectSession(id)
        try? keychain.delete(account: keychainAccount(for: id))
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
