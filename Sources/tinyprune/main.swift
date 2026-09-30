import Foundation
import TinyPruneIPC

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
let command = arguments.first(where: { $0 != "--json" })

guard command == "status" else {
    FileHandle.standardError.write(Data("usage: tinyprune status [--json]\n".utf8))
    exit(64)
}

final class HealthResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AgentHealth, AgentHealthClientError> = .failure(.unavailable)

    func store(_ result: Result<AgentHealth, AgentHealthClientError>) {
        lock.withLock { self.result = result }
    }

    func load() -> Result<AgentHealth, AgentHealthClientError> {
        lock.withLock { result }
    }
}

let semaphore = DispatchSemaphore(value: 0)
let resultBox = HealthResultBox()

AgentHealthClient().health { response in
    resultBox.store(response)
    semaphore.signal()
}

if semaphore.wait(timeout: .now() + 2) == .timedOut {
    resultBox.store(.failure(.unavailable))
}

switch resultBox.load() {
case .success(let health):
    if wantsJSON {
        let output = [
            "protocolVersion": String(health.protocolVersion),
            "serviceVersion": health.serviceVersion,
            "status": "available",
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        print("TinyPrune agent available (protocol \(health.protocolVersion), service \(health.serviceVersion))")
    }
case .failure:
    if wantsJSON {
        print("{\"status\":\"unavailable\"}")
    } else {
        FileHandle.standardError.write(Data("TinyPrune agent is unavailable. Open TinyPrune.app and try again.\n".utf8))
    }
    exit(69)
}
