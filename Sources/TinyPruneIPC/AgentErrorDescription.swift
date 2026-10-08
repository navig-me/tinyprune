import Foundation

/// User-facing wording and sysexits-style exit codes for agent failures, shared by the CLI and Finder extension.
public enum AgentErrorDescription {
    public enum ExitCode {
        public static let usage: Int32 = 64
        public static let dataError: Int32 = 65
        public static let agentError: Int32 = 70
        public static let unavailable: Int32 = 69
        /// Timed out, interrupted, or busy: retrying later may succeed.
        public static let temporaryFailure: Int32 = 75
        public static let configuration: Int32 = 78
    }

    public static func message(for error: AgentServiceError) -> String {
        switch error {
        case .unsupportedProtocol(let expected, let received):
            "Protocol mismatch: the agent expects version \(expected) but this tool speaks \(received). Update TinyPrune."
        case .invalidRequest(let message):
            "The agent rejected the request: \(message)"
        case .storageUnavailable(let message):
            "The agent's storage is unavailable: \(message)"
        case .policyConflict:
            "The policy changed while the request was being prepared. Try again."
        case .rootUnavailable(let message):
            "A managed folder is unavailable: \(message)"
        }
    }

    public static func message(for error: AgentClientError) -> String {
        switch error {
        case .unavailable:
            "The TinyPrune agent is not running or is unreachable. Open TinyPrune and make sure its background agent is enabled."
        case .encodingFailed:
            "The request could not be encoded."
        case .invalidReply:
            "The agent sent a reply that could not be read."
        case .unsupportedProtocol(let version):
            "The agent speaks protocol version \(version), which this tool does not support. Update TinyPrune."
        case .timedOut:
            "The agent did not answer in time. The request may have been applied; check the current state before retrying."
        case .interrupted:
            "The connection to the agent was interrupted. The request may have been applied; check the current state before retrying."
        }
    }

    /// `true` when the request was sent but its outcome is unknown.
    public static func requestMayHaveApplied(_ error: AgentClientError) -> Bool {
        switch error {
        case .timedOut, .interrupted: true
        case .unavailable, .encodingFailed, .invalidReply, .unsupportedProtocol: false
        }
    }

    public static func exitCode(for error: AgentServiceError) -> Int32 {
        switch error {
        case .invalidRequest: ExitCode.dataError
        case .policyConflict: ExitCode.temporaryFailure
        case .rootUnavailable, .unsupportedProtocol: ExitCode.unavailable
        case .storageUnavailable: ExitCode.agentError
        }
    }

    public static func exitCode(for error: AgentClientError) -> Int32 {
        switch error {
        case .unavailable, .unsupportedProtocol: ExitCode.unavailable
        case .timedOut, .interrupted: ExitCode.temporaryFailure
        case .encodingFailed, .invalidReply: ExitCode.agentError
        }
    }

    /// Stable machine-readable identifier for `--json` error output.
    public static func code(for error: AgentServiceError) -> String {
        switch error {
        case .unsupportedProtocol: "unsupportedProtocol"
        case .invalidRequest: "invalidRequest"
        case .storageUnavailable: "storageUnavailable"
        case .policyConflict: "policyConflict"
        case .rootUnavailable: "rootUnavailable"
        }
    }

    public static func code(for error: AgentClientError) -> String {
        switch error {
        case .unavailable: "unavailable"
        case .encodingFailed: "encodingFailed"
        case .invalidReply: "invalidReply"
        case .unsupportedProtocol: "unsupportedProtocol"
        case .timedOut: "timedOut"
        case .interrupted: "interrupted"
        }
    }

    /// Any thrown error, as the Finder extension needs it.
    public static func message(for error: any Error) -> String {
        if let error = error as? AgentClientError { return message(for: error) }
        return error.localizedDescription
    }
}
