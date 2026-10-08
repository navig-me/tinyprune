import Foundation
import TinyPruneDomain

public enum TinyPruneAgentXPC {
    public static let protocolVersion = 2
    public static let machServiceName = "com.navig-me.tinyprune.agent"
}

public struct AgentHealth: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serviceVersion: String

    public init(protocolVersion: Int = TinyPruneAgentXPC.protocolVersion, serviceVersion: String) {
        self.protocolVersion = protocolVersion
        self.serviceVersion = serviceVersion
    }
}
public struct AgentPolicySnapshot: Codable, Equatable, Sendable {
    public let rules: [LifetimeRule]
    public let overrides: [ItemPolicyOverride]
    public let managedRoots: [ManagedRoot]
    /// Effective pause state: `false` once `pausedUntil` has passed.
    public let globallyPaused: Bool
    /// When set together with `globallyPaused`, the pause lifts automatically at this instant.
    public let pausedUntil: Date?
    /// Monotonic policy revision. `replacePolicy`/`saveRule` succeed only when this matches the agent's current revision.
    public let revision: Int

    public init(rules: [LifetimeRule], overrides: [ItemPolicyOverride], managedRoots: [ManagedRoot] = [], globallyPaused: Bool, pausedUntil: Date? = nil, revision: Int = 0) {
        self.rules = rules
        self.overrides = overrides
        self.managedRoots = managedRoots
        self.globallyPaused = globallyPaused
        self.pausedUntil = pausedUntil
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case rules, overrides, managedRoots, globallyPaused, pausedUntil, revision }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decode([LifetimeRule].self, forKey: .rules)
        overrides = try container.decode([ItemPolicyOverride].self, forKey: .overrides)
        managedRoots = try container.decodeIfPresent([ManagedRoot].self, forKey: .managedRoots) ?? []
        globallyPaused = try container.decode(Bool.self, forKey: .globallyPaused)
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}
public struct AgentUpcomingItem: Codable, Equatable, Sendable, Identifiable {
    public let explanation: CandidateExplanation
    public var id: FilesystemIdentity { explanation.candidateIdentity }

    public init(explanation: CandidateExplanation) {
        self.explanation = explanation
    }
}

public struct AgentRuleStats: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let matches: Int
    public let due: Int

    public init(ruleID: UUID, matches: Int, due: Int) {
        self.ruleID = ruleID
        self.matches = matches
        self.due = due
    }
}
public enum AgentRootState: String, Codable, Sendable {
    case watching, indexing, recovering, offline, bookmarkStale, permissionDenied, error
}

public struct AgentRootStatus: Codable, Equatable, Sendable, Identifiable {
    public let rootID: UUID
    public let path: String
    public let state: AgentRootState
    public let detail: String?
    public var id: UUID { rootID }

    public init(rootID: UUID, path: String, state: AgentRootState, detail: String? = nil) {
        self.rootID = rootID
        self.path = path
        self.state = state
        self.detail = detail
    }
}

/// Managed folder as shown to clients that must not receive security-scoped bookmark data.
public struct AgentRootSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    /// Last path component.
    public let name: String

    public init(id: UUID, path: String, name: String) {
        self.id = id
        self.path = path
        self.name = name
    }
}

/// One entry of a batched item-override update. `policy == nil` clears the override at `path`.
public struct AgentItemOverrideChange: Codable, Equatable, Sendable {
    public let path: String
    public let policy: ItemOverridePolicy?

    public init(path: String, policy: ItemOverridePolicy?) {
        self.path = path
        self.policy = policy
    }
}

public struct AgentOverviewSnapshot: Codable, Equatable, Sendable {
    public let policy: AgentPolicySnapshot
    public let upcoming: [AgentUpcomingItem]
    public let ruleStats: [AgentRuleStats]
    public let indexedItems: Int
    public let databaseBytes: Int64
    public let rootStatuses: [AgentRootStatus]

    public init(policy: AgentPolicySnapshot, upcoming: [AgentUpcomingItem], ruleStats: [AgentRuleStats] = [], indexedItems: Int = 0, databaseBytes: Int64 = 0, rootStatuses: [AgentRootStatus] = []) {
        self.policy = policy
        self.upcoming = upcoming
        self.ruleStats = ruleStats
        self.indexedItems = indexedItems
        self.databaseBytes = databaseBytes
        self.rootStatuses = rootStatuses
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(AgentPolicySnapshot.self, forKey: .policy)
        upcoming = try container.decode([AgentUpcomingItem].self, forKey: .upcoming)
        ruleStats = try container.decodeIfPresent([AgentRuleStats].self, forKey: .ruleStats) ?? []
        indexedItems = try container.decodeIfPresent(Int.self, forKey: .indexedItems) ?? 0
        databaseBytes = try container.decodeIfPresent(Int64.self, forKey: .databaseBytes) ?? 0
        rootStatuses = try container.decodeIfPresent([AgentRootStatus].self, forKey: .rootStatuses) ?? []
    }
}

