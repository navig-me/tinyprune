import Foundation

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

public enum AgentHealthClientError: Error, Equatable, Sendable {
    case unavailable
    case invalidReply
}

@objc public protocol TinyPruneAgentProtocol {
    func health(reply: @escaping (Data) -> Void)
}

public final class AgentHealthClient: @unchecked Sendable {
    public init() {}

    public func health(completion: @escaping @Sendable (Result<AgentHealth, AgentHealthClientError>) -> Void) {
        let connection = NSXPCConnection(machServiceName: TinyPruneAgentXPC.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: TinyPruneAgentProtocol.self)
        connection.invalidationHandler = { completion(.failure(.unavailable)) }
        connection.interruptionHandler = { completion(.failure(.unavailable)) }
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            completion(.failure(.unavailable))
            connection.invalidate()
        } as? TinyPruneAgentProtocol

        proxy?.health { data in
            defer { connection.invalidate() }
            guard let health = try? JSONDecoder().decode(AgentHealth.self, from: data) else {
                completion(.failure(.invalidReply))
                return
            }
            completion(.success(health))
        }
    }
}
