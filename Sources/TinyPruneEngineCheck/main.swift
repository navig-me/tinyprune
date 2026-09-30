import Foundation
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence

@main
struct TinyPruneEngineCheck {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("TinyPrune-Engine-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("candidate.tmp")
        try Data("TinyPrune metadata-only safety fixture".utf8).write(to: fixture)
        let modified = Date(timeIntervalSinceReferenceDate: 100)
        try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: fixture.path)

        var trashPath: String?
        defer {
            if let trashPath { try? fileManager.removeItem(atPath: trashPath) }
            try? fileManager.removeItem(at: root)
        }

        let store = try SQLiteSafetyStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
        let fileAccess = LocalTrashFileAccess(fileManager: fileManager)
        guard let candidate = try await fileAccess.inspect(path: fixture.path) else {
            throw SmokeFailure.fixtureMissing
        }
        let previewRule = try makeRule(scope: root.path, state: .preview)
        try await store.replaceSnapshot(PolicySnapshot(rules: [previewRule], overrides: [], globallyPaused: false))
        var duplicatePolicyRejected = false
        do {
            try await store.replaceSnapshot(PolicySnapshot(rules: [previewRule, previewRule], overrides: [], globallyPaused: true))
        } catch {
            duplicatePolicyRejected = true
        }
        let recoveredPolicy = try await store.loadSnapshot()
        guard duplicatePolicyRejected, recoveredPolicy.rules == [previewRule], !recoveredPolicy.globallyPaused else {
            throw SmokeFailure.persistenceTransactionFailed
        }
        guard case .scheduled(let explanation) = RuleEvaluator.evaluate(candidate: candidate, against: previewRule) else {
            throw SmokeFailure.deadlineIndexFailed
        }
        try await store.saveDeadline(PersistedDeadline(identity: candidate.identity, scheduledAt: explanation.scheduledAt, explanation: explanation))
        guard let nextDeadline = try await store.nextDeadline(), nextDeadline.identity == candidate.identity,
              nextDeadline.scheduledAt == explanation.scheduledAt else {
            throw SmokeFailure.deadlineIndexFailed
        }
        let previewCoordinator = TrashCoordinator(
            policyStore: store,
            fileAccess: fileAccess,
            audit: store,
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 200))
        )
        let scheduledAt = modified.addingTimeInterval(10)
        let request = TrashRequest(candidateIdentity: candidate.identity, source: .rule(previewRule.id), scheduledAt: scheduledAt)
        let previewOutcome = try await previewCoordinator.execute(request)
        let previewEvents = try await store.auditEvents()
        guard previewOutcome == .previewed,
              fileManager.fileExists(atPath: fixture.path),
              previewEvents.map(\.kind) == [.previewSkipped] else {
            throw SmokeFailure.previewMovedFixture
        }

        let activeRule = try makeRule(id: previewRule.id, scope: root.path, state: .active)
        try await store.replaceSnapshot(PolicySnapshot(rules: [activeRule], overrides: [], globallyPaused: false))
        let activeCoordinator = TrashCoordinator(
            policyStore: store,
            fileAccess: fileAccess,
            audit: store,
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 200))
        )
        let activeOutcome = try await activeCoordinator.execute(request)
        guard case .movedToTrash(let originalPath, let movedPath) = activeOutcome else {
            throw SmokeFailure.activeMoveDidNotComplete
        }
        trashPath = movedPath
        let protectedFolder = root.appendingPathComponent("build", isDirectory: true)
        let protectedFile = protectedFolder.appendingPathComponent("contract.txt")
        try fileManager.createDirectory(at: protectedFolder, withIntermediateDirectories: true)
        try Data("protected fixture".utf8).write(to: protectedFile)
        try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: protectedFolder.path)
        guard let folderCandidate = try await fileAccess.inspect(path: protectedFolder.path),
              let modifiedAt = folderCandidate.timestamps.modified else {
            throw SmokeFailure.protectedDescendantNotChecked
        }
        let folderRule = try makeFolderRule(scope: root.path)
        let keep = ItemPolicyOverride(path: protectedFile.path, policy: .keep(protectDescendants: false))
        try await store.replaceSnapshot(PolicySnapshot(rules: [folderRule], overrides: [keep], globallyPaused: false))
        let folderRequest = TrashRequest(
            candidateIdentity: folderCandidate.identity,
            source: .rule(folderRule.id),
            scheduledAt: modifiedAt.addingTimeInterval(10)
        )
        let folderOutcome = try await activeCoordinator.execute(folderRequest)
        guard folderOutcome == .skipped("folder contains a protected descendant"),
              fileManager.fileExists(atPath: protectedFolder.path),
              fileManager.fileExists(atPath: protectedFile.path) else {
            throw SmokeFailure.protectedDescendantNotChecked
        }
        let activeEvents = try await store.auditEvents()
        guard originalPath == fixture.path,
              !fileManager.fileExists(atPath: fixture.path),
              fileManager.fileExists(atPath: movedPath),
              Set(activeEvents.map(\.kind)) == Set([.previewSkipped, .trashAttempted, .movedToTrash, .safetySkipped]) else {
            throw SmokeFailure.activeMoveDidNotComplete
        }
        print("TinyPrune safety smoke passed: Preview preserved; active cleanup trashed only the verified item; protected descendant was retained; SQLite audit recorded outcomes")
    }

    private static func makeRule(id: UUID = UUID(), scope: String, state: RuleState) throws -> LifetimeRule {
        try LifetimeRule(
            id: id,
            name: "Temporary exports",
            scope: RuleScope(path: scope, recursive: false),
            matcher: ItemMatcher(itemKind: .file, exactNames: ["candidate.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 10),
            action: .trashItem,
            state: state
        )
    }
    private static func makeFolderRule(scope: String) throws -> LifetimeRule {
        try LifetimeRule(
            name: "Build folders",
            scope: RuleScope(path: scope, recursive: false),
            matcher: ItemMatcher(itemKind: .directory, exactNames: ["build"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 10),
            action: .trashItem,
            state: .active
        )
    }
}

private enum SmokeFailure: Error {
    case fixtureMissing
    case previewMovedFixture
    case persistenceTransactionFailed
    case deadlineIndexFailed
    case activeMoveDidNotComplete
    case protectedDescendantNotChecked
}

private struct FixedClock: SafetyClock {
    let instant: Date
    init(_ instant: Date) { self.instant = instant }
    func now() -> Date { instant }
}

