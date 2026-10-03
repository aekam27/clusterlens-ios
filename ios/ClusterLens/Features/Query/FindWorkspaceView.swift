import SwiftUI

struct FindWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let database: String
    let collection: String
    @State private var rules: [FilterRule] = []
    @State private var any = false
    @State private var rawMode = false
    @State private var rawFilter = "{}"
    @State private var fields = ""
    @State private var descending = false
    @State private var format: DataExportFormat = .json
    @State private var rowLimit = "1000"
    @State private var message: String?
    @State private var session: CollectionBrowseSession?
    @State private var page: CollectionPage?
    @State private var pageNumber = 0
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var exporting = false
    @State private var progressRows = 0
    @State private var progressBytes = 0
    @State private var pendingExport: DataExportRequest?
    @State private var exportResult: DataExportResult?
    @State private var showResetBuilder = false

    var body: some View {
        Form {
            Section {
                Text("\(database).\(collection)").font(.caption).textSelection(.enabled)
                Text("Find, preview and export matching documents.").foregroundStyle(.secondary)
                Button(rawMode ? "Start a new visual filter" : "Edit as raw JSON") {
                    if rawMode { showResetBuilder = true }
                    else {
                        do { rawFilter = try FindQuery.build(rules: rules, any: any); rawMode = true }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            Section(rawMode ? "Raw MongoDB filter" : "Visual filter") {
                if rawMode {
                    TextEditor(text: $rawFilter).font(.system(.body, design: .monospaced)).frame(minHeight: 150)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Raw MongoDB filter JSON")
                    Text("JSON / Extended JSON only. Shell functions and JavaScript are not executed. Raw filters are preserved; returning to the builder starts a new filter.")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu("Filter templates") {
                        Button("Match all") { rawFilter = "{}" }
                        Button("Field equals text") { rawFilter = "{\"status\": {\"$eq\": \"active\"}}" }
                        Button("ObjectId") { rawFilter = "{\"_id\": {\"$oid\": \"507f1f77bcf86cd799439011\"}}" }
                        Button("Date range") { rawFilter = "{\"createdAt\": {\"$gte\": {\"$date\": \"2026-01-01T00:00:00Z\"}}}" }
                        Button("Text pattern") { rawFilter = "{\"name\": {\"$regularExpression\": {\"pattern\": \"^A\", \"options\": \"i\"}}}" }
                    }
                } else {
                    Picker("Match", selection: $any) { Text("All conditions").tag(false); Text("Any condition").tag(true) }
                    ForEach($rules) { $rule in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Field, e.g. status", text: $rule.field)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel("Filter field")
                            Picker("Operator", selection: $rule.operation) {
                                ForEach(FilterOperator.allCases) { Text($0.title).tag($0) }
                            }
                            if rule.operation != .exists && rule.operation != .oneOf {
                                Picker("Value type", selection: $rule.type) { ForEach(FilterValueType.allCases) { Text($0.rawValue).tag($0) } }
                            }
                            if rule.type != .null || rule.operation == .exists || rule.operation == .oneOf {
                                TextField(rule.operation == .exists ? "true or false" : (rule.operation == .oneOf ? "JSON array, e.g. [1, 2]" : "Value"), text: $rule.value)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Filter value")
                            }
                            Button("Remove condition", role: .destructive) { rules.removeAll { $0.id == rule.id } }
                        }
                    }
                    Button("Add condition") { rules.append(FilterRule()) }.disabled(rules.count >= 30)
                    if rules.isEmpty { Text("No conditions: matches every document.").font(.caption) }
                }
            }
            .disabled(busy)
            Section("Columns and ordering") {
                TextField("All fields, or comma-separated paths", text: $fields, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Selected columns")
                if let suggestions = suggestedFields, !suggestions.isEmpty {
                    Menu("Choose from this preview") {
                        ForEach(suggestions, id: \.self) { field in
                            Button(field) { toggleField(field) }
                        }
                    }
                    Text("Suggestions come from this page and may omit fields in other documents.").font(.caption)
                }
                Text("Blank selects all fields for JSON. CSV requires explicit columns. Use dotted paths for nested objects; _id is included only when selected. CSV array traversal is not supported.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("_id descending", isOn: $descending)
                Text("Live scan with simple collation; concurrent changes can affect results.").font(.caption).foregroundStyle(.secondary)
            }.disabled(busy)
            Section("Preview") {
                Button("Apply filter and preview") { preview(start: true) }.disabled(busy)
                if let page {
                    Text("Page \(pageNumber) · \(page.documents.count) documents")
                    ForEach(Array(page.documents.enumerated()), id: \.offset) { _, document in
                        DisclosureGroup(document.browseLabelForDocument) {
                            Text(String(document.prettyPrinted.prefix(16_384))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if document.prettyPrinted.count > 16_384 { Text("Preview shortened; use export for the complete document.").font(.caption) }
                        }
                    }
                    if page.documents.isEmpty { Text("No documents found.") }
                    if page.hasMore { Button("Next preview page") { preview(start: false) }.disabled(busy) }
                    else { Text("End of this cursor.").font(.caption) }
                    Text("Changes above take effect when you apply the filter again. Next page uses the captured filter.").font(.caption)
                }
            }
            Section("Export matching documents") {
                Picker("Format", selection: $format) { ForEach(DataExportFormat.allCases) { Text($0.rawValue).tag($0) } }.disabled(busy)
                TextField("Rows, 1–10,000", text: $rowLimit).keyboardType(.numberPad).disabled(busy).accessibilityLabel("Maximum export rows")
                Text("Reads new pages from the database, beyond the visible preview. Maximum 10,000 rows and 50 MiB; no total-count query is run. JSON retains canonical BSON types. CSV uses fixed columns, Extended JSON for typed values, and prefixes potentially executable spreadsheet cells with an apostrophe.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review export…") { prepareExport() }.disabled(busy)
                if exporting { Text("\(progressRows) rows · \(progressBytes.formatted()) bytes written").monospacedDigit() }
                if let exportResult {
                    Text("\(exportResult.request.database).\(exportResult.request.collection) · \(exportResult.request.query.fields.isEmpty ? "All fields" : exportResult.request.query.fields.joined(separator: ", "))").font(.caption)
                    Text(exportResult.summary).font(.footnote)
                    ShareLink("Save or share \(exportResult.request.format.rawValue)", item: exportResult.url)
                    Text("This temporary file is removed when you leave this screen or start another export. Save a copy using the share sheet.").font(.caption)
                }
            }
            if busy {
                Section {
                    ProgressView(exporting ? "Exporting…" : "Reading…")
                    Button("Cancel read") { task?.cancel() }
                    Text("An active network call may finish or time out before cancellation completes. Partial exports are discarded.").font(.caption)
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary).textSelection(.enabled) } }
        }
        .navigationTitle("Filter & export").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .alert("Start a new visual filter?", isPresented: $showResetBuilder) {
            Button("Keep raw filter", role: .cancel) {}
            Button("Start new filter", role: .destructive) { rules = []; any = false; rawMode = false; rawFilter = "{}" }
        } message: { Text("The raw filter cannot be safely imported into this limited builder. This replaces it with an empty filter.") }
        .confirmationDialog("Export matching documents?", isPresented: Binding(get: { pendingExport != nil }, set: { if !$0 { pendingExport = nil } }), titleVisibility: .visible) {
            if let request = pendingExport {
                Button("Export up to \(request.rowLimit) rows") { pendingExport = nil; export(request) }
                Button("Cancel", role: .cancel) { pendingExport = nil }
            }
        } message: {
            if let request = pendingExport {
                Text("\(model.profile?.name ?? "Connection") · \(request.database).\(request.collection)\n\(request.format.rawValue), \(request.query.fields.isEmpty ? "all fields" : request.query.fields.joined(separator: ", ")). Current filter, ordered by _id. Up to \(request.rowLimit) rows; actual total and file size are unknown. This is a new live scan.")
            }
        }
        .onDisappear { stop(); discardExport() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
    }

    private var suggestedFields: [String]? {
        page.map { Array(Set($0.documents.flatMap { if case .object(let fields) = $0 { return Array(fields.keys) }; return [] })).sorted() }
    }
    private func toggleField(_ field: String) {
        var selected = fields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if selected.contains(field) { selected.removeAll { $0 == field } } else { selected.append(field) }
        fields = selected.joined(separator: ", ")
    }
    private func query() throws -> FindQuery {
        try FindQuery(rawFilter: rawMode ? rawFilter : FindQuery.build(rules: rules, any: any), fields: fields, descending: descending)
    }
    private func preview(start: Bool) {
        do {
            if start {
                if let session { Task { await model.closeBrowsing(session) } }
                session = try model.prepareBrowsing(database: database, collection: collection, query: query()); pageNumber = 0
            }
            guard let session else { throw ClientError.notConnected }
            page = nil; message = nil; busy = true
            task = Task {
                defer { busy = false; task = nil }
                do { page = try await model.loadBrowsePage(session, start: start); try Task.checkCancellation(); pageNumber += 1 }
                catch { page = nil; message = error is CancellationError ? "Read cancelled. Apply the filter again to restart." : error.localizedDescription; await model.closeBrowsing(session); self.session = nil }
            }
        } catch { message = error.localizedDescription }
    }
    private func prepareExport() {
        do {
            guard let id = model.activeProfileID, let limit = Int(rowLimit) else { throw FindQuery.invalid("Enter a whole-number row limit.") }
            pendingExport = try DataExportRequest(connectionID: id, database: database, collection: collection, query: query(), format: format, rowLimit: limit)
        } catch { message = error.localizedDescription }
    }
    private func export(_ request: DataExportRequest) {
        discardExport(); page = nil; message = nil; busy = true; exporting = true; progressRows = 0; progressBytes = 0
        if let session { Task { await model.closeBrowsing(session) } }; session = nil
        task = Task {
            defer { busy = false; exporting = false; task = nil }
            do {
                exportResult = try await model.exportData(request) { rows, bytes in
                    Task { @MainActor in progressRows = rows; progressBytes = bytes }
                }
            } catch { message = error is CancellationError ? "Export cancelled. The partial file was discarded." : error.localizedDescription }
        }
    }
    private func stop() {
        task?.cancel()
        if let session { Task { await model.closeBrowsing(session) } }
        session = nil
    }
    private func discardExport() { if let result = exportResult { try? FileManager.default.removeItem(at: result.url) }; exportResult = nil }
}

private extension JSONValue {
    var browseLabelForDocument: String {
        if case .object(let object) = self, let id = object["_id"] { return id.browseLabel }
        return "Document · expand to inspect"
    }
}
