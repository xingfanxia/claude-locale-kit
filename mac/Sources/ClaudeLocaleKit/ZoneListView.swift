import AppKit
import SwiftUI

struct ZoneListView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<String?> {
        Binding(get: { model.draft.timeZone },
                set: { if let zone = $0 { model.draft.timeZone = zone } })
    }

    var body: some View {
        let rows = ZoneRow.filtered(model.zoneQuery)
        VStack(spacing: 0) {
            SearchField(text: $model.zoneQuery, prompt: String(localized: "Search time zones"))
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ScrollViewReader { proxy in
                List(selection: selection) {
                    ForEach(regions(rows), id: \.name) { region in
                        Section {
                            ForEach(region.rows) { row in
                                ZoneRowView(row: row).tag(Optional(row.id))
                            }
                        } header: {
                            Text(verbatim: region.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onAppear { proxy.scrollTo(model.draft.timeZone, anchor: .center) }
            }
            .overlay {
                if rows.isEmpty {
                    Text("No time zone matches “\(model.zoneQuery)”. Try a city, a region or an offset such as +09.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        }
    }

    /// Rows keep their catalog order inside each IANA area.
    private func regions(_ rows: [ZoneRow]) -> [(name: String, rows: [ZoneRow])] {
        Dictionary(grouping: rows, by: \.region)
            .map { (name: $0.key, rows: $0.value) }
            .sorted { $0.name < $1.name }
    }
}

private struct ZoneRowView: View {
    let row: ZoneRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.city)
                    .lineLimit(1)
                Text(verbatim: row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(verbatim: row.offset)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// NSSearchField: the native look, clear button and Escape-to-clear behaviour.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
