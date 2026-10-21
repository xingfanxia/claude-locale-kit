import AppKit
import ProfileCore
import SwiftUI

enum Palette {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let match = Color(nsColor: .systemTeal)
    static let warn = Color(nsColor: .systemOrange)
}

enum Fmt {
    /// "UTC+05:30", "UTC−07:00" (typographic minus).
    static func offset(seconds: Int) -> String {
        let sign = seconds < 0 ? "\u{2212}" : "+"
        let a = abs(seconds)
        return String(format: "UTC%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
    }

    static func offsetSeconds(zone: String, at date: Date) -> Int? {
        TimeZone(identifier: zone)?.secondsFromGMT(for: date)
    }

    /// Parses `date +%z` style output ("+0900", "-0700", "+05:30").
    static func parseOffset(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        guard s.count == 5, let first = s.first, first == "+" || first == "-",
              let hh = Int(s.dropFirst().prefix(2)), let mm = Int(s.suffix(2)) else { return nil }
        let value = hh * 3600 + mm * 60
        return first == "-" ? -value : value
    }

    static func localeName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static func posix(_ locale: String) -> String {
        locale.replacingOccurrences(of: "-", with: "_") + ".UTF-8"
    }

    static func clock(_ date: Date, zone: String, locale: String) -> (time: String, date: String) {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: zone)
        f.locale = Locale(identifier: locale)
        f.timeStyle = .medium
        f.dateStyle = .none
        let time = f.string(from: date)
        f.timeStyle = .none
        f.dateStyle = .full
        return (time, f.string(from: date))
    }

    static func abbreviation(zone: String, at date: Date) -> String? {
        TimeZone(identifier: zone)?.abbreviation(for: date)
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct ZoneRow: Identifiable, Equatable {
    let id: String
    let offset: String
    /// Last path component, readable: "America/Argentina/Buenos_Aires" -> "Buenos Aires".
    let city: String
    /// The system's localized generic name ("Pacific Time"), or the IANA id when there is none.
    let detail: String
    /// IANA area ("Europe", "America"); the zone itself for area-less ids such as "UTC".
    let region: String
    let searchText: String

    static func city(_ zone: String) -> String {
        (zone.split(separator: "/").last.map(String.init) ?? zone).replacingOccurrences(of: "_", with: " ")
    }

    static let all: [ZoneRow] = {
        let now = Date()
        return Catalog.timeZones.sorted().map { zone in
            let offset = Fmt.offsetSeconds(zone: zone, at: now).map(Fmt.offset(seconds:)) ?? String(localized: "unknown")
            let name = TimeZone(identifier: zone)?.localizedName(for: .generic, locale: .current) ?? zone
            let search = [zone.replacingOccurrences(of: "_", with: " "), name, offset].joined(separator: " ").lowercased()
            let region = zone.split(separator: "/").first.map(String.init) ?? zone
            return ZoneRow(id: zone, offset: offset, city: city(zone), detail: name, region: region, searchText: search)
        }
    }()

    static func filtered(_ query: String) -> [ZoneRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: "\u{2212}")
        guard !q.isEmpty else { return all }
        return all.filter { $0.searchText.contains(q) }
    }
}
