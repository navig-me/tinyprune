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
let finderExtensionIdentifier = "com.navig-me.tinyprune.finder"
let extensionURL = contentsURL.appendingPathComponent("PlugIns/TinyPruneFinderExtension.appex", isDirectory: true)
let extensionContentsURL = extensionURL.appendingPathComponent("Contents", isDirectory: true)
let extensionMacOSURL = extensionContentsURL.appendingPathComponent("MacOS", isDirectory: true)
let finderEntitlementsURL = repositoryRoot.appendingPathComponent("Resources/Entitlements/FinderExtension.entitlements")

// Signing configuration. Default is an ad-hoc development build. Release builds set
// TINYPRUNE_SIGN_IDENTITY to a Developer ID Application identity (name or SHA-1), which
// additionally enables the secure timestamp and builds a universal binary.
let environment = ProcessInfo.processInfo.environment
let signIdentity = environment["TINYPRUNE_SIGN_IDENTITY"].flatMap { $0.isEmpty ? nil : $0 } ?? "-"
let isAdHoc = signIdentity == "-"
let marketingVersion = environment["TINYPRUNE_VERSION"].flatMap { $0.isEmpty ? nil : $0 } ?? "0.1.0"
let buildNumber = environment["TINYPRUNE_BUILD"].flatMap { $0.isEmpty ? nil : $0 } ?? "1"
let universal = environment["TINYPRUNE_UNIVERSAL"] == "1" || !isAdHoc
let distribution = environment["TINYPRUNE_DISTRIBUTION"] ?? "direct"
guard ["direct", "homebrew"].contains(distribution) else {
    FileHandle.standardError.write(Data("TINYPRUNE_DISTRIBUTION must be direct or homebrew\n".utf8))
    exit(1)
}
let publicUpdateKey = environment["TINYPRUNE_SPARKLE_PUBLIC_KEY"] ?? ""
guard publicUpdateKey.isEmpty || Data(base64Encoded: publicUpdateKey)?.count == 32 else {
    FileHandle.standardError.write(Data("TINYPRUNE_SPARKLE_PUBLIC_KEY must be a base64 Ed25519 public key (32 bytes).\n".utf8))
    exit(1)
}
let updatesEnabled = distribution == "direct" && !isAdHoc && !publicUpdateKey.isEmpty
// The xcbuild-based `--arch a --arch b` path rejects the Finder extension's Swift 5 language mode
// ("SWIFT_VERSION '' is unsupported"), so universal builds compile each architecture with the
// native build system and merge the products with lipo.
let architectures = ["arm64", "x86_64"]
let universalDirectory = repositoryRoot.appendingPathComponent(".build/universal-release", isDirectory: true)
let binDirectory = universal ? universalDirectory : repositoryRoot.appendingPathComponent(".build/release", isDirectory: true)
let executableProducts = ["TinyPruneApp", "TinyPruneAgent", "tinyprune", "TinyPruneFinderExtension"]

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
    let source = binDirectory.appendingPathComponent(name)
    let destination = macOSURL.appendingPathComponent(name)
    try fileManager.copyItem(at: source, to: destination)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
}

func writePropertyList(_ value: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
}

