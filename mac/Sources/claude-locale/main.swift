import AppKit
import Foundation
import ProfileCore

// claude-locale: start Claude Code with a chosen time zone and locale for that process only.
// `run` replaces itself with Claude Code via execve, so the PID, arguments, signals and exit
// status are Claude Code's own.

let usage = """
Usage:
  claude-locale run [--profile PATH] [--tz ZONE] [--locale TAG] [--claude PATH] [--] [claude args...]
  claude-locale desktop [--profile PATH] [--tz ZONE] [--locale TAG] [--restart] [-- app args...]
  claude-locale desktop --normal [--restart]
  claude-locale check [--profile PATH] [--json]
  claude-locale settings-snippet [--profile PATH]
  claude-locale validate FILE
  claude-locale version

run         Start Claude Code with TZ, LANG and LC_ALL from the profile (plus the
            DISABLE_TELEMETRY / DISABLE_ERROR_REPORTING opt-outs when enabled).
desktop     Start Claude Desktop with TZ from the profile and the profile's locale as its
            preferred language (-AppleLanguages), for that launch only. --normal starts it
            without them. If it is running, nothing happens unless --restart is given; then
            it is asked to quit normally (it may ask about unsaved work) and waited for.
check       Show the configured profile next to what /bin/date observes with it.
settings-snippet
            Print a Claude Code settings "env" block with only the opt-outs.
            Setup, not verified: paste it into ~/.claude/settings.json yourself.
validate    Exit 0 if FILE is a valid v1 profile, 1 otherwise.

Exit status of run: Claude Code's own once it starts (same PID, signals go to it).
Before that: 2 usage or profile error, 126 claude not executable, 127 claude not found.
Exit status of desktop: 0 started, 2 usage or profile error, 3 running (no --restart),
4 did not quit within 60 s, 5 not running after the launch request, 6 an update was still
installing after 300 s (nothing started), 127 Claude Desktop not installed.

Default profile: $XDG_CONFIG_HOME/claude-locale-kit/profile.json or ~/.config/claude-locale-kit/profile.json
"""

let version = "0.2.0"

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("claude-locale: \(message)\n".utf8))
    exit(code)
}

struct Options {
    var profilePath: String?
    var timeZone: String?
    var locale: String?
    var claudePath: String?
    var json = false
    var restart = false
    var normal = false
    var rest: [String] = []
}

/// `allowPassthrough`: arguments after `--` are kept. `unknownStartsPassthrough` (run only): the
/// first unrecognised argument also starts them.
/// `desktopFlags`: --restart and --normal are options (desktop only; for run they are Claude
/// Code's own arguments and pass through).
func parseOptions(_ args: ArraySlice<String>, allowPassthrough: Bool, unknownStartsPassthrough: Bool? = nil,
                  desktopFlags: Bool = false) -> Options {
    let unknownPasses = unknownStartsPassthrough ?? allowPassthrough
    var o = Options()
    var it = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value", code: 2) }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--profile": o.profilePath = value(a)
        case "--tz": o.timeZone = value(a)
        case "--locale": o.locale = value(a)
        case "--claude": o.claudePath = value(a)
        case "--json": o.json = true
        case "--restart" where desktopFlags: o.restart = true
        case "--normal" where desktopFlags: o.normal = true
        case "--":
            guard allowPassthrough else { fail("unexpected --", code: 2) }
            while let r = it.next() { o.rest.append(r) }
        default:
            // For `run`, the first argument the wrapper does not recognise starts Claude Code's
            // own arguments, so `claude-locale run --model opus` passes `--model opus` through.
            guard unknownPasses else { fail("unknown option \(a)", code: 2) }
            o.rest.append(a)
            while let r = it.next() { o.rest.append(r) }
        }
    }
    return o
}

func profileURL(_ o: Options) -> URL {
    o.profilePath.map { URL(fileURLWithPath: $0) } ?? Profile.defaultURL()
}

