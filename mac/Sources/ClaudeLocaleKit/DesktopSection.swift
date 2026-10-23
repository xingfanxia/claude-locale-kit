import SwiftUI

/// Restarting Claude Desktop with the saved profile, and back to normal.
struct DesktopSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart with this profile")
                    Text("Asks Claude Desktop to quit (it may ask about unsaved work), then starts it with this time zone and language for that launch only.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Restart with Profile") { model.restartDesktop(withProfile: true) }
                    .disabled(!model.isSaved || model.hasUnsavedChanges || model.desktopBusy || model.cli == nil)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart normally")
                    Text("Starts Claude Desktop with your Mac's own time zone and language again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restart Normally") { model.restartDesktop(withProfile: false) }
                    .disabled(model.desktopBusy || model.cli == nil)
            }
            if model.desktopBusy {
                ProgressView()
                    .controlSize(.small)
            }
        } header: {
            Text("Claude Desktop")
        } footer: {
            if model.hasUnsavedChanges {
                Footnote("Save the profile first: Claude Desktop starts with the saved profile.")
            } else {
                Footnote("After you quit Claude Desktop, opening it the usual way starts it normally again.")
            }
        }
    }
}
