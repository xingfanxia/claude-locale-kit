import AppKit

// Hidden developer hook: render the main window offscreen to PNGs and exit, without
// showing any window or activating the app. Usage: ClaudeLocaleKit --render-snapshots <dir>
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-snapshots") {
    guard arguments.indices.contains(flag + 1) else {
        FileHandle.standardError.write(Data("usage: ClaudeLocaleKit --render-snapshots <dir>\n".utf8))
        exit(64)
    }
    exit(Snapshots.render(to: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)))
}

ClaudeLocaleKitApp.main()
