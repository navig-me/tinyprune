import Testing
import Foundation
@testable import TinyPruneIPC

@Suite struct AgentErrorDescriptionTests {
    private let clientErrors: [AgentClientError] = [
        .unavailable, .encodingFailed, .invalidReply, .unsupportedProtocol(9), .timedOut, .interrupted,
    ]
    private let serviceErrors: [AgentServiceError] = [
        .unsupportedProtocol(expected: 2, received: 1), .invalidRequest("bad"), .storageUnavailable("disk"),
        .policyConflict, .rootUnavailable("Volume missing"),
    ]

    @Test func timedOutAndInterruptedWarnTheRequestMayHaveApplied() {
        #expect(AgentErrorDescription.requestMayHaveApplied(.timedOut))
        #expect(AgentErrorDescription.requestMayHaveApplied(.interrupted))
        #expect(!AgentErrorDescription.requestMayHaveApplied(.unavailable))
        #expect(AgentErrorDescription.message(for: AgentClientError.timedOut).contains("may have been applied"))
        #expect(AgentErrorDescription.message(for: AgentClientError.interrupted).contains("may have been applied"))
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

    @Test func everyErrorHasADistinctReadableMessageAndCode() {
        let clientMessages = clientErrors.map { AgentErrorDescription.message(for: $0) }
        #expect(Set(clientMessages).count == clientErrors.count)
        let serviceMessages = serviceErrors.map { AgentErrorDescription.message(for: $0) }
        #expect(Set(serviceMessages).count == serviceErrors.count)
        #expect(Set(clientErrors.map { AgentErrorDescription.code(for: $0) }).count == clientErrors.count)
        #expect(Set(serviceErrors.map { AgentErrorDescription.code(for: $0) }).count == serviceErrors.count)
        // Never the raw enum dump the CLI used to print.
        for message in clientMessages + serviceMessages {
            #expect(!message.contains("AgentServiceError") && !message.contains("AgentClientError"))
        }
    }

    @Test func serviceMessagesCarryTheAgentDetail() {
        #expect(AgentErrorDescription.message(for: AgentServiceError.invalidRequest("scope too broad")).contains("scope too broad"))
        #expect(AgentErrorDescription.message(for: AgentServiceError.rootUnavailable("Volume missing")).contains("Volume missing"))
    }

    @Test func arbitraryErrorsFallBackToLocalizedDescription() {
        struct Other: LocalizedError { var errorDescription: String? { "custom failure" } }
        #expect(AgentErrorDescription.message(for: Other()) == "custom failure")
        #expect(AgentErrorDescription.message(for: AgentClientError.timedOut as any Error) == AgentErrorDescription.message(for: AgentClientError.timedOut))
    }
}
