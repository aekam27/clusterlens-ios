import SwiftUI
import UIKit

struct FindResultsView: View {
    let documents: [JSONValue]
    @Binding var columns: [String]
    var useForQuery: (([String]) -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var textSize
    var inspectValue: (InspectedValue) -> Void = { _ in }

    private var suggestions: [String] { ResultProjection.suggestions(in: documents) }
    private var displayed: [String] {
        Array((columns.isEmpty ? ResultProjection.initialColumns(from: suggestions) : columns).prefix(ResultProjection.maximumColumns))
    }
    private var wide: Bool { sizeClass == .regular && !textSize.isAccessibilitySize }

    var body: some View {
        if !documents.isEmpty {
            HStack {
                Label(wide ? "Table" : "Records", systemImage: wide ? "tablecells" : "rectangle.grid.1x2")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(Array(Set(suggestions + displayed)).sorted(), id: \.self) { field in
                        Button {
                            var next = displayed
                            if next.contains(field) { next.removeAll { $0 == field } }
                            else if next.count < ResultProjection.maximumColumns { next.append(field) }
                            if !next.isEmpty { columns = next }
                        } label: {
                            Label(field, systemImage: displayed.contains(field) ? "checkmark.circle.fill" : "circle")
                        }
                        .accessibilityIdentifier("resultColumn_\(field)")
                        .disabled((displayed.count == 1 && displayed.contains(field)) || (displayed.count == ResultProjection.maximumColumns && !displayed.contains(field)))
                    }
                    Button("Reset display columns") { columns = ResultProjection.initialColumns(from: suggestions) }
                } label: { Label("Columns (\(displayed.count))", systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("resultColumns")
            }
            Text("Compare selected fields from this page. Tap a value to inspect it; Missing and null are different. Display changes do not run a query.")
                .font(.caption).foregroundStyle(.secondary)
            if let useForQuery {
                Button("Use these columns for query & export") { useForQuery(displayed) }
                    .accessibilityHint("Fills the column editor. Apply the filter or review an export explicitly to use it.")
            }
            if wide { table } else { cards }
            Text("Field suggestions sample this page only. Up to 8 display columns; arrays stay intact in the inspector.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var table: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("Record").frame(width: 76, alignment: .leading)
                    ForEach(displayed, id: \.self) { Text($0).frame(width: 156, alignment: .leading).lineLimit(2) }
                }.font(.caption.weight(.semibold)).padding(12).background(Color.secondary.opacity(0.08))
                ForEach(Array(documents.enumerated()), id: \.offset) { index, document in
                    HStack(alignment: .top, spacing: 0) {
                        Button("\(index + 1)") { inspect(document, row: index) }
                            .buttonStyle(.plain).accessibilityLabel("Inspect record \(index + 1)").accessibilityIdentifier("inspectRecord_\(index)").frame(width: 76, alignment: .leading)
                        ForEach(displayed, id: \.self) { field in
                            valueButton(document, field: field, row: index).frame(width: 156, alignment: .leading)
                        }
                    }.padding(12).background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.04))
                    Divider()
                }
            }
        }.accessibilityIdentifier("resultsTable")
    }

    private var cards: some View {
        ForEach(Array(documents.enumerated()), id: \.offset) { index, document in
            VStack(alignment: .leading, spacing: 12) {
                Button { inspect(document, row: index) } label: {
                    HStack { Text("Record \(index + 1)").font(.headline); Spacer(); Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Inspect record \(index + 1)").accessibilityIdentifier("inspectRecord_\(index)")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: textSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 14) {
                    ForEach(displayed, id: \.self) { field in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field).font(.caption).foregroundStyle(.secondary)
                            valueButton(document, field: field, row: index)
                        }
                    }
                }
            }.padding(.vertical, 8)
        }
    }

    private func valueButton(_ document: JSONValue, field: String, row: Int) -> some View {
        let value = ResultProjection.value(at: field, in: document)
        let cell = ResultCell(value)
        return Button {
            inspectValue(InspectedValue(title: "Record \(row + 1) · \(field)", value: value))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(cell.text.isEmpty ? "Empty text" : cell.text)
                    .font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                    .foregroundStyle(cell.missing ? .secondary : .primary)
                Text(cell.type).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel("Record \(row + 1), \(field), \(cell.type), \(cell.text)")
        .accessibilityHint("Inspect this value")
        .accessibilityIdentifier("resultCell_\(row)_\(field)")
    }

    private func inspect(_ document: JSONValue, row: Int) {
        inspectValue(InspectedValue(title: "Record \(row + 1)", value: document))
    }
}

struct InspectedValue: Identifiable {
    let id = UUID()
    let title: String
    let value: JSONValue?
}

struct ResultInspector: View {
    let value: InspectedValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let document = value.value {
                        InspectorNode(name: "Value", value: document, depth: 0)
                        Button("Copy complete Extended JSON") { UIPasteboard.general.string = document.prettyPrinted }
                        Text("Inspection is read-only. Large branches show at most 100 children and 12 levels; copying includes the complete selected value.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("Field is missing", systemImage: "minus.circle", description: Text("This document does not contain this field. It is not a null value."))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.navigationTitle(value.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct InspectorNode: View {
    let name: String
    let value: JSONValue
    let depth: Int
    @State private var expanded = false
    private var children: [(String, JSONValue)] {
        switch value {
        case .object(let object): return object.keys.sorted().prefix(100).compactMap { key in object[key].map { (key, $0) } }
        case .array(let array): return array.prefix(100).enumerated().map { ("[\($0.offset)]", $0.element) }
        default: return []
        }
    }
    private var count: Int {
        switch value { case .object(let object): return object.count; case .array(let array): return array.count; default: return 0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if count > 0 && depth < 12 {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .top) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        Text(name).fontWeight(.semibold)
                        Spacer()
                        Text(ResultCell(value).text).foregroundStyle(.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed").accessibilityHint("Expand or collapse nested fields").accessibilityIdentifier("inspectorNode_\(depth)_\(name)")
                if expanded {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        InspectorNode(name: child.0, value: child.1, depth: depth + 1).padding(.leading, 14)
                    }
                    if count > 100 { Text("Showing 100 of \(count) children. Copy includes all values.").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text(name + " · " + ResultCell(value).type).font(.caption).foregroundStyle(.secondary)
                Text(String(value.prettyPrinted.prefix(4096))).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if depth >= 12 { Text("Depth preview limit. Copy includes the full value.").font(.caption) }
                if case .string(let text) = value, text.count > 4000 { Text("Long text preview shortened. Copy includes the full value.").font(.caption) }
            }
        }.padding(.vertical, 5)
    }
}
