import Darwin
import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence

@Suite struct RulePreviewPermissionTests {
    @Test(.enabled(if: geteuid() != 0))
    func unreadableScopeFailsRatherThanReportingExactZeroMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrunePreviewPermission-\(UUID())")
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: blocked.appendingPathComponent("expired.tmp"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = try SQLiteSafetyStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
        let previewer = RulePreviewer(store: store, fileAccess: LocalTrashFileAccess(), clock: SystemSafetyClock(), configuration: RulePreviewConfiguration())
        let rule = try LifetimeRule(name: "Unreadable fixture", scope: RuleScope(path: blocked.path, recursive: true),
                                    matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
                                    expiryBasis: .modified, lifetime: RuleDuration(seconds: 10), action: .trashItem, state: .preview)
        let snapshot = PolicySnapshot(rules: [], overrides: [], globallyPaused: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        do {
            _ = try await previewer.run(rule: rule, snapshot: snapshot, access: RootAccessToken(url: root))
            Issue.record("An unreadable scope must not produce a successful exact preview")
        } catch RulePreviewError.invalidRequest(let message) {
            #expect(message.contains(blocked.path))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        let readable = try await previewer.run(rule: rule, snapshot: snapshot, access: RootAccessToken(url: root))
        #expect(readable.matches == 1)
        #expect(!readable.truncated)
        #expect(try await store.indexedDeadlineCount() == 0)
    }
}
