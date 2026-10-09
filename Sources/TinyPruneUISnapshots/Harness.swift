import AppKit
import CoreText
import Foundation
import ServiceManagement
import SwiftUI
import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence
import TinyPruneUI

let quickMode = ProcessInfo.processInfo.environment["TINYPRUNE_UI_QUICK"] != nil
let dumpControlsMode = ProcessInfo.processInfo.environment["TINYPRUNE_UI_DUMP"] != nil

// MARK: - Assertions

@MainActor
enum Check {
    static var failures: [String] = []
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
            print("  ok   \(message)")
        } else {
            failures.append(message)
            print("  FAIL \(message)")
        }
    }

    static func fail(_ message: String) { expect(false, message) }
}

@MainActor
func phase(_ title: String) { print("\n== \(title)") }

// MARK: - Run loop

@MainActor
private func spinRunLoopOnce() { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }

/// Lets SwiftUI, Combine, and actor hops make progress without a fixed production sleep.
@MainActor
func pump(_ seconds: TimeInterval = 0.2) async {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        spinRunLoopOnce()
        await Task.yield()
    } while Date() < end
}

@MainActor
@discardableResult
func waitFor(_ what: String, timeout: TimeInterval = quickMode ? 8 : 25, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        await pump(0.05)
    }
    Check.fail("timed out waiting for \(what)")
    return false
}

/// Like `waitFor`, but a timeout is reported to the caller instead of failing the run.
@MainActor
func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        await pump(0.05)
    }
    return await condition()
}

// MARK: - Fonts

/// Registers the bundled typefaces for this process, matching what `ATSApplicationFontsPath` does in the packaged app.
@MainActor
func registerBundledFonts(repositoryRoot: URL) {
    let fonts = repositoryRoot.appendingPathComponent("Resources/Fonts")
    let urls = (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "ttf" } ?? []
    for url in urls {
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            print("  font registration failed for \(url.lastPathComponent): \(String(describing: error?.takeRetainedValue()))")
        }
    }
    for family in [Typography.displayFamily, Typography.bodyFamily, Typography.monoFamily] {
        let available = NSFont(name: family, size: 13) != nil || NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false
        Check.expect(available, "bundled font family \(family) resolves")
    }
}

// MARK: - Agent plumbing

/// Calls the real handler in-process, through the same JSON codec XPC uses.
struct InProcessTransport: AgentTransport {
    let handler: AgentRequestHandler

    func request(_ request: AgentRequest) async throws -> AgentResponse {
        let data = try JSONEncoder().encode(request)
        let reply = await handler.handle(data)
        return try JSONDecoder().decode(AgentResponse.self, from: reply)
    }
}

struct UnavailableTransport: AgentTransport {
    func request(_ request: AgentRequest) async throws -> AgentResponse { throw AgentClientError.unavailable }
}

/// Real agent for everything except scripted faults: `previewRule` can show truncation and a stalled scan, policy
/// writes can report a stale revision, and overview loads can fail to prove the model keeps its last good state.
final class ScriptedTransport: AgentTransport, @unchecked Sendable {
    enum PreviewMode: Sendable {
        case passthrough
        case canned(AgentRulePreview)
        case hang
    }

    private let base: any AgentTransport
    private let lock = NSLock()
    private var mode = PreviewMode.passthrough
    private var previewCount = 0
    private var log: [AgentOperation] = []
    private var pendingConflicts = 0
    private var overviewFails = false
    private var interruptsNextMutation = false

    init(base: any AgentTransport) { self.base = base }

    func setMode(_ newMode: PreviewMode) { lock.withLock { mode = newMode } }
    var previewRequests: Int { lock.withLock { previewCount } }
    func requests(matching predicate: (AgentOperation) -> Bool) -> Int { lock.withLock { log.filter(predicate).count } }