public enum AgentActivityKind: String, Codable, Sendable {
    case policyReplaced
    case ruleCreated
    case ruleEdited
    case rulePaused
    case ruleDeleted
    case itemProtected
    case itemUnprotected
    case expiryChanged
    case globalPauseChanged
    case previewSkipped
    case notDue
    case safetySkipped
    case trashAttempted
    case movedToTrash
    case trashFailed
    case settingsChanged
}

public struct AgentActivityItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let kind: AgentActivityKind
    public let identity: FilesystemIdentity?
    public let ruleID: UUID?
    public let detail: String?

    public init(id: UUID, occurredAt: Date, kind: AgentActivityKind, identity: FilesystemIdentity? = nil, ruleID: UUID? = nil, detail: String? = nil) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.identity = identity
        self.ruleID = ruleID
        self.detail = detail
    }
}


public struct AgentItemExplanation: Codable, Equatable, Sendable {
    public let path: String
    public let identity: FilesystemIdentity
    public let resolution: RuleResolution
    public let overrides: [ItemPolicyOverride]
    public let globallyPaused: Bool

    public init(path: String, identity: FilesystemIdentity, resolution: RuleResolution, overrides: [ItemPolicyOverride], globallyPaused: Bool) {
        self.path = path
        self.identity = identity
        self.resolution = resolution
        self.overrides = overrides
        self.globallyPaused = globallyPaused
    }
}

public struct AgentPreviewSample: Codable, Equatable, Sendable {
    public let path: String
    public let scheduledAt: Date
    public let bytes: Int64?

    public init(path: String, scheduledAt: Date, bytes: Int64?) {
        self.path = path
        self.scheduledAt = scheduledAt
        self.bytes = bytes
    }
}

/// Result of an explicit, user-requested dry run of a rule. Nothing is persisted and nothing is trashed.
public struct AgentRulePreview: Codable, Equatable, Sendable {
    public let matches: Int
    public let eligibleNow: Int
    public let estimatedBytes: Int64
    public let scannedEntries: Int
    public let truncated: Bool
    public let durationSeconds: Double
    /// Soonest matches first, at most 20.
    public let samples: [AgentPreviewSample]

    public init(matches: Int, eligibleNow: Int, estimatedBytes: Int64, scannedEntries: Int, truncated: Bool, durationSeconds: Double, samples: [AgentPreviewSample]) {
        self.matches = matches
        self.eligibleNow = eligibleNow
        self.estimatedBytes = estimatedBytes
        self.scannedEntries = scannedEntries
        self.truncated = truncated
        self.durationSeconds = durationSeconds
        self.samples = samples
    }
}

public enum AgentOperation: Codable, Equatable, Sendable {
    case health
    case loadPolicy
    case loadOverview
    case loadActivity(limit: Int)
    case explainItem(path: String)
    case replacePolicy(AgentPolicySnapshot)
    case setItemOverride(path: String, policy: ItemOverridePolicy)
    case clearItemOverride(path: String)
    case setGlobalPause(Bool)
    /// Pauses all rules until the given instant; the agent resumes automatically (audited). Must be in the future.
    case pauseUntil(Date)
    case loadSettings
    case updateSettings(AgentSettings)
    /// Allocated size of an item inside an available managed folder (metadata only, bounded walk).
    case itemSize(path: String)
    case previewRule(LifetimeRule)
    case deleteRule(UUID)
    case rebuildIndex
    /// Atomic rule save: validates, upserts the rule (merging `roots` when non-nil), adds Keep overrides for
    /// `keepPaths`, clears overrides for `unkeepPaths`, in one transaction guarded by `revision`.
    case saveRule(rule: LifetimeRule, roots: [ManagedRoot]?, keepPaths: [String], unkeepPaths: [String], revision: Int)
    /// Batched override changes applied in one transaction; `policy == nil` clears.
    case setItemOverrides(changes: [AgentItemOverrideChange])
    /// Managed folders without bookmark data.
    case loadRoots
    /// Cancels running rule preview scans.
    case cancelPreview
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operation: AgentOperation

