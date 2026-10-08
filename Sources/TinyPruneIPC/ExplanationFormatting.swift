import Foundation
import TinyPruneDomain

/// Human-readable explanation text shared by the CLI (`why`) and the Finder extension so both always agree.
/// Pure and deterministic: time, calendar, and locale are injected.
public enum ExplanationFormatter {
    /// Full description, including the item overrides that were considered.
    public static func describe(
        _ explanation: AgentItemExplanation,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var lines = summaryLines(explanation, now: now, calendar: calendar, locale: locale)
        if explanation.overrides.isEmpty {
            lines.append("Overrides: none")
        } else {
            lines.append("Overrides:")
            for override in explanation.overrides {
                lines.append("  \(override.path): \(overrideDescription(override.policy, calendar: calendar, locale: locale))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Short description without the override list.
    public static func summary(
        _ explanation: AgentItemExplanation,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        summaryLines(explanation, now: now, calendar: calendar, locale: locale).joined(separator: "\n")
    }

    static func summaryLines(_ explanation: AgentItemExplanation, now: Date, calendar: Calendar, locale: Locale) -> [String] {
        func format(_ date: Date) -> String { Self.format(date, calendar: calendar, locale: locale) }
        var lines = [explanation.path]
        switch explanation.resolution {
        case .scheduled(let item):
            lines.append(schedule(at: item.scheduledAt, disposition: item.disposition, now: now, format: format))
            lines.append("Rule: \(item.matchedRuleName)")
            lines.append("Reason: \(basisPhrase(item.expiryBasis)) (\(format(item.basisDate)))")
            if item.scheduledAt > item.eligibleAt {
                lines.append("Includes a grace period; it was eligible \(format(item.eligibleAt)).")
            }
        case .customExpiry(let item):
            lines.append(schedule(at: item.expiresAt, disposition: item.disposition, now: now, format: format))
            lines.append("Reason: an expiry was set on this item")
        case .protected(let item):
            if RuleScope.normalized(item.protectedPath) == RuleScope.normalized(explanation.path) {
                lines.append("Kept: TinyPrune will not touch this item.")
            } else {
                lines.append("Kept: protected because \(item.protectedPath) is kept\(item.protectsDescendants ? " (including everything inside it)" : "").")
            }
        case .suppressed(let reason):
            lines.append("Not scheduled: \(suppressionPhrase(reason))")
        case .noRule:
            lines.append("No rule applies; TinyPrune will do nothing.")
        case .ambiguousRules(let ids):
            lines.append("Not scheduled: \(ids.count) rules tie, and TinyPrune will not guess.")
        case .ambiguousOverrides(let ids):
            lines.append("Not scheduled: \(ids.count) item overrides conflict.")
        }
        if explanation.globallyPaused { lines.append("TinyPrune is paused, so nothing is moved right now.") }
        return lines
    }

    private static func schedule(at date: Date, disposition: ScheduledDisposition, now: Date, format: (Date) -> String) -> String {
        switch disposition {
        case .active:
            return date <= now
                ? "Due now: moves to the Trash on the next safety check."
                : "Scheduled: moves to the Trash on \(format(date))."
        case .preview:
            return date <= now
                ? "Preview: would be due now. Nothing is moved while the rule is in Preview."
                : "Preview: would move to the Trash on \(format(date)). Nothing is moved while the rule is in Preview."
        }
    }

    static func basisPhrase(_ basis: ExpiryBasis) -> String {
        switch basis {
        case .created: "counted from when it was created"
        case .modified: "counted from when it was last modified"
        case .firstObserved: "counted from when TinyPrune first saw it"
        case .observedActivity: "counted from the last activity TinyPrune saw"
        case .accessed: "counted from when it was last opened"
        case .projectActivity: "counted from the last activity in its project"
        case .explicitDate: "counted from a date you set"
        }
    }

    static func suppressionPhrase(_ reason: EvaluationSuppression) -> String {
        switch reason {
        case .itemDoesNotMatch: "the item does not match the rule"
        case .missingExpiryTimestamp: "TinyPrune does not yet know the date the rule counts from"
        case .pausedRule: "the rule is paused"
        case .globalPause: "TinyPrune is paused"
        case .previewOnly: "the rule is in Preview"
        case .hiddenProtected: "hidden items are protected"
        }
    }

    static func overrideDescription(_ policy: ItemOverridePolicy, calendar: Calendar, locale: Locale) -> String {
        switch policy {
        case .inherit: "uses its folder rules"
        case .keep(let protectDescendants): protectDescendants ? "Keep, including everything inside" : "Keep"
        case .customExpiry(let date, let state):
            "expires \(format(date, calendar: calendar, locale: locale))\(state == .active ? "" : " (\(state.rawValue))")"
        }
    }

    static func format(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
