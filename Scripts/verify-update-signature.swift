import CryptoKit
import Foundation

// Public information only: public key, archive path, detached signature. Never accepts a private key.
guard CommandLine.arguments.count == 4,
      let keyData = Data(base64Encoded: CommandLine.arguments[1]), keyData.count == 32,
      let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else {
    FileHandle.standardError.write(Data("Usage: verify-update-signature.swift PUBLIC_KEY FILE SIGNATURE\n".utf8))
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        throw NSError(domain: "TinyPruneUpdateSignature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Signature does not match the public key embedded in the released app."])
    }
    print("Update signature matches the released app's public key.")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
