import Foundation

/// What the saved profile asks for next to what /bin/date reported when started with it.
/// Only the UTC offset is compared: it is the one value the check observes from a real process.
struct Verification: Equatable {
    var zone: String
    var expectedOffset: String
    var observedOffset: String?
    var observedAbbreviation: String?
    var lang: String?
    var matches: Bool

    init?(_ result: CheckResult, at date: Date) {
        guard result.profileError == nil, let zone = result.configured?.timeZone else { return nil }
        let expected = Fmt.offsetSeconds(zone: zone, at: date)
        let observed = result.observed?.utcOffset.flatMap(Fmt.parseOffset)
        self.zone = zone
        expectedOffset = expected.map(Fmt.offset(seconds:)) ?? String(localized: "unknown")
        observedOffset = observed.map(Fmt.offset(seconds:))
        observedAbbreviation = result.observed?.timeZoneAbbreviation
        lang = result.childEnvironment["LANG"]
        matches = expected != nil && expected == observed
    }
}
