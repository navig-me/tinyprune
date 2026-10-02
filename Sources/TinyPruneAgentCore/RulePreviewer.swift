import Foundation
import TinyPruneDomain
import TinyPruneEngine
import TinyPruneIPC
import TinyPrunePersistence

/// Hard bounds for the explicit rule dry run (ADR 0003).
public struct RulePreviewLimits: Equatable, Sendable {
    public static let defaultMaxEntries = 500_000
    public static let defaultMaxDurationSeconds: TimeInterval = 20
    public static let batchSize = 256
    public static let sampleLimit = 20

    /// Maximum scope entries enumerated before the result is marked truncated.
    public var maxEntries: Int
    /// Wall-clock budget before the result is marked truncated.
    public var maxDurationSeconds: TimeInterval
    /// Shared total entry budget for measuring matched directories.
    public var sizeWalkEntries: Int

    public init(
        maxEntries: Int = RulePreviewLimits.defaultMaxEntries,
        maxDurationSeconds: TimeInterval = RulePreviewLimits.defaultMaxDurationSeconds,
        sizeWalkEntries: Int = ItemSizeMeasurer.defaultMaxEntries
    ) {
        self.maxEntries = maxEntries
        self.maxDurationSeconds = maxDurationSeconds
        self.sizeWalkEntries = sizeWalkEntries
    }
}

/// Limits plus an injectable monotonic time source (seconds) so tests can exhaust the budget without sleeping.
public struct RulePreviewConfiguration: Sendable {
    public var limits: RulePreviewLimits
    public var uptime: @Sendable () -> TimeInterval

    public init(
        limits: RulePreviewLimits = RulePreviewLimits(),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.limits = limits
        self.uptime = uptime
    }
}

public enum RulePreviewError: Error, Equatable, Sendable {
    case invalidRequest(String)
}

/// Read-only, bounded dry run of one rule. It never writes to the database, audit log, xattrs or filesystem,
/// and it never invokes a Trash executor. Evaluation goes through `IndexedCandidateEvaluation`, the same path the
/// indexer uses, with the rule forced into Preview disposition.
///
/// Persisted-state semantics mirror the indexer's scan: observed-activity/first-observed bases use the stored
/// value when present, otherwise "first observed" is `now` (exactly what the indexer would persist on its first
/// sighting). Project-activity basis uses stored project activity only; nothing is recorded.
struct RulePreviewer: Sendable {
    let store: SQLiteSafetyStore
    let fileAccess: LocalTrashFileAccess
    let clock: any SafetyClock
    let configuration: RulePreviewConfiguration

    /// Runs off every actor; cancelling the caller cancels the traversal.
    func run(rule: LifetimeRule, snapshot: PolicySnapshot, access: RootAccessToken) async throws -> AgentRulePreview {
        let task = Task.detached(priority: .utility) {
            defer { withExtendedLifetime(access) {} }
            return try await self.execute(rule: rule, snapshot: snapshot, rootURL: access.url)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func execute(rule requested: LifetimeRule, snapshot: PolicySnapshot, rootURL: URL) async throws -> AgentRulePreview {
        let started = configuration.uptime()
        let limits = RulePreviewLimits(
            maxEntries: min(configuration.limits.maxEntries, RulePreviewLimits.defaultMaxEntries),
            maxDurationSeconds: min(configuration.limits.maxDurationSeconds, RulePreviewLimits.defaultMaxDurationSeconds),
            sizeWalkEntries: min(configuration.limits.sizeWalkEntries, ItemSizeMeasurer.defaultMaxEntries)
        )
        let now = clock.now()
        let rule: LifetimeRule
        do {
            rule = try LifetimeRule(
                id: requested.id,
                name: requested.name,
                scope: requested.scope,
                matcher: requested.matcher,
                expiryBasis: requested.expiryBasis,
                lifetime: requested.lifetime,
                gracePeriod: requested.gracePeriod,
                action: requested.action,
                state: .preview,
                matchMode: requested.matchMode
            )
        } catch {
            throw RulePreviewError.invalidRequest("The rule is not valid: \(error)")
        }
        let rules = snapshot.rules.filter { $0.id != rule.id } + [rule]

        let scopePath = rule.scope.path
        // Reject symlinked ancestors as well as a symlink at the scope itself. Lexical root containment alone
        // would otherwise allow a scope such as managed/link/to/an/outside/folder.
        var checkedURL = rootURL.standardizedFileURL
        let rootPath = checkedURL.path
        guard scopePath == rootPath || scopePath.hasPrefix(rootPath + "/") else {
            throw RulePreviewError.invalidRequest("The rule's folder must be inside an available managed folder.")
        }
        let components = scopePath == rootPath ? [] : scopePath.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
        for component in [""] + components {
            try Task.checkCancellation()
            if !component.isEmpty { checkedURL.appendPathComponent(component) }
            if (try? checkedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw RulePreviewError.invalidRequest("The rule's folder contains a symbolic link, which TinyPrune does not follow.")
            }
        }
        let scopeValues = try? URL(fileURLWithPath: scopePath).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard let scopeValues else {
            throw RulePreviewError.invalidRequest("The rule's folder does not exist.")
        }
        guard scopeValues.isSymbolicLink != true else {
            throw RulePreviewError.invalidRequest("The rule's folder is a symbolic link, which TinyPrune does not follow.")
        }
        let isDirectory = scopeValues.isDirectory == true
        let enumeratesChildren: Bool
        switch rule.matchMode {
        case .scoped, .template:
            guard isDirectory else { throw RulePreviewError.invalidRequest("The rule's scope must be a folder.") }
            enumeratesChildren = true
        case .exactPath, .itemSpecific:
            enumeratesChildren = false
        }

        var tally = Tally()
        func finish() -> AgentRulePreview {
            AgentRulePreview(
                matches: tally.matches,
                eligibleNow: tally.eligibleNow,
                estimatedBytes: tally.bytes,
                scannedEntries: tally.scanned,
                truncated: tally.truncated,
                durationSeconds: max(0, configuration.uptime() - started),
                samples: tally.samples
            )
        }
        try Task.checkCancellation()
        if limits.maxEntries <= 0 || configuration.uptime() - started >= limits.maxDurationSeconds {
            tally.truncated = true
            return finish()
        }

        guard enumeratesChildren else {
            tally.scanned = 1
            try await evaluate(URL(fileURLWithPath: scopePath), rule: rule, rules: rules, snapshot: snapshot, now: now, limits: limits, started: started, tally: &tally)
            return finish()
        }

        let recursive = rule.scope.recursive
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: scopePath, isDirectory: true),
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw RulePreviewError.invalidRequest("The rule's folder cannot be read.")
        }

        var exhausted = false
        while !exhausted {
            var batch: [URL] = []
            batch.reserveCapacity(RulePreviewLimits.batchSize)
            while batch.count < RulePreviewLimits.batchSize {
                try Task.checkCancellation()
                if tally.scanned >= limits.maxEntries || configuration.uptime() - started >= limits.maxDurationSeconds {
                    tally.truncated = true
                    exhausted = true
                    break
                }
                guard let child = enumerator.nextObject() as? URL else {
                    exhausted = true
                    break
                }
                tally.scanned += 1
                let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                // Foundation enumerators do not descend into symlinks. skipDescendants is only valid for an
                // actual directory; calling it on a link/file can skip an unrelated next directory.
                if values?.isSymbolicLink == true { continue }
                if !recursive && values?.isDirectory == true { enumerator.skipDescendants() }
                batch.append(child)
            }
            for child in batch {
                try Task.checkCancellation()
                if configuration.uptime() - started >= limits.maxDurationSeconds {
                    tally.truncated = true
                    exhausted = true
                    break
                }
                try await evaluate(child, rule: rule, rules: rules, snapshot: snapshot, now: now, limits: limits, started: started, tally: &tally)
            }
        }
        return finish()
    }

