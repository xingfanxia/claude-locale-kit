import AppKit
import ProfileCore
import SwiftUI

/// Renders the window offscreen to PNGs for visual review. Uses fixture models with a fixed
/// date; never reads or writes the real profile, never shows a window or activates the app.
@MainActor
enum Snapshots {
    /// 2026-10-21 05:32:07 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_792_560_727)
    static let cli = URL(fileURLWithPath: "/Applications/Claude Locale Kit.app/Contents/MacOS/claude-locale")
    static let profileURL = URL(fileURLWithPath: "/Users/you/.config/claude-locale-kit/profile.json")

    static func verified() -> AppModel {
        let profile = Profile(timeZone: "Asia/Tokyo", locale: "ja-JP", disableTelemetry: true)
        var result = CheckResult()
        result.profilePath = profileURL.path
        result.configured = .init(timeZone: profile.timeZone, locale: profile.locale,
                                  disableTelemetry: true, disableErrorReporting: false)
        result.childEnvironment = Dictionary(uniqueKeysWithValues: profile.childVariables)
        result.observed = .init(date: "2026-10-21T14:32:07", utcOffset: "+0900", timeZoneAbbreviation: "JST")
        return AppModel(draft: profile, saved: profile, profileURL: profileURL,
                        hostZone: TimeZone(identifier: "America/Los_Angeles")!, cli: cli,
                        check: .done(result), clock: { fixedDate })
    }

    static func firstRun() -> AppModel {
        AppModel(draft: Profile(timeZone: "Europe/London", locale: "en-GB"), saved: nil, profileURL: profileURL,
                 hostZone: TimeZone(identifier: "Europe/London")!, cli: cli, clock: { fixedDate })
    }

    static func mismatch() -> AppModel {
        let saved = Profile(timeZone: "America/Sao_Paulo", locale: "pt-BR")
        var result = CheckResult()
        result.configured = .init(timeZone: saved.timeZone, locale: saved.locale,
                                  disableTelemetry: false, disableErrorReporting: false)
        result.observed = .init(date: "2026-10-21T05:32:07", utcOffset: "+0000", timeZoneAbbreviation: "UTC")
        let model = AppModel(draft: Profile(timeZone: "Asia/Kolkata", locale: "hi-IN"), saved: saved,
                             profileURL: profileURL, hostZone: TimeZone(identifier: "UTC")!, cli: cli,
                             check: .done(result), clock: { fixedDate })
        model.notice = .error("Could not save the profile: You don’t have permission to save the file “profile.json” in the folder “claude-locale-kit”.")
        return model
    }

    static func render(to dir: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(dir.path): \(error)\n".utf8))
            return 1
        }
        let window = CGSize(width: 940, height: 720)
        let tall = CGSize(width: 940, height: 1580)
        let cases: [(String, NSAppearance.Name, CGSize, () -> AppModel)] = [
            ("verified-light", .aqua, window, verified),
            ("verified-dark", .darkAqua, window, verified),
            ("verified-full-light", .aqua, tall, verified),
            ("verified-full-dark", .darkAqua, tall, verified),
            ("first-run-light", .aqua, tall, firstRun),
            ("mismatch-dark", .darkAqua, tall, mismatch),
        ]
        for (name, appearance, size, make) in cases {
            let url = dir.appendingPathComponent("\(name).png")
            guard let png = snapshot(ContentView(model: make()), size: size, appearance: appearance) else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                return 1
            }
            do { try png.write(to: url) } catch {
                FileHandle.standardError.write(Data("cannot write \(url.path): \(error)\n".utf8))
                return 1
            }
            print(url.path)
        }
        return 0
    }

    private static func snapshot(_ view: some View, size: CGSize, appearance: NSAppearance.Name) -> Data? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let List, Form and TimelineView finish their first passes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        return rep.representation(using: .png, properties: [:])
    }
}
