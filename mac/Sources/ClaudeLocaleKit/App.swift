import AppKit
import SwiftUI

enum AppInfo {
    static let name = "Claude Locale Kit"
    static let version = "0.1.0"
}

struct ClaudeLocaleKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.live()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable with no bundle; give it a Dock icon and focus.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
