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
        try await verifyProjectActivity()
        try await verifyRecoveryAndRestartKeep()
        try await verifyAgentMutations()
        try await verifyTimedPauseSettingsAndRetention()
        try verifyDefaultGraceAndHiddenProtection()
        try await verifyItemSize()
        try await verifyRulePreview()
        try await verifyHydrationAndCustomExpiry()
        try await verifyPauseLapseRunsOnePreflight()
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
        let scheduler = DeadlineScheduler(store: store, coordinator: activeCoordinator, clock: FixedClock(Date(timeIntervalSinceReferenceDate: 200)))
        try await scheduler.runDueNow()
        let firstRunEvents = try await store.auditEvents()
        guard let moveEvent = firstRunEvents.first(where: { $0.kind == .movedToTrash }),
              let movedPath = moveEvent.detail else {
            throw SmokeFailure.activeMoveDidNotComplete
        }
        let originalPath = fixture.path
        trashPath = movedPath
        try await scheduler.runDueNow()
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
              overview.upcoming.isEmpty else {
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
              activeEvents.filter({ $0.kind == .trashAttempted }).count == 1,
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
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
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
            let fileAccess = LocalTrashFileAccess(fileManager: fileManager)
            guard let originalCandidate = try await fileAccess.inspect(path: file.path) else {
                throw SmokeFailure.observedActivityDidNotInitialize
            }
            let renamedFile = root.appendingPathComponent("renamed.tmp")
            try fileManager.moveItem(at: file, to: renamedFile)
            clock.set(Date(timeIntervalSince1970: 1_500))
            try await indexer.processChanges(
                ManagedRootEvent(
                    paths: [file.path, renamedFile.path],
                    flags: [UInt32(kFSEventStreamEventFlagItemRenamed), UInt32(kFSEventStreamEventFlagItemCreated)],
                    eventIDs: [1, 2]
                ),
                for: managedRoot.id
            )
            guard let renamedDeadline = try await store.upcomingDeadlines().first,
                  renamedDeadline.identity.volumeIdentifier == originalCandidate.identity.volumeIdentifier,
                  renamedDeadline.identity.resourceIdentifier == originalCandidate.identity.resourceIdentifier,
                  renamedDeadline.identity.pathHint == renamedFile.path,
                  let renamedActivity = try await store.observedActivity(for: renamedDeadline.identity),
                  renamedActivity.firstObservedAt == Date(timeIntervalSince1970: 1_000),
                  renamedActivity.lastObservedAt == Date(timeIntervalSince1970: 1_500) else {
                throw SmokeFailure.renameDidNotPreserveIdentity
            }
            clock.set(Date(timeIntervalSince1970: 2_000))
            try await indexer.processChanges(
                ManagedRootEvent(paths: [renamedFile.path], flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [3]),
                for: managedRoot.id
            )
            let updated = try await store.upcomingDeadlines().first
            let cursor = try await store.eventCursor(for: managedRoot.id)
            guard updated?.identity.pathHint == renamedFile.path,
                  updated?.explanation.basisDate == Date(timeIntervalSince1970: 2_000),
                  updated?.scheduledAt == Date(timeIntervalSince1970: 2_060),
                  (cursor ?? 0) >= 3 else {
                throw SmokeFailure.observedActivityDidNotReset
            }
            await indexer.stop()
            continuation.finish()
        } catch {
            await indexer.stop()
            continuation.finish()
            throw error
        }
        print("Observed-activity smoke passed: rename preserved filesystem identity and first observation; modification reset the deadline")
    }

    private static func verifyProjectActivity() async throws {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Project-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("sample", isDirectory: true)
        let sources = project.appendingPathComponent("Sources", isDirectory: true)
        let generatedDirectory = project.appendingPathComponent("node_modules", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let manifest = project.appendingPathComponent("package.json")
        let source = sources.appendingPathComponent("main.swift")
        let generated = generatedDirectory.appendingPathComponent("bundle.js")
        try Data("{}".utf8).write(to: manifest)
        try Data("source".utf8).write(to: source)
        try Data("generated".utf8).write(to: generated)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 90)], ofItemAtPath: manifest.path)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: source.path)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 500)], ofItemAtPath: generated.path)

        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let managedRoot = try ManagedRoot(displayName: root.lastPathComponent, path: root.standardizedFileURL.path, bookmarkData: bookmark)
        let rule = try LifetimeRule(
            name: "Inactive dependencies",
            scope: RuleScope(path: managedRoot.path, recursive: true),
            matcher: ItemMatcher(itemKind: .directory, exactNames: ["node_modules"]),
            expiryBasis: .projectActivity,
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
            guard let initial,
                  initial.identity.pathHint == generatedDirectory.path,
                  initial.explanation.basisDate == Date(timeIntervalSince1970: 100) else {
                throw SmokeFailure.projectActivityDidNotInitialize
            }

            clock.set(Date(timeIntervalSince1970: 2_000))
            try await indexer.processChanges(
                ManagedRootEvent(paths: [generated.path], flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [4]),
                for: managedRoot.id
            )
            guard try await store.nextDeadline()?.scheduledAt == Date(timeIntervalSince1970: 160) else {
                throw SmokeFailure.generatedProjectNoiseChangedActivity
            }

            clock.set(Date(timeIntervalSince1970: 3_000))
            try await indexer.processChanges(
                ManagedRootEvent(paths: [source.path], flags: [UInt32(kFSEventStreamEventFlagItemModified)], eventIDs: [5]),
                for: managedRoot.id
            )
            guard let updated = try await store.nextDeadline(),
                  updated.explanation.basisDate == Date(timeIntervalSince1970: 3_000),
                  updated.scheduledAt == Date(timeIntervalSince1970: 3_060) else {
                throw SmokeFailure.meaningfulProjectActivityDidNotReset
            }
            await indexer.stop()
            continuation.finish()
        } catch {
            await indexer.stop()
            continuation.finish()
            throw error
        }
        print("Project-activity smoke passed: source changes reset matched cleanup deadlines while node_modules changes were ignored")
    }

    private static func verifyRecoveryAndRestartKeep() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Recovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let keptFile = rootURL.appendingPathComponent("keep.tmp")
        try Data("keep across restart".utf8).write(to: keptFile)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: keptFile.path)
        let bookmark = try rootURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = try ManagedRoot(displayName: rootURL.lastPathComponent, path: rootURL.standardizedFileURL.path, bookmarkData: bookmark)
        let rule = try LifetimeRule(
            name: "Temporary files",
            scope: RuleScope(path: root.path, recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 60),
            action: .trashItem,
            state: .active
        )
        let databaseURL = rootURL.appendingPathComponent("state.sqlite3")
        let store = try SQLiteSafetyStore(databaseURL: databaseURL)
        try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))
        let indexer = ManagedRootIndexer(store: store)

        do {
            try await indexer.start()
            _ = try await waitForDeadline(store: store, path: keptFile.path)

            let missedFile = rootURL.appendingPathComponent("missed.tmp")
            try Data("reconcile after overflow".utf8).write(to: missedFile)
            try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: missedFile.path)
            try await indexer.processChanges(
                ManagedRootEvent(paths: [], flags: [], eventIDs: [900], requiresRecovery: true),
                for: root.id
            )
            let recoveredDeadline = try await waitForDeadline(store: store, path: missedFile.path)
            let cursor = try await store.eventCursor(for: root.id)
            let diagnostics = await indexer.diagnosticsSnapshot()
            guard recoveredDeadline.identity.pathHint == missedFile.path,
                  (cursor ?? 0) >= 900,
                  diagnostics.recoveryCount == 1 else {
                throw SmokeFailure.recoveryDidNotRebuild
            }

            let fileAccess = LocalTrashFileAccess(fileManager: fileManager)
            guard let keptCandidate = try await fileAccess.inspect(path: keptFile.path) else {
                throw SmokeFailure.keepDidNotSurviveRestart
            }
            let keep = ItemPolicyOverride(
                identity: keptCandidate.identity,
                path: keptCandidate.identity.pathHint,
                policy: .keep(protectDescendants: false)
            )
            try await store.replaceSnapshot(PolicySnapshot(rules: [rule], overrides: [keep], managedRoots: [root], globallyPaused: false))
            await indexer.stop()

            let reopenedStore = try SQLiteSafetyStore(databaseURL: databaseURL)
            let restartedIndexer = ManagedRootIndexer(store: reopenedStore)
            do {
                try await restartedIndexer.start()
                let scanDeadline = ProcessInfo.processInfo.systemUptime + 10
                var scanDiagnostics = await restartedIndexer.diagnosticsSnapshot()
                while scanDiagnostics.fullTreeScans == 0 {
                    guard ProcessInfo.processInfo.systemUptime < scanDeadline else {
                        throw SmokeFailure.keepDidNotSurviveRestart
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    scanDiagnostics = await restartedIndexer.diagnosticsSnapshot()
                }
                let recoveredSnapshot = try await reopenedStore.loadSnapshot()
                let deadlines = try await reopenedStore.upcomingDeadlines()
                guard recoveredSnapshot.overrides == [keep],
                      !deadlines.contains(where: { $0.identity.pathHint == keptFile.path }),
                      deadlines.contains(where: { $0.identity.pathHint == missedFile.path }),
                      fileManager.fileExists(atPath: keptFile.path) else {
                    throw SmokeFailure.keepDidNotSurviveRestart
                }
                await restartedIndexer.stop()
            } catch {
                await restartedIndexer.stop()
                throw error
            }
        } catch {
            await indexer.stop()
            throw error
        }
        print("Recovery/restart smoke passed: overflow rebuilt deadlines, persisted state restarted, and Keep prevented rescheduling")
    }

    private static func verifyAgentMutations() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Mutations-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let file = rootURL.appendingPathComponent("invoice.tmp")
        try Data("fixture".utf8).write(to: file)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        let bookmark = try rootURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = try ManagedRoot(displayName: rootURL.lastPathComponent, path: rootURL.standardizedFileURL.path, bookmarkData: bookmark)
        let rule = try LifetimeRule(
            name: "Temporary files",
            scope: RuleScope(path: root.path, recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 60),
            action: .trashItem,
            state: .preview
        )
        let store = try SQLiteSafetyStore(databaseURL: rootURL.appendingPathComponent("state.sqlite3"))
        let runtime = ManagedRootAgentRuntime(store: store)
        let handler = AgentRequestHandler(store: store, runtime: runtime)

        func send(_ operation: AgentOperation) async throws -> AgentResponsePayload {
            let reply = await handler.handle(try JSONEncoder().encode(AgentRequest(operation: operation)))
            return try JSONDecoder().decode(AgentResponse.self, from: reply).payload
        }

        do {
            guard try await send(.replacePolicy(AgentPolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))) == .acknowledged,
                  case .failure = try await send(.setItemOverride(path: "/etc/hosts", policy: .keep(protectDescendants: false))) else {
                throw SmokeFailure.agentRequestFailed
            }
            try await runtime.start()
            guard try await send(.setItemOverride(path: file.path, policy: .keep(protectDescendants: false))) == .acknowledged,
                  case .itemExplanation(let kept) = try await send(.explainItem(path: file.path)),
                  case .protected = kept.resolution else {
                throw SmokeFailure.agentRequestFailed
            }
            guard try await send(.clearItemOverride(path: file.path)) == .acknowledged,
                  case .itemExplanation(let inherited) = try await send(.explainItem(path: file.path)),
                  case .scheduled = inherited.resolution,
                  try await send(.setGlobalPause(true)) == .acknowledged,
                  case .itemExplanation(let paused) = try await send(.explainItem(path: file.path)),
                  case .suppressed(.globalPause) = paused.resolution,
                  try await send(.setGlobalPause(false)) == .acknowledged,
                  try await send(.deleteRule(rule.id)) == .acknowledged,
                  case .itemExplanation(let removed) = try await send(.explainItem(path: file.path)),
                  case .noRule = removed.resolution else {
                throw SmokeFailure.agentRequestFailed
            }
            guard case .activity(let activity) = try await send(.loadActivity(limit: 50)) else {
                throw SmokeFailure.agentRequestFailed
            }
            let kinds = Set(activity.map(\.kind))
            guard kinds.isSuperset(of: [.ruleCreated, .itemProtected, .itemUnprotected, .globalPauseChanged, .ruleDeleted]) else {
                throw SmokeFailure.agentRequestFailed
            }
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
        print("Agent mutation smoke passed: Keep, Inherit, pause, delete, and explanations went through the request handler with audit events")
    }

    private static func verifyPauseLapseRunsOnePreflight() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-PauseLapse-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let base = Date(timeIntervalSince1970: 2_000_000)
        let file = rootURL.appendingPathComponent("due.tmp")
        try Data("fixture".utf8).write(to: file)
        try fileManager.setAttributes([.modificationDate: base], ofItemAtPath: file.path)
        let bookmark = try rootURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = try ManagedRoot(displayName: rootURL.lastPathComponent, path: rootURL.standardizedFileURL.path, bookmarkData: bookmark)
        let rule = try LifetimeRule(
            name: "Temporary files",
            scope: RuleScope(path: root.path, recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 60),
            action: .trashItem,
            state: .preview
        )
        let clock = MutableSmokeClock(base)
        let store = try SQLiteSafetyStore(databaseURL: rootURL.appendingPathComponent("state.sqlite3"), clock: clock)
        let runtime = ManagedRootAgentRuntime(store: store, clock: clock)
        let handler = AgentRequestHandler(store: store, runtime: runtime, clock: clock)
        func send(_ operation: AgentOperation) async throws -> AgentResponsePayload {
            let reply = await handler.handle(try JSONEncoder().encode(AgentRequest(operation: operation)))
            return try JSONDecoder().decode(AgentResponse.self, from: reply).payload
        }
        let lateFile = rootURL.appendingPathComponent("late.tmp")
        func preflightCount(_ target: URL) async throws -> Int {
            try await store.auditEvents().filter { [.previewSkipped, .trashAttempted, .movedToTrash].contains($0.kind) && $0.identity?.pathHint == target.standardizedFileURL.path }.count
        }
        do {
            guard try await send(.replacePolicy(AgentPolicySnapshot(rules: [rule], overrides: [], managedRoots: [root], globallyPaused: false))) == .acknowledged else {
                throw SmokeFailure.pauseLapsePreflightFailed
            }
            try await runtime.start()
            _ = try await waitForDeadline(store: store, path: file.standardizedFileURL.path)
            guard try await send(.pauseUntil(base.addingTimeInterval(1_000))) == .acknowledged else { throw SmokeFailure.pauseLapsePreflightFailed }
            // Let the paused agent settle, then lapse the pause with the injected clock only.
            try await Task.sleep(nanoseconds: 300_000_000)
            // An item that first appears while paused must still be indexed, and only gets a preflight once the pause lifts.
            try Data("late".utf8).write(to: lateFile)
            try fileManager.setAttributes([.modificationDate: base], ofItemAtPath: lateFile.path)
            _ = try await waitForDeadline(store: store, path: lateFile.standardizedFileURL.path)
            guard try await preflightCount(file) == 0, try await preflightCount(lateFile) == 0 else { throw SmokeFailure.pauseLapsePreflightFailed }
            clock.set(base.addingTimeInterval(2_000))
            await runtime.schedulingPolicyDidChange()
            let limit = ProcessInfo.processInfo.systemUptime + 10
            while true {
                let first = try await preflightCount(file)
                let second = try await preflightCount(lateFile)
                if first > 0 && second > 0 { break }
                guard ProcessInfo.processInfo.systemUptime < limit else { throw SmokeFailure.pauseLapsePreflightFailed }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 700_000_000)
            let counts = (try await preflightCount(file), try await preflightCount(lateFile))
            guard counts == (1, 1) else {
                print("pause lapse produced \(counts) preflight events for two due candidates")
                throw SmokeFailure.pauseLapsePreflightFailed
            }
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
        print("Pause-lapse smoke passed: one due Preview candidate got exactly one preflight after the pause lapsed")
    }

    private static func verifyTimedPauseSettingsAndRetention() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("TinyPrune-Settings-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = MutableSmokeClock(start)
        let databaseURL = rootURL.appendingPathComponent("state.sqlite3")
        let store = try SQLiteSafetyStore(databaseURL: databaseURL, clock: clock)
        let handler = AgentRequestHandler(store: store, clock: clock)

        func send(_ operation: AgentOperation) async throws -> AgentResponsePayload {
            let reply = await handler.handle(try JSONEncoder().encode(AgentRequest(operation: operation)))
            return try JSONDecoder().decode(AgentResponse.self, from: reply).payload
        }
        func policy() async throws -> AgentPolicySnapshot {
            guard case .policy(let snapshot) = try await send(.loadPolicy) else { throw SmokeFailure.agentRequestFailed }
            return snapshot
        }

        // Timed pause: effective state follows the injected clock, and the lapse is audited exactly once.
        let end = start.addingTimeInterval(3_600)
        guard case .failure = try await send(.pauseUntil(start.addingTimeInterval(-1))),
              try await send(.pauseUntil(end)) == .acknowledged else { throw SmokeFailure.agentRequestFailed }
        let paused = try await policy()
        let pausedSnapshot = try await store.loadSnapshot()
        guard paused.globallyPaused, paused.pausedUntil == end, pausedSnapshot.globallyPaused else { throw SmokeFailure.timedPauseFailed }
        clock.set(end.addingTimeInterval(1))
        let lapsed = try await policy()
        let lapsedAgain = try await store.loadSnapshot()
        guard !lapsed.globallyPaused, lapsed.pausedUntil == nil, !lapsedAgain.globallyPaused, lapsedAgain.pausedUntil == nil else {
            throw SmokeFailure.timedPauseFailed
        }
        let automaticResumes = try await store.auditEvents().filter { $0.kind == .globalPauseChanged && $0.detail == "resumed automatically" }
        guard automaticResumes.count == 1 else { throw SmokeFailure.timedPauseFailed }

        // Settings round trip, persistence across reopen, and audit.
        guard case .settings(let initial) = try await send(.loadSettings), initial == .default, !initial.protectHiddenFiles else {
            throw SmokeFailure.settingsFailed
        }
        let updated = AgentSettings(defaultGracePeriodSeconds: 600, protectHiddenFiles: true, activityRetentionDays: 0)
        guard case .settings(let saved) = try await send(.updateSettings(updated)), saved == updated,
              case .settings(let loaded) = try await send(.loadSettings), loaded == updated,
              try await SQLiteSafetyStore(databaseURL: databaseURL, clock: clock).loadSettings() == updated,
              try await store.loadSnapshot().settings == updated,
              case .activity(let activity) = try await send(.loadActivity(limit: 50)),
              activity.contains(where: { $0.kind == .settingsChanged }) else { throw SmokeFailure.settingsFailed }

        // Retention: 0 keeps everything; N days prunes older events on maintenance and on settings change.
        let oldEvent = TrashAuditEvent(occurredAt: clock.now().addingTimeInterval(-40 * 86_400), kind: .notDue)
        let recentEvent = TrashAuditEvent(occurredAt: clock.now().addingTimeInterval(-86_400), kind: .notDue)
        try await store.append(oldEvent)
        try await store.append(recentEvent)
        try await store.performMaintenance()
        var ids = Set(try await store.auditEvents().map(\.id))
        guard ids.contains(oldEvent.id), ids.contains(recentEvent.id) else { throw SmokeFailure.retentionFailed }
        let retained = AgentSettings(defaultGracePeriodSeconds: 600, protectHiddenFiles: true, activityRetentionDays: 30)
        guard case .settings = try await send(.updateSettings(retained)) else { throw SmokeFailure.retentionFailed }
        ids = Set(try await store.auditEvents().map(\.id))
        guard !ids.contains(oldEvent.id), ids.contains(recentEvent.id),
              try await store.auditEvents().contains(where: { $0.kind == .settingsChanged }) else { throw SmokeFailure.retentionFailed }
        let secondOld = TrashAuditEvent(occurredAt: clock.now().addingTimeInterval(-60 * 86_400), kind: .notDue)
        try await store.append(secondOld)
        try await store.performMaintenance()
        ids = Set(try await store.auditEvents().map(\.id))
        guard !ids.contains(secondOld.id), ids.contains(recentEvent.id) else { throw SmokeFailure.retentionFailed }
        print("Timed pause, settings, and retention smoke passed: pause lapsed once via injected clock, settings persisted with audit, old audit events pruned only when retention > 0")
    }

    private static func verifyDefaultGraceAndHiddenProtection() throws {
        let scope = "/tmp/tinyprune-hidden-check"
        let modified = Date(timeIntervalSince1970: 5_000)
        func candidate(_ path: String) -> RuleCandidate {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return RuleCandidate(
                identity: FilesystemIdentity(volumeIdentifier: UUID(), resourceIdentifier: Data(name.utf8), pathHint: path),
                name: name,
                kind: .file,
                timestamps: CandidateTimestamps(modified: modified)
            )
        }
        func rule(exact: Set<String> = [], globs: Set<String> = [], grace: RuleDuration? = nil) throws -> LifetimeRule {
            try LifetimeRule(
                name: "Check",
                scope: RuleScope(path: scope, recursive: true),
                matcher: ItemMatcher(itemKind: .file, exactNames: exact, globPatterns: globs),
                expiryBasis: .modified,
                lifetime: RuleDuration(seconds: 100),
                gracePeriod: grace,
                action: .trashItem,
                state: .active
            )
        }
        func scheduledAt(_ result: CandidateEvaluation) -> Date? {
            if case .scheduled(let explanation) = result { return explanation.scheduledAt }
            return nil
        }

        // Default grace shifts scheduledAt; a rule's own grace wins.
        let plain = try rule(exact: ["junk.tmp"])
        let withGrace = try rule(exact: ["junk.tmp"], grace: RuleDuration(seconds: 30))
        let item = candidate("\(scope)/junk.tmp")
        let grace = AgentSettings(defaultGracePeriodSeconds: 600)
        guard scheduledAt(RuleEvaluator.evaluate(candidate: item, against: plain)) == modified.addingTimeInterval(100),
              scheduledAt(RuleEvaluator.evaluate(candidate: item, against: plain, settings: grace)) == modified.addingTimeInterval(700),
              scheduledAt(RuleEvaluator.evaluate(candidate: item, against: withGrace, settings: grace)) == modified.addingTimeInterval(130),
              case .scheduled(let resolved) = RuleResolver.resolve(candidate: item, rules: [plain], settings: grace),
              resolved.scheduledAt == modified.addingTimeInterval(700) else { throw SmokeFailure.defaultGraceFailed }

        // Hidden protection and the explicit dot-name exemption.
        let hiddenSettings = AgentSettings(protectHiddenFiles: true)
        let hiddenParent = candidate("\(scope)/.cache/junk.tmp")
        guard RuleEvaluator.evaluate(candidate: hiddenParent, against: plain, settings: hiddenSettings) == .suppressed(.hiddenProtected),
              scheduledAt(RuleEvaluator.evaluate(candidate: hiddenParent, against: plain)) != nil,
              scheduledAt(RuleEvaluator.evaluate(candidate: item, against: plain, settings: hiddenSettings)) != nil,
              RuleResolver.resolve(candidate: hiddenParent, rules: [plain], settings: hiddenSettings) == .suppressed(.hiddenProtected) else {
            throw SmokeFailure.hiddenProtectionFailed
        }
        let dotExact = try rule(exact: [".DS_Store"])
        let dotGlob = try rule(globs: ["**/.#*"])
        guard scheduledAt(RuleEvaluator.evaluate(candidate: candidate("\(scope)/sub/.DS_Store"), against: dotExact, settings: hiddenSettings)) != nil,
              scheduledAt(RuleEvaluator.evaluate(candidate: candidate("\(scope)/sub/.#lock"), against: dotGlob, settings: hiddenSettings)) != nil else {
            throw SmokeFailure.hiddenProtectionFailed
        }
        print("Default grace and hidden-file smoke passed: grace shifts scheduledAt, hidden items are suppressed, explicit dot-name rules are exempt")
    }

    private static func verifyItemSize() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Size-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let folder = rootURL.appendingPathComponent("build", isDirectory: true)
        try fileManager.createDirectory(at: folder.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 20_000).write(to: folder.appendingPathComponent("a.bin"))
        try Data(repeating: 9, count: 5_000).write(to: folder.appendingPathComponent("nested/b.bin"))
        let bookmark = try rootURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = try ManagedRoot(displayName: rootURL.lastPathComponent, path: rootURL.standardizedFileURL.path, bookmarkData: bookmark)
        let store = try SQLiteSafetyStore(databaseURL: rootURL.appendingPathComponent("state.sqlite3"))
        let runtime = ManagedRootAgentRuntime(store: store)
        let handler = AgentRequestHandler(store: store, runtime: runtime)
        func send(_ operation: AgentOperation) async throws -> AgentResponsePayload {
            let reply = await handler.handle(try JSONEncoder().encode(AgentRequest(operation: operation)))
            return try JSONDecoder().decode(AgentResponse.self, from: reply).payload
        }
        do {
            guard try await send(.replacePolicy(AgentPolicySnapshot(rules: [], overrides: [], managedRoots: [root], globallyPaused: false))) == .acknowledged else {
                throw SmokeFailure.itemSizeFailed
            }
            try await runtime.start()
            let folderPath = folder.standardizedFileURL.path
            guard case .itemSize(let path, let bytes, let items, let truncated) = try await send(.itemSize(path: folderPath)),
                  path == folderPath, bytes >= 25_000, items == 4, !truncated,
                  case .failure = try await send(.itemSize(path: "/etc/hosts")) else { throw SmokeFailure.itemSizeFailed }
            guard let bounded = ItemSizeMeasurer.measure(path: folderPath, maxEntries: 2), bounded.truncated, bounded.items == 2 else {
                throw SmokeFailure.itemSizeFailed
            }
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
        print("Item size smoke passed: managed folder measured from allocated sizes, outside paths rejected, walk bounded and truncated")
    }

    private static func verifyRulePreview() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Preview-\(UUID().uuidString)", isDirectory: true)
        let scope = rootURL.appendingPathComponent("scope", isDirectory: true)
        try fileManager.createDirectory(at: scope.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scope.appendingPathComponent("build/nested", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let old = now.addingTimeInterval(-1_000)
        for name in ["old1.tmp", "old2.tmp", "sub/old3.tmp", "keep.tmp", ".hidden.tmp"] {
            let url = scope.appendingPathComponent(name)
            try Data(repeating: 1, count: 10_000).write(to: url)
            try fileManager.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let fresh = scope.appendingPathComponent("new.tmp")
        try Data(repeating: 1, count: 10_000).write(to: fresh)
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        try fileManager.createSymbolicLink(at: scope.appendingPathComponent("link.tmp"), withDestinationURL: scope.appendingPathComponent("old1.tmp"))
        try fileManager.createSymbolicLink(at: scope.appendingPathComponent("outside-link"), withDestinationURL: fileManager.temporaryDirectory)
        let buildFolder = scope.appendingPathComponent("build", isDirectory: true)
        try Data(repeating: 7, count: 20_000).write(to: buildFolder.appendingPathComponent("a.bin"))
        try Data(repeating: 9, count: 5_000).write(to: buildFolder.appendingPathComponent("nested/b.bin"))
        try fileManager.setAttributes([.modificationDate: old], ofItemAtPath: buildFolder.path)

        let bookmark = try rootURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = try ManagedRoot(displayName: rootURL.lastPathComponent, path: rootURL.standardizedFileURL.path, bookmarkData: bookmark)
        let store = try SQLiteSafetyStore(databaseURL: rootURL.appendingPathComponent("state.sqlite3"))
        let keepPath = scope.appendingPathComponent("keep.tmp").standardizedFileURL.path
        let keep = ItemPolicyOverride(path: keepPath, policy: .keep(protectDescendants: false))
        let scopePath = scope.standardizedFileURL.path

        func tmpRule(basis: ExpiryBasis = .modified, state: RuleState = .paused, scopePath: String) throws -> LifetimeRule {
            try LifetimeRule(
                name: "Preview temp files",
                scope: RuleScope(path: scopePath, recursive: true),
                matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["**/*.tmp"]),
                expiryBasis: basis,
                lifetime: RuleDuration(seconds: 10),
                action: .trashItem,
                state: state
            )
        }
        func buildRule() throws -> LifetimeRule {
            try LifetimeRule(
                name: "Preview build folders",
                scope: RuleScope(path: scopePath, recursive: false),
                matcher: ItemMatcher(itemKind: .directory, exactNames: ["build"]),
                expiryBasis: .modified,
                lifetime: RuleDuration(seconds: 10),
                action: .trashItem,
                state: .active
            )
        }
        func withRuntime(_ configuration: RulePreviewConfiguration, _ body: (ManagedRootAgentRuntime, AgentRequestHandler) async throws -> Void) async throws {
            let runtime = ManagedRootAgentRuntime(store: store, clock: FixedClock(now), rulePreview: configuration)
            let handler = AgentRequestHandler(store: store, runtime: runtime, clock: FixedClock(now))
            do {
                try await runtime.start()
                try await body(runtime, handler)
                await runtime.stop()
            } catch {
                await runtime.stop()
                throw error
            }
        }
        func send(_ handler: AgentRequestHandler, _ operation: AgentOperation) async throws -> AgentResponsePayload {
            let reply = await handler.handle(try JSONEncoder().encode(AgentRequest(operation: operation)))
            return try JSONDecoder().decode(AgentResponse.self, from: reply).payload
        }

        // Policy: no saved rules, a Keep override, hidden-file protection on. The rule under test is never saved.
        try await withRuntime(RulePreviewConfiguration()) { runtime, handler in
            guard try await send(handler, .replacePolicy(AgentPolicySnapshot(rules: [], overrides: [keep], managedRoots: [root], globallyPaused: false))) == .acknowledged,
                  case .settings = try await send(handler, .updateSettings(AgentSettings(protectHiddenFiles: true))) else {
                throw SmokeFailure.rulePreviewFailed("setup")
            }
            let auditBefore = try await store.auditEvents().count

            // Requested state .paused is evaluated as Preview. Matches: old1, old2, sub/old3, new (Keep, hidden, symlink excluded).
            guard case .rulePreview(let preview) = try await send(handler, .previewRule(try tmpRule(scopePath: scopePath))) else {
                throw SmokeFailure.rulePreviewFailed("no preview payload")
            }
            guard preview.matches == 4, preview.eligibleNow == 3, !preview.truncated,
                  preview.estimatedBytes >= 40_000, preview.scannedEntries >= 9,
                  preview.samples.count == 4,
                  preview.samples.allSatisfy({ !$0.path.hasSuffix("keep.tmp") && !$0.path.hasSuffix(".hidden.tmp") && !$0.path.hasSuffix("link.tmp") }),
                  preview.samples.last?.path.hasSuffix("/new.tmp") == true,
                  preview.samples.last?.scheduledAt == now.addingTimeInterval(10) else {
                throw SmokeFailure.rulePreviewFailed("counts \(preview)")
            }

            // Directory match: bounded measurer contributes the folder's allocated size once.
            guard case .rulePreview(let folderPreview) = try await send(handler, .previewRule(try buildRule())),
                  folderPreview.matches == 1, folderPreview.eligibleNow == 1, folderPreview.estimatedBytes >= 25_000,
                  folderPreview.samples.first?.bytes == folderPreview.estimatedBytes else {
                throw SmokeFailure.rulePreviewFailed("folder rule")
            }

            // First-observed basis with no stored record: first observed is `now`, so nothing is eligible yet and nothing is persisted.
            guard case .rulePreview(let observed) = try await send(handler, .previewRule(try tmpRule(basis: .firstObserved, scopePath: scopePath))),
                  observed.matches == 4, observed.eligibleNow == 0,
                  observed.samples.allSatisfy({ $0.scheduledAt == now.addingTimeInterval(10) }) else {
                throw SmokeFailure.rulePreviewFailed("first observed")
            }

            // Out-of-root and missing scopes are rejected with invalidRequest.
            let outside = fileManager.temporaryDirectory.standardizedFileURL.path
            guard case .failure(.invalidRequest) = try await send(handler, .previewRule(try tmpRule(scopePath: outside))),
                  case .failure(.invalidRequest) = try await send(handler, .previewRule(try tmpRule(scopePath: scopePath + "/missing"))),
                  case .failure(.invalidRequest) = try await send(handler, .previewRule(try tmpRule(scopePath: scopePath + "/outside-link/no-such-subdir"))) else {
                throw SmokeFailure.rulePreviewFailed("rejection")
            }

            // No side effects: no audit events, deadlines, observed activity, or policy changes; fixtures untouched.
            let oldPath = scope.appendingPathComponent("old1.tmp").path
            guard let identity = try await LocalTrashFileAccess().inspect(path: oldPath)?.identity,
                  try await store.auditEvents().count == auditBefore,
                  try await store.indexedDeadlineCount() == 0,
                  try await store.observedActivity(for: identity) == nil,
                  try await store.loadSnapshot().rules.isEmpty,
                  fileManager.fileExists(atPath: oldPath) else {
                throw SmokeFailure.rulePreviewFailed("side effects")
            }

            // Cancelling the call cancels the traversal.
            let cancelled = Task { try await runtime.previewRule(try tmpRule(scopePath: scopePath)) }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                throw SmokeFailure.rulePreviewFailed("cancel ignored")
            } catch is CancellationError {}
        }

        // Entry cap truncates.
        try await withRuntime(RulePreviewConfiguration(limits: RulePreviewLimits(maxEntries: 3))) { _, handler in
            guard case .rulePreview(let capped) = try await send(handler, .previewRule(try tmpRule(scopePath: scopePath))),
                  capped.truncated, capped.scannedEntries == 3 else { throw SmokeFailure.rulePreviewFailed("entry cap") }
        }
        // Wall-clock budget truncates with an injected time source (no sleeping).
        let ticker = PreviewTicker()
        try await withRuntime(RulePreviewConfiguration(limits: RulePreviewLimits(maxDurationSeconds: 20), uptime: { ticker.next() })) { _, handler in
            guard case .rulePreview(let timed) = try await send(handler, .previewRule(try tmpRule(scopePath: scopePath))),
                  timed.truncated, timed.scannedEntries < 9 else { throw SmokeFailure.rulePreviewFailed("time budget") }
        }
        // Shared directory-walk budget truncates the byte estimate.
        try await withRuntime(RulePreviewConfiguration(limits: RulePreviewLimits(sizeWalkEntries: 2))) { _, handler in
            guard case .rulePreview(let walked) = try await send(handler, .previewRule(try buildRule())),
                  walked.matches == 1, walked.truncated else { throw SmokeFailure.rulePreviewFailed("size budget") }
        }
        print("Rule preview smoke passed: matches, eligibleNow, Keep/hidden/symlink exclusion, caps truncate, cancellation, out-of-root rejected, no audit/deadline/observation side effects")
    }

    private static func verifyHydrationAndCustomExpiry() async throws {
        let fm = FileManager.default
        let rootURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("TinyPrune-Expiry-\(UUID().uuidString)", isDirectory: true)
        let folder = rootURL.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var trashedPaths: [String] = []
        defer {
            for path in trashedPaths { try? fm.removeItem(atPath: path) }
            try? fm.removeItem(at: rootURL)
        }
        let now = Date()
        let clock = MutableSmokeClock(now)
        for name in ["package.json", "first.tmp", "observed.tmp", "project.tmp", "expire.tmp", "keep.tmp", "inherit.tmp"] {
            let url = folder.appendingPathComponent(name)
            try Data("metadata fixture".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
        let bookmark = try rootURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = try ManagedRoot(displayName: rootURL.lastPathComponent, path: rootURL.standardizedFileURL.path, bookmarkData: bookmark)
        let store = try SQLiteSafetyStore(databaseURL: rootURL.appendingPathComponent("state.sqlite3"), clock: clock)
        let runtime = ManagedRootAgentRuntime(store: store, clock: clock)
        let handler = AgentRequestHandler(store: store, runtime: runtime, clock: clock)
        func send(_ operation: AgentOperation) async throws -> AgentResponsePayload {
            let data = await handler.handle(try JSONEncoder().encode(AgentRequest(operation: operation)))
            return try JSONDecoder().decode(AgentResponse.self, from: data).payload
        }
        func path(_ name: String) -> String { folder.appendingPathComponent(name).standardizedFileURL.path }
        func awaitDeadline(_ itemPath: String) async throws -> PersistedDeadline {
            let until = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < until {
                if let item = try await store.upcomingDeadlines().first(where: { $0.identity.pathHint == itemPath }) { return item }
                await Task.yield()
            }
            throw SmokeFailure.rulePreviewFailed("expiry deadline absent: \(itemPath)")
        }
        do {
            let rules = try [(ExpiryBasis.firstObserved, "first.tmp"), (.observedActivity, "observed.tmp"), (.projectActivity, "project.tmp")].map { basis, name in
                try LifetimeRule(name: name, scope: RuleScope(path: folder.standardizedFileURL.path, recursive: false),
                                 matcher: ItemMatcher(itemKind: .file, exactNames: [name]), expiryBasis: basis,
                                 lifetime: RuleDuration(seconds: 60), action: .trashItem, state: .preview)
            }
            try await store.replaceSnapshot(PolicySnapshot(rules: rules, overrides: [], managedRoots: [root], globallyPaused: false))
            try await runtime.start()
            for name in ["first.tmp", "observed.tmp", "project.tmp"] {
                let scheduled = try await awaitDeadline(path(name))
                guard case .itemExplanation(let why) = try await send(.explainItem(path: path(name))),
                      case .scheduled(let explanation) = why.resolution,
                      explanation.matchedRuleID == scheduled.explanation.matchedRuleID,
                      explanation.expiryBasis == scheduled.explanation.expiryBasis,
                      abs(explanation.basisDate.timeIntervalSince(scheduled.explanation.basisDate)) < 0.001,
                      abs(explanation.scheduledAt.timeIntervalSince(scheduled.scheduledAt)) < 0.001 else {
                    throw SmokeFailure.rulePreviewFailed("Upcoming and Why disagree: \(name)")
                }
            }

            // Pause the background worker while arranging future explicit expiries. No lifetime rule is required.
            guard try await send(.replacePolicy(AgentPolicySnapshot(rules: [], overrides: [], managedRoots: [root], globallyPaused: true))) == .acknowledged else {
                throw SmokeFailure.rulePreviewFailed("custom policy")
            }
            let expiry = now.addingTimeInterval(30)
            for name in ["expire.tmp", "keep.tmp", "inherit.tmp"] {
                guard try await send(.setItemOverride(path: path(name), policy: .customExpiry(expiry, state: .active))) == .acknowledged else {
                    throw SmokeFailure.rulePreviewFailed("custom save")
                }
                let deadline = try await awaitDeadline(path(name))
                guard case .customOverride(let id) = deadline.source,
                      deadline.explanation.customOverrideID == id, deadline.scheduledAt == expiry,
                      deadline.explanation.disposition == .active,
                      case .overview(let overview) = try await send(.loadOverview),
                      overview.upcoming.contains(where: { $0.id == deadline.identity && $0.explanation.scheduledAt == expiry }) else {
                    throw SmokeFailure.rulePreviewFailed("custom not in Upcoming")
                }
            }
            let staleKeepDeadline = try await awaitDeadline(path("keep.tmp"))
            guard try await send(.setItemOverride(path: path("keep.tmp"), policy: .keep(protectDescendants: false))) == .acknowledged,
                  try await send(.setItemOverride(path: path("inherit.tmp"), policy: .inherit)) == .acknowledged else {
                throw SmokeFailure.rulePreviewFailed("custom removal")
            }
            _ = try await awaitDeadline(path("expire.tmp")) // Recovery has finished rebuilding the remaining custom deadline.
            guard try await store.upcomingDeadlines().allSatisfy({ $0.identity.pathHint != path("keep.tmp") && $0.identity.pathHint != path("inherit.tmp") }) else {
                throw SmokeFailure.rulePreviewFailed("Keep/Inherit retained custom deadline")
            }
            // Removing the explicit override also removes its deadline.
            guard try await send(.setItemOverride(path: path("inherit.tmp"), policy: .customExpiry(expiry, state: .preview))) == .acknowledged,
                  try await send(.clearItemOverride(path: path("inherit.tmp"))) == .acknowledged else {
                throw SmokeFailure.rulePreviewFailed("clear custom")
            }
            _ = try await awaitDeadline(path("expire.tmp"))
            guard try await store.upcomingDeadlines().allSatisfy({ $0.identity.pathHint != path("inherit.tmp") }) else {
                throw SmokeFailure.rulePreviewFailed("clear retained custom deadline")
            }

            // Exercise the actual scheduler and real Trash preflight without timers or sleeps.
            // A stale deadline restored after Keep demonstrates SQLite never authorizes a move.
            try await store.saveDeadline(staleKeepDeadline)
            let coordinator = TrashCoordinator(policyStore: store, fileAccess: LocalTrashFileAccess(), audit: store, clock: clock)
            let scheduler = DeadlineScheduler(store: store, coordinator: coordinator, clock: clock)
            clock.set(expiry.addingTimeInterval(1))
            try await store.setGlobalPause(false, auditEvent: TrashAuditEvent(occurredAt: clock.now(), kind: .globalPauseChanged))
            try await scheduler.runDueNow()
            try await scheduler.runDueNow()
            let events = try await store.auditEvents()
            trashedPaths = events.filter { $0.kind == .movedToTrash }.compactMap(\.detail)
            guard !fm.fileExists(atPath: path("expire.tmp")),
                  fm.fileExists(atPath: path("keep.tmp")), fm.fileExists(atPath: path("inherit.tmp")),
                  events.filter({ $0.kind == .movedToTrash }).count == 1,
                  events.contains(where: { $0.kind == .safetySkipped && $0.identity == staleKeepDeadline.identity }),
                  try await store.indexedDeadlineCount() == 0 else {
                throw SmokeFailure.rulePreviewFailed("custom Trash/Keep safety")
            }
            await runtime.stop()
        } catch {
            await runtime.stop()
            trashedPaths = (try? await store.auditEvents().filter { $0.kind == .movedToTrash }.compactMap(\.detail)) ?? []
            throw error
        }
        print("Hydration/custom expiry smoke passed: Why agrees with Upcoming for observed/project bases; explicit expiry indexed; Keep/Inherit/clear remove deadlines; scheduler trashed exactly one due item once and stale Keep deadline was rejected")
    }

    private static func waitForDeadline(store: SQLiteSafetyStore, path: String) async throws -> PersistedDeadline {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let match = try await store.upcomingDeadlines().first(where: { $0.identity.pathHint == path }) {
                return match
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SmokeFailure.recoveryDidNotRebuild
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
    case timedPauseFailed
    case pauseLapsePreflightFailed
    case settingsFailed
    case retentionFailed
    case defaultGraceFailed
    case hiddenProtectionFailed
    case itemSizeFailed
    case rulePreviewFailed(String)
    case eventPathsMissing([String])
    case observedActivityDidNotInitialize
    case renameDidNotPreserveIdentity
    case observedActivityDidNotReset
    case projectActivityDidNotInitialize
    case generatedProjectNoiseChangedActivity
    case meaningfulProjectActivityDidNotReset
    case recoveryDidNotRebuild
    case keepDidNotSurviveRestart
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


private final class PreviewTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func next() -> TimeInterval { lock.withLock { value += 10; return value } }
}
