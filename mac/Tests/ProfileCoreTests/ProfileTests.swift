import XCTest
@testable import ProfileCore

final class ProfileTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../profile/fixtures").standardized
    }

    private func files(_ kind: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent(kind), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    func testGoldenValidFixturesParse() throws {
        let urls = try files("valid")
        XCTAssertFalse(urls.isEmpty)
        for url in urls { XCTAssertNoThrow(try Profile.load(from: url), url.lastPathComponent) }
    }

    func testGoldenInvalidFixturesAreRejected() throws {
        let urls = try files("invalid")
        XCTAssertFalse(urls.isEmpty)
        for url in urls { XCTAssertThrowsError(try Profile.load(from: url), url.lastPathComponent) }
    }

    func testRoundTrip() throws {
        let p = Profile(timeZone: "Australia/Lord_Howe", locale: "en-AU", disableTelemetry: true)
        XCTAssertEqual(try Profile.parse(p.jsonData()), p)
    }

    func testChildEnvironmentOnlyAddsEnabledOptOuts() {
        let base = ["DISABLE_TELEMETRY": "0", "PATH": "/usr/bin", "TZ": "Asia/Shanghai"]
        let env = Profile(timeZone: "Europe/London", locale: "en-GB").childEnvironment(base: base)
        XCTAssertEqual(env["TZ"], "Europe/London")
        XCTAssertEqual(env["LANG"], "en_GB.UTF-8")
        XCTAssertEqual(env["LC_ALL"], "en_GB.UTF-8")
        XCTAssertEqual(env["DISABLE_TELEMETRY"], "0", "a disabled opt-out must not override the user's own value")
        XCTAssertNil(env["DISABLE_ERROR_REPORTING"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testSettingsSnippetNeverCarriesTimeZoneOrLocale() {
        let s = Profile(timeZone: "UTC", locale: "en-US", disableTelemetry: true, disableErrorReporting: true).settingsEnvSnippet
        XCTAssertTrue(s.contains("DISABLE_TELEMETRY"))
        XCTAssertTrue(s.contains("DISABLE_ERROR_REPORTING"))
        XCTAssertFalse(s.contains("TZ"))
        XCTAssertFalse(s.contains("LANG"))
    }

    func testDefaultURLHonoursAbsoluteXDGOnly() {
        XCTAssertEqual(Profile.defaultURL(environment: ["XDG_CONFIG_HOME": "/tmp/x"]).path, "/tmp/x/claude-locale-kit/profile.json")
        XCTAssertTrue(Profile.defaultURL(environment: ["XDG_CONFIG_HOME": "relative"]).path.hasSuffix("/.config/claude-locale-kit/profile.json"))
    }
}