    /// The next `count` `replacePolicy` / `saveRule` requests are answered with `policyConflict` without reaching the agent.
    func injectPolicyConflicts(_ count: Int) { lock.withLock { pendingConflicts = count } }
    /// While set, `loadOverview` throws `AgentClientError.unavailable`.
    func setOverviewFailing(_ failing: Bool) { lock.withLock { overviewFails = failing } }
    /// The next mutating request throws `AgentClientError.interrupted` after it has been applied by the real agent.
    func interruptNextMutationAfterApplying() { lock.withLock { interruptsNextMutation = true } }

    private static func isMutation(_ operation: AgentOperation) -> Bool {
        switch operation {
        case .replacePolicy, .saveRule, .setItemOverride, .setItemOverrides, .clearItemOverride, .setGlobalPause, .pauseUntil,
             .updateSettings, .deleteRule, .rebuildIndex:
            return true
        default:
            return false
        }
    }

    func request(_ request: AgentRequest) async throws -> AgentResponse {
        lock.withLock { log.append(request.operation) }
        switch request.operation {
        case .loadOverview:
            if lock.withLock({ overviewFails }) { throw AgentClientError.unavailable }
        case .replacePolicy, .saveRule:
            let conflict = lock.withLock { () -> Bool in
                guard pendingConflicts > 0 else { return false }
                pendingConflicts -= 1
                return true
            }
            if conflict { return AgentResponse(payload: .failure(.policyConflict)) }
        case .previewRule:
            let current = lock.withLock { () -> PreviewMode in previewCount += 1; return mode }
            switch current {
            case .passthrough: break
            case .canned(let preview): return AgentResponse(payload: .rulePreview(preview))
            case .hang:
                // Resumes only when the caller cancels, so the cancel path is observable.
                try await Task.sleep(for: .seconds(3_600))
            }
        default:
            break
        }
        let response = try await base.request(request)
        if Self.isMutation(request.operation), lock.withLock({ () -> Bool in
            let interrupt = interruptsNextMutation
            interruptsNextMutation = false
            return interrupt
        }) {
            throw AgentClientError.interrupted
        }
        return response
    }
}

@MainActor
final class StubServices: AgentSystemServices {
    var agentStatus: SMAppService.Status
    var launchesAtLogin = false
    private(set) var registerCalls = 0

    init(status: SMAppService.Status) { agentStatus = status }

    func registerAgent() throws { registerCalls += 1 }
    private(set) var restartCalls = 0
    func restartAgent() throws { restartCalls += 1 }
    func reconcileAgentAfterUpdate() throws -> Bool { false }
    func openLoginItems() {}
    func setLaunchAtLogin(_ enabled: Bool) throws { launchesAtLogin = enabled }
}

@MainActor
final class LiveAgent {
    let directory: URL
    let store: SQLiteSafetyStore
    let runtime: ManagedRootAgentRuntime
    let handler: AgentRequestHandler
    let transport: ScriptedTransport

    init(directory: URL) async throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSafetyStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        runtime = ManagedRootAgentRuntime(store: store)
        try await runtime.start()
        handler = AgentRequestHandler(store: store, runtime: runtime)
        transport = ScriptedTransport(base: InProcessTransport(handler: handler))
    }

    func model(services: StubServices, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) -> AgentViewModel {
        AgentViewModel(transport: transport, services: services, postsNotifications: false, defaults: defaults, now: now)
    }

    func stop() async { await runtime.stop() }
}

// MARK: - Fixture tree

/// A realistic tree inside the home directory (bookmark creation and managed roots reject temp-only roots).
struct Fixture {
    let root: URL
    var downloads: URL { root.appendingPathComponent("Downloads") }
    var screenshots: URL { root.appendingPathComponent("Screenshots") }
    var projects: URL { root.appendingPathComponent("Projects") }
    var scratch: URL { root.appendingPathComponent("Scratch") }
    var contract: URL { downloads.appendingPathComponent("Signed contract.pdf") }
    var dueCache: URL { projects.appendingPathComponent("webapp/__pycache__") }
    var oldLogs: [URL] = []
    var recentLogs: [URL] = []

