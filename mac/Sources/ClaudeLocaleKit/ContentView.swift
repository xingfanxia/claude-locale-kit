import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ZoneListView(model: model)
                .frame(width: 272)
            Divider()
            VStack(spacing: 0) {
                ClockHeader(model: model)
                Divider()
                Form {
                    FormatSections(model: model)
                    ProfileSection(model: model)
                    VerifySection(model: model)
                    ClaudeCodeSection(model: model)
                    SurfacesSection()
                }
                .formStyle(.grouped)
                if let notice = model.notice {
                    NoticeBar(notice: notice) { model.notice = nil }
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 940, minHeight: 620, idealHeight: 720)
        .background(Palette.page)
    }
}

/// The result of the last action, kept until dismissed or replaced.
struct NoticeBar: View {
    let notice: AppModel.Notice
    let dismiss: () -> Void

    var body: some View {
        let (text, isError) = switch notice {
        case .info(let t): (t, false)
        case .error(let t): (t, true)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Palette.warn : Palette.match)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .accessibilityLabel(Text("Dismiss"))
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Section footer text. Grouped forms otherwise trail-align wrapped footers.
struct Footnote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}