/// Loads the profile, then applies --tz/--locale overrides. A missing profile is fine when both
/// overrides are given.
func resolveProfile(_ o: Options) -> Profile {
    let url = profileURL(o)
    var profile: Profile
    if FileManager.default.fileExists(atPath: url.path) {
        do { profile = try Profile.load(from: url) } catch let e as ProfileError {
            fail("\(url.path): \(e.description)", code: 2)
        } catch { fail("\(url.path): \(error.localizedDescription)", code: 2) }
    } else if o.timeZone != nil, o.locale != nil {
        profile = .fallback
    } else {
        fail("no profile at \(url.path). Save one in the Mac app, or pass both --tz and --locale.", code: 2)
    }
    if let tz = o.timeZone { profile.timeZone = tz }
    if let l = o.locale { profile.locale = l }
    do { try profile.validate() } catch let e as ProfileError { fail(e.description, code: 2) } catch { fail("\(error)", code: 2) }
    return profile
}

/// First executable `claude` on PATH that is not this wrapper (so `alias claude=...` or a
/// same-named symlink cannot recurse).
func findClaude(environment: [String: String]) -> String? {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("claude")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
        if candidate.resolvingSymlinksInPath().path == me { continue }
        return candidate.path
    }
    return nil
}

func run(_ o: Options) -> Never {
    let profile = resolveProfile(o)
    let base = ProcessInfo.processInfo.environment
    guard let claude = o.claudePath ?? findClaude(environment: base) else {
        fail("could not find `claude` on PATH. Pass --claude PATH.", code: 127)
    }
    let env = profile.childEnvironment(base: base)
    let argv = [claude] + o.rest
    var cArgs = argv.map { strdup($0) } + [nil]
    var cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(claude, &cArgs, &cEnv)
    let err = errno
    fail("could not start \(claude): \(String(cString: strerror(err)))", code: err == ENOENT ? 127 : 126)
}

/// Starts Claude Desktop through /usr/bin/open (the route the live test used), with the profile's
/// TZ and -AppleLanguages unless --normal. Never forces a quit.
func desktop(_ o: Options) -> Never {
    let profile: Profile? = o.normal ? nil : resolveProfile(o)
    if o.normal, o.timeZone != nil || o.locale != nil || o.profilePath != nil {
        fail("--normal takes no profile, --tz or --locale", code: 2)
    }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DesktopLaunch.bundleID) else {
        fail("Claude Desktop is not installed.", code: 127)
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopLaunch.bundleID)
    if !running.isEmpty {
        guard o.restart else {
            fail("Claude Desktop is running. Quit it first, or pass --restart to ask it to quit normally.", code: 3)
        }
        running.forEach { _ = $0.terminate() }
        let deadline = Date().addingTimeInterval(60)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if running.contains(where: { !$0.isTerminated }) {
            fail("Claude Desktop did not quit within 60 s; it may be asking you something. Nothing was started.", code: 4)
        }
    }
    guard updateInstallerFinished() else {
        fail("a Claude Desktop update was still installing after 300 s. Nothing was started; try again shortly.", code: 6)
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = DesktopLaunch.openArguments(app: app, profile: profile, extra: o.rest)
    do { try open.run() } catch { fail("could not run open: \(error.localizedDescription)", code: 5) }
    open.waitUntilExit()
    guard open.terminationStatus == 0 else { fail("open exited with status \(open.terminationStatus)", code: 5) }
    // open's exit status only says the request was accepted; wait for the process itself.
    let started = Date().addingTimeInterval(20)
    while NSRunningApplication.runningApplications(withBundleIdentifier: DesktopLaunch.bundleID).isEmpty, Date() < started {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    if NSRunningApplication.runningApplications(withBundleIdentifier: DesktopLaunch.bundleID).isEmpty {
        fail("the launch was requested, but Claude Desktop was not running 20 s later.", code: 5)
    }
    if let profile {
        print("Claude Desktop is running, started with TZ=\(profile.timeZone) and preferred language \(profile.locale) (this launch only).")
    } else {
        print("Claude Desktop is running, started normally.")
    }
    exit(0)
}

/// A staged auto-update installs when Claude Desktop quits; starting it before the installer
/// finishes could launch a bundle mid-replacement. True once no installer runs (waits ≤ 300 s).
func updateInstallerFinished() -> Bool {
    let deadline = Date().addingTimeInterval(300)
    repeat {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "\(DesktopLaunch.bundleID).ShipIt"]
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        if p.terminationStatus == 1 { return true }  // pgrep: no match
        if p.terminationStatus != 0 { return false }
        Thread.sleep(forTimeInterval: 1)
    } while Date() < deadline
    return false
}

