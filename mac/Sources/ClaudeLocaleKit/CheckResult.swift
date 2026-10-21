import Foundation

/// Output of `claude-locale check --json`. Decoded leniently: any missing or mistyped field
/// becomes nil and the UI shows "unknown" for it.
struct CheckResult: Equatable {
    struct Configured: Equatable {
        var timeZone: String?
        var locale: String?
        var disableTelemetry: Bool?
        var disableErrorReporting: Bool?
    }

    struct Observed: Equatable {
        var date: String?
        var utcOffset: String?
        var timeZoneAbbreviation: String?
    }

    var profilePath: String?
    var profileError: String?
    var configured: Configured?
    var childEnvironment: [String: String] = [:]
    var observed: Observed?
    var claudePath: String?

    static func parse(_ data: Data) -> CheckResult? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var result = CheckResult()
        result.profilePath = obj["profilePath"] as? String
        result.profileError = obj["profileError"] as? String
        result.claudePath = obj["claudePath"] as? String
        if let c = obj["configured"] as? [String: Any] {
            result.configured = Configured(
                timeZone: c["timeZone"] as? String,
                locale: c["locale"] as? String,
                disableTelemetry: c["disableTelemetry"] as? Bool,
                disableErrorReporting: c["disableErrorReporting"] as? Bool)
        }
        if let env = obj["childEnvironment"] as? [String: Any] {
            result.childEnvironment = env.compactMapValues { $0 as? String }
        }
        if let o = obj["observed"] as? [String: Any] {
            result.observed = Observed(
                date: o["date"] as? String,
                utcOffset: o["utcOffset"] as? String,
                timeZoneAbbreviation: o["timeZoneAbbreviation"] as? String)
        }
        return result
    }
}

enum CLIRunner {
    /// The bundled CLI sits next to the app executable: Contents/MacOS in the .app,
    /// or the build products directory under `swift run`.
    static func locate() -> URL? {
        var candidates: [URL] = []
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "claude-locale") { candidates.append(aux) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("claude-locale"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `claude-locale check --json --profile <path>` with a fixed argument list (no shell).
    static func check(cli: URL, profile: URL) async -> Result<CheckResult, CheckFailure> {
        await Task.detached(priority: .userInitiated) { () -> Result<CheckResult, CheckFailure> in
            let process = Process()
            process.executableURL = cli
            process.arguments = ["check", "--json", "--profile", profile.path]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch {
                return .failure(CheckFailure(message: String(localized: "Could not start claude-locale: \(error.localizedDescription)")))
            }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            if let result = CheckResult.parse(stdout) { return .success(result) }
            let detail = String(decoding: stderr, as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? String(localized: "exit status \(process.terminationStatus)")
            return .failure(CheckFailure(message: String(localized: "claude-locale check returned no readable result (\(detail)).")))
        }.value
    }
}

struct CheckFailure: Error, Equatable {
    var message: String
}
