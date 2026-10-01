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
    public let globallyPaused: Bool

    public init(rules: [LifetimeRule], overrides: [ItemPolicyOverride], managedRoots: [ManagedRoot] = [], globallyPaused: Bool) {
        self.rules = rules
        self.overrides = overrides
        self.managedRoots = managedRoots
        self.globallyPaused = globallyPaused
    }
}
public struct AgentUpcomingItem: Codable, Equatable, Sendable, Identifiable {
    public let explanation: CandidateExplanation
    public var id: FilesystemIdentity { explanation.candidateIdentity }

    public init(explanation: CandidateExplanation) {
        self.explanation = explanation
    }
}

public struct AgentOverviewSnapshot: Codable, Equatable, Sendable {
    public let policy: AgentPolicySnapshot
    public let upcoming: [AgentUpcomingItem]

    public init(policy: AgentPolicySnapshot, upcoming: [AgentUpcomingItem]) {
        self.policy = policy
        self.upcoming = upcoming
    }
}


public enum AgentOperation: Codable, Equatable, Sendable {
    case health
    case loadPolicy
    case loadOverview
    case replacePolicy(AgentPolicySnapshot)
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
