import Foundation

/// How Claude Desktop is started with a profile, for that launch only: `TZ` in its environment and
/// the profile's locale as its one preferred language (`-AppleLanguages`, an argument-domain
/// default that lasts until the app quits). Nothing is written to the app or to user defaults.
public enum DesktopLaunch {
    public static let bundleID = "com.anthropic.claudefordesktop"

    /// Arguments for `/usr/bin/open`. `extra` goes to the app after its own arguments.
    public static func openArguments(app: URL, profile: Profile?, extra: [String] = []) -> [String] {
        var args = ["-a", app.path]
        if let profile { args += ["--env", "TZ=\(profile.timeZone)"] }
        let appArgs = (profile.map { ["-AppleLanguages", "(\($0.locale))"] } ?? []) + extra
        if !appArgs.isEmpty { args += ["--args"] + appArgs }
        return args
    }
}
