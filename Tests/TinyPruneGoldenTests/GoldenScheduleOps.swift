import Foundation
import TinyPruneDomain
import TinyPruneEngine
import TinyPrunePersistence

extension GoldenOps {
    // These are scripted metadata decisions, not a test of SQLite or FSEvents transport.
    // Hydration, project aggregation, observation persistence and resolution call the Swift reference APIs.
    static func scheduleScan(_ input: FixtureObject) async throws -> FixtureObject {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPrune-Golden-Schedule-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.sqlite3")
        var store = try SQLiteSafetyStore(databaseURL: database)
        let root = RuleScope.normalized(input["root"] as? String ?? "/Develop")
        let rules = try (input["rules"] as? [FixtureObject] ?? []).map(rule)
        let overrides = try (input["overrides"] as? [FixtureObject] ?? []).map(override)
        let settings = try settings(input["settings"] as? FixtureObject)
        var known: [FilesystemIdentity] = []
        for record in input["observations"] as? [FixtureObject] ?? [] {
            let id = try identity(record)
            guard let first = date(record["first"]), let last = date(record["last"]) else {
                throw FixtureFormatError(description: "observation requires first and last")
            }
            known.append(id)
            try await store.recordInitialObservations([PersistedObservedActivity(identity: id,
                firstObservedAt: first, lastObservedAt: last)])
        }
        let steps = input["steps"] as? [FixtureObject] ?? [input]
        var results: [FixtureObject] = []
        for step in steps {
            if step["restart"] as? Bool == true { store = try SQLiteSafetyStore(databaseURL: database) }
            guard let now = date(step["now"] ?? input["now"]) else { throw FixtureFormatError(description: "schedule requires now") }
            let tree = try (step["tree"] as? [FixtureObject] ?? []).map(candidate)
            let events = step["events"] as? [FixtureObject] ?? []
            let tracks = rules.contains { $0.expiryBasis == .projectActivity && $0.state != .paused &&
                ($0.matchMode == .template || scheduleWithin($0.scope.path, root) || scheduleWithin(root, $0.scope.path)) }
            if tracks {
                let scan = try await store.beginProjectActivityScan()
                var projects: [PersistedProjectActivity] = []
                var sources: [ProjectActivityObservation] = []
                for item in tree {
                    let path = item.identity.pathHint
                    let parent = (path as NSString).deletingLastPathComponent
                    if scheduleMarkers.contains(item.name), !scheduleIgnored(parent, root),
                       let directory = tree.first(where: { $0.identity.pathHint == parent && $0.kind == .directory }) {
                        let old = try await store.observedActivity(for: item.identity)
                        let basis = scheduleMeaningful(path, root) ? item.timestamps.modified ?? now : item.timestamps.created ?? old?.firstObservedAt ?? now
                        projects.append(PersistedProjectActivity(identity: directory.identity, lastActivityAt: basis))
                        try await store.recordInitialObservations([PersistedObservedActivity(identity: item.identity, firstObservedAt: old?.firstObservedAt ?? now, lastObservedAt: old?.lastObservedAt ?? now)])
                        known.append(item.identity)
                    }
                    if item.kind == .file, scheduleMeaningful(path, root), let modified = item.timestamps.modified {
                        sources.append(ProjectActivityObservation(path: path, modifiedAt: modified))
                    }
                }
                try await store.recordProjectActivities(projects, scanID: scan)
                try await store.recordProjectObservations(sources, scanID: scan)
                try await store.finishProjectActivityScan(scanID: scan, atOrBelow: root)
                for event in events {
                    let path = try string(event, "path")
                    if scheduleMeaningful(path, root) { _ = try await store.recordProjectActivity(at: path, date: date(event["at"]) ?? now) }
                }
            }
            var items: [FixtureObject] = []
            for item in tree {
                var supplied: PersistedObservedActivity?
                if IndexedCandidateEvaluation.usesObservedActivity(item, rules: rules) {
                    let eventDates = try events.filter { try string($0, "path") == item.identity.pathHint }.map { date($0["at"]) ?? now }
                    if let event = eventDates.max() {
                        try await store.recordObservedActivity(identity: item.identity, at: event)
                    } else if let old = try await store.observedActivity(for: item.identity) {
                        if let modified = item.timestamps.modified, modified > old.lastObservedAt {
                            try await store.reconcileObservedActivity(identity: item.identity, through: modified)
                        }
                        // Critical: refresh the hint before removing the renamed old subtree.
                        try await store.recordInitialObservations([PersistedObservedActivity(identity: item.identity, firstObservedAt: old.firstObservedAt, lastObservedAt: old.lastObservedAt)])
                    } else {
                        try await store.recordInitialObservations([PersistedObservedActivity(identity: item.identity, firstObservedAt: now, lastObservedAt: now)])
                    }
                    supplied = try await store.observedActivity(for: item.identity)
                    known.append(item.identity)
                }
                let hydrated = try await IndexedCandidateEvaluation.hydrate(item, rules: rules, store: store, now: now, suppliedActivity: supplied)
                let resolution = RuleResolver.resolve(candidate: hydrated, rules: rules, overrides: overrides, globallyPaused: false, settings: settings)
                let protected = item.kind == .directory && tree.contains { child in
                    child.identity.pathHint != item.identity.pathHint && scheduleWithin(child.identity.pathHint, item.identity.pathHint) &&
                    (overrides.contains { RuleResolver.keepProtectsDescendant(of: item.identity.pathHint, override: $0, childIdentity: child.identity, childPath: child.identity.pathHint) } || (settings.protectHiddenFiles && child.name.hasPrefix(".")))
                }
                items.append(["path": item.identity.pathHint, "resolution": encode(resolution), "protectedDescendant": protected])
            }
            for path in step["removed"] as? [String] ?? [] { try await store.removeObservedActivity(atOrBelow: path); try await store.removeProjectActivity(atOrBelow: path) }
            var observations: [FixtureObject] = []
            var seen = Set<FilesystemIdentity>()
            for id in known where seen.insert(id).inserted {
                if let record = try await store.observedActivity(for: id) {
                    observations.append(["path": record.identity.pathHint, "resource": record.identity.resourceIdentifier.map { String(format: "%02x", $0) }.joined(), "first": record.firstObservedAt.timeIntervalSince1970, "last": record.lastObservedAt.timeIntervalSince1970])
                }
            }
            observations.sort { ($0["path"] as! String, $0["resource"] as! String) < ($1["path"] as! String, $1["resource"] as! String) }
            results.append(["items": items, "observations": observations])
        }
        return ["steps": results]
    }
    private static let scheduleMarkers: Set<String> = [".git", "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod", "Gemfile", "pom.xml", "build.gradle", "composer.json"]
    private static let scheduleNoise: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".cache", "dist", "build", "target"]
    private static func scheduleWithin(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    private static func scheduleIgnored(_ path: String, _ root: String) -> Bool {
        let relative = scheduleWithin(path, root) ? String(path.dropFirst(root.count)) : path
        let parts = relative.split(separator: "/").map(String.init)
        return parts.contains { scheduleNoise.contains($0) } || zip(parts, parts.dropFirst()).contains { $0 == ".next" && $1 == "cache" }
    }
    private static func scheduleMeaningful(_ path: String, _ root: String) -> Bool {
        !scheduleIgnored(path, root) && !(path as NSString).lastPathComponent.lowercased().hasSuffix(".log")
    }
}
