import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsConnections = false

    var body: some View {
        NavigationStack {
            List {
                if let profile = model.profile {
                    Section {
                        Button {
                            showsConnections = true
                        } label: {
                            HStack(spacing: 12) {
                                AppMark(size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(profile.name).font(.headline)
                                        if model.profiles.count > 1 {
                                            Text("\(model.profiles.count)")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.tint)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                                        }
                                    }
                                    Text(profile.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                connectionStatus
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }

                if let error = model.globalError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Databases") {
                    if case .connecting = model.activeConnectionStatus, model.databases.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView("Connecting…")
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if !model.activeConnectionStatus.isConnected {
                        Button {
                            if let id = model.activeProfileID {
                                Task { await model.reconnect(id) }
                            }
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 10)
                    } else if model.databases.isEmpty {
                        ContentUnavailableView(
                            "No databases",
                            systemImage: "cylinder",
                            description: Text("This MongoDB user may not have access to any databases.")
                        )
                    } else {
                        ForEach(model.databases) { database in
                            NavigationLink {
                                CollectionListView(database: database.name)
                            } label: {
                                Label(database.name, systemImage: "cylinder")
                                    .font(.body.weight(.medium))
                                    .padding(.vertical, 5)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Browse")
            .refreshable { await model.refreshDatabases() }
            .sheet(isPresented: $showsConnections) {
                ConnectionManagerView()
                    .environmentObject(model)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsConnections = true } label: {
                        Image(systemName: "server.rack")
                    }
                    .accessibilityLabel("Manage connections")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refreshDatabases() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.activeConnectionStatus {
        case .saved:
            StatusPill(title: "Saved", color: .secondary)
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected:
            StatusPill(title: "Connected", color: .green)
        case .failed:
            StatusPill(title: "Offline", color: .orange)
        }
    }
}

private struct CollectionListView: View {
    @EnvironmentObject private var model: AppModel
    let database: String
    @State private var collections: [CollectionInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading collections…")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn’t load collections",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if collections.isEmpty {
                ContentUnavailableView("No collections", systemImage: "tray")
            } else {
                Section("\(collections.count) collections") {
                    ForEach(collections) { collection in
                        NavigationLink {
                            QueryWorkbenchView(database: database, collection: collection.name)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: collection.type == "view" ? "rectangle.stack" : "tablecells")
                                    .foregroundStyle(.tint)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.name).font(.body.weight(.medium))
                                    Text(collection.type.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle(database)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            collections = try await model.fetchCollections(database: database)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
