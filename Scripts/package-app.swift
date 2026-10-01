import Foundation

let fileManager = FileManager.default
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let packageDirectory = repositoryRoot.appendingPathComponent(".build/package", isDirectory: true)
let appURL = packageDirectory.appendingPathComponent("TinyPrune.app", isDirectory: true)
let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
let launchAgentsURL = contentsURL.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
let appIdentifier = "com.navig-me.tinyprune"
let agentLabel = "com.navig-me.tinyprune.agent"

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = repositoryRoot
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "TinyPrunePackager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) failed with status \(process.terminationStatus)"])
    }
}

func copyExecutable(_ name: String) throws {
    let source = repositoryRoot.appendingPathComponent(".build/release/\(name)")
    let destination = macOSURL.appendingPathComponent(name)
    try fileManager.copyItem(at: source, to: destination)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
}

func writePropertyList(_ value: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
}

do {
    try run("/usr/bin/swift", ["build", "--configuration", "release"])
    try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: appURL.path) { try fileManager.removeItem(at: appURL) }
    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)

    try copyExecutable("TinyPruneApp")
    try copyExecutable("TinyPruneAgent")
    try copyExecutable("tinyprune")
    try Data("APPLTPRN".utf8).write(to: contentsURL.appendingPathComponent("PkgInfo"))

    try writePropertyList([
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "TinyPruneApp",
        "CFBundleIdentifier": appIdentifier,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "TinyPrune",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": true,
        "NSPrincipalClass": "NSApplication",
    ], to: contentsURL.appendingPathComponent("Info.plist"))

    try writePropertyList([
        "Label": agentLabel,
        "BundleProgram": "Contents/MacOS/TinyPruneAgent",
        "MachServices": [agentLabel: true],
        "RunAtLoad": true,
        "KeepAlive": true,
    ], to: launchAgentsURL.appendingPathComponent("\(agentLabel).plist"))

    try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appURL.path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
    print("Packaged unsigned-for-distribution development app: \(appURL.path)")
    print("Build uses an ad-hoc signature; Developer ID signing and notarization remain release steps.")
} catch {
    FileHandle.standardError.write(Data("TinyPrune app packaging failed: \(error)\n".utf8))
    exit(1)
}
