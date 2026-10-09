import SwiftUI

struct SavedFindPresetsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let context: FindPresetContext
    let load: (SavedFindPreset) -> Void
    @State private var renaming: SavedFindPreset?
    @State private var newName = ""
    @State private var deleting: SavedFindPreset?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.profile?.name ?? "Connection").font(.headline)
                    Text("\(context.database).\(context.collection)").font(.caption).textSelection(.enabled)
                    Text("Load copies the filter, columns and _id sort into the editor. It does not run a query or export.").font(.footnote)
                }
                if let error = model.presetStorageError {
                    Section("Storage unavailable") {
                        Text(error).foregroundStyle(.red)
                        Button("Retry loading saved queries") { model.reloadFindPresets() }
                    }
                }
                Section("Saved in this collection") {
                    let presets = model.findPresets(in: context)
                    if presets.isEmpty {
                        ContentUnavailableView("No saved queries", systemImage: "bookmark", description: Text("Return to Filter & export, configure a query, then save it with a name."))
                    }
                    ForEach(presets) { preset in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preset.name).font(.headline)
                            Text("\(preset.fields.isEmpty ? "All fields" : preset.fields.joined(separator: ", ")) · _id \(preset.descending ? "descending" : "ascending")")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Inspect saved filter") {
                                Text(String(preset.filterJSON.prefix(4096))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if preset.filterJSON.count > 4096 {
                                    Text("Preview limited to 4,096 characters. Load settings to inspect the complete filter in the editor.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack { controls(preset) }
                                VStack(alignment: .leading) { controls(preset) }
                            }
                        }.buttonStyle(.borderless).padding(.vertical, 4)
                    }
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
                Section {
                    Text("Stored only on this device, with the current connection identity and namespace. Presets contain filter values, which may be sensitive; do not save secrets. No connection URI or result documents are copied. Up to 100 presets and 2 MiB total.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Saved queries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename saved query", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Query name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") { rename() }
            } message: { Text("The name is unique within this connection and collection.") }
            .confirmationDialog("Delete saved query?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let preset = deleting {
                    Button("Delete \(preset.name)", role: .destructive) { delete(preset) }
                    Button("Cancel", role: .cancel) { deleting = nil }
                }
            } message: { Text("Only this local preset is removed. No database documents or collections change.") }
            .onChange(of: model.activeProfileID) { _, id in if id != context.connectionID { dismiss() } }
        }
    }

    @ViewBuilder
    private func controls(_ preset: SavedFindPreset) -> some View {
        Button("Load settings") { load(preset); dismiss() }
            .accessibilityLabel("Load saved query \(preset.name)")
            .accessibilityHint("Fills the editor without running a query")
        Button("Rename") { newName = preset.name; renaming = preset; message = nil }
            .disabled(model.presetStorageError != nil)
            .accessibilityLabel("Rename saved query \(preset.name)")
        Button("Delete", role: .destructive) { deleting = preset; message = nil }
            .disabled(model.presetStorageError != nil)
            .accessibilityLabel("Delete saved query \(preset.name)")
    }

    private func rename() {
        guard let preset = renaming else { return }
        renaming = nil
        do { try model.renameFindPreset(id: preset.id, in: context, to: newName); message = nil }
        catch { message = error.localizedDescription }
    }

    private func delete(_ preset: SavedFindPreset) {
        deleting = nil
        do { try model.deleteFindPreset(id: preset.id, in: context); message = nil }
        catch { message = error.localizedDescription }
    }
}
