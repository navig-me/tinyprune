import Darwin
import Foundation

let fileManager = FileManager.default
let command = CommandLine.arguments.dropFirst().first ?? ""
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
let supportDirectory = homeDirectory.appendingPathComponent("Library/Application Support/TinyPrune", isDirectory: true)
let binaryDirectory = supportDirectory.appendingPathComponent("bin", isDirectory: true)
let launchAgentsDirectory = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
let label = "com.navig-me.tinyprune.agent"
let launchAgentURL = launchAgentsDirectory.appendingPathComponent("\(label).plist")
let launchDomain = "gui/\(getuid())"

func run(_ executable: String, _ arguments: [String], in directory: URL? = nil, allowFailure: Bool = false) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard allowFailure || process.terminationStatus == 0 else {
        throw NSError(domain: "TinyPruneAgentInstaller", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) failed with status \(process.terminationStatus)"])
    }
    return process.terminationStatus
}
func launchAgentPropertyList(agentPath: String) -> [String: Any] {
    [
        "Label": label,
        "ProgramArguments": [agentPath],
        "MachServices": [label: true],
        "RunAtLoad": true,
        "KeepAlive": true,
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": supportDirectory.appendingPathComponent("agent.log").path,
        "StandardErrorPath": supportDirectory.appendingPathComponent("agent-error.log").path,
    ]
}

func installBinary(named name: String) throws {
    let source = repositoryRoot.appendingPathComponent(".build/release/\(name)")
    let destination = binaryDirectory.appendingPathComponent(name)
    let temporary = binaryDirectory.appendingPathComponent(".\(name)-\(UUID().uuidString)")
    try fileManager.copyItem(at: source, to: temporary)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: temporary, to: destination)
}

func install() throws {
    try fileManager.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
    _ = try run("/usr/bin/swift", ["build", "--configuration", "release"], in: repositoryRoot)
    try installBinary(named: "TinyPruneAgent")
    try installBinary(named: "tinyprune")

    let agentPath = binaryDirectory.appendingPathComponent("TinyPruneAgent").path
    let plist = launchAgentPropertyList(agentPath: agentPath)
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: launchAgentURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: launchAgentURL.path)

    _ = try run("/bin/launchctl", ["bootout", launchDomain, launchAgentURL.path], allowFailure: true)
    _ = try run("/bin/launchctl", ["bootstrap", launchDomain, launchAgentURL.path])
    _ = try run("/bin/launchctl", ["kickstart", "-k", "\(launchDomain)/\(label)"])
    print("TinyPrune LaunchAgent installed for the current user.")
    print("Agent binary: \(agentPath)")
    print("Policy database: \(supportDirectory.appendingPathComponent("state.sqlite3").path)")
    print("Start the native window with: swift run TinyPruneApp")
}
func previewConfiguration() throws {
    let agentPath = binaryDirectory.appendingPathComponent("TinyPruneAgent").path
    let plist = launchAgentPropertyList(agentPath: agentPath)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    guard let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          parsed["Label"] as? String == label,
          parsed["ProgramArguments"] as? [String] == [agentPath],
          (parsed["MachServices"] as? [String: Bool])?[label] == true else {
        throw NSError(domain: "TinyPruneAgentInstaller", code: 2, userInfo: [NSLocalizedDescriptionKey: "Generated LaunchAgent property list is invalid."])
    }
    FileHandle.standardOutput.write(data)
}


func uninstall() throws {
    _ = try run("/bin/launchctl", ["bootout", launchDomain, launchAgentURL.path], allowFailure: true)
    if fileManager.fileExists(atPath: launchAgentURL.path) {
        try fileManager.removeItem(at: launchAgentURL)
    }
    for name in ["TinyPruneAgent", "tinyprune"] {
        let path = binaryDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: path.path) { try fileManager.removeItem(at: path) }
    }
    print("TinyPrune LaunchAgent and installed binaries removed. Local policy and audit data were retained.")
}

do {
    switch command {
    case "install": try install()
    case "uninstall": try uninstall()
    case "preview": try previewConfiguration()
    default:
        FileHandle.standardError.write(Data("usage: swift Scripts/manage-agent.swift [install|uninstall|preview]\n".utf8))
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("TinyPrune agent setup failed: \(error)\n".utf8))
    exit(1)
}
