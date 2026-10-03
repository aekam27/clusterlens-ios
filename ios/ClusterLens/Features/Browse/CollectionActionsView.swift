import SwiftUI

struct CollectionActionsView: View {
    @EnvironmentObject private var model: AppModel
    let database: String
    let collections: [CollectionInfo]
    @State private var operation: QueryOperation = .createCollection
    @State private var name = ""
    @State private var typedNamespace = ""
    @State private var pending: QueryRequest?
    @State private var message: String?
    @State private var running = false

    private var namespace: String { "\(database).\(name)" }

    var body: some View {
        Form {
            Section("Target") {
                Text(model.profile?.name ?? "No connection").font(.headline)
                Text(model.profile?.host ?? "").font(.caption).textSelection(.enabled)
                LabeledContent("Database", value: database)
                Picker("Action", selection: $operation) {
                    Text("Create collection").tag(QueryOperation.createCollection)
                    Text("Drop collection").tag(QueryOperation.dropCollection)
                }
                if operation == .createCollection {
                    TextField("New collection name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Creates an ordinary empty collection. Views, validators, capped and time-series options are not configured here.").font(.caption)
                } else {
                    Picker("Collection", selection: $name) {
                        Text("Choose one collection").tag("")
                        ForEach(collections.filter { $0.type == "collection" }) { Text($0.name).tag($0.name) }
                    }
                    Text("Dropping removes the collection, all documents and its indexes. This cannot be undone by ClusterLens.")
                        .foregroundStyle(.red)
                    Text("Type exactly: \(namespace)").textSelection(.enabled)
                    TextField("database.collection", text: $typedNamespace)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Confirm exact namespace to drop")
                }
            }.disabled(running)
            Section("Write protection") {
                Label(model.writesUnlocked ? "Writes unlocked" : "Read-only: writes locked", systemImage: model.writesUnlocked ? "lock.open" : "lock")
                if !model.writesUnlocked {
                    Button("Unlock with Face ID / passcode") {
                        Task { do { try await model.unlockWrites() } catch { message = error.localizedDescription } }
                    }.disabled(running)
                }
                Text("Database permissions are still required. The final confirmation captures this exact connection and namespace. No automatic retry is performed.").font(.caption)
                Button(operation == .dropCollection ? "Review drop…" : "Review create…", role: operation == .dropCollection ? .destructive : nil) { prepare() }
                    .disabled(running || !model.writesUnlocked || name.isEmpty || (operation == .dropCollection && typedNamespace != namespace))
            }
            if running { ProgressView("Waiting for the server’s result…") }
            if let message { Section { Text(message).textSelection(.enabled) } }
        }
        .navigationTitle("Manage collections").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Confirm collection action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let request = pending {
                Button("\(request.operation.title): \(request.database).\(request.collection)", role: request.operation == .dropCollection ? .destructive : nil) {
                    pending = nil; perform(request)
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            if let request = pending {
                Text("\(model.profile?.name ?? "Connection") · \(model.profile?.host ?? "")\n\(request.database).\(request.collection)\n" + (request.operation == .dropCollection ? "Permanently remove this collection, its documents and indexes?" : "Create this empty collection?"))
            }
        }
        .onChange(of: operation) { _, _ in name = ""; typedNamespace = ""; pending = nil; message = nil }
        .onChange(of: model.writesUnlocked) { _, unlocked in if !unlocked { pending = nil } }
        .onChange(of: model.activeProfileID) { _, _ in pending = nil }
        .onDisappear { pending = nil }
    }

    private func prepare() {
        do {
            let source = JSONValue.object(["confirmNamespace": .string(operation == .dropCollection ? typedNamespace : namespace)]).prettyPrinted
            pending = try model.prepareQuery(database: database, collection: name, operation: operation, sourceText: source)
        } catch { message = error.localizedDescription }
    }
    private func perform(_ request: QueryRequest) {
        running = true; message = nil
        Task {
            defer { running = false }
            do {
                _ = try await model.runQuery(request, writeConfirmed: true)
                message = "Server acknowledged \(request.operation.title) for \(request.database).\(request.collection). Return to the collection list to refresh it."
                name = ""; typedNamespace = ""
            } catch {
                message = "\(error.localizedDescription)\nIf dispatch had begun, a network failure may leave the outcome unknown. Check the collection list and permissions before retrying; this action was not automatically repeated."
            }
        }
    }
}
