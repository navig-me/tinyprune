import Foundation
import TinyPruneIPC
import TinyPruneDomain

let schemaVersion = 1

enum CLIError: Error {
    case usage(String)
    case client(AgentClientError)
    case service(AgentServiceError)
    case unexpected
    case config(file: String, error: ConfigError)
    case rootsNotManaged([String])
    /// An earlier step of a multi-step command already took effect.
    case partiallyApplied(String, cause: any Error)
}

/// Positional operands and flags of one command. Unknown flags and a wrong operand count are usage errors.
struct CommandArguments {
    let operands: [String]
    let flags: Set<String>

    init(_ raw: [String], command: String, allowedFlags: Set<String> = [], operandCount: ClosedRange<Int>, operandUsage: String) throws {
        var operands: [String] = []
        var flags: Set<String> = []
        var optionsEnded = false
        for token in raw {
            if !optionsEnded, token == "--" {
                optionsEnded = true
            } else if !optionsEnded, token.hasPrefix("-"), token != "-" {
                guard allowedFlags.contains(token) else {
                    throw CLIError.usage("Unknown option '\(token)' for '\(command)'.")
                }
                flags.insert(token)
            } else {
                operands.append(token)
            }
        }
        guard operandCount.contains(operands.count) else {
            throw CLIError.usage(operands.count < operandCount.lowerBound
                ? "'\(command)' needs \(operandUsage)."
                : "'\(command)' takes \(operandUsage); unexpected argument '\(operands[operandCount.upperBound])'.")
        }
        self.operands = operands
        self.flags = flags
    }
}

