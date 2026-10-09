import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

@Suite struct AgentXPCTransportTests {
    @Test func testVersionedHealthRequestCrossesAnonymousXPCConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-XPC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        let service = AgentXPCService(handler: AgentRequestHandler(store: store))
        let delegate = TestListenerDelegate(service: service)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: TinyPruneAgentProtocol.self)
        connection.resume()
        defer {
            connection.invalidate()
            listener.invalidate()
        }

        let requestData = try JSONEncoder().encode(AgentRequest(operation: .health))
        let replyData: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            } as? TinyPruneAgentProtocol
            guard let proxy else {
                continuation.resume(throwing: AgentClientError.unavailable)
                return
            }
            proxy.request(requestData) { data in continuation.resume(returning: data) }
        }

        let response = try JSONDecoder().decode(AgentResponse.self, from: replyData)
        #expect(response.protocolVersion == TinyPruneAgentXPC.protocolVersion)
        guard case .health(let health) = response.payload else { Issue.record("Expected health response over XPC"); return }
        #expect(health.serviceVersion == "0.1.12")
    }
}

private final class TestListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: AgentXPCService

    init(service: AgentXPCService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: TinyPruneAgentProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