do {
    if universal {
        if fileManager.fileExists(atPath: universalDirectory.path) { try fileManager.removeItem(at: universalDirectory) }
        try fileManager.createDirectory(at: universalDirectory, withIntermediateDirectories: true)
        for architecture in architectures {
            try run("/usr/bin/swift", ["build", "--configuration", "release", "--triple", "\(architecture)-apple-macosx14.0"])
        }
        for product in executableProducts {
            let slices = architectures.map { repositoryRoot.appendingPathComponent(".build/\($0)-apple-macosx/release/\(product)").path }
            try run("/usr/bin/lipo", ["-create"] + slices + ["-output", universalDirectory.appendingPathComponent(product).path])
        }
    } else {
        try run("/usr/bin/swift", ["build", "--configuration", "release"])
    }
    try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: appURL.path) { try fileManager.removeItem(at: appURL) }
    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)

    try copyExecutable("TinyPruneApp")
    try copyExecutable("TinyPruneAgent")
    try copyExecutable("tinyprune")
    try Data("APPLTPRN".utf8).write(to: contentsURL.appendingPathComponent("PkgInfo"))

    // SwiftPM links the binary artifact but does not embed it in a hand-packaged app.
    // Discover the one macOS universal framework from the pinned artifact, not build products.
    let artifactsURL = repositoryRoot.appendingPathComponent(".build/artifacts", isDirectory: true)
    guard let artifacts = fileManager.enumerator(at: artifactsURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
        throw NSError(domain: "TinyPrunePackager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sparkle SwiftPM artifact is missing."])
    }
    var sparkleSources: [URL] = []
    for case let url as URL in artifacts where url.lastPathComponent == "Sparkle.framework" {
        if url.path.contains("macos-") { sparkleSources.append(url) }
        artifacts.skipDescendants()
    }
    guard sparkleSources.count == 1, let sparkleSource = sparkleSources.first else {
        throw NSError(domain: "TinyPrunePackager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected one pinned macOS Sparkle.framework artifact."])
    }
    let frameworksURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
    try fileManager.createDirectory(at: frameworksURL, withIntermediateDirectories: true)
    let sparkleURL = frameworksURL.appendingPathComponent("Sparkle.framework", isDirectory: true)
    try run("/usr/bin/ditto", [sparkleSource.path, sparkleURL.path])

    let fontsSourceURL = repositoryRoot.appendingPathComponent("Resources/Fonts", isDirectory: true)
    let fontsURL = resourcesURL.appendingPathComponent("Fonts", isDirectory: true)
    try fileManager.copyItem(at: fontsSourceURL, to: fontsURL)

    try fileManager.createDirectory(at: extensionMacOSURL, withIntermediateDirectories: true)
    let extensionBinary = extensionMacOSURL.appendingPathComponent("TinyPruneFinderExtension")
    try fileManager.copyItem(at: binDirectory.appendingPathComponent("TinyPruneFinderExtension"), to: extensionBinary)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extensionBinary.path)

    try writePropertyList([
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "TinyPruneApp",
        "CFBundleIdentifier": appIdentifier,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "TinyPrune",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": marketingVersion,
        "CFBundleVersion": buildNumber,
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": true,
        "TinyPruneDistribution": distribution,
        "TinyPruneUpdatesEnabled": updatesEnabled,
        "TinyPruneSigning": isAdHoc ? "ad-hoc" : "developer-id",
        "SUEnableAutomaticChecks": updatesEnabled,
        "SUAllowsAutomaticUpdates": false,
        "SUAutomaticallyUpdate": false,
        "SUFeedURL": "https://tinyprune.com/updates/appcast.xml",
        "SUPublicEDKey": publicUpdateKey,
        "SURequireSignedFeed": true,
        "SUVerifyUpdateBeforeExtraction": true,
        "SUSignedFeedFailureExpirationInterval": 0,
        "SUEnableSystemProfiling": false,
        "ATSApplicationFontsPath": "Fonts",
        "NSPrincipalClass": "NSApplication",
        "CFBundleURLTypes": [[
            "CFBundleURLName": appIdentifier,
            "CFBundleURLSchemes": ["tinyprune"],
        ]],
    ], to: contentsURL.appendingPathComponent("Info.plist"))

    try writePropertyList([
        "Label": agentLabel,
        "BundleProgram": "Contents/MacOS/TinyPruneAgent",
        "MachServices": [agentLabel: true],
        "RunAtLoad": true,
        "KeepAlive": true,
    ], to: launchAgentsURL.appendingPathComponent("\(agentLabel).plist"))

    try writePropertyList([
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "TinyPrune Finder Extension",
        "CFBundleExecutable": "TinyPruneFinderExtension",
        "CFBundleIdentifier": finderExtensionIdentifier,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "TinyPruneFinderExtension",
        "CFBundlePackageType": "XPC!",
        "CFBundleShortVersionString": marketingVersion,
        "CFBundleVersion": buildNumber,
        "LSMinimumSystemVersion": "14.0",
        "NSExtension": [
            "NSExtensionPointIdentifier": "com.apple.FinderSync",
            "NSExtensionPrincipalClass": "TinyPruneFinderExtension.FinderSync",
        ],
    ], to: extensionContentsURL.appendingPathComponent("Info.plist"))

    try run("/usr/bin/plutil", ["-lint", extensionContentsURL.appendingPathComponent("Info.plist").path])
    // Every component uses hardened runtime; release builds add a secure timestamp.
    // The Finder extension keeps its own bundle identifier and the sandbox entitlements
    // (App Sandbox is mandatory for Finder Sync). It is signed before its container.
    func sign(_ path: URL, identifier: String? = nil, entitlements: URL? = nil, preserveEntitlements: Bool = false) throws {
        var arguments = ["--force", "--sign", signIdentity, "--options", "runtime", isAdHoc ? "--timestamp=none" : "--timestamp"]
        if let identifier { arguments += ["--identifier", identifier] }
        if let entitlements { arguments += ["--entitlements", entitlements.path] }
        if preserveEntitlements { arguments += ["--preserve-metadata=entitlements"] }
        try run("/usr/bin/codesign", arguments + [path.path])
    }
    // Sign nested Sparkle helpers inside-out; never use --deep to sign.
    let sparkleVersionURL = sparkleURL.appendingPathComponent("Versions/B")
    for helper in [
        "XPCServices/Downloader.xpc",
        "XPCServices/Installer.xpc",
        "Autoupdate",
        "Updater.app",
    ] {
        let helperURL = sparkleVersionURL.appendingPathComponent(helper)
        if fileManager.fileExists(atPath: helperURL.path) { try sign(helperURL, preserveEntitlements: true) }
    }
    try sign(sparkleURL)
    try sign(extensionURL, identifier: finderExtensionIdentifier, entitlements: finderEntitlementsURL)
    // Security-scoped bookmarks created by the app must resolve in the agent, so every
    // executable that touches them shares the app's signing identifier (ADR 0004).
    for name in ["TinyPruneAgent", "tinyprune"] {
        try sign(macOSURL.appendingPathComponent(name), identifier: appIdentifier)
    }
    try sign(appURL, identifier: appIdentifier, entitlements: isAdHoc ? repositoryRoot.appendingPathComponent("Resources/Entitlements/AppDevelopment.entitlements") : nil)
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
    if !updatesEnabled {
        print(distribution == "homebrew" ? "In-app updates disabled: Homebrew manages this distribution." :
              isAdHoc ? "In-app updates disabled: unsigned/development preview." :
              "In-app updates disabled: TINYPRUNE_SPARKLE_PUBLIC_KEY is not configured.")
    }
    if isAdHoc {
        print("Packaged development app (ad-hoc signature, hardened runtime): \(appURL.path)")
        print("Developer ID signing and notarization require TINYPRUNE_SIGN_IDENTITY; see ADR 0004.")
    } else {
        print("Packaged release app signed as '\(signIdentity)': \(appURL.path)")
    }
} catch {
    FileHandle.standardError.write(Data("TinyPrune app packaging failed: \(error)\n".utf8))
    exit(1)
}