    private func evaluate(
        _ url: URL,
        rule: LifetimeRule,
        rules: [LifetimeRule],
        snapshot: PolicySnapshot,
        now: Date,
        limits: RulePreviewLimits,
        started: TimeInterval,
        tally: inout Tally
    ) async throws {
        // Unreadable, vanished or symlinked entries are skipped, never fatal to a dry run.
        guard let candidate = try? await fileAccess.inspect(path: url.path) else { return }
        let evaluated = try await IndexedCandidateEvaluation.hydrate(candidate, rules: rules, store: store, now: now)
        guard case .scheduled(let explanation) = IndexedCandidateEvaluation.resolve(evaluated, rules: rules, snapshot: snapshot),
              explanation.matchedRuleID == rule.id else { return }

        tally.matches += 1
        if explanation.scheduledAt <= now { tally.eligibleNow += 1 }

        var itemBytes: Int64?
        let path = candidate.identity.pathHint
        if let covered = tally.coveredDirectory, path.hasPrefix(covered + "/") {
            // Already counted inside a matched ancestor folder; never double count.
        } else if candidate.kind == .directory {
            let remaining = limits.sizeWalkEntries - tally.sizeWalkUsed
            if remaining > 0, let measurement = ItemSizeMeasurer.measure(
                path: path, maxEntries: remaining,
                shouldStop: { configuration.uptime() - started >= limits.maxDurationSeconds }
            ) {
                try Task.checkCancellation()
                tally.sizeWalkUsed += measurement.items
                tally.bytes += measurement.bytes
                if measurement.truncated { tally.truncated = true }
                itemBytes = measurement.bytes
                tally.coveredDirectory = path
            } else {
                tally.truncated = true
            }
        } else if let measurement = ItemSizeMeasurer.measure(path: path, maxEntries: 1) {
            tally.bytes += measurement.bytes
            itemBytes = measurement.bytes
        }

        let sample = AgentPreviewSample(path: path, scheduledAt: explanation.scheduledAt, bytes: itemBytes)
        if tally.samples.count < RulePreviewLimits.sampleLimit || Self.precedes(sample, tally.samples[tally.samples.count - 1]) {
            tally.samples.append(sample)
            tally.samples.sort(by: Self.precedes)
            if tally.samples.count > RulePreviewLimits.sampleLimit { tally.samples.removeLast() }
        }
    }

    private static func precedes(_ lhs: AgentPreviewSample, _ rhs: AgentPreviewSample) -> Bool {
        lhs.scheduledAt != rhs.scheduledAt ? lhs.scheduledAt < rhs.scheduledAt : lhs.path < rhs.path
    }

    private struct Tally {
        var scanned = 0
        var matches = 0
        var eligibleNow = 0
        var bytes: Int64 = 0
        var sizeWalkUsed = 0
        var truncated = false
        var coveredDirectory: String?
        var samples: [AgentPreviewSample] = []
    }
}
