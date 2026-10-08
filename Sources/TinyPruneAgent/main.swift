import Foundation
import Dispatch
import TinyPruneAgentCore
import TinyPruneDomain
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

/// Keeps the XPC listener and its delegate alive for the process lifetime (`NSXPCListener.delegate` is weak).
private enum AgentRetainedObjects {
    nonisolated(unsafe) static var objects: [AnyObject] = []
}

@main
struct TinyPruneAgentMain {
    /// Synchronous entry point: the main thread must run the main run loop so `NSWorkspace`
    /// mount/unmount/wake notifications (delivered on the main thread) are actually serviced.
    static func main() {
        Task { await bootstrap() }
        RunLoop.main.run()
    }

    private static func bootstrap() async {
        let store: SQLiteSafetyStore
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            store = try SQLiteSafetyStore(databaseURL: applicationSupport
                .appendingPathComponent("TinyPrune", isDirectory: true)
                .appendingPathComponent("state.sqlite3"))
        } catch {
            FileHandle.standardError.write(Data("TinyPruneAgent: cannot open the safety store: \(error)\n".utf8))
            exit(EX_UNAVAILABLE)
        }
        let runtime = ManagedRootAgentRuntime(store: store)
        await runtime.start()
        let service = AgentXPCService(handler: AgentRequestHandler(store: store, runtime: runtime))
        let delegate = AgentListenerDelegate(service: service)
        let listener = NSXPCListener(machServiceName: TinyPruneAgentXPC.machServiceName)
        listener.delegate = delegate
        PeerRequirement.apply(to: listener)
        AgentRetainedObjects.objects = [service, delegate, listener]
        listener.resume()
    }
}
