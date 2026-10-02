import Foundation
import TinyPruneDomain

public enum TinyPruneAgentXPC {
    public static let protocolVersion = 1
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

    public init(rules: [LifetimeRule], overrides: [ItemPolicyOverride], managedRoots: [ManagedRoot] = [], globallyPaused: Bool, pausedUntil: Date? = nil) {
        self.rules = rules
        self.overrides = overrides
        self.managedRoots = managedRoots
        self.globallyPaused = globallyPaused
        self.pausedUntil = pausedUntil
    }

    private enum CodingKeys: String, CodingKey { case rules, overrides, managedRoots, globallyPaused, pausedUntil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decode([LifetimeRule].self, forKey: .rules)
        overrides = try container.decode([ItemPolicyOverride].self, forKey: .overrides)
        managedRoots = try container.decodeIfPresent([ManagedRoot].self, forKey: .managedRoots) ?? []
        globallyPaused = try container.decode(Bool.self, forKey: .globallyPaused)
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
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

public struct AgentOverviewSnapshot: Codable, Equatable, Sendable {
    public let policy: AgentPolicySnapshot
    public let upcoming: [AgentUpcomingItem]
    public let ruleStats: [AgentRuleStats]
    public let indexedItems: Int
    public let databaseBytes: Int64

    public init(policy: AgentPolicySnapshot, upcoming: [AgentUpcomingItem], ruleStats: [AgentRuleStats] = [], indexedItems: Int = 0, databaseBytes: Int64 = 0) {
        self.policy = policy
        self.upcoming = upcoming
        self.ruleStats = ruleStats
        self.indexedItems = indexedItems
        self.databaseBytes = databaseBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(AgentPolicySnapshot.self, forKey: .policy)
        upcoming = try container.decode([AgentUpcomingItem].self, forKey: .upcoming)
        ruleStats = try container.decodeIfPresent([AgentRuleStats].self, forKey: .ruleStats) ?? []
        indexedItems = try container.decodeIfPresent(Int.self, forKey: .indexedItems) ?? 0
        databaseBytes = try container.decodeIfPresent(Int64.self, forKey: .databaseBytes) ?? 0
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
}

@objc public protocol TinyPruneAgentProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
}

private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (Result<AgentResponse, AgentClientError>) -> Void

    init(_ completion: @escaping @Sendable (Result<AgentResponse, AgentClientError>) -> Void) {
        self.completion = completion
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

public final class TinyPruneAgentClient: @unchecked Sendable {
    public init() {}

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
        connection.invalidationHandler = { once.finish(.failure(.unavailable)) }
        connection.interruptionHandler = { once.finish(.failure(.unavailable)) }
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            once.finish(.failure(.unavailable))
            connection.invalidate()
        } as? TinyPruneAgentProtocol
        guard let proxy else {
            once.finish(.failure(.unavailable))
            connection.invalidate()
            return
        }

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
