import SwiftUI

/// Runs the bundled CLI's check against the saved file and shows expected vs observed.
struct VerifySection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check the saved profile")
                    Text("Starts /bin/date with the profile’s environment and compares the UTC offset it reports.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Check", action: model.runCheck)
                    .disabled(!model.isSaved || model.check == .running)
            }
            result
        } header: {
            Text("Verify")
        } footer: {
            if model.isSaved && model.hasUnsavedChanges {
                Footnote("The check reads the saved file. Save to include your latest changes.")
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch model.check {
        case .idle:
            if !model.isSaved {
                Text("Save the profile to check it.")
                    .foregroundStyle(.secondary)
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            problem(message)
        case .done(let result):
            if let v = Verification(result, at: model.now) {
                LabeledContent("Time zone") { Text(verbatim: v.zone) }
                LabeledContent("Expected offset") { Text(verbatim: v.expectedOffset).monospacedDigit() }
                LabeledContent("Reported by /bin/date") {
                    Text(verbatim: [v.observedOffset ?? String(localized: "nothing"), v.observedAbbreviation ?? ""]
                        .joined(separator: "  ")).monospacedDigit()
                }
                if let lang = v.lang {
                    LabeledContent("LANG and LC_ALL") { Text(verbatim: lang).font(.callout.monospaced()) }
                }
                verdict(v)
            } else {
                problem(result.profileError ?? String(localized: "The check did not report a configured profile."))
            }
        }
    }

    @ViewBuilder private func verdict(_ v: Verification) -> some View {
        if v.matches {
            Label("Match. The test process reported \(v.expectedOffset).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.match)
        } else {
            Label("Mismatch. Expected \(v.expectedOffset), but /bin/date reported \(v.observedOffset ?? String(localized: "nothing")).",
                  systemImage: "xmark.octagon.fill")
                .foregroundStyle(Palette.warn)
        }
    }

    private func problem(_ message: String) -> some View {
        Label {
            Text(verbatim: message).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
        }
    }
}
