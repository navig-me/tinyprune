import Foundation
import Testing
@testable import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence

/// Preview must not promise what execution would refuse (S11): folders holding protected content are excluded from
/// the eligible counts/bytes/samples, and an item nested inside a matched ancestor is not a separate match.
@Suite struct RulePreviewExecutionParityTests {
    @Test func previewExcludesProtectedFoldersAndCountsOnlyTopMostMatches() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TinyPrunePreviewParity-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func makeDirectory(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let plain = try makeDirectory("a/build")
        try Data("x".utf8).write(to: plain.appendingPathComponent("out.bin"))
        let protected = try makeDirectory("b/build")
        let keptFile = protected.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keptFile)
        let outer = try makeDirectory("c/build")
        let nested = try makeDirectory("c/build/inner/build")
        try Data("y".utf8).write(to: nested.appendingPathComponent("out.bin"))
        let old = Date(timeIntervalSince1970: 100)
        for directory in [nested, outer, protected, plain] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }

        let store = try SQLiteSafetyStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
        let rule = try LifetimeRule(
            name: "Build folders", scope: RuleScope(path: root.path, recursive: true),
            matcher: ItemMatcher(itemKind: .directory, exactNames: ["build"]),
            expiryBasis: .modified, lifetime: RuleDuration(seconds: 10), action: .trashItem, state: .preview
        )
        let keep = ItemPolicyOverride(path: keptFile.path, policy: .keep(protectDescendants: false))
        let snapshot = PolicySnapshot(rules: [], overrides: [keep], globallyPaused: false)
        let previewer = RulePreviewer(store: store, fileAccess: LocalTrashFileAccess(), clock: SystemSafetyClock(), configuration: RulePreviewConfiguration())

        let preview = try await previewer.run(rule: rule, snapshot: snapshot, access: RootAccessToken(url: root))

        // Top-most matches: a/build, b/build, c/build (c/build/inner/build is covered by its matched ancestor).
        #expect(preview.matches == 3)
        // b/build holds a Keep, so execution would skip it.
        #expect(preview.eligibleNow == 2)
        let samplePaths = Set(preview.samples.map(\.path))
        #expect(samplePaths.count == 2)
        #expect(samplePaths.allSatisfy { !$0.contains("/b/build") && !$0.contains("/inner/") })
        #expect(try await store.indexedDeadlineCount() == 0)
    }

    @Test func previewOfAnActionTheExecutorDoesNotImplementPromisesNothing() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TinyPrunePreviewParity-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("old.tmp")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        let store = try SQLiteSafetyStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
        let rule = try LifetimeRule(
            name: "Other action", scope: RuleScope(path: root.path, recursive: false),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
            expiryBasis: .modified, lifetime: RuleDuration(seconds: 10), action: .emptyContents, state: .preview
        )
        let previewer = RulePreviewer(store: store, fileAccess: LocalTrashFileAccess(), clock: SystemSafetyClock(), configuration: RulePreviewConfiguration())

        let preview = try await previewer.run(rule: rule, snapshot: PolicySnapshot(rules: [], overrides: [], globallyPaused: false), access: RootAccessToken(url: root))

        #expect(preview.matches == 1)
        #expect(preview.eligibleNow == 0)
        #expect(preview.samples.isEmpty)
    }
}
