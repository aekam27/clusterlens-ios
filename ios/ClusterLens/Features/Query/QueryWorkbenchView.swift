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
        QueryOperation.allCases.filter { !$0.isWrite || model.writesUnlocked }
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
                        }

                        Divider()

                        TextEditor(text: $editorText)
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
                        }

                        Button {
                            if operation.isWrite {
                                showWriteConfirmation = true
                            } else {
                                Task { await run() }
                            }
                        } label: {
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
            "Run \(operation.title)?",
            isPresented: $showWriteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run write query", role: .destructive) { Task { await run() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This changes data in \(database).\(collection) and may not be reversible.")
        }
    }

    private func parsedInput() throws -> [String: JSONValue] {
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
            errorMessage = "The editor does not contain a valid JSON object."
        }
    }

    private func run() async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            execution = try await model.runQuery(
                database: database,
                collection: collection,
                operation: operation,
                input: parsedInput(),
                sourceText: editorText
            )
        } catch let error as DecodingError {
            errorMessage = "Invalid JSON: \(error.localizedDescription)"
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
