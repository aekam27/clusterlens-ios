import SwiftUI
import UIKit

struct QueryWorkbenchView: View {
    @EnvironmentObject private var model: AppModel
    let database: String
    let collection: String

    @State private var operation: QueryOperation
    @State private var editorText: String
    @State private var execution: QueryExecution?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var showWriteConfirmation = false
    @State private var pendingWrite: QueryRequest?
    @State private var queryTask: Task<Void, Never>?
    @State private var runningOperation: QueryOperation?
    @State private var cancellationRequested = false

    init(
        database: String,
        collection: String,
        initialOperation: QueryOperation = .find,
        initialInput: String? = nil
    ) {
        self.database = database
        self.collection = collection
        _operation = State(initialValue: initialOperation)
        _editorText = State(initialValue: initialInput ?? initialOperation.template)
    }

    private var availableOperations: [QueryOperation] {
        QueryOperation.allCases.filter { !$0.isCollectionAction && (!$0.isWrite || model.writesUnlocked) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Label(database, systemImage: "cylinder")
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Label(collection, systemImage: "tablecells")
                    Spacer()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                NavigationLink { FindWorkspaceView(database: database, collection: collection) } label: {
                    Label("Build a filter, choose columns & export", systemImage: "line.3.horizontal.decrease")
                }
                Text("Raw operation input: JSON / Extended JSON only. MongoDB shell code is not executed.")
                    .font(.caption).foregroundStyle(.secondary)

                SectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Operation").font(.headline)
                            Spacer()
                            Picker("Operation", selection: $operation) {
                                ForEach(availableOperations) { item in
                                    Label(item.title, systemImage: item.symbol).tag(item)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(isRunning)
                        }

                        Divider()

                        TextEditor(text: $editorText)
                            .disabled(isRunning)
                            .codeEditorStyle()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 235)
                            .padding(10)
                            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )

                        HStack {
                            Label("Extended JSON supported", systemImage: "curlybraces")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Format", action: formatEditor)
                                .font(.caption.weight(.medium))
                                .disabled(isRunning)
                        }

                        Button(action: prepareAndRun) {
                            HStack {
                                if isRunning { ProgressView().tint(.white) }
                                Label(isRunning ? "Running…" : "Run \(operation.title)", systemImage: "play.fill")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(operation.isWrite ? .orange : .accentColor)
                        .disabled(isRunning)

                        if isRunning && runningOperation?.isWrite == false {
                            Button(cancellationRequested ? "Cancellation requested…" : "Cancel read") {
                                cancellationRequested = true
                                queryTask?.cancel()
                            }
                            .disabled(cancellationRequested)
                            Text("An in-flight network call must finish or time out before another query can run.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                if let execution {
                    QueryResultView(execution: execution)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(collection)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: operation) { _, value in
            editorText = value.template
            execution = nil
            errorMessage = nil
        }
        .confirmationDialog(
            "Run \(pendingWrite?.operation.title ?? "write")?",
            isPresented: $showWriteConfirmation,
            titleVisibility: .visible
        ) {
            if let request = pendingWrite {
                Button("Run write query", role: .destructive) {
                    pendingWrite = nil
                    start(request, writeConfirmed: true)
                }
            }
            Button("Cancel", role: .cancel) { pendingWrite = nil }
        } message: {
            if let request = pendingWrite {
                Text("This changes data in \(request.database).\(request.collection) and may not be reversible. It runs the query captured when you tapped Run.")
            }
        }
        .onChange(of: model.writesUnlocked) { _, unlocked in
            if !unlocked {
                pendingWrite = nil
                showWriteConfirmation = false
            }
        }
        .onDisappear {
            pendingWrite = nil
            if runningOperation?.isWrite == false { queryTask?.cancel() }
        }
    }

    private func parsedInput() throws -> [String: JSONValue] {
        guard editorText.utf8.count <= QuerySafety.maximumInputBytes else {
            throw QuerySafety.Violation(message: "Query input exceeds the 256 KiB mobile limit.")
        }
        try StrictJSON.validate(editorText)
        guard let data = editorText.data(using: .utf8) else { throw ClientError.encoding }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func formatEditor() {
        do {
            let input = try parsedInput()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(input)
            editorText = String(decoding: data, as: UTF8.self)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareAndRun() {
        do {
            let request = try model.prepareQuery(database: database, collection: collection,
                                                 operation: operation, sourceText: editorText)
            if request.operation.isWrite {
                pendingWrite = request
                showWriteConfirmation = true
            } else {
                start(request)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func start(_ request: QueryRequest, writeConfirmed: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        runningOperation = request.operation
        cancellationRequested = false
        execution = nil
        errorMessage = nil
        queryTask = Task { await run(request, writeConfirmed: writeConfirmed) }
    }

    private func run(_ request: QueryRequest, writeConfirmed: Bool) async {
        defer {
            isRunning = false
            runningOperation = nil
            queryTask = nil
        }
        do {
            let result = try await model.runQuery(request, writeConfirmed: writeConfirmed)
            if model.activeProfileID == request.connectionID { execution = result }
        } catch is CancellationError {
            errorMessage = request.operation.isWrite ? "Write cancelled before dispatch." : "Read cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private struct QueryResultView: View {
    let execution: QueryExecution
    @State private var copied = false

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Result").font(.headline)
                    Spacer()
                    StatusPill(title: "\(execution.elapsedMS.formatted()) ms", color: .green)
                    Button {
                        UIPasteboard.general.string = execution.result.prettyPrinted
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy result")
                }

                if execution.operation == "find" || execution.operation == "aggregate" {
                    Text("Bounded preview: up to 100 documents. This may not include every match. Use a filter or projection to narrow results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    Text(execution.result.prettyPrinted)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(Color(red: 0.82, green: 0.90, blue: 0.86))
                        .padding(14)
                }
                .frame(maxHeight: 440)
                .background(Color(red: 0.055, green: 0.065, blue: 0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
