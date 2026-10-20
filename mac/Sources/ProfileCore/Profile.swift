import Foundation

/// The v1 profile shared with the browser extension. See profile/README.md.
public struct Profile: Equatable, Sendable {
    public static let schemaID = "claude-locale-kit/profile"
    public static let currentVersion = 1

    public var timeZone: String
    public var locale: String
    public var disableTelemetry: Bool
    public var disableErrorReporting: Bool

    public init(timeZone: String, locale: String, disableTelemetry: Bool = false, disableErrorReporting: Bool = false) {
        self.timeZone = timeZone
        self.locale = locale
        self.disableTelemetry = disableTelemetry
        self.disableErrorReporting = disableErrorReporting
    }

    public static let fallback = Profile(timeZone: "UTC", locale: "en-US")
}

public enum ProfileError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case notObject
    case unknownKey(String)
    case missingKey(String)
    case wrongType(String)
    case wrongSchema
    case wrongVersion
    case unknownTimeZone(String)
    case unknownLocale(String)

    public var description: String {
        switch self {
        case .notJSON: return "The file is not valid JSON."
        case .notObject: return "A profile must be a JSON object."
        case .unknownKey(let k): return "Unsupported key \"\(k)\". Profiles only hold schema, version, timeZone, locale and cli."
        case .missingKey(let k): return "Missing required key \"\(k)\"."
        case .wrongType(let k): return "\"\(k)\" has the wrong type."
        case .wrongSchema: return "\"schema\" must be \"\(Profile.schemaID)\"."
        case .wrongVersion: return "\"version\" must be \(Profile.currentVersion)."
        case .unknownTimeZone(let z): return "\"\(z)\" is not a supported IANA time zone."
        case .unknownLocale(let l): return "\"\(l)\" is not a supported locale."
        }
    }
}

extension Profile {
    private static let topKeys: Set<String> = ["schema", "version", "timeZone", "locale", "cli"]
    private static let cliKeys: Set<String> = ["disableTelemetry", "disableErrorReporting"]

    /// Strict parse: unknown keys, wrong types and values outside the catalog are rejected.
    public static func parse(_ data: Data) throws -> Profile {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ProfileError.notJSON
        }
        guard let obj = any as? [String: Any] else { throw ProfileError.notObject }
        for key in obj.keys where !topKeys.contains(key) { throw ProfileError.unknownKey(key) }

        guard let schema = obj["schema"] else { throw ProfileError.missingKey("schema") }
        guard let schemaString = schema as? String, !isBool(schema) else { throw ProfileError.wrongType("schema") }
        guard schemaString == schemaID else { throw ProfileError.wrongSchema }

        guard let version = obj["version"] else { throw ProfileError.missingKey("version") }
        guard let number = version as? NSNumber, !isBool(version) else { throw ProfileError.wrongType("version") }
        guard number.doubleValue == Double(currentVersion) else { throw ProfileError.wrongVersion }

        let timeZone = try requiredString(obj, "timeZone")
        let locale = try requiredString(obj, "locale")

        var telemetry = false
        var errors = false
        if let cliValue = obj["cli"] {
            guard let cli = cliValue as? [String: Any] else { throw ProfileError.wrongType("cli") }
            for key in cli.keys where !cliKeys.contains(key) { throw ProfileError.unknownKey("cli.\(key)") }
            telemetry = try optionalBool(cli, "disableTelemetry")
            errors = try optionalBool(cli, "disableErrorReporting")
        }
        let profile = Profile(timeZone: timeZone, locale: locale, disableTelemetry: telemetry, disableErrorReporting: errors)
        try profile.validate()
        return profile
    }

    public func validate() throws {
        guard Catalog.timeZones.contains(timeZone) else { throw ProfileError.unknownTimeZone(timeZone) }
        guard Catalog.locales.contains(locale) else { throw ProfileError.unknownLocale(locale) }
    }

    public func jsonData() -> Data {
        let obj: [String: Any] = [
            "schema": Profile.schemaID,
            "version": Profile.currentVersion,
            "timeZone": timeZone,
            "locale": locale,
            "cli": ["disableTelemetry": disableTelemetry, "disableErrorReporting": disableErrorReporting],
        ]
        // Force-try is safe: the object only holds JSON-native values.
        var data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// `en-US` -> `en_US.UTF-8`.
    public var posixLocale: String { locale.replacingOccurrences(of: "-", with: "_") + ".UTF-8" }

    /// Variables the CLI wrapper sets on the child process. Opt-outs are only added when enabled;
    /// a disabled opt-out leaves any value the user already exported untouched.
    public var childVariables: [(String, String)] {
        var vars = [("TZ", timeZone), ("LANG", posixLocale), ("LC_ALL", posixLocale)]
        if disableTelemetry { vars.append(("DISABLE_TELEMETRY", "1")) }
        if disableErrorReporting { vars.append(("DISABLE_ERROR_REPORTING", "1")) }
        return vars
    }

    public func childEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        for (k, v) in childVariables { env[k] = v }
        return env
    }

    /// A Claude Code settings `env` block with only the documented telemetry/error opt-outs.
    /// Time zone and locale are deliberately absent: Claude Desktop sets TZ for its Code tab itself.
    public var settingsEnvSnippet: String {
        var env: [String: String] = [:]
        if disableTelemetry { env["DISABLE_TELEMETRY"] = "1" }
        if disableErrorReporting { env["DISABLE_ERROR_REPORTING"] = "1" }
        let data = try! JSONSerialization.data(withJSONObject: ["env": env], options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("claude-locale-kit/profile.json")
    }

    public static func load(from url: URL) throws -> Profile {
        try parse(Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try validate()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try jsonData().write(to: url, options: .atomic)
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func requiredString(_ obj: [String: Any], _ key: String) throws -> String {
        guard let value = obj[key] else { throw ProfileError.missingKey(key) }
        guard let s = value as? String else { throw ProfileError.wrongType(key) }
        return s
    }

    private static func optionalBool(_ obj: [String: Any], _ key: String) throws -> Bool {
        guard let value = obj[key] else { return false }
        guard isBool(value), let b = value as? Bool else { throw ProfileError.wrongType("cli.\(key)") }
        return b
    }
}
