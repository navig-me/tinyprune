import Foundation
import os
import Security

/// Code-signing requirement used to authenticate XPC peers. The app, Finder extension, CLI and agent are
/// all signed by the same team, so the requirement is derived from the running process's own signature.
public enum PeerRequirement {
    private static let logger = Logger(subsystem: "com.navig-me.tinyprune", category: "ipc")

    /// `nil` for unsigned / ad-hoc development builds, which carry no team identifier.
    public static func current() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty,
              team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Requires the remote end of an outgoing connection to be signed by this team (no-op for unsigned dev builds).
    public static func apply(to connection: NSXPCConnection) {
        guard let requirement = current() else {
            logger.notice("Unsigned build: XPC peer code-signing requirement skipped")
            return
        }
        connection.setCodeSigningRequirement(requirement)
    }

    /// Requires every peer connecting to a listener to be signed by this team (no-op for unsigned dev builds).
    public static func apply(to listener: NSXPCListener) {
        guard let requirement = current() else {
            logger.notice("Unsigned build: XPC listener code-signing requirement skipped")
            return
        }
        listener.setConnectionCodeSigningRequirement(requirement)
    }
}
