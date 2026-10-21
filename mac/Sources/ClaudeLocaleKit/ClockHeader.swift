import SwiftUI

/// The chosen zone's current time, formatted the way the chosen locale formats it.
struct ClockHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = model.now
            let zone = model.draft.timeZone
            let clock = Fmt.clock(now, zone: zone, locale: model.draft.locale)
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ZoneRow.city(zone))
                        .font(.title3.weight(.semibold))
                    Text(verbatim: clock.time)
                        .font(.system(size: 52, weight: .light).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: clock.date)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: zone)
                        .font(.callout.weight(.medium))
                    Text(verbatim: offsetLine(zone: zone, at: now))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(verbatim: relation(zone: zone, at: now))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.trailing)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
    }

    private func offsetLine(zone: String, at date: Date) -> String {
        let offset = Fmt.offsetSeconds(zone: zone, at: date).map(Fmt.offset(seconds:)) ?? String(localized: "unknown")
        guard let abbreviation = Fmt.abbreviation(zone: zone, at: date), !abbreviation.hasPrefix("GMT") else {
            return offset
        }
        return "\(offset)  \(abbreviation)"
    }

    private func relation(zone: String, at date: Date) -> String {
        guard let target = Fmt.offsetSeconds(zone: zone, at: date) else { return "" }
        let delta = target - model.hostZone.secondsFromGMT(for: date)
        if delta == 0 { return String(localized: "Same time as this Mac") }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        let amount = f.string(from: TimeInterval(abs(delta))) ?? ""
        return delta > 0
            ? String(localized: "\(amount) ahead of this Mac")
            : String(localized: "\(amount) behind this Mac")
    }
}