    static func build() throws -> Fixture {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let root = home.appendingPathComponent("TinyPruneUIFixture-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var fixture = Fixture(root: root)
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

        func file(_ url: URL, kb: Int, modified: Date, created: Date? = nil) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: kb * 1024).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified, .creationDate: created ?? modified], ofItemAtPath: url.path)
        }

        for (name, kb, age) in [("Xcode Command Line Tools.dmg", 4_096, 3.0), ("Figma installer.dmg", 3_072, 12), ("Sketch update.dmg", 2_048, 20)] {
            try file(fixture.downloads.appendingPathComponent(name), kb: kb, modified: ago(age))
        }
        for (name, kb, age) in [("Quarterly export.zip", 1_536, 20.0), ("Site backup.zip", 2_560, 8), ("Photos for review.zip", 1_024, 2)] {
            try file(fixture.downloads.appendingPathComponent(name), kb: kb, modified: ago(age))
        }
        for (name, kb, age) in [("Meeting notes.txt", 12, 33.0), ("Invoice 0412.pdf", 240, 41), ("Boarding pass.pdf", 180, 5)] {
            try file(fixture.downloads.appendingPathComponent(name), kb: kb, modified: ago(age))
        }
        try file(fixture.contract, kb: 320, modified: ago(60))

        for (index, age) in [11.0, 9.5, 8.2, 6.5, 3.0, 1.0].enumerated() {
            let when = ago(age)
            try file(fixture.screenshots.appendingPathComponent("Screenshot 2026-09-\(10 + index) at 09.4\(index).png"), kb: 650, modified: when, created: when)
        }

        let web = fixture.projects.appendingPathComponent("webapp")
        try file(web.appendingPathComponent("package.json"), kb: 2, modified: ago(1))
        try file(web.appendingPathComponent("src/index.js"), kb: 8, modified: ago(1))
        for index in 0..<24 {
            try file(web.appendingPathComponent("node_modules/pkg-\(index)/index.js"), kb: 120, modified: ago(60))
        }
        for index in 0..<4 {
            try file(web.appendingPathComponent("__pycache__/mod\(index).pyc"), kb: 64, modified: ago(14))
        }
        try FileManager.default.setAttributes([.modificationDate: ago(14)], ofItemAtPath: fixture.dueCache.path)
        try file(web.appendingPathComponent("dist/bundle.js"), kb: 900, modified: ago(40))
        let api = fixture.projects.appendingPathComponent("api")
        try file(api.appendingPathComponent("main.py"), kb: 6, modified: ago(2))
        for index in 0..<6 { try file(api.appendingPathComponent(".venv/lib/site-\(index).py"), kb: 200, modified: ago(50)) }
        for index in 0..<4 { try file(api.appendingPathComponent("__pycache__/m\(index).pyc"), kb: 48, modified: ago(21)) }
        try FileManager.default.setAttributes([.modificationDate: ago(21)], ofItemAtPath: api.appendingPathComponent("__pycache__").path)

        for (index, age) in [45.0, 52, 61, 38, 90, 120, 44, 70].enumerated() {
            let url = web.appendingPathComponent("logs/debug-\(index).log")
            try file(url, kb: 512, modified: ago(age))
            fixture.oldLogs.append(url)
        }
        for (index, age) in [5.0, 2, 0.5].enumerated() {
            let url = web.appendingPathComponent("logs/recent-\(index).log")
            try file(url, kb: 128, modified: ago(age))
            fixture.recentLogs.append(url)
        }

        for (name, kb) in [("sketch idea.md", 4), ("whiteboard.jpg", 900), ("todo.txt", 1)] {
            try file(fixture.scratch.appendingPathComponent(name), kb: kb, modified: ago(0.1))
        }
        return fixture
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}
