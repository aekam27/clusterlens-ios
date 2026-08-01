import Foundation
import LocalAuthentication

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profile: ConnectionProfile?
    @Published private(set) var databases: [DatabaseInfo] = []
    @Published private(set) var history: [QueryHistoryEntry] = []
    @Published private(set) var writesUnlocked = false
    @Published private(set) var isBootstrapping = true
    @Published var globalError: String?

    private let keychain = KeychainService()
    private let defaults = UserDefaults.standard
    private let profileKey = "direct-connection-profile-v2"
    private let uriAccount = "mongodb-connection-string"
    private let client = MongoDirectClient()

    func bootstrap() async {
        defer { isBootstrapping = false }
        history = loadHistory()
        guard let profileData = defaults.data(forKey: profileKey),
              let storedProfile = try? JSONDecoder().decode(ConnectionProfile.self, from: profileData),
              let uri = try? keychain.read(account: uriAccount) else { return }
        profile = storedProfile
        do {
            try await client.connect(uri: uri)
            databases = try await client.databases()
        } catch {
            globalError = connectionHelp(for: error)
        }
    }

    func connect(name: String, connectionString: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURI = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ClientError.invalidConnectionString }
        let summary = try MongoConnectionString.summary(for: trimmedURI)

        try await client.connect(uri: trimmedURI)
        let fetchedDatabases = try await client.databases()
        let newProfile = ConnectionProfile(
            name: trimmedName,
            host: summary.host,
            usesSRV: summary.usesSRV
        )
        try keychain.save(trimmedURI, account: uriAccount)
        defaults.set(try JSONEncoder().encode(newProfile), forKey: profileKey)
        profile = newProfile
        databases = fetchedDatabases
        globalError = nil
    }

    func refreshDatabases() async {
        guard profile != nil else { return }
        do {
            databases = try await client.databases()
            globalError = nil
        } catch {
            globalError = connectionHelp(for: error)
        }
    }

    func fetchCollections(database: String) async throws -> [CollectionInfo] {
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
        let execution = try await client.runQuery(
            database: database,
            collection: collection,
            operation: operation,
            input: input
        )
        let entry = QueryHistoryEntry(
            id: UUID(),
            date: Date(),
            database: database,
            collection: collection,
            operation: operation,
            input: sourceText,
            elapsedMS: execution.elapsedMS
        )
        history.insert(entry, at: 0)
        history = Array(history.prefix(50))
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
        history = []
        saveHistory()
    }

    func disconnect() {
        try? keychain.delete(account: uriAccount)
        defaults.removeObject(forKey: profileKey)
        profile = nil
        databases = []
        writesUnlocked = false
        globalError = nil
        Task { await client.disconnect() }
    }

    private var historyURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("ClusterLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("query-history.json")
    }

    private func loadHistory() -> [QueryHistoryEntry] {
        guard let url = historyURL,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data) else { return [] }
        return entries
    }

    private func saveHistory() {
        guard let url = historyURL,
              let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func connectionHelp(for error: Error) -> String {
        let message = error.localizedDescription
        let lowercased = message.lowercased()
        if lowercased.contains("authentication") || lowercased.contains("auth failed") {
            return "Authentication failed. Check the username, password, authSource, and percent-encode special characters in credentials."
        }
        if lowercased.contains("server selection") || lowercased.contains("timed out") {
            return "The cluster could not be reached. Add this iPhone's current public IP to Atlas Network Access and confirm the cluster is running."
        }
        if lowercased.contains("dns") || lowercased.contains("srv") {
            return "Atlas DNS discovery failed. Check the mongodb+srv hostname and try a network that allows DNS SRV lookups."
        }
        return message
    }
}
