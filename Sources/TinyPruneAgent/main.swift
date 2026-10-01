import Foundation
import TinyPruneAgentCore
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence


private final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
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
        let service = AgentXPCService(handler: AgentRequestHandler(store: store))
        let delegate = AgentListenerDelegate(service: service)
        let listener = NSXPCListener(machServiceName: TinyPruneAgentXPC.machServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
