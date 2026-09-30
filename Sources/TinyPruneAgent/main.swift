import Foundation
import TinyPruneAgentCore
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

private final class XPCReply: @unchecked Sendable {
    private let reply: (Data) -> Void
    init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    func send(_ data: Data) { reply(data) }
}

final class TinyPruneAgentService: NSObject, TinyPruneAgentProtocol {
    private let handler: AgentRequestHandler

    init(handler: AgentRequestHandler) {
        self.handler = handler
    }

    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        let response = XPCReply(reply)
        Task { [handler, response, data] in response.send(await handler.handle(data)) }
    }
}

final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: TinyPruneAgentService

    init(service: TinyPruneAgentService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: TinyPruneAgentProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

@main
struct TinyPruneAgentMain {
    static func main() throws {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let store = try SQLiteSafetyStore(databaseURL: applicationSupport
            .appendingPathComponent("TinyPrune", isDirectory: true)
            .appendingPathComponent("state.sqlite3"))
        let service = TinyPruneAgentService(handler: AgentRequestHandler(store: store))
        let delegate = AgentListenerDelegate(service: service)
        let listener = NSXPCListener(machServiceName: TinyPruneAgentXPC.machServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
