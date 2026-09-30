import Foundation
import TinyPruneIPC
import TinyPruneDomain

@main
struct TinyPruneCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first(where: { !$0.hasPrefix("--") }) ?? "status"
        let wantsJSON = arguments.contains("--json")

        guard command == "status" || command == "rules" || command == "upcoming" else {
            writeError("usage: tinyprune [status|rules|upcoming] [--json]\n")
            exit(64)
        }

        let operation: AgentOperation
        switch command {
        case "status": operation = .health
        case "rules": operation = .loadPolicy
        default: operation = .loadOverview
        }
        let response: AgentResponse
        do {
            response = try await TinyPruneAgentClient().request(AgentRequest(operation: operation))
        } catch {
            if wantsJSON {
                print("{\"status\":\"unavailable\"}")
            } else {
                writeError("TinyPrune agent is unavailable. Open TinyPrune.app and try again.\n")
            }
            exit(69)
        }

        switch (command, response.payload) {
        case ("status", .health(let health)):
            if wantsJSON {
                let output = StatusOutput(status: "available", protocolVersion: health.protocolVersion, serviceVersion: health.serviceVersion)
                do {
                    let data = try JSONEncoder.sorted.encode(output)
                    print(String(decoding: data, as: UTF8.self))
                } catch {
                    writeError("Could not encode agent status.\n")
                    exit(70)
                }
            } else {
                print("TinyPrune agent available (protocol \(health.protocolVersion), service \(health.serviceVersion))")
            }
        case ("rules", .policy(let snapshot)):
            if wantsJSON {
                do {
                    let data = try JSONEncoder.sorted.encode(snapshot.rules)
                    print(String(decoding: data, as: UTF8.self))
                } catch {
                    writeError("Could not encode rules.\n")
                    exit(70)
                }
            } else if snapshot.rules.isEmpty {
                print("No rules configured.")
            } else {
                for rule in snapshot.rules {
                    print("\(rule.name)  \(rule.state.rawValue)  \(rule.scope.path)  \(matcherDescription(rule))  \(rule.expiryBasis.rawValue) for \(durationDescription(rule.lifetime.seconds))")
                }
            }
        case ("upcoming", .overview(let overview)):
            if wantsJSON {
                do {
                    let data = try JSONEncoder.sorted.encode(overview.upcoming.map(\.explanation))
                    print(String(decoding: data, as: UTF8.self))
                } catch {
                    writeError("Could not encode Upcoming items.\n")
                    exit(70)
                }
            } else if overview.upcoming.isEmpty {
                print("No scheduled items.")
            } else {
                for item in overview.upcoming {
                    let explanation = item.explanation
                    print("\(explanation.candidateIdentity.pathHint)  \(explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened))  \(explanation.matchedRuleName)  \(explanation.disposition.rawValue)")
                }
            }
        case (_, .failure(let error)):
            writeError("TinyPrune agent request failed: \(error)\n")
            exit(69)
        default:
            writeError("TinyPrune agent returned an unexpected response.\n")
            exit(70)
        }
    }

    private static func matcherDescription(_ rule: LifetimeRule) -> String {
        let values = rule.matcher.exactNames.sorted() + rule.matcher.globPatterns.sorted()
        let kind = rule.matcher.itemKind.rawValue
        return "\(kind) \(values.isEmpty ? "items" : values.joined(separator: ", "))"
    }

    private static func durationDescription(_ seconds: TimeInterval) -> String {
        let day: TimeInterval = 86_400
        if seconds.truncatingRemainder(dividingBy: day) == 0 { return "\(Int(seconds / day))d" }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds))s"
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private struct StatusOutput: Encodable {
    let status: String
    let protocolVersion: Int
    let serviceVersion: String
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
