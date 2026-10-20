import Foundation

/// Builds the Terminal launch script. The app never runs `claude` itself; Terminal runs the
/// bundled CLI, which applies the saved profile and execs Claude Code.
enum Launcher {
    /// POSIX single-quote escaping: wrap in '…' and turn each ' into '\''.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func commandLine(cli: URL, profile: URL) -> String {
        "\(quote(cli.path)) run --profile \(quote(profile.path)) --"
    }

    static func script(cli: URL, profile: URL) -> String {
        "#!/bin/sh\nexec \(commandLine(cli: cli, profile: profile))\n"
    }

    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/claude-locale-kit/launch.command")
    }

    static func writeScript(cli: URL, profile: URL) throws -> URL {
        let url = scriptURL
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try Data(script(cli: cli, profile: profile).utf8).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
