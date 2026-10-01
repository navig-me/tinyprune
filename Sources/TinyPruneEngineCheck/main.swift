import Foundation
import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence
import Dispatch

@main
struct TinyPruneEngineCheck {
    static func main() async throws {
        try verifyFSEvents()
        try await verifyObservedActivity()
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
              Set(previewEvents.map(\.kind)) == Set([.policyReplaced, .previewSkipped]) else {
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
        let handler = AgentRequestHandler(store: store)
        let overviewRequest = AgentRequest(operation: .loadOverview)
        let overviewData = try JSONEncoder().encode(overviewRequest)
        let overviewReply = await handler.handle(overviewData)
        let overviewResponse = try JSONDecoder().decode(AgentResponse.self, from: overviewReply)
        guard case .overview(let overview) = overviewResponse.payload,
              overview.policy.rules == [folderRule],
              overview.upcoming.count == 1,
              overview.upcoming[0].explanation.candidateIdentity == candidate.identity else {
            throw SmokeFailure.agentRequestFailed
        }
        let malformedReply = await handler.handle(Data("not-json".utf8))
        let malformedResponse = try JSONDecoder().decode(AgentResponse.self, from: malformedReply)
        guard case .failure(.invalidRequest) = malformedResponse.payload else {
            throw SmokeFailure.agentRequestFailed
        }
        let activeEvents = try await store.auditEvents()
        guard originalPath == fixture.path,
              !fileManager.fileExists(atPath: fixture.path),
              fileManager.fileExists(atPath: movedPath),
              Set(activeEvents.map(\.kind)) == Set([.policyReplaced, .previewSkipped, .trashAttempted, .movedToTrash, .safetySkipped]) else {
            throw SmokeFailure.activeMoveDidNotComplete
        }
        print("TinyPrune safety smoke passed: Preview preserved; active cleanup trashed only the verified item; protected descendant was retained; SQLite audit recorded outcomes")
    }

    private static func verifyFSEvents() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("TinyPrune-FSEvents-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let fixture = root.appendingPathComponent("created.tmp")
        let latch = FSEventLatch()
        let stream = try ManagedRootEventStream(rootPath: root.path, latency: 0.05) { event in
            latch.record(event)
        }
        defer { stream.stop() }
        try Data("FSEvents fixture".utf8).write(to: fixture)
        guard latch.semaphore.wait(timeout: .now() + 5) == .success else {
            throw SmokeFailure.eventPathsMissing(latch.receivedPaths)
        }
        print("FSEvents smoke passed: created-file event delivered")
    }

    private static func verifyObservedActivity() async throws {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Activity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let file = root.appendingPathComponent("idle.tmp")
        try Data("metadata only".utf8).write(to: file)

        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let managedRoot = try ManagedRoot(displayName: root.lastPathComponent, path: root.standardizedFileURL.path, bookmarkData: bookmark)
        let rule = try LifetimeRule(
            name: "Observed activity",
            scope: RuleScope(path: managedRoot.path, recursive: false),
            matcher: ItemMatcher(itemKind: .file, exactNames: ["idle.tmp"]),
            expiryBasis: .observedActivity,
            lifetime: RuleDuration(seconds: 60),
            action: .trashItem,
            state: .preview
        )
        let store = try SQLiteSafetyStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [managedRoot], globallyPaused: false))
        let clock = MutableSmokeClock(Date(timeIntervalSince1970: 1_000))
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let indexer = ManagedRootIndexer(store: store, clock: clock) { continuation.yield(()) }

        do {
            try await indexer.start()
            let initial = await withTaskGroup(of: PersistedDeadline?.self) { group in
                group.addTask {
                    for await _ in updates {
                        if let deadline = try? await store.upcomingDeadlines().first { return deadline }
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
            guard let initial, initial.explanation.basisDate == Date(timeIntervalSince1970: 1_000) else {
                throw SmokeFailure.observedActivityDidNotInitialize
            }
            clock.set(Date(timeIntervalSince1970: 2_000))
            try await indexer.processChanges(
                ManagedRootEvent(paths: [file.path], flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [1]),
                for: managedRoot.id
            )
            let updated = try await store.upcomingDeadlines().first
            guard updated?.explanation.basisDate == Date(timeIntervalSince1970: 2_000),
                  updated?.scheduledAt == Date(timeIntervalSince1970: 2_060) else {
                throw SmokeFailure.observedActivityDidNotReset
            }
            await indexer.stop()
            continuation.finish()
        } catch {
            await indexer.stop()
            continuation.finish()
            throw error
        }
        print("Observed-activity smoke passed: initial timestamp persisted and modified-file event reset the deadline")
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
    case agentRequestFailed
    case eventPathsMissing([String])
    case observedActivityDidNotInitialize
    case observedActivityDidNotReset
}
private final class FSEventLatch: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var paths: [String] = []

    var receivedPaths: [String] { lock.withLock { paths } }

    func record(_ event: ManagedRootEvent) {
        lock.withLock { paths.append(contentsOf: event.paths) }
        if event.paths.contains(where: { $0.hasSuffix("/created.tmp") }) { semaphore.signal() }
    }
}

private struct FixedClock: SafetyClock {
    let instant: Date
    init(_ instant: Date) { self.instant = instant }
    func now() -> Date { instant }
}

private final class MutableSmokeClock: SafetyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    func now() -> Date {
        lock.withLock { instant }
    }

    func set(_ instant: Date) {
        lock.withLock { self.instant = instant }
    }
}

