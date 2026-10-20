import Foundation
import ProfileCore

// claude-locale: start Claude Code with a chosen time zone and locale for that process only.
// `run` replaces itself with Claude Code via execve, so the PID, arguments, signals and exit
// status are Claude Code's own.

let usage = """
Usage:
  claude-locale run [--profile PATH] [--tz ZONE] [--locale TAG] [--claude PATH] [--] [claude args...]
  claude-locale check [--profile PATH] [--json]
  claude-locale settings-snippet [--profile PATH]
  claude-locale validate FILE
  claude-locale version

run         Start Claude Code with TZ, LANG and LC_ALL from the profile (plus the
            DISABLE_TELEMETRY / DISABLE_ERROR_REPORTING opt-outs when enabled).
check       Show the configured profile next to what /bin/date observes with it.
settings-snippet
            Print a Claude Code settings "env" block with only the opt-outs.
            Setup, not verified: paste it into ~/.claude/settings.json yourself.
validate    Exit 0 if FILE is a valid v1 profile, 1 otherwise.

Default profile: $XDG_CONFIG_HOME/claude-locale-kit/profile.json or ~/.config/claude-locale-kit/profile.json
"""

let version = "0.1.0"

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
    var rest: [String] = []
}

func parseOptions(_ args: ArraySlice<String>, allowPassthrough: Bool) -> Options {
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
        case "--":
            guard allowPassthrough else { fail("unexpected --", code: 2) }
            while let r = it.next() { o.rest.append(r) }
        default:
            // For `run`, the first argument the wrapper does not recognise starts Claude Code's
            // own arguments, so `claude-locale run --model opus` passes `--model opus` through.
            guard allowPassthrough else { fail("unknown option \(a)", code: 2) }
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
