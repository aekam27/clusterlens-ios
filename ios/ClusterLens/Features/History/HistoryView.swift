import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView(
                        "No query history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Successful queries appear here and stay protected by iOS file encryption.")
                    )
                } else {
                    List(model.history) { entry in
                        NavigationLink {
                            QueryWorkbenchView(
                                database: entry.database,
                                collection: entry.collection,
                                initialOperation: entry.operation,
                                initialInput: entry.input
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.operation.symbol)
                                    .foregroundStyle(entry.operation.isWrite ? Color.orange : Color.accentColor)
                                    .frame(width: 30, height: 30)
                                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(entry.operation.title).font(.body.weight(.semibold))
                                        Text("·").foregroundStyle(.tertiary)
                                        Text("\(entry.elapsedMS.formatted()) ms")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(entry.database).\(entry.collection)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(entry.date, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !model.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Clear query history?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive, action: model.clearHistory)
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}