@main
struct TinyPruneCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let wantsJSON = arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        if arguments.contains("--help") || arguments.contains("-h") || arguments.first == "help" {
            print(usage)
            exit(0)
        }
        let command = arguments.first ?? "status"
        let rest = Array(arguments.dropFirst())

        do {
            try await run(command: command, arguments: rest, json: wantsJSON)
        } catch {
            exit(report(error, json: wantsJSON))
        }
    }

    // MARK: Errors

    private struct Failure {
        let code: String
        let message: String
        let exitCode: Int32
        let mayHaveApplied: Bool
        let isUsage: Bool
    }

    private static func failure(for error: any Error) -> Failure {
        switch error {
        case CLIError.usage(let message):
            return Failure(code: "usage", message: message, exitCode: AgentErrorDescription.ExitCode.usage, mayHaveApplied: false, isUsage: true)
        case CLIError.client(let client):
            return Failure(
                code: AgentErrorDescription.code(for: client), message: AgentErrorDescription.message(for: client),
                exitCode: AgentErrorDescription.exitCode(for: client),
                mayHaveApplied: AgentErrorDescription.requestMayHaveApplied(client), isUsage: false
            )
        case CLIError.service(let service):
            return Failure(
                code: AgentErrorDescription.code(for: service), message: AgentErrorDescription.message(for: service),
                exitCode: AgentErrorDescription.exitCode(for: service), mayHaveApplied: false, isUsage: false
            )
        case CLIError.partiallyApplied(let prefix, let cause):
            let inner = failure(for: cause)
            return Failure(code: inner.code, message: "\(prefix) \(inner.message)", exitCode: inner.exitCode, mayHaveApplied: true, isUsage: false)
        default:
            return Failure(
                code: "unexpectedResponse", message: "TinyPrune agent returned an unexpected response.",
                exitCode: AgentErrorDescription.ExitCode.agentError, mayHaveApplied: false, isUsage: false
            )
        }
    }

    /// Prints the error (JSON on stdout with `--json`, text on stderr otherwise) and returns the exit code.
    private static func report(_ error: any Error, json: Bool) -> Int32 {
        switch error {
        case CLIError.config(let file, let configError):
            if json {
                emitJSON(InvalidConfigOutput(schemaVersion: schemaVersion, status: "invalid", file: file, line: configError.line, message: configError.message))
            } else {
                writeError("\(file):\(configError.line.map { "\($0): " } ?? " ")\(configError.message)\n")
            }
            return AgentErrorDescription.ExitCode.dataError
        case CLIError.rootsNotManaged(let roots):
            if json {
                emitJSON(RootsNotManagedOutput(schemaVersion: schemaVersion, status: "rootsNotManaged", roots: roots))
            } else {
                writeError("These config roots are not inside a managed folder:\n\(roots.map { "  \($0)" }.joined(separator: "\n"))\nAdd each folder in TinyPrune.app, then run the command again.\n")
            }
            return AgentErrorDescription.ExitCode.configuration
        case CLIError.client(.unavailable) where json:
            // Stable machine contract since v0.1.0: scripts and the Homebrew smoke test match this exact object.
            print("{\"schemaVersion\":\(schemaVersion),\"status\":\"unavailable\"}")
            return AgentErrorDescription.ExitCode.unavailable
        default:
            let info = failure(for: error)
            if json {
                emitJSON(ErrorOutput(
                    schemaVersion: schemaVersion, status: "error", code: info.code, message: info.message,
                    exitCode: Int(info.exitCode), mayHaveApplied: info.mayHaveApplied
                ))
            } else if info.isUsage {
                writeError("\(info.message)\n\(usage)\n")
            } else {
                writeError("tinyprune: \(info.message)\n")
                if info.mayHaveApplied { writeError("Check the result with `tinyprune status`, `tinyprune rules`, or `tinyprune upcoming` before retrying.\n") }
            }
            return info.exitCode
        }
    }

    private static func emitJSON<Value: Encodable>(_ value: Value) {
        if let data = try? JSONEncoder.sorted.encode(value) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("{\"schemaVersion\":\(schemaVersion),\"status\":\"error\"}")
        }
    }

    // MARK: Commands

    private static let usage = """
    usage: tinyprune [command] [--json]
      status | rules | upcoming | activity
      keep <path> [--descendants]
      expire <path> <7d|12h|30m|2w|tonight|tomorrow>
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
            _ = try CommandArguments(arguments, command: command, operandCount: 0...0, operandUsage: "no arguments")
            guard case .health(let health) = try await send(.health) else { throw CLIError.unexpected }
            if json {
                try printJSON(StatusOutput(schemaVersion: schemaVersion, status: "available", protocolVersion: health.protocolVersion, serviceVersion: health.serviceVersion))
            } else {
                print("TinyPrune agent available (protocol \(health.protocolVersion), service \(health.serviceVersion))")
            }
        case "rules":
            _ = try CommandArguments(arguments, command: command, operandCount: 0...0, operandUsage: "no arguments")
            guard case .policy(let snapshot) = try await send(.loadPolicy) else { throw CLIError.unexpected }
            if json {
                try printJSON(RulesOutput(schemaVersion: schemaVersion, globallyPaused: snapshot.globallyPaused, rules: snapshot.rules))
            } else if snapshot.rules.isEmpty {
                print("No rules configured.")
            } else {
                if snapshot.globallyPaused { print("All rules are paused.") }
                for rule in snapshot.rules {
                    print("\(rule.id.uuidString)  \(rule.name)  \(rule.state.rawValue)  \(rule.scope.path)  \(ConfigPlan.matcherDescription(rule))  \(rule.expiryBasis.rawValue) for \(ConfigPlan.durationDescription(rule.lifetime.seconds))")
                }
            }
        case "upcoming":
            _ = try CommandArguments(arguments, command: command, operandCount: 0...0, operandUsage: "no arguments")
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
            _ = try CommandArguments(arguments, command: command, operandCount: 0...0, operandUsage: "no arguments")
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
            let parsed = try CommandArguments(arguments, command: command, allowedFlags: ["--descendants"], operandCount: 1...1, operandUsage: "a path")
            let path = try normalizedPath(parsed.operands[0])
            try await mutate(.setItemOverride(path: path, policy: .keep(protectDescendants: parsed.flags.contains("--descendants"))), json: json, summary: "Keeping \(path)")
        case "expire":
            let parsed = try CommandArguments(arguments, command: command, operandCount: 2...2, operandUsage: "a path and a time")
            guard let preset = ExpiryPreset(parsing: parsed.operands[1]) else {
                if ExpiryPreset(parsing: parsed.operands[0]) != nil {
                    throw CLIError.usage("The arguments look swapped: use `tinyprune expire <path> <when>`, for example `tinyprune expire \(parsed.operands[1]) \(parsed.operands[0])`.")
                }
                throw CLIError.usage("Unrecognized time '\(parsed.operands[1])'. Use a number with m, h, d, or w (for example 7d), or tonight or tomorrow.")
            }
            let path = try normalizedPath(parsed.operands[0])
            let date = preset.date(from: Date(), calendar: .current)
            try await mutate(.setItemOverride(path: path, policy: .customExpiry(date, state: .active)), json: json, summary: "\(path) expires \(date.formatted(date: .abbreviated, time: .shortened))")
        case "inherit":
            let parsed = try CommandArguments(arguments, command: command, operandCount: 1...1, operandUsage: "a path")
            let path = try normalizedPath(parsed.operands[0])
            try await mutate(.clearItemOverride(path: path), json: json, summary: "\(path) now inherits its rule")
        case "why":
            let parsed = try CommandArguments(arguments, command: command, operandCount: 1...1, operandUsage: "a path")
            let path = try normalizedPath(parsed.operands[0])
            guard case .itemExplanation(let explanation) = try await send(.explainItem(path: path)) else { throw CLIError.unexpected }
            if json {
                try printJSON(WhyOutput(schemaVersion: schemaVersion, explanation: explanation))
            } else {
                print(ExplanationFormatter.describe(explanation, now: Date(), calendar: .current, locale: .current))
            }
        case "pause":
            let parsed = try CommandArguments(arguments, command: command, operandCount: 0...1, operandUsage: "an optional length")
            if let spec = parsed.operands.first {
                let now = Date()
                let calendar = Calendar.current
                let date: Date?
                switch spec.lowercased() {
                case "today": date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                case "tomorrow": date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                    .flatMap { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }
                default: date = ExpiryPreset(parsing: spec)?.date(from: now, calendar: calendar)
                }
                guard let date, date > now else { throw CLIError.usage("Unrecognized pause length '\(spec)'.") }
                try await mutate(.pauseUntil(date), json: json, summary: "TinyPrune is paused until \(date.formatted(date: .abbreviated, time: .shortened))")
            } else {
                try await mutate(.setGlobalPause(true), json: json, summary: "TinyPrune is paused")
            }
        case "resume":
            _ = try CommandArguments(arguments, command: command, operandCount: 0...0, operandUsage: "no arguments")
            try await mutate(.setGlobalPause(false), json: json, summary: "TinyPrune resumed")
        case "delete-rule":
            let parsed = try CommandArguments(arguments, command: command, operandCount: 1...1, operandUsage: "a rule id")
            guard let id = UUID(uuidString: parsed.operands[0]) else { throw CLIError.usage("'\(parsed.operands[0])' is not a rule id. Run `tinyprune rules` to list ids.") }
            try await mutate(.deleteRule(id), json: json, summary: "Rule deleted")
        case "rebuild-index":
            _ = try CommandArguments(arguments, command: command, operandCount: 0...0, operandUsage: "no arguments")
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
        } catch let error as AgentClientError {
            throw CLIError.client(error)
        } catch {
            throw CLIError.client(.unavailable)
        }
        if case .failure(let error) = response.payload { throw CLIError.service(error) }
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

    static func normalizedPath(_ raw: String) throws -> String {
        guard !raw.isEmpty else { throw CLIError.usage("A path must not be empty.") }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    static func printJSON<Value: Encodable>(_ value: Value) throws {
        let data = try JSONEncoder.sorted.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private struct ErrorOutput: Encodable {
    let schemaVersion: Int
    let status: String
    let code: String
    let message: String
    let exitCode: Int
    let mayHaveApplied: Bool
}

private struct InvalidConfigOutput: Encodable {
    let schemaVersion: Int
    let status: String
    let file: String
    let line: Int?
    let message: String
}

private struct RootsNotManagedOutput: Encodable {
    let schemaVersion: Int
    let status: String
    let roots: [String]
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
            let (file, document, _) = try load(rest, subcommand: subcommand, allowedFlags: [])
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
            let (file, document, active) = try load(rest, subcommand: subcommand, allowedFlags: ["--active"])
            let plan = try makePlan(document: document, snapshot: try await loadPolicy(), active: active)
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
            let (file, document, active) = try load(rest, subcommand: subcommand, allowedFlags: ["--active"])
            // The agent only accepts a policy written against the revision it was read at, so a concurrent
            // edit (or pause) is never overwritten. On a conflict, reload and re-plan against the new state.
            var appliedPlan: ConfigPlan?
            for attempt in 1...3 {
                let snapshot = try await loadPolicy()
                let candidate = try makePlan(document: document, snapshot: snapshot, active: active)
                guard candidate.isApplicable else { throw CLIError.rootsNotManaged(candidate.unmanagedRoots) }
                appliedPlan = candidate
                guard candidate.hasRuleChanges else { break }
                let replacement = AgentPolicySnapshot(
                    rules: candidate.merged, overrides: snapshot.overrides,
                    managedRoots: snapshot.managedRoots, globallyPaused: snapshot.globallyPaused,
                    pausedUntil: snapshot.pausedUntil, revision: snapshot.revision
                )
                do {
                    guard case .acknowledged = try await TinyPruneCLI.send(.replacePolicy(replacement)) else { throw CLIError.unexpected }
                    break
                } catch CLIError.service(let error) where error == .policyConflict && attempt < 3 {
                    appliedPlan = nil
                    continue
                }
            }
            guard let plan = appliedPlan else { throw CLIError.service(.policyConflict) }
            let newExceptions = plan.exceptions.filter(\.isNew)
            if !newExceptions.isEmpty {
                let changes = newExceptions.map { AgentItemOverrideChange(path: $0.override.path, policy: $0.override.policy) }
                do {
                    guard case .acknowledged = try await TinyPruneCLI.send(.setItemOverrides(changes: changes)) else { throw CLIError.unexpected }
                } catch where plan.hasRuleChanges {
                    throw CLIError.partiallyApplied("The rules were applied, but the exceptions were not set.", cause: error)
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
            _ = try CommandArguments(rest, command: "config export", operandCount: 0...0, operandUsage: "no arguments")
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

    private static func load(_ arguments: [String], subcommand: String, allowedFlags: Set<String>) throws -> (file: String, document: ConfigDocument, active: Bool) {
        let parsed = try CommandArguments(arguments, command: "config \(subcommand)", allowedFlags: allowedFlags, operandCount: 1...1, operandUsage: "exactly one file")
        let file = try TinyPruneCLI.normalizedPath(parsed.operands[0])
        let active = parsed.flags.contains("--active")
        let text: String
        do {
            text = try String(contentsOfFile: file, encoding: .utf8)
        } catch {
            throw CLIError.config(file: file, error: ConfigError(line: nil, message: "Cannot read file: \(error.localizedDescription)"))
        }
        do {
            return (file, try ConfigDocument.parse(text, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path), active)
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
