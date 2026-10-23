import SwiftUI

/// Starting Claude Code with the profile: Terminal, a shell alias, or the settings snippet.
struct ClaudeCodeSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Claude Code in Terminal")
                    Text("Opens a new Terminal window that starts Claude Code with the saved profile.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Terminal", action: model.openInTerminal)
                    .disabled(!model.isSaved || model.cli == nil)
            }

            if let command = model.commandLine {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Command for a shell alias or script")
                        Spacer()
                        Button("Copy Command") {
                            model.copy(command, confirmation: String(localized: "Command copied."))
                        }
                    }
                    Text(verbatim: command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Add your own Claude Code arguments after the final --.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings snippet")
                    Text("Setup, not verified. An \"env\" block with only the opt-outs above, for ~/.claude/settings.json. Paste it yourself; it does not set the time zone or locale.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Copy Snippet") {
                    model.copy(model.draft.settingsEnvSnippet, confirmation: String(localized: "Settings snippet copied."))
                }
            }
        } header: {
            Text("Claude Code")
        }
    }
}

/// Which Claude surfaces the profile reaches today. Stated plainly; nothing here is a promise.
struct SurfacesSection: View {
    var body: some View {
        Section {
            row("Claude Code (command line)",
                "TZ, LANG and LC_ALL apply to the process claude-locale starts and to its child processes. Other request details are not changed.",
                symbol: "checkmark.circle.fill", tint: Palette.match)
            row("claude.ai in Chrome",
                "Through the browser extension, after you import this profile there.",
                symbol: "puzzlepiece.extension", tint: .secondary)
            row("Claude Desktop chat",
                "Partly tested. Restart with Profile starts Claude Desktop with this language and time zone for that launch. In a live test, chat requests carried the profile's language; whether chat sends the profile's time zone is not verified yet.",
                symbol: "minus.circle", tint: Palette.warn)
        } header: {
            Text("Where this applies")
        } footer: {
            Footnote("This changes what apps read from your clock and language settings. It does not change your network address, account country or anything Anthropic determines on its servers.")
        }
    }

    private func row(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, symbol: String, tint: some ShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
