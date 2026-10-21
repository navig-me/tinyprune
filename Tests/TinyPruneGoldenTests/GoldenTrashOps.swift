import Foundation
@testable import TinyPruneDomain
@testable import TinyPruneEngine
import TinyPruneIPC

/// `trash.execute` scenarios drive the real `TrashCoordinator` against scripted collaborators and report the
/// outcome, the audit trail, and the exact order of filesystem calls. See `Fixtures/golden/README.md`.
extension GoldenOps {
    static func snapshot(_ object: FixtureObject) throws -> PolicySnapshot {
        PolicySnapshot(
            rules: try (object["rules"] as? [FixtureObject] ?? []).map(rule),
            overrides: try (object["overrides"] as? [FixtureObject] ?? []).map(override),
            managedRoots: try (object["roots"] as? [FixtureObject] ?? []).map {
                try ManagedRoot(displayName: $0["name"] as? String ?? "Root", path: try string($0, "path"), bookmarkData: Data([1]))
            },
            globallyPaused: object["globallyPaused"] as? Bool ?? false,
            settings: try settings(object["settings"] as? FixtureObject)
        )
    }

    static func trashExecute(_ input: FixtureObject) async throws -> FixtureObject {
        let now = Date(timeIntervalSince1970: input["now"] as? Double ?? 0)

        let requestObject = try object(input, "request")
        let sourceObject = try object(requestObject, "source")
        let source: ScheduledSource
        if sourceObject["rule"] != nil { source = .rule(try uuid(sourceObject, "rule")) }
        else { source = .customOverride(try uuid(sourceObject, "customOverride")) }
        let request = TrashRequest(
            candidateIdentity: try identity(try object(requestObject, "identity")),
            source: source,
            scheduledAt: Date(timeIntervalSince1970: requestObject["scheduledAt"] as? Double ?? 0)
        )

        // Policy snapshots are served in order; the last one repeats. `{"error": true}` makes a load fail.
        let snapshotEntries: [PolicySnapshot?]
        if let list = input["snapshots"] as? [FixtureObject] {
            snapshotEntries = try list.map { $0["error"] as? Bool == true ? nil : try snapshot($0) }
        } else {
            snapshotEntries = [try snapshot(try object(input, "snapshot"))]
        }

        let filesystem = input["filesystem"] as? FixtureObject ?? [:]
        let candidates: [RuleCandidate?]
        if let list = filesystem["candidates"] as? [Any] {
            candidates = try list.map { item -> RuleCandidate? in
                guard let object = item as? FixtureObject else { return nil }
                return try candidate(object)
            }
        } else {
            candidates = [try (filesystem["candidate"] as? FixtureObject).map(candidate)]
        }
        let walkValues: [String]
        if let list = filesystem["walk"] as? [String] { walkValues = list } else { walkValues = [filesystem["walk"] as? String ?? "none"] }

        let access = ScriptedFileAccess(
            candidates: candidates,
            symlinkAncestor: filesystem["symlinkAncestor"] as? Bool ?? false,
            symlinkError: filesystem["symlinkError"] as? Bool ?? false,
            inspectError: filesystem["inspectError"] as? Bool ?? false,
            walk: walkValues,
            trashError: filesystem["trashError"] as? String
        )
        let failingAuditKinds = Set((input["auditFailsOn"] as? [String] ?? []).compactMap(TrashAuditKind.init(rawValue:)))
        let audit = RecordingAudit(failOn: failingAuditKinds)

        let gateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPruneGolden-\(UUID())")
        defer { try? FileManager.default.removeItem(at: gateDirectory) }
        if input["updatePending"] as? Bool == true {
            try UpdateInstallationGate(directory: gateDirectory).beginInstallation(targetVersion: "2", currentVersion: "1")
        }

        let measurement = (input["measure"] as? FixtureObject).map {
            ItemSizeMeasurement(bytes: Int64($0["bytes"] as? Int ?? 0), items: $0["items"] as? Int ?? 0, truncated: $0["truncated"] as? Bool ?? false)
        }
        let limits = input["walkLimits"] as? FixtureObject
        let coordinator = TrashCoordinator(
            policyStore: ScriptedPolicyStore(entries: snapshotEntries),
            fileAccess: access,
            audit: audit,
            clock: FixedClock(value: now),
            updateGate: UpdateInstallationGate(directory: gateDirectory),
            candidateHydrator: try (input["hydrated"] as? FixtureObject).map { StubHydrator(result: try candidate($0)) },
            descendantWalkLimits: DescendantWalkLimits(
                maxEntries: limits?["maxEntries"] as? Int ?? 250_000,
                maxDuration: limits?["maxSeconds"] as? Double ?? 10
            ),
            sizeMeasurer: { _ in measurement }
        )

        var result: FixtureObject
        do {
            result = encode(try await coordinator.execute(request))
        } catch let error as TrashExecutionError {
            result = encode(error)
        }
        result["calls"] = await access.calls()
        result["audit"] = await audit.events().map { event -> FixtureObject in
            var rendered: FixtureObject = ["kind": event.kind.rawValue, "at": event.occurredAt.timeIntervalSince1970]
            if let id = event.ruleID { rendered["ruleId"] = id.uuidString }
            if let detail = event.detail { rendered["detail"] = detail }
            if let bytes = event.bytes { rendered["bytes"] = bytes }
            if let items = event.itemCount { rendered["itemCount"] = items }
            return rendered
        }
        return result
    }

