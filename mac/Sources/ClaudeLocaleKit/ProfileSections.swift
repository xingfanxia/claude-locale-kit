import ProfileCore
import SwiftUI

/// Locale picker and the two Claude Code opt-outs.
struct FormatSections: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Picker(selection: $model.draft.locale) {
                ForEach(Catalog.locales, id: \.self) { tag in
                    Text(verbatim: Fmt.localeName(tag)).tag(tag)
                }
            } label: {
                Text("Language and region")
                Text("Sets LANG and LC_ALL to \(model.draft.posixLocale)")
            }
        }

        Section {
            Toggle(isOn: $model.draft.disableTelemetry) {
                Text("Turn off telemetry")
                Text("Adds DISABLE_TELEMETRY=1 when Claude Code starts with this profile. Turning off telemetry (metrics) also turns off feature-flag fetching and may affect Remote Control. Error reporting is a separate switch below.")
            }
            Toggle(isOn: $model.draft.disableErrorReporting) {
                Text("Turn off error reporting")
                Text("Adds DISABLE_ERROR_REPORTING=1 when Claude Code starts with this profile.")
            }
        } header: {
            Text("Claude Code opt-outs")
        }
    }
}

/// Where the profile lives and whether the window matches it.
struct ProfileSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    Text(verbatim: model.displayPath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Reveal in Finder", action: model.revealInFinder)
                        .disabled(!model.isSaved)
                }
            } label: {
                Text("File")
            }
            HStack(spacing: 12) {
                status
                Spacer()
                Button("Save Profile", action: model.save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasUnsavedChanges)
            }
        } header: {
            Text("Profile")
        } footer: {
            Footnote("Claude Code started from this app reads this file. To use the same settings in Chrome, import the file in the browser extension.")
        }
    }

    @ViewBuilder private var status: some View {
        if !model.isSaved {
            Label("Not saved yet", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        } else if model.hasUnsavedChanges {
            Label("Unsaved changes", systemImage: "circle.lefthalf.filled")
                .foregroundStyle(Palette.warn)
        } else {
            Label("Saved", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}
