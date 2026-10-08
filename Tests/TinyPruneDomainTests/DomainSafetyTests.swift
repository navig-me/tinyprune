import Foundation
import Testing
@testable import TinyPruneDomain

@Suite struct DomainSafetyTests {
    // MARK: Broadness

    @Test func veryBroadPathsAreCaseInsensitiveAndIncludeHomes() {
        for path in ["/Users", "/users", "/Users/example", "/USERS/Example", "/Users/example/Library", "/Volumes", "/Volumes/Backup",
                     "/private", "/Applications", NSHomeDirectory(), NSHomeDirectory() + "/Library", NSHomeDirectory() + "/"] {
            #expect(RuleScope.isVeryBroad(path: path), "\(path)")
        }
        for path in ["/Users/example/Developer", "/Users/example/Library/Caches/pip", "/Volumes/Backup/Projects", "/Developer"] {
            #expect(!RuleScope.isVeryBroad(path: path), "\(path)")
        }
        #expect(!RuleScope.isVeryBroad(path: "relative/path"))
    }

    @Test func ruleBroadnessFollowsScopeAndMatcherShape() throws {
        func rule(
            scope: String, recursive: Bool = true, names: Set<String> = [], globs: Set<String> = [],
            basis: ExpiryBasis = .modified, mode: RuleMatchMode = .scoped
        ) throws -> LifetimeRule {
            try LifetimeRule(
                name: "r", scope: RuleScope(path: scope, recursive: recursive),
                matcher: ItemMatcher(itemKind: .fileOrDirectory, exactNames: names, globPatterns: globs),
                expiryBasis: basis, lifetime: RuleDuration(seconds: 3600), action: .trashItem, state: .active, matchMode: mode
            )
        }
        let home = try rule(scope: "/Users/example", names: ["x"])
        #expect(home.isVeryBroad && home.isBroad)
        let catchAll = try rule(scope: "/Users/example/Work")
        #expect(!catchAll.isVeryBroad && catchAll.isBroad)
        let flatCatchAll = try rule(scope: "/Users/example/Work", recursive: false)
        #expect(!flatCatchAll.isBroad)
        let named = try rule(scope: "/Users/example/Work", names: ["node_modules"])
        #expect(!named.isBroad)
        let developer = try rule(scope: "/Users/example/Work", names: ["node_modules"], basis: .projectActivity)
        #expect(developer.isBroad)
        let developerFlat = try rule(scope: "/Users/example/Work", recursive: false, names: ["node_modules"], basis: .projectActivity)
        #expect(!developerFlat.isBroad)
        let templateMode = try rule(scope: "/Users/example/Work", recursive: false, names: ["dist"], basis: .projectActivity, mode: .template)
        #expect(templateMode.isBroad)
    }