    static func encode(_ outcome: TrashExecutionOutcome) -> FixtureObject {
        switch outcome {
        case .previewed: return ["outcome": "previewed"]
        case .notDue(let deadline): return ["outcome": "notDue", "deadline": deadline.timeIntervalSince1970]
        case .skipped(let reason): return ["outcome": "skipped", "reason": reason]
        case .deferred(let reason): return ["outcome": "deferred", "reason": reason]
        case .movedToTrash(let original, let trashed): return ["outcome": "movedToTrash", "originalPath": original, "trashedPath": trashed]
        }
    }

    /// Error details wrap platform error text, so only the kind (and the trashed path, which is the one datum a
    /// caller needs to recover a moved item) are part of the contract.
    static func encode(_ error: TrashExecutionError) -> FixtureObject {
        switch error {
        case .policyReadFailed: return ["error": "policyReadFailed"]
        case .filesystemReadFailed: return ["error": "filesystemReadFailed"]
        case .auditWriteFailed: return ["error": "auditWriteFailed"]
        case .filesystemOperationFailed: return ["error": "filesystemOperationFailed"]
        case .movedButAuditFailed(let path, _): return ["error": "movedButAuditFailed", "trashedPath": path]
        case .updateInstallationPending: return ["error": "updateInstallationPending"]
        }
    }
}

private struct ScriptedFailure: Error, CustomStringConvertible {
    let description: String
}

private struct FixedClock: SafetyClock {
    let value: Date
    func now() -> Date { value }
}

private struct StubHydrator: CandidateHydrating {
    let result: RuleCandidate
    func hydrate(_ candidate: RuleCandidate, rules: [LifetimeRule], now: Date) async throws -> RuleCandidate { result }
}

private actor ScriptedPolicyStore: PolicySnapshotProviding {
    private var entries: [PolicySnapshot?]
    init(entries: [PolicySnapshot?]) { self.entries = entries }

    func loadSnapshot() async throws -> PolicySnapshot {
        let entry = entries.count > 1 ? entries.removeFirst() : entries[0]
        guard let entry else { throw ScriptedFailure(description: "policy unavailable") }
        return entry
    }
}

private actor RecordingAudit: TrashAuditRecording {
    private let failOn: Set<TrashAuditKind>
    private var recorded: [TrashAuditEvent] = []
    init(failOn: Set<TrashAuditKind>) { self.failOn = failOn }

    func append(_ event: TrashAuditEvent) async throws {
        if failOn.contains(event.kind) { throw ScriptedFailure(description: "audit unavailable") }
        recorded.append(event)
    }

    func events() -> [TrashAuditEvent] { recorded }
}

private actor ScriptedFileAccess: TrashFileAccess {
    private var candidates: [RuleCandidate?]
    private let symlinkAncestor: Bool
    private let symlinkError: Bool
    private let inspectError: Bool
    private var walk: [String]
    private let trashError: String?
    private var log: [String] = []

    init(candidates: [RuleCandidate?], symlinkAncestor: Bool, symlinkError: Bool, inspectError: Bool, walk: [String], trashError: String?) {
        self.candidates = candidates
        self.symlinkAncestor = symlinkAncestor
        self.symlinkError = symlinkError
        self.inspectError = inspectError
        self.walk = walk
        self.trashError = trashError
    }

    func calls() -> [String] { log }

    func inspect(path: String) async throws -> RuleCandidate? {
        log.append("inspect")
        if inspectError { throw ScriptedFailure(description: "inspect failed") }
        return candidates.count > 1 ? candidates.removeFirst() : candidates[0]
    }

    func hasSymbolicLinkAncestor(of path: String, below rootPath: String) async throws -> Bool {
        log.append("symlinkCheck")
        if symlinkError { throw ScriptedFailure(description: "symlink check failed") }
        return symlinkAncestor
    }

    func hasProtectedDescendant(path: String, overrides: [ItemPolicyOverride], protectHiddenFiles: Bool, budget: DescendantWalkBudget) async throws -> DescendantProtection {
        log.append("walk protectHidden=\(protectHiddenFiles) maxEntries=\(budget.maxEntries) seconds=\(Int(budget.deadline.timeIntervalSince(budget.clock.now())))")
        let value = walk.count > 1 ? walk.removeFirst() : walk[0]
        switch value {
        case "none": return .none
        case "protected": return .protected
        case "indeterminate": return .indeterminate
        default: throw ScriptedFailure(description: "walk failed")
        }
    }

    func moveToTrash(path: String, expectedIdentity: FilesystemIdentity) async throws -> String {
        log.append("move \(path)")
        if let trashError { throw ScriptedFailure(description: trashError) }
        return "/.Trash/\(URL(fileURLWithPath: path).lastPathComponent)"
    }
}
