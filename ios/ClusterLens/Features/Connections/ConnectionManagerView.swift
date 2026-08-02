import SwiftUI

struct ConnectionManagerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAddConnection = false
    @State private var pendingRemoval: ConnectionProfile?

    private var connectedCount: Int {
        model.profiles.filter { model.connectionStates[$0.id]?.isConnected == true }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.profiles) { profile in
                        ConnectionRow(
                            profile: profile,
                            status: model.connectionStates[profile.id] ?? .saved,
                            isActive: profile.id == model.activeProfileID
                        ) {
                            Task {
                                await model.activate(profile.id)
                                dismiss()
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                pendingRemoval = profile
                            }
                            if model.connectionStates[profile.id]?.isConnected == true {
                                Button("Disconnect", systemImage: "bolt.slash") {
                                    Task { await model.disconnectSession(profile.id) }
                                }
                                .tint(.orange)
                            } else {
                                Button("Reconnect", systemImage: "arrow.clockwise") {
                                    Task { await model.reconnect(profile.id) }
                                }
                                .tint(.blue)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Connections")
                        Spacer()
                        Text("\(connectedCount) live")
                            .textCase(nil)
                    }
                } footer: {
                    Text("Live sessions stay open while you switch between clusters. Write access relocks on every switch.")
                }

                Section {
                    Button {
                        showsAddConnection = true
                    } label: {
                        Label("Add connection", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                }

                Section("On-device privacy") {
                    Label("URIs use device-bound Keychain storage", systemImage: "iphone.and.arrow.forward")
                    Label("Connection metadata is excluded from backups", systemImage: "externaldrive.badge.xmark")
                    Label("Nothing is synced through ClusterLens", systemImage: "icloud.slash")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsAddConnection = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showsAddConnection) {
                SetupView(mode: .additionalConnection)
                    .environmentObject(model)
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.name ?? "connection")?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                presenting: pendingRemoval
            ) { profile in
                Button("Remove from this iPhone", role: .destructive) {
                    Task {
                        await model.removeConnection(profile.id)
                        pendingRemoval = nil
                        if model.profiles.isEmpty { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { profile in
                Text("This deletes \(profile.name)'s saved URI from the Keychain and removes its local query history.")
            }
        }
    }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile
    let status: ConnectionStatus
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(status.tint.opacity(0.12))
                    Image(systemName: "server.rack")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(status.tint)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }
                    }
                    Text(profile.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(status.title, systemImage: status.symbol)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(status.tint)
                }

                Spacer()
                if case .connecting = status {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension ConnectionStatus {
    var title: String {
        switch self {
        case .saved: "Saved on device"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .saved: "bookmark.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .saved: .secondary
        case .connecting: .blue
        case .connected: .green
        case .failed: .orange
        }
    }
}
