import Foundation

/// Built-in starting points. Templates only ever produce ordinary, editable `LifetimeRule`s.
public enum RuleTemplate: String, CaseIterable, Codable, Sendable, Identifiable {
    case developerCleanup
    case downloads
    case screenshots
    case temporaryWorkspace
    case buildArtifacts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .developerCleanup: "Developer Cleanup"
        case .downloads: "Downloads"
        case .screenshots: "Screenshots"
        case .temporaryWorkspace: "Temporary Workspace"
        case .buildArtifacts: "Build Artifacts"
        }
    }

    public var summary: String {
        switch self {
        case .developerCleanup: "Dependencies, virtual environments, caches, and build output once a project goes quiet."
        case .downloads: "DMG installers after 7 days, ZIP archives after 14, everything else after 30."
        case .screenshots: "Screenshots 7 days after they are created."
        case .temporaryWorkspace: "Anything placed in the chosen folder expires after a set time."
        case .buildArtifacts: "dist, build, target, coverage, and .cache folders after 30 days of project inactivity."
        }
    }

    /// Developer templates cover a broad tree, so callers should start them in Preview.
    public var isBroad: Bool {
        switch self {
        case .developerCleanup, .buildArtifacts: true
        case .downloads, .screenshots, .temporaryWorkspace: false
        }
    }

    public func rules(in folderPath: String, state: RuleState, temporaryLifetime: TimeInterval = 3 * 86_400) throws -> [LifetimeRule] {
        let scope = try RuleScope(path: folderPath, recursive: true)
        let day: TimeInterval = 86_400

        func rule(_ name: String, kind: ItemKind, names: Set<String> = [], globs: Set<String> = [], basis: ExpiryBasis, days: TimeInterval) throws -> LifetimeRule {
            try LifetimeRule(
                name: name,
                scope: scope,
                matcher: ItemMatcher(itemKind: kind, exactNames: names, globPatterns: globs),
                expiryBasis: basis,
                lifetime: RuleDuration(seconds: days * day),
                action: .trashItem,
                state: state
            )
        }

        switch self {
        case .developerCleanup:
            return [
                try rule("Old node_modules", kind: .directory, names: ["node_modules"], basis: .projectActivity, days: 30),
                try rule("Old Python environments", kind: .directory, names: [".venv", "venv"], basis: .projectActivity, days: 45),
                try rule("Stale Python caches", kind: .directory, names: ["__pycache__", ".pytest_cache"], basis: .modified, days: 7),
                try rule("Stale Next.js cache", kind: .directory, globs: ["**/.next/cache"], basis: .projectActivity, days: 14),
                try rule("Old build output", kind: .directory, names: ["dist", "build", "target"], basis: .projectActivity, days: 30),
            ]
        case .downloads:
            return [
                try rule("Old installers", kind: .file, globs: ["*.dmg"], basis: .firstObserved, days: 7),
                try rule("Old archives", kind: .file, globs: ["*.zip"], basis: .firstObserved, days: 14),
                try rule("Other old downloads", kind: .fileOrDirectory, basis: .firstObserved, days: 30),
            ]
        case .screenshots:
            return [try rule("Old screenshots", kind: .file, globs: ["Screenshot*", "Screen Shot*"], basis: .created, days: 7)]
        case .temporaryWorkspace:
            return [try LifetimeRule(
                name: "Temporary workspace",
                scope: scope,
                matcher: ItemMatcher(itemKind: .fileOrDirectory, exactNames: []),
                expiryBasis: .firstObserved,
                lifetime: RuleDuration(seconds: temporaryLifetime),
                action: .trashItem,
                state: state
            )]
        case .buildArtifacts:
            return [try rule("Old build artifacts", kind: .directory, names: ["dist", "build", "target", "coverage", ".cache"], basis: .projectActivity, days: 30)]
        }
    }
}
