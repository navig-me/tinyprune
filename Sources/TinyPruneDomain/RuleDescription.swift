import Foundation

public extension RuleDuration {
    /// Compact human wording such as "30 days" or "6 hours".
    var humanDescription: String {
        let day: TimeInterval = 86_400
        func plural(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        if seconds.truncatingRemainder(dividingBy: day) == 0 { return plural(Int(seconds / day), "day") }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return plural(Int(seconds / 3_600), "hour") }
        if seconds.truncatingRemainder(dividingBy: 60) == 0 { return plural(Int(seconds / 60), "minute") }
        return plural(Int(seconds), "second")
    }
}

public extension ExpiryBasis {
    var phrase: String {
        switch self {
        case .created: "after creation"
        case .modified: "since last modification"
        case .firstObserved: "after TinyPrune first saw it"
        case .observedActivity: "since the last observed activity"
        case .accessed: "since last access"
        case .projectActivity: "of project inactivity"
        case .explicitDate: "after the chosen date"
        }
    }
}

public extension LifetimeRule {
    /// "When a folder named node_modules is inside ~/Developer/** and 30 days of project inactivity have passed, move the folder to Trash."
    func naturalDescription(homeDirectory: String = NSHomeDirectory()) -> String {
        let kindNoun: String
        switch matcher.itemKind {
        case .file: kindNoun = "file"
        case .directory: kindNoun = "folder"
        case .fileOrDirectory: kindNoun = "item"
        }
        let names = matcher.exactNames.sorted()
        let globs = matcher.globPatterns.sorted()
        let subject: String
        if names.isEmpty && globs.isEmpty {
            subject = "any \(kindNoun)"
        } else if !names.isEmpty && globs.isEmpty {
            subject = "a \(kindNoun) named \(names.joined(separator: " or "))"
        } else {
            subject = "a \(kindNoun) matching \((names + globs).joined(separator: ", "))"
        }
        var display = scope.path
        if display == homeDirectory { display = "~" }
        else if display.hasPrefix(homeDirectory + "/") { display = "~" + display.dropFirst(homeDirectory.count) }
        let place = scope.recursive ? "\(display)/**" : display
        let action: String
        switch self.action {
        case .trashItem: action = "move the \(kindNoun) to Trash"
        case .emptyContents: action = "move the folder's contents to Trash"
        case .trashMatchingChildren: action = "move matching children to Trash"
        }
        let grace = gracePeriod.map { " After a \($0.humanDescription) grace period," } ?? ""
        return "When \(subject) is inside \(place) and \(lifetime.humanDescription) \(expiryBasis.phrase) have passed,\(grace) \(action)."
    }
}