    @Test func managedRootDangerGuardIsCaseInsensitiveAndFlagsVeryBroadRoots() throws {
        for path in ["/applications", "/APPLICATIONS/Foo", "/Usr/local", "/system/Library", "/Users/example/LIBRARY", "/Users/example/library"] {
            #expect(throws: ManagedRootValidationError.dangerousPath, "\(path)") {
                _ = try ManagedRoot(displayName: "x", path: path, bookmarkData: Data([1]))
            }
        }
        let home = try ManagedRoot(displayName: "Home", path: "/Users/example", bookmarkData: Data([1]))
        #expect(home.isVeryBroad)
        let work = try ManagedRoot(displayName: "Work", path: "/Users/example/Work", bookmarkData: Data([1]))
        #expect(!work.isVeryBroad)
    }

    @Test func symlinkIntoProtectedLocationIsDangerous() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("tp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("sys")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System")
        let path = RuleScope.normalized(link.path)
        #expect(throws: ManagedRootValidationError.dangerousPath) {
            _ = try ManagedRoot(displayName: "Sneaky", path: path, bookmarkData: Data([1]))
        }
    }

    // MARK: Globs

    @Test func globWithoutSlashMatchesBasenameAtAnyDepth() throws {
        let matcher = try ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.log"])
        #expect(matcher.matches(name: "a.log", relativePath: "a.log", kind: .file))
        #expect(matcher.matches(name: "a.log", relativePath: "deep/er/a.log", kind: .file))
        #expect(!matcher.matches(name: "a.txt", relativePath: "deep/a.txt", kind: .file))
    }

    @Test func globWithSlashIsAnchoredToScopeRelativePath() throws {
        let matcher = try ItemMatcher(itemKind: .directory, exactNames: [], globPatterns: ["build/out", "/dist/*"])
        #expect(matcher.matches(name: "out", relativePath: "build/out", kind: .directory))
        #expect(!matcher.matches(name: "out", relativePath: "x/build/out", kind: .directory))
        #expect(matcher.matches(name: "a", relativePath: "dist/a", kind: .directory))
        #expect(!matcher.matches(name: "a", relativePath: "dist/a/b", kind: .directory))
    }

    @Test func globStarsMatchNewlinesAndDoNotMatchTrailingNewlineWithDollarSemantics() {
        #expect(GlobPattern("**").matches("a\nb/c"))
        #expect(GlobPattern("a*").matches("a\nb"))
        #expect(!GlobPattern("abc").matches("abc\n"))
    }

    // MARK: Identity

    @Test func identityCreationTimeAndGenerationBreakEqualityOnlyWhenBothPresent() {
        let volume = UUID()
        let id = Data([1])
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let a = FilesystemIdentity(volumeIdentifier: volume, resourceIdentifier: id, pathHint: "/a", creationTime: t1, generation: 1)
        #expect(a == FilesystemIdentity(volumeIdentifier: volume, resourceIdentifier: id, pathHint: "/b", creationTime: t1, generation: 1))
        #expect(a != FilesystemIdentity(volumeIdentifier: volume, resourceIdentifier: id, pathHint: "/a", creationTime: t2, generation: 1))
        #expect(a != FilesystemIdentity(volumeIdentifier: volume, resourceIdentifier: id, pathHint: "/a", creationTime: t1, generation: 2))
        #expect(a == FilesystemIdentity(volumeIdentifier: volume, resourceIdentifier: id, pathHint: "/a"))
        #expect(Set([a, FilesystemIdentity(volumeIdentifier: volume, resourceIdentifier: id, pathHint: "/a")]).count == 1)
    }

    @Test func identityDecodesLegacyPayloadAndRoundTripsNewFields() throws {
        let legacy = Data(#"{"volumeIdentifier":"00000000-0000-0000-0000-000000000009","resourceIdentifier":"AQ==","pathHint":"/x"}"#.utf8)
        let decoded = try JSONDecoder().decode(FilesystemIdentity.self, from: legacy)
        #expect(decoded.creationTime == nil && decoded.generation == nil && decoded.isPersistent)

        let full = FilesystemIdentity(
            volumeIdentifier: UUID(), resourceIdentifier: Data([2]), pathHint: "/y",
            creationTime: Date(timeIntervalSince1970: 5), generation: 7, isPersistent: false
        )
        let back = try JSONDecoder().decode(FilesystemIdentity.self, from: JSONEncoder().encode(full))
        #expect(back.creationTime == full.creationTime && back.generation == 7 && !back.isPersistent)
    }

    // MARK: Templates and hidden names

    @Test func downloadsAndTemporaryWorkspaceOnlyTouchTopLevel() throws {
        for template in [RuleTemplate.downloads, .temporaryWorkspace] {
            for rule in try template.rules(in: "/Users/example/Work", state: .active) {
                #expect(!rule.scope.recursive)
                #expect(rule.scope.relativePath(of: "/Users/example/Work/dir/file") == nil)
                #expect(rule.scope.relativePath(of: "/Users/example/Work/file") == "file")
            }
        }
    }

    @Test func hiddenNameHelper() {
        #expect(ItemMatcher.isHiddenName(".git"))
        #expect(!ItemMatcher.isHiddenName("git"))
        #expect(ItemMatcher.hasHiddenComponent("a/.b/c"))
        #expect(!ItemMatcher.hasHiddenComponent("a/b/c.d"))
    }
}
