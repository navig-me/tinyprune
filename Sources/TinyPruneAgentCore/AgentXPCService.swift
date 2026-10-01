import Foundation
import TinyPruneIPC

private final class XPCReply: @unchecked Sendable {
    private let reply: (Data) -> Void

    init(_ reply: @escaping (Data) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data) {
        reply(data)
    }
}

public final class AgentXPCService: NSObject, TinyPruneAgentProtocol {
    private let handler: AgentRequestHandler

    public init(handler: AgentRequestHandler) {
        self.handler = handler
    }

    public func request(_ data: Data, reply: @escaping (Data) -> Void) {
        let response = XPCReply(reply)
        Task { [handler, response, data] in
            response.send(await handler.handle(data))
        }
    }
}
