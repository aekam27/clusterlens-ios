import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let profile = model.profile {
                    Section {
                        HStack(spacing: 12) {
                            AppMark(size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).font(.headline)
                                Text(profile.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            StatusPill(title: "Connected", color: .green)
                        }
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
                    if model.databases.isEmpty && model.globalError == nil {
                        HStack {
                            Spacer()
                            ProgressView("Loading databases…")
                            Spacer()
                        }
                        .padding(.vertical, 20)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refreshDatabases() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
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
