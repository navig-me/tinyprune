import Foundation

/// Item-expiry choices shared by the CLI and the Finder extension so both surfaces compute the same instant.
///
/// `tonight` is the next 23:59 in the supplied calendar. When it is already 23:59 or later it rolls to the
/// next day's 23:59 rather than silently shrinking to an hour-long expiry.
public enum ExpiryPreset: Equatable, Sendable {
    case tonight
    case tomorrow
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case weeks(Int)

    /// Longest accepted relative expiry (100 years). Larger values are rejected rather than overflowing.
    public static let maximumSeconds: Int = 100 * 365 * 86_400

    /// Parses `tonight`, `tomorrow`, or a positive whole number followed by `m`, `h`, `d`, or `w`.
    public init?(parsing text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "tonight": self = .tonight
        case "tomorrow": self = .tomorrow
        default:
            guard let unit = normalized.last,
                  let amount = Int(normalized.dropLast()),
                  amount > 0 else { return nil }
            let preset: ExpiryPreset
            let unitSeconds: Int
            switch unit {
            case "m": preset = .minutes(amount); unitSeconds = 60
            case "h": preset = .hours(amount); unitSeconds = 3_600
            case "d": preset = .days(amount); unitSeconds = 86_400
            case "w": preset = .weeks(amount); unitSeconds = 604_800
            default: return nil
            }
            let (seconds, overflow) = amount.multipliedReportingOverflow(by: unitSeconds)
            guard !overflow, seconds <= Self.maximumSeconds else { return nil }
            self = preset
        }
    }

    /// The expiry instant, always strictly after `now`.
    public func date(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .tonight:
            if let tonight = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now), tonight > now {
                return tonight
            }
            if let today = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now),
               let next = calendar.date(byAdding: .day, value: 1, to: today), next > now {
                return next
            }
            return now.addingTimeInterval(86_400)
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        case .minutes(let amount):
            return now.addingTimeInterval(TimeInterval(amount) * 60)
        case .hours(let amount):
            return now.addingTimeInterval(TimeInterval(amount) * 3_600)
        case .days(let amount):
            return calendar.date(byAdding: .day, value: amount, to: now) ?? now.addingTimeInterval(TimeInterval(amount) * 86_400)
        case .weeks(let amount):
            return calendar.date(byAdding: .day, value: amount * 7, to: now) ?? now.addingTimeInterval(TimeInterval(amount) * 604_800)
        }
    }

    /// Short label for menus.
    public var title: String {
        switch self {
        case .tonight: "Tonight"
        case .tomorrow: "Tomorrow"
        case .minutes(let amount): amount == 1 ? "1 Minute" : "\(amount) Minutes"
        case .hours(let amount): amount == 1 ? "1 Hour" : "\(amount) Hours"
        case .days(let amount): amount == 1 ? "1 Day" : "\(amount) Days"
        case .weeks(let amount): amount == 1 ? "1 Week" : "\(amount) Weeks"
        }
    }
}