    public init(protocolVersion: Int = TinyPruneAgentXPC.protocolVersion, operation: AgentOperation) {
        self.protocolVersion = protocolVersion
        self.operation = operation
    }
}

public enum AgentServiceError: Codable, Equatable, Sendable {
    case unsupportedProtocol(expected: Int, received: Int)
    case invalidRequest(String)
    case storageUnavailable(String)
    /// `replacePolicy`/`saveRule` carried a stale revision; reload and re-apply.
    case policyConflict
    /// The item lies in a managed folder that is currently offline or unreadable.
    case rootUnavailable(String)
}

public enum AgentResponsePayload: Codable, Equatable, Sendable {
    case health(AgentHealth)
    case policy(AgentPolicySnapshot)
    case overview(AgentOverviewSnapshot)
    case activity([AgentActivityItem])
    case itemExplanation(AgentItemExplanation)
    case settings(AgentSettings)
    case itemSize(path: String, bytes: Int64, items: Int, truncated: Bool)
    case rulePreview(AgentRulePreview)
    case acknowledged
    case failure(AgentServiceError)
    case roots([AgentRootSummary])
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let payload: AgentResponsePayload

    public init(protocolVersion: Int = TinyPruneAgentXPC.protocolVersion, payload: AgentResponsePayload) {
        self.protocolVersion = protocolVersion
        self.payload = payload
    }
}

public enum AgentClientError: Error, Equatable, Sendable {
    case unavailable
    case encodingFailed
    case invalidReply
    case unsupportedProtocol(Int)
    /// No reply within the client timeout; the request may still be applied.
    case timedOut
    /// The connection broke after the request was sent; the request may have been applied.
    case interrupted
}

@objc public protocol TinyPruneAgentProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
}

private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var requestSent = false
    private let completion: @Sendable (Result<AgentResponse, AgentClientError>) -> Void

    init(_ completion: @escaping @Sendable (Result<AgentResponse, AgentClientError>) -> Void) {
        self.completion = completion
    }

    /// Call immediately before handing the request to XPC: a later disconnect may mean the agent applied it.
    func markSent() {
        lock.withLock { requestSent = true }
    }

    /// Connection loss maps to `.interrupted` once the request may have been delivered, `.unavailable` before.
    func finishDisconnected() {
        let sent = lock.withLock { requestSent }
        finish(.failure(sent ? .interrupted : .unavailable))
    }

    func finish(_ result: Result<AgentResponse, AgentClientError>) {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldComplete { completion(result) }
    }
}

private final class ConnectionInvalidator: @unchecked Sendable {
    private let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
    func invalidate() { connection.invalidate() }
}

public final class TinyPruneAgentClient: @unchecked Sendable {
    private let timeout: TimeInterval

    /// `timeout` bounds the wait for a reply (seconds); a non-positive value disables it.
    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public func request(
        _ request: AgentRequest,
        completion: @escaping @Sendable (Result<AgentResponse, AgentClientError>) -> Void
    ) {
        guard let data = try? JSONEncoder().encode(request) else {
            completion(.failure(.encodingFailed))
            return
        }

        let connection = NSXPCConnection(machServiceName: TinyPruneAgentXPC.machServiceName, options: [])
        let once = CompletionOnce(completion)
        connection.remoteObjectInterface = NSXPCInterface(with: TinyPruneAgentProtocol.self)
        PeerRequirement.apply(to: connection)
        connection.invalidationHandler = { once.finishDisconnected() }
        connection.interruptionHandler = { once.finishDisconnected() }
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            once.finishDisconnected()
            connection.invalidate()
        } as? TinyPruneAgentProtocol
        guard let proxy else {
            once.finish(.failure(.unavailable))
            connection.invalidate()
            return
        }

        if timeout > 0 {
            let invalidator = ConnectionInvalidator(connection)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                once.finish(.failure(.timedOut))
                invalidator.invalidate()
            }
        }

        once.markSent()
        proxy.request(data) { reply in
            defer { connection.invalidate() }
            guard let response = try? JSONDecoder().decode(AgentResponse.self, from: reply) else {
                once.finish(.failure(.invalidReply))
                return
            }
            guard response.protocolVersion == TinyPruneAgentXPC.protocolVersion else {
                once.finish(.failure(.unsupportedProtocol(response.protocolVersion)))
                return
            }
            once.finish(.success(response))
        }
    }

    public func request(_ request: AgentRequest) async throws -> AgentResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.request(request) { result in continuation.resume(with: result) }
        }
    }
}
