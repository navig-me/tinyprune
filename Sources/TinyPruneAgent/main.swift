import Foundation
import TinyPruneIPC

final class TinyPruneAgentService: NSObject, TinyPruneAgentProtocol {
    func health(reply: @escaping (Data) -> Void) {
        let response = AgentHealth(serviceVersion: "0.1.0")
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }
}

final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = TinyPruneAgentService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: TinyPruneAgentProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: TinyPruneAgentXPC.machServiceName)
let delegate = AgentListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
