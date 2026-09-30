#if canImport(XCTest)
import XCTest
@testable import TinyPruneIPC

final class AgentHealthTests: XCTestCase {
    func testHealthPayloadRoundTripsAcrossTheIPCEncoding() throws {
        let health = AgentHealth(serviceVersion: "0.1.0")
        let payload = try JSONEncoder().encode(health)
        XCTAssertEqual(try JSONDecoder().decode(AgentHealth.self, from: payload), health)
    }

    func testProtocolVersionIsExplicit() {
        XCTAssertEqual(TinyPruneAgentXPC.protocolVersion, 1)
        XCTAssertEqual(TinyPruneAgentXPC.machServiceName, "com.navig-me.tinyprune.agent")
    }
}
#endif
