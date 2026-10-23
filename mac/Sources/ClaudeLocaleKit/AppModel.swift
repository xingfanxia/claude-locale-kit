import AppKit
import ProfileCore
import SwiftUI

/// State for the single window. Disk, process and Terminal side effects happen only in the
/// action methods, so a fixture model (see Snapshots) can render every state without them.
@MainActor
final class AppModel: ObservableObject {
    enum CheckState: Equatable {
        case idle
        case running
        case done(CheckResult)
        case failed(String)
    }

    enum Notice: Equatable {
        case info(String)
        case error(String)
    }

    @Published var draft: Profile
    @Published private(set) var saved: Profile?
    @Published var zoneQuery = ""
    @Published private(set) var check: CheckState
    @Published var notice: Notice?
    @Published private(set) var desktopBusy = false

    let profileURL: URL
    let hostZone: TimeZone
    let cli: URL?
    private let clock: () -> Date

    init(draft: Profile, saved: Profile?, profileURL: URL, hostZone: TimeZone, cli: URL?,
         check: CheckState = .idle, clock: @escaping () -> Date) {
        self.draft = draft
        self.saved = saved
        self.profileURL = profileURL
        self.hostZone = hostZone
        self.cli = cli
        self.check = check
        self.clock = clock
    }

    static func live() -> AppModel {
        let url = Profile.defaultURL()
        var saved: Profile?
        var problem: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do { saved = try Profile.load(from: url) } catch let e as ProfileError {
                problem = e.description
            } catch { problem = error.localizedDescription }
        }
        let model = AppModel(draft: saved ?? suggested(), saved: saved, profileURL: url,
                             hostZone: .current, cli: CLIRunner.locate(), clock: Date.init)
        if let problem {
            model.notice = .error(String(localized: "The saved profile could not be read: \(problem) Saving replaces it."))
        }
        return model
    }

    /// First-run draft: this Mac's own zone and language when the catalog has them.
    static func suggested() -> Profile {
        let zone = TimeZone.current.identifier
        let tag = Locale.current.identifier(.bcp47)
        return Profile(timeZone: Catalog.timeZones.contains(zone) ? zone : Profile.fallback.timeZone,
                       locale: Catalog.locales.contains(tag) ? tag : Profile.fallback.locale)
    }

    var now: Date { clock() }
    var isSaved: Bool { saved != nil }
    var hasUnsavedChanges: Bool { draft != saved }
    var displayPath: String { Fmt.shortPath(profileURL.path) }

    var commandLine: String? {
        cli.map { Launcher.commandLine(cli: $0, profile: profileURL) }
    }

    // MARK: Actions

    func save() {
        do {
            try draft.save(to: profileURL)
            saved = draft
            check = .idle
            notice = .info(String(localized: "Profile saved."))
        } catch {
            notice = .error(String(localized: "Could not save the profile: \(error.localizedDescription)"))
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([profileURL])
    }

    func runCheck() {
        guard let cli else {
            check = .failed(String(localized: "The bundled claude-locale tool is missing. Reinstall the app."))
            return
        }
        check = .running
        let profile = profileURL
        Task {
            switch await CLIRunner.check(cli: cli, profile: profile) {
            case .success(let result): check = .done(result)
            case .failure(let failure): check = .failed(failure.message)
            }
        }
    }

    /// Writes the launch script and hands it to Terminal. Only ever called from a button.
    func openInTerminal() {
        guard let cli else {
            notice = .error(String(localized: "The bundled claude-locale tool is missing. Reinstall the app."))
            return
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            notice = .error(String(localized: "Terminal was not found."))
            return
        }
        do {
            let script = try Launcher.writeScript(cli: cli, profile: profileURL)
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in
                    self.notice = .error(String(localized: "Terminal could not open the launch script: \(error.localizedDescription)"))
                }
            }
        } catch {
            notice = .error(String(localized: "Could not write the launch script: \(error.localizedDescription)"))
        }
    }

    /// Restarts Claude Desktop through the bundled CLI: with the saved profile, or normally. Only
    /// ever called from a button. The CLI asks Desktop to quit the normal way and never forces it.
    func restartDesktop(withProfile: Bool) {
        guard let cli else {
            notice = .error(String(localized: "The bundled claude-locale tool is missing. Reinstall the app."))
            return
        }
        let arguments = withProfile ? ["desktop", "--restart", "--profile", profileURL.path] : ["desktop", "--normal", "--restart"]
        desktopBusy = true
        Task {
            let r = await CLIRunner.run(cli: cli, arguments: arguments, timeout: 420)
            desktopBusy = false
            if r.status == 0 {
                notice = .info(r.out)
            } else {
                notice = .error(r.err.isEmpty ? String(localized: "claude-locale desktop exited with status \(r.status).") : r.err)
            }
        }
    }

    func copy(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = .info(confirmation)
    }
}
