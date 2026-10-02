import Foundation
import TinyPruneIPC
import TinyPruneDomain

let schemaVersion = 1

enum CLIError: Error {
    case usage(String)
    case unavailable
    case agent(String)
    case unexpected
    case config(file: String, error: ConfigError)
    case rootsNotManaged([String])
}

@main
struct TinyPruneCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let wantsJSON = arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        let command = arguments.first ?? "status"
        let rest = Array(arguments.dropFirst())

        do {
            try await run(command: command, arguments: rest, json: wantsJSON)
        } catch CLIError.usage(let message) {
            writeError("\(message)\n\(usage)\n")
            exit(64)
        } catch CLIError.unavailable {
            if wantsJSON {
                print("{\"schemaVersion\":\(schemaVersion),\"status\":\"unavailable\"}")
            } else {
                writeError("TinyPrune agent is unavailable. Open TinyPrune.app and try again.\n")
            }
            exit(69)
        } catch CLIError.config(let file, let error) {
            if wantsJSON {
                let line = error.line.map(String.init) ?? "null"
                let message = String(decoding: (try? JSONEncoder().encode(error.message)) ?? Data("\"\"".utf8), as: UTF8.self)
                let path = String(decoding: (try? JSONEncoder().encode(file)) ?? Data("\"\"".utf8), as: UTF8.self)
                print("{\"schemaVersion\":\(schemaVersion),\"status\":\"invalid\",\"file\":\(path),\"line\":\(line),\"message\":\(message)}")
            } else {
                writeError("\(file):\(error.line.map { "\($0): " } ?? " ")\(error.message)\n")
            }
            exit(65)
        } catch CLIError.rootsNotManaged(let roots) {
            if wantsJSON {
                let list = String(decoding: (try? JSONEncoder().encode(roots)) ?? Data("[]".utf8), as: UTF8.self)
                print("{\"schemaVersion\":\(schemaVersion),\"status\":\"rootsNotManaged\",\"roots\":\(list)}")
            } else {
                writeError("These config roots are not inside a managed folder:\n\(roots.map { "  \($0)" }.joined(separator: "\n"))\nAdd each folder in TinyPrune.app, then run the command again.\n")
            }
            exit(78)
        } catch CLIError.agent(let message) {
            writeError("TinyPrune agent request failed: \(message)\n")
            exit(69)
        } catch {
            writeError("TinyPrune agent returned an unexpected response.\n")
            exit(70)
        }
    }

    private static let usage = """
    usage: tinyprune [command] [--json]
      status | rules | upcoming | activity
      keep <path> [--descendants]
      expire <path> <7d|12h|30m|tonight|tomorrow>
      inherit <path>
      why <path>
      pause [1h|today|tomorrow] | resume
      delete-rule <rule-id>
      rebuild-index
      config validate <file> | config preview <file> [--active]
      config apply <file> [--active] | config export
    """

    private static func run(command: String, arguments: [String], json: Bool) async throws {
        switch command {
        case "status":
            guard case .health(let health) = try await send(.health) else { throw CLIError.unexpected }
            if json {
                try printJSON(StatusOutput(schemaVersion: schemaVersion, status: "available", protocolVersion: health.protocolVersion, serviceVersion: health.serviceVersion))
            } else {
                print("TinyPrune agent available (protocol \(health.protocolVersion), service \(health.serviceVersion))")
            }
        case "rules":
            guard case .policy(let snapshot) = try await send(.loadPolicy) else { throw CLIError.unexpected }
            if json {
                try printJSON(RulesOutput(schemaVersion: schemaVersion, globallyPaused: snapshot.globallyPaused, rules: snapshot.rules))
            } else if snapshot.rules.isEmpty {
                print("No rules configured.")
            } else {
                if snapshot.globallyPaused { print("All rules are paused.") }
                for rule in snapshot.rules {
                    print("\(rule.id.uuidString)  \(rule.name)  \(rule.state.rawValue)  \(rule.scope.path)  \(matcherDescription(rule))  \(rule.expiryBasis.rawValue) for \(durationDescription(rule.lifetime.seconds))")
                }
            }
        case "upcoming":
            guard case .overview(let overview) = try await send(.loadOverview) else { throw CLIError.unexpected }
            if json {
                try printJSON(UpcomingOutput(schemaVersion: schemaVersion, items: overview.upcoming.map(\.explanation)))
            } else if overview.upcoming.isEmpty {
                print("No scheduled items.")
            } else {
                for item in overview.upcoming {
                    let explanation = item.explanation
                    print("\(explanation.candidateIdentity.pathHint)  \(explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened))  \(explanation.matchedRuleName)  \(explanation.disposition.rawValue)")
                }
            }
        case "activity":
            guard case .activity(let items) = try await send(.loadActivity(limit: 50)) else { throw CLIError.unexpected }
            if json {
                try printJSON(ActivityOutput(schemaVersion: schemaVersion, events: items))
            } else if items.isEmpty {
                print("No activity recorded.")
            } else {
                for item in items {
                    print("\(item.occurredAt.formatted(date: .abbreviated, time: .standard))  \(item.kind.rawValue)  \(item.identity?.pathHint ?? item.detail ?? "")")
                }
            }
        case "keep":
            let path = try pathArgument(arguments)
            let descendants = arguments.contains("--descendants")
            try await mutate(.setItemOverride(path: path, policy: .keep(protectDescendants: descendants)), json: json, summary: "Keeping \(path)")
        case "expire":
            guard arguments.count == 2 else { throw CLIError.usage("expire needs a path and a time.") }
            let path = try pathArgument(arguments)
            guard let date = parseExpiry(arguments[1], now: Date()) else {
                throw CLIError.usage("Unrecognized time '\(arguments[1])'.")
            }
            try await mutate(.setItemOverride(path: path, policy: .customExpiry(date, state: .active)), json: json, summary: "\(path) expires \(date.formatted(date: .abbreviated, time: .shortened))")
        case "inherit":
            let path = try pathArgument(arguments)
            try await mutate(.clearItemOverride(path: path), json: json, summary: "\(path) now inherits its rule")
        case "why":
            let path = try pathArgument(arguments)
            guard case .itemExplanation(let explanation) = try await send(.explainItem(path: path)) else { throw CLIError.unexpected }
            if json {
                try printJSON(WhyOutput(schemaVersion: schemaVersion, explanation: explanation))
            } else {
                print(describe(explanation))
            }
        case "pause":
            if let spec = arguments.first {
                let date: Date?
                switch spec.lowercased() {
                case "today": date = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                case "tomorrow": date = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date())
                default: date = parseExpiry(spec, now: Date())
                }
                guard let date, date > Date() else { throw CLIError.usage("Unrecognized pause length '\(spec)'.") }
                try await mutate(.pauseUntil(date), json: json, summary: "TinyPrune is paused until \(date.formatted(date: .abbreviated, time: .shortened))")
            } else {
                try await mutate(.setGlobalPause(true), json: json, summary: "TinyPrune is paused")
            }
        case "resume":
            try await mutate(.setGlobalPause(false), json: json, summary: "TinyPrune resumed")
        case "delete-rule":
            guard arguments.count == 1, let id = UUID(uuidString: arguments[0]) else { throw CLIError.usage("delete-rule needs a rule id.") }
            try await mutate(.deleteRule(id), json: json, summary: "Rule deleted")
        case "rebuild-index":
            try await mutate(.rebuildIndex, json: json, summary: "Index rebuild started")
        case "config":
            try await ConfigCommand.run(arguments: arguments, json: json)
        default:
            throw CLIError.usage("Unknown command '\(command)'.")
        }
    }

    static func send(_ operation: AgentOperation) async throws -> AgentResponsePayload {
        let response: AgentResponse
        do {
            response = try await TinyPruneAgentClient().request(AgentRequest(operation: operation))
        } catch {
            throw CLIError.unavailable
        }
        if case .failure(let error) = response.payload { throw CLIError.agent(String(describing: error)) }
        return response.payload
    }

    private static func mutate(_ operation: AgentOperation, json: Bool, summary: String) async throws {
        guard case .acknowledged = try await send(operation) else { throw CLIError.unexpected }
        if json {
            try printJSON(MutationOutput(schemaVersion: schemaVersion, status: "ok", summary: summary))
        } else {
            print(summary)
        }
    }

    static func pathArgument(_ arguments: [String]) throws -> String {
        guard let raw = arguments.first(where: { !$0.hasPrefix("--") }) else { throw CLIError.usage("A path is required.") }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return url.standardizedFileURL.path
    }

    static func parseExpiry(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        switch text.lowercased() {
        case "tonight":
            return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now).flatMap { $0 > now ? $0 : nil }
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: now)
        default:
            guard let unit = text.last, let amount = Double(text.dropLast()), amount > 0 else { return nil }
            let seconds: Double
            switch unit {
            case "m": seconds = 60
            case "h": seconds = 3_600
            case "d": seconds = 86_400
            case "w": seconds = 604_800
            default: return nil
            }
            return now.addingTimeInterval(amount * seconds)
        }
    }

    private static func describe(_ explanation: AgentItemExplanation) -> String {
        var lines = [explanation.path]
        switch explanation.resolution {
        case .scheduled(let item):
            lines.append("Scheduled: \(item.scheduledAt.formatted(date: .abbreviated, time: .shortened)) (\(item.disposition.rawValue))")
            lines.append("Matched rule: \(item.matchedRuleName)")
            lines.append("Reason: \(item.expiryBasis.rawValue) since \(item.basisDate.formatted(date: .abbreviated, time: .shortened))")
        case .customExpiry(let item):
            lines.append("Scheduled: \(item.expiresAt.formatted(date: .abbreviated, time: .shortened)) (\(item.disposition.rawValue))")
            lines.append("Reason: explicit expiry set on this item")
        case .protected(let item):
            lines.append("Protected by Keep on \(item.protectedPath)\(item.protectsDescendants ? " (including descendants)" : "")")
        case .suppressed(let reason):
            lines.append("Not scheduled: \(reason.rawValue)")
        case .noRule:
            lines.append("No rule applies; TinyPrune will do nothing.")
        case .ambiguousRules(let ids):
            lines.append("Not scheduled: \(ids.count) rules tie; TinyPrune will not guess.")
        case .ambiguousOverrides(let ids):
            lines.append("Not scheduled: \(ids.count) conflicting overrides.")
        }
        lines.append("Overrides: \(explanation.overrides.isEmpty ? "None" : explanation.overrides.map(\.path).joined(separator: ", "))")
        if explanation.globallyPaused { lines.append("TinyPrune is paused globally.") }
        return lines.joined(separator: "\n")
    }

    static func matcherDescription(_ rule: LifetimeRule) -> String { ConfigPlan.matcherDescription(rule) }

    static func durationDescription(_ seconds: TimeInterval) -> String { ConfigPlan.durationDescription(seconds) }

    static func printJSON<Value: Encodable>(_ value: Value) throws {
        let data = try JSONEncoder.sorted.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private struct StatusOutput: Encodable {
    let schemaVersion: Int
    let status: String
    let protocolVersion: Int
    let serviceVersion: String
}

private struct RulesOutput: Encodable {
    let schemaVersion: Int
    let globallyPaused: Bool
    let rules: [LifetimeRule]
}

private struct UpcomingOutput: Encodable {
    let schemaVersion: Int
    let items: [CandidateExplanation]
}

private struct ActivityOutput: Encodable {
    let schemaVersion: Int
    let events: [AgentActivityItem]
}

private struct WhyOutput: Encodable {
    let schemaVersion: Int
    let explanation: AgentItemExplanation
}

private struct MutationOutput: Encodable {
    let schemaVersion: Int
    let status: String
    let summary: String
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// `tinyprune config …` (spec §41). Parsing is local; every policy read or write goes through the agent.
enum ConfigCommand {
    static func run(arguments: [String], json: Bool) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.usage("config needs validate, preview, apply, or export.")
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "validate":
            let (file, document) = try load(rest, allowedFlags: [])
            let instances = document.roots.count * document.rules.count
            if json {
                try TinyPruneCLI.printJSON(ValidateOutput(
                    schemaVersion: schemaVersion, status: "valid", file: file, roots: document.roots.map(\.path),
                    rules: document.rules.count, ruleInstances: instances, exceptions: document.exceptions.count
                ))
            } else {
                print("\(file) is valid: \(document.roots.count) root(s), \(document.rules.count) rule(s) (\(instances) scoped), \(document.exceptions.count) exception(s).")
            }
        case "preview":
            let (file, document) = try load(rest, allowedFlags: ["--active"])
            let plan = try makePlan(document: document, snapshot: try await loadPolicy(), active: rest.contains("--active"))
            if json {
                try TinyPruneCLI.printJSON(PreviewOutput(
                    schemaVersion: schemaVersion, status: "preview", file: file, applicable: plan.unmanagedRoots.isEmpty,
                    unmanagedRoots: plan.unmanagedRoots, added: plan.added,
                    changed: plan.changed.map { ChangedRule(before: $0.before, after: $0.after, fields: $0.fields) },
                    removed: plan.removed, unchanged: plan.unchanged,
                    exceptions: plan.exceptions.map { ExceptionPlan(path: $0.override.path, policy: $0.override.policy, action: $0.isNew ? "set" : "unchanged") }
                ))
            } else {
                printPreview(file: file, document: document, plan: plan)
            }
        case "apply":
            let (file, document) = try load(rest, allowedFlags: ["--active"])
            let snapshot = try await loadPolicy()
            let plan = try makePlan(document: document, snapshot: snapshot, active: rest.contains("--active"))
            guard plan.isApplicable else { throw CLIError.rootsNotManaged(plan.unmanagedRoots) }
            if plan.hasRuleChanges {
                let replacement = AgentPolicySnapshot(
                    rules: plan.merged, overrides: snapshot.overrides,
                    managedRoots: snapshot.managedRoots, globallyPaused: snapshot.globallyPaused
                )
                guard case .acknowledged = try await TinyPruneCLI.send(.replacePolicy(replacement)) else { throw CLIError.unexpected }
            }
            let newExceptions = plan.exceptions.filter(\.isNew)
            for exception in newExceptions {
                guard case .acknowledged = try await TinyPruneCLI.send(.setItemOverride(path: exception.override.path, policy: exception.override.policy)) else {
                    throw CLIError.unexpected
                }
            }
            if json {
                try TinyPruneCLI.printJSON(ApplyOutput(
                    schemaVersion: schemaVersion, status: "applied", file: file, added: plan.added.count, changed: plan.changed.count,
                    removed: plan.removed.count, unchanged: plan.unchanged, exceptionsSet: newExceptions.count
                ))
            } else {
                print("Applied \(file): \(plan.added.count) added, \(plan.changed.count) changed, \(plan.removed.count) removed, \(plan.unchanged) unchanged; \(newExceptions.count) exception(s) set.")
                if plan.added.contains(where: { $0.state == .preview }) {
                    print("New rules start in Preview; review upcoming matches, then re-run with --active to enable them.")
                }
            }
        case "export":
            let snapshot = try await loadPolicy()
            let text = ConfigDocument.render(policy: snapshot.rules, roots: snapshot.managedRoots, overrides: snapshot.overrides)
            if json {
                try TinyPruneCLI.printJSON(ExportOutput(schemaVersion: schemaVersion, config: text))
            } else {
                print(text, terminator: "")
            }
        default:
            throw CLIError.usage("Unknown config command '\(subcommand)'.")
        }
    }

    // MARK: Loading

    private static func load(_ arguments: [String], allowedFlags: Set<String>) throws -> (String, ConfigDocument) {
        if let flag = arguments.first(where: { $0.hasPrefix("--") && !allowedFlags.contains($0) }) {
            throw CLIError.usage("Unknown option '\(flag)'.")
        }
        let operands = arguments.filter { !$0.hasPrefix("--") }
        guard operands.count == 1 else { throw CLIError.usage("config needs exactly one file.") }
        let file = try TinyPruneCLI.pathArgument(operands)
        let text: String
        do {
            text = try String(contentsOfFile: file, encoding: .utf8)
        } catch {
            throw CLIError.config(file: file, error: ConfigError(line: nil, message: "Cannot read file: \(error.localizedDescription)"))
        }
        do {
            return (file, try ConfigDocument.parse(text, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path))
        } catch let error as ConfigError {
            throw CLIError.config(file: file, error: error)
        }
    }

    private static func loadPolicy() async throws -> AgentPolicySnapshot {
        guard case .policy(let snapshot) = try await TinyPruneCLI.send(.loadPolicy) else { throw CLIError.unexpected }
        return snapshot
    }

    private static func makePlan(document: ConfigDocument, snapshot: AgentPolicySnapshot, active: Bool) throws -> ConfigPlan {
        try ConfigPlan.make(
            document: document, currentRules: snapshot.rules, currentRoots: snapshot.managedRoots,
            currentOverrides: snapshot.overrides, activate: active
        )
    }

    // MARK: Output

    private static func printPreview(file: String, document: ConfigDocument, plan: ConfigPlan) {
        print("Config \(file): \(document.roots.count) root(s), \(document.rules.count) rule(s). Nothing was changed.")
        plan.summaryLines.forEach { print($0) }
    }

    // MARK: JSON payloads

    private struct ValidateOutput: Encodable {
        let schemaVersion: Int
        let status: String
        let file: String
        let roots: [String]
        let rules: Int
        let ruleInstances: Int
        let exceptions: Int
    }

    private struct ChangedRule: Encodable {
        let before: LifetimeRule
        let after: LifetimeRule
        let fields: [String]
    }

    private struct ExceptionPlan: Encodable {
        let path: String
        let policy: ItemOverridePolicy
        let action: String
    }

    private struct PreviewOutput: Encodable {
        let schemaVersion: Int
        let status: String
        let file: String
        let applicable: Bool
        let unmanagedRoots: [String]
        let added: [LifetimeRule]
        let changed: [ChangedRule]
        let removed: [LifetimeRule]
        let unchanged: Int
        let exceptions: [ExceptionPlan]
    }

    private struct ApplyOutput: Encodable {
        let schemaVersion: Int
        let status: String
        let file: String
        let added: Int
        let changed: Int
        let removed: Int
        let unchanged: Int
        let exceptionsSet: Int
    }

    private struct ExportOutput: Encodable {
        let schemaVersion: Int
        let config: String
    }
}
