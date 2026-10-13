import Testing
@testable import TinyPruneIPC

@Suite struct AgentErrorDescriptionTests {
    private let clientErrors: [AgentClientError] = [
        .unavailable, .encodingFailed, .invalidReply, .unsupportedProtocol(9), .timedOut, .interrupted,
    ]
    private let serviceErrors: [AgentServiceError] = [
        .unsupportedProtocol(expected: 3, received: 2), .invalidRequest("bad"), .storageUnavailable("disk"),
        .policyConflict, .rootUnavailable("Volume missing"),
    ]

    @Test func timedOutAndInterruptedWarnTheRequestMayHaveApplied() {
        #expect(AgentErrorDescription.requestMayHaveApplied(.timedOut))
        #expect(AgentErrorDescription.requestMayHaveApplied(.interrupted))
        #expect(!AgentErrorDescription.requestMayHaveApplied(.unavailable))
    }

    @Test func exitCodesFollowSysexits() {
        #expect(AgentErrorDescription.exitCode(for: AgentClientError.unavailable) == 69)
        #expect(AgentErrorDescription.exitCode(for: AgentClientError.timedOut) == 75)
        #expect(AgentErrorDescription.exitCode(for: AgentClientError.interrupted) == 75)
        #expect(AgentErrorDescription.exitCode(for: AgentClientError.invalidReply) == 70)
        #expect(AgentErrorDescription.exitCode(for: AgentServiceError.invalidRequest("x")) == 65)
        #expect(AgentErrorDescription.exitCode(for: AgentServiceError.policyConflict) == 75)
        #expect(AgentErrorDescription.exitCode(for: AgentServiceError.storageUnavailable("x")) == 70)
        #expect(AgentErrorDescription.exitCode(for: AgentServiceError.rootUnavailable("x")) == 69)
    }

    @Test func errorCodesDistinguishFailureKinds() {
        #expect(Set(clientErrors.map { AgentErrorDescription.code(for: $0) }).count == clientErrors.count)
        #expect(Set(serviceErrors.map { AgentErrorDescription.code(for: $0) }).count == serviceErrors.count)
    }

}
