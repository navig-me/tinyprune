import Testing
import Foundation
@testable import TinyPruneIPC

@Suite struct AgentHealthTests {
    @Test func testHealthPayloadRoundTripsAcrossTheIPCEncoding() throws {
        let health = AgentHealth(serviceVersion: "0.1.0")
        let payload = try JSONEncoder().encode(health)
        #expect(try JSONDecoder().decode(AgentHealth.self, from: payload) == health)
    }

    @Test func testProtocolVersionIsExplicit() {
        #expect(TinyPruneAgentXPC.protocolVersion == 1)
        #expect(TinyPruneAgentXPC.machServiceName == "com.navig-me.tinyprune.agent")
    }
}