struct Observed: Encodable {
    let date: String
    let utcOffset: String
    let timeZoneAbbreviation: String
}

struct CheckReport: Encodable {
    struct Configured: Encodable {
        let timeZone: String
        let locale: String
        let disableTelemetry: Bool
        let disableErrorReporting: Bool
    }
    let profilePath: String
    let profileError: String?
    let configured: Configured?
    let childEnvironment: [String: String]
    let observed: Observed?
    let claudePath: String?
}

/// Runs /bin/date with only the child's TZ/LANG/LC_ALL to show what a process actually observes.
func observe(_ profile: Profile) -> Observed? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/date")
    p.arguments = ["+%Y-%m-%dT%H:%M:%S|%z|%Z"]
    p.environment = Dictionary(uniqueKeysWithValues: profile.childVariables.filter { ["TZ", "LANG", "LC_ALL"].contains($0.0) })
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").map(String.init)
    guard p.terminationStatus == 0, out.count == 3 else { return nil }
    return Observed(date: out[0], utcOffset: out[1], timeZoneAbbreviation: out[2])
}

func check(_ o: Options) -> Never {
    let url = profileURL(o)
    var profile: Profile?
    var problem: String?
    do { profile = try Profile.load(from: url) } catch let e as ProfileError { problem = e.description } catch {
        problem = FileManager.default.fileExists(atPath: url.path) ? error.localizedDescription : "No profile saved yet."
    }
    let claude = findClaude(environment: ProcessInfo.processInfo.environment)
    let report = CheckReport(
        profilePath: url.path,
        profileError: problem,
        configured: profile.map { .init(timeZone: $0.timeZone, locale: $0.locale, disableTelemetry: $0.disableTelemetry, disableErrorReporting: $0.disableErrorReporting) },
        childEnvironment: Dictionary(uniqueKeysWithValues: profile?.childVariables ?? []),
        observed: profile.flatMap(observe),
        claudePath: claude
    )
    if o.json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try! enc.encode(report))
        print()
    } else {
        print("Profile:   \(report.profilePath)")
        if let problem { print("Problem:   \(problem)") }
        if let c = report.configured {
            print("Configured: \(c.timeZone), \(c.locale)")
            for (k, v) in report.childEnvironment.sorted(by: { $0.key < $1.key }) { print("  \(k)=\(v)") }
        }
        if let ob = report.observed { print("Observed:  \(ob.date) \(ob.utcOffset) \(ob.timeZoneAbbreviation) (from /bin/date)") }
        print("claude:    \(claude ?? "not found on PATH")")
    }
    exit(problem == nil ? 0 : 1)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "run":
    run(parseOptions(args.dropFirst(), allowPassthrough: true))
case "desktop":
    desktop(parseOptions(args.dropFirst(), allowPassthrough: true, unknownStartsPassthrough: false, desktopFlags: true))
case "check":
    check(parseOptions(args.dropFirst(), allowPassthrough: false))
case "settings-snippet":
    let profile = resolveProfile(parseOptions(args.dropFirst(), allowPassthrough: false))
    FileHandle.standardError.write(Data("Setup, not verified: add this \"env\" block to ~/.claude/settings.json yourself. Time zone and locale are not included because Claude Desktop sets TZ for its Code tab.\n".utf8))
    print(profile.settingsEnvSnippet)
case "validate":
    guard args.count == 2, let path = args.last else { fail("validate needs exactly one FILE", code: 2) }
    do {
        _ = try Profile.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        print("valid")
    } catch let e as ProfileError {
        print("invalid: \(e.description)"); exit(1)
    } catch {
        print("invalid: \(error.localizedDescription)"); exit(1)
    }
case "version", "--version":
    print("claude-locale \(version)")
case "help", "--help", "-h", nil:
    print(usage)
default:
    fail("unknown command \(args.first!). Run claude-locale help.", code: 2)
}
