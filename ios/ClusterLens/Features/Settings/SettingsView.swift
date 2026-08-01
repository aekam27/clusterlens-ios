import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var authError: String?
    @State private var confirmDisconnect = false

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
                    Label("Connection string stored in Keychain", systemImage: "key.fill")
                    Label("History uses complete file protection", systemImage: "lock.doc.fill")
                    Label("No proxy or gateway involved", systemImage: "arrow.left.arrow.right")
                }

                Section("About") {
                    LabeledContent("Version", value: "0.2.0")
                    LabeledContent("Client", value: "Native SwiftUI")
                    LabeledContent("Transport", value: "MongoDB wire protocol + TLS")
                }

                Section {
                    Button("Disconnect cluster", role: .destructive) {
                        confirmDisconnect = true
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Disconnect this cluster?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive, action: model.disconnect)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The connection string will be removed from this iPhone. Query history is retained until you clear it.")
            }
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
