import Foundation
import TinyPruneEngine
import TinyPruneIPC
import TinyPruneDomain
import TinyPrunePersistence

public actor AgentRequestHandler {
    private let store: SQLiteSafetyStore
    private let serviceVersion: String

    public init(store: SQLiteSafetyStore, serviceVersion: String = "0.1.0") {
        self.store = store
        self.serviceVersion = serviceVersion
    }

    public func handle(_ data: Data) async -> Data {
        guard let request = try? JSONDecoder().decode(AgentRequest.self, from: data) else {
            return encode(AgentResponse(payload: .failure(.invalidRequest("Request payload is malformed."))))
        }
        guard request.protocolVersion == TinyPruneAgentXPC.protocolVersion else {
            return encode(AgentResponse(payload: .failure(.unsupportedProtocol(
                expected: TinyPruneAgentXPC.protocolVersion,
                received: request.protocolVersion
            ))))
        }

        do {
            switch request.operation {
            case .health:
                return encode(AgentResponse(payload: .health(AgentHealth(serviceVersion: serviceVersion))))
            case .loadPolicy:
                let snapshot = try await store.loadSnapshot()
                let policy = AgentPolicySnapshot(rules: snapshot.rules, overrides: snapshot.overrides, managedRoots: snapshot.managedRoots, globallyPaused: snapshot.globallyPaused)
                return encode(AgentResponse(payload: .policy(policy)))
            case .loadOverview:
                let snapshot = try await store.loadSnapshot()
                let upcoming = try await store.upcomingDeadlines(limit: 20).map { AgentUpcomingItem(explanation: $0.explanation) }
                let policy = AgentPolicySnapshot(rules: snapshot.rules, overrides: snapshot.overrides, managedRoots: snapshot.managedRoots, globallyPaused: snapshot.globallyPaused)
                return encode(AgentResponse(payload: .overview(AgentOverviewSnapshot(policy: policy, upcoming: upcoming))))
            case .replacePolicy(let policy):
                if let error = validationError(for: policy) {
                    return encode(AgentResponse(payload: .failure(.invalidRequest(error))))
                }
                try await store.replaceSnapshot(PolicySnapshot(
                    rules: policy.rules,
                    overrides: policy.overrides,
                    managedRoots: policy.managedRoots,
                    globallyPaused: policy.globallyPaused
                ))
                return encode(AgentResponse(payload: .acknowledged))
            }
        } catch {
            return encode(AgentResponse(payload: .failure(.storageUnavailable(String(describing: error)))))
        }
    }
    private func validationError(for policy: AgentPolicySnapshot) -> String? {
        var ruleIDs = Set<UUID>()
        var rootIDs = Set<UUID>()
        var rootPaths = Set<String>()
        for root in policy.managedRoots {
            guard rootIDs.insert(root.id).inserted, rootPaths.insert(root.path).inserted else {
                return "Managed root IDs and paths must be unique."
            }
            do {
                _ = try ManagedRoot(id: root.id, displayName: root.displayName, path: root.path, bookmarkData: root.bookmarkData)
            } catch {
                return "Managed root \(root.displayName) is invalid: \(error)"
            }
        }
        for rule in policy.rules {
            guard ruleIDs.insert(rule.id).inserted else { return "Rule IDs must be unique." }
            do {
                let scope = try RuleScope(path: rule.scope.path, recursive: rule.scope.recursive)
                guard scope.path == rule.scope.path else { return "Rule scope paths must be normalized absolute paths." }
                let matcher = try ItemMatcher(itemKind: rule.matcher.itemKind, exactNames: rule.matcher.exactNames, globPatterns: rule.matcher.globPatterns)
                let lifetime = try RuleDuration(seconds: rule.lifetime.seconds)
                let gracePeriod = try rule.gracePeriod.map { try RuleDuration(seconds: $0.seconds) }
                _ = try LifetimeRule(
                    id: rule.id,
                    name: rule.name,
                    scope: scope,
                    matcher: matcher,
                    expiryBasis: rule.expiryBasis,
                    lifetime: lifetime,
                    gracePeriod: gracePeriod,
                    action: rule.action,
                    state: rule.state,
                    matchMode: rule.matchMode
                )
            } catch {
                return "Rule \(rule.name) is invalid: \(error)"
            }
            if rule.matchMode != .template,
               !policy.managedRoots.contains(where: { rule.scope.path == $0.path || rule.scope.path.hasPrefix($0.path + "/") }) {
                return "Every non-template rule must be inside a bookmarked managed root."
            }
        }

        for override in policy.overrides {
            guard override.path.hasPrefix("/"),
                  override.path != "/",
                  RuleScope.normalized(override.path) == override.path else {
                return "Override paths must be normalized absolute paths below the filesystem root."
            }
            if let identity = override.identity,
               identity.resourceIdentifier.isEmpty || !identity.pathHint.hasPrefix("/") {
                return "Identity-bound overrides require a stable resource ID and an absolute path hint."
            }
            if case .customExpiry(let date, _) = override.policy, !date.timeIntervalSince1970.isFinite {
                return "Custom expiry dates must be finite."
            }
        }
        return nil
    }

    private func encode(_ response: AgentResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}
