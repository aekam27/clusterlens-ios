import SwiftUI
import UIKit

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
                            if collection.type == "collection" {
                                CollectionBrowserView(database: database, collection: collection.name)
                            } else {
                                QueryWorkbenchView(database: database, collection: collection.name)
                            }
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
        .toolbar {
            NavigationLink("Manage") { CollectionActionsView(database: database, collections: collections) }
        }
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


// List creates document rows on demand. A page replaces the previous page; we
// never append an entire collection to SwiftUI state.
private struct CollectionBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let database: String
    let collection: String
    @State private var session: CollectionBrowseSession?
    @State private var window = CollectionPageWindow()
    @State private var pageTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var didStart = false
    @State private var expandedRow: Int?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("Forward scan · _id ascending")
                    .font(.subheadline.weight(.semibold))
                Text("Up to 20 documents per page. Only the current page is kept. Concurrent database changes can affect this live scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Restart") { restart() }
                        .disabled(isLoading)
                    Spacer()
                    if isLoading {
                        ProgressView()
                        Button("Cancel") { stop(message: "Read cancelled. Restart to browse again.") }
                    } else if window.page?.hasMore == true, let session {
                        Button("Next page") { load(session, start: false) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if isLoading {
                    Text("An active network call must finish or time out before another page can load.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let page = window.page {
                Section("Page \(window.pageNumber) · \(page.documents.count) \(page.documents.count == 1 ? "document" : "documents") · \(window.documentsSeen) seen") {
                    ForEach(Array(page.documents.enumerated()), id: \.offset) { index, document in
                        BrowseDocumentRow(document: document, ordinal: window.documentsSeen - page.documents.count + index + 1,
                                          isExpanded: expandedRow == index) {
                            expandedRow = expandedRow == index ? nil : index
                        }
                        .id("\(window.pageNumber)-\(index)")
                    }
                    if page.documents.isEmpty { Text("No documents found.").foregroundStyle(.secondary) }
                    if !page.hasMore && !page.documents.isEmpty {
                        Text("End of this cursor.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(collection)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            NavigationLink("Filter & export") { FindWorkspaceView(database: database, collection: collection) }
                .disabled(isLoading)
            NavigationLink("Query") { QueryWorkbenchView(database: database, collection: collection) }
                .disabled(isLoading)
        }
        .task {
            if !didStart {
                didStart = true
                restart()
            }
        }
        .onDisappear { stop(message: "Browsing paused. Restart to open a new cursor.") }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stop(message: "Browsing paused. Restart to open a new cursor.") }
        }
    }

    private func restart() {
        guard !isLoading else { return }
        stop(message: nil)
        do {
            let newSession = try model.prepareBrowsing(database: database, collection: collection)
            session = newSession
            window.begin(newSession.id)
            load(newSession, start: true)
        } catch {
            message = error.localizedDescription
        }
    }

    private func load(_ request: CollectionBrowseSession, start: Bool) {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        expandedRow = nil
        window.releasePage()
        pageTask = Task {
            defer {
                isLoading = false
                pageTask = nil
            }
            do {
                let page = try await model.loadBrowsePage(request, start: start)
                try Task.checkCancellation()
                guard session?.id == request.id else {
                    await model.closeBrowsing(request)
                    return
                }
                try window.accept(page, sessionID: request.id)
            } catch {
                await model.closeBrowsing(request)
                if session?.id == request.id {
                    session = nil
                    window.close()
                    message = error is CancellationError
                        ? "Read cancelled. Restart to browse again."
                        : "\(error.localizedDescription) Restart browsing or use Query with a filter/projection."
                }
            }
        }
    }

    private func stop(message: String?) {
        pageTask?.cancel()
        if let session { Task { await model.closeBrowsing(session) } }
        session = nil
        window.close()
        expandedRow = nil
        self.message = message
    }
}

private struct BrowseDocumentRow: View {
    let document: JSONValue
    let ordinal: Int
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var preview = ""
    @State private var isTruncated = false

    private var identifier: String {
        guard case .object(let fields) = document, let value = fields["_id"] else { return "No _id field" }
        return value.browseLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Document \(ordinal)").font(.caption).foregroundStyle(.secondary)
                        Text(identifier).font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ScrollView(.horizontal) {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
                if isTruncated {
                    Text("Showing the first 16,384 characters. Copy includes the complete document.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Copy document") { UIPasteboard.general.string = document.prettyPrinted }
                    .font(.caption)
            }
        }
        .onChange(of: isExpanded, initial: true) { _, expanded in
            if expanded {
                let formatted = document.prettyPrinted
                preview = String(formatted.prefix(16_384))
                isTruncated = formatted.count > 16_384
            } else {
                preview = ""
                isTruncated = false
            }
        }
    }
}
