import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = "My Cluster"
    @State private var connectionString = ""
    @State private var revealsConnectionString = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        AppMark(size: 72)
                        Text("Your cluster,\nin your pocket.")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .tracking(-0.8)
                        Text("Connect straight to MongoDB, browse databases, and run queries from your iPhone—no gateway required.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }

                    SectionCard {
                        VStack(alignment: .leading, spacing: 15) {
                            Label("Direct cluster connection", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 7) {
                                Text("NAME").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                TextField("Production", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("MONGODB CONNECTION STRING")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(revealsConnectionString ? "Hide" : "Show") {
                                        revealsConnectionString.toggle()
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                                Group {
                                    if revealsConnectionString {
                                        TextField("mongodb+srv://user:password@cluster…", text: $connectionString)
                                    } else {
                                        SecureField("mongodb+srv://user:password@cluster…", text: $connectionString)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            }

                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Button {
                                Task { await connect() }
                            } label: {
                                HStack {
                                    if isConnecting { ProgressView().tint(.white) }
                                    Text(isConnecting ? "Connecting to MongoDB…" : "Connect directly")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(isConnecting || connectionString.isEmpty)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Your full connection string is stored only in the iOS Keychain.", systemImage: "key.fill")
                        Label("Atlas must allow this iPhone's current public IP in Network Access.", systemImage: "network.badge.shield.half.filled")
                        Label("Use a dedicated database user with the minimum permissions you need.", systemImage: "person.badge.shield.checkmark")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                }
                .padding(22)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await model.connect(name: name, connectionString: connectionString)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
