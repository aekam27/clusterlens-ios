import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var authError: String?
    @State private var showsConnections = false
    @State private var confirmDisconnectSession = false
    @State private var confirmRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                if let profile = model.profile {
                    Section("Connection") {
                        LabeledContent("Name", value: profile.name)
                        LabeledContent("Cluster") {
                            Text(profile.host)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        LabeledContent("Discovery", value: profile.usesSRV ? "DNS SRV" : "Seed hosts")
                        LabeledContent("Status", value: connectionStatusTitle)
                        Button("Manage \(model.profiles.count) saved connection\(model.profiles.count == 1 ? "" : "s")") {
                            showsConnections = true
                        }
                    }
                }

                Section {
                    HStack {
                        Label("Write queries", systemImage: model.writesUnlocked ? "lock.open.fill" : "lock.fill")
                        Spacer()
                        StatusPill(
                            title: model.writesUnlocked ? "Unlocked" : "Locked",
                            color: model.writesUnlocked ? .orange : .green
                        )
                    }

                    if model.writesUnlocked {
                        Button("Lock write queries", action: model.lockWrites)
                    } else {
                        Button("Unlock with Face ID / passcode") {
                            Task { await unlockWrites() }
                        }
                    }

                    if let authError {
                        Text(authError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Writes relock whenever the app leaves the foreground. Your MongoDB user's roles remain the final permission boundary.")
                }

                Section("Privacy") {
                    Label("URIs stored in the device-bound Keychain", systemImage: "key.fill")
                    Label("Profiles and history excluded from backups", systemImage: "externaldrive.badge.xmark")
                    Label("Local files use complete protection", systemImage: "lock.doc.fill")
                    Label("No proxy or gateway involved", systemImage: "arrow.left.arrow.right")
                }

                Section("About") {
                    LabeledContent("Version", value: "0.3.0")
                    LabeledContent("Client", value: "Native SwiftUI")
                    LabeledContent("Transport", value: "MongoDB wire protocol + TLS")
                }

                Section {
                    if model.activeConnectionStatus.isConnected {
                        Button("Disconnect active session") {
                            confirmDisconnectSession = true
                        }
                    } else if let id = model.activeProfileID {
                        Button("Reconnect active session") {
                            Task { await model.reconnect(id) }
                        }
                    }
                    Button("Remove saved connection", role: .destructive) {
                        confirmRemoval = true
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showsConnections) {
                ConnectionManagerView()
                    .environmentObject(model)
            }
            .confirmationDialog("Disconnect this session?", isPresented: $confirmDisconnectSession) {
                Button("Disconnect") {
                    if let id = model.activeProfileID {
                        Task { await model.disconnectSession(id) }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The connection remains saved on this iPhone and can be reconnected later.")
            }
            .confirmationDialog("Remove this saved connection?", isPresented: $confirmRemoval) {
                Button("Remove from this iPhone", role: .destructive) {
                    if let id = model.activeProfileID {
                        Task { await model.removeConnection(id) }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes its URI from the Keychain and removes its local query history.")
            }
        }
    }

    private var connectionStatusTitle: String {
        switch model.activeConnectionStatus {
        case .saved: "Saved"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Needs attention"
        }
    }

    private func unlockWrites() async {
        authError = nil
        do {
            try await model.unlockWrites()
        } catch {
            authError = error.localizedDescription
        }
    }
}
