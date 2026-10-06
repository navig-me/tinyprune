import Foundation

/// Built-in starting points. Templates only ever produce ordinary, editable `LifetimeRule`s.
public enum RuleTemplate: String, CaseIterable, Codable, Sendable, Identifiable {
    case developerCleanup
    case downloads
    case screenshots
    case temporaryWorkspace
    case buildArtifacts
    case xcodeDerivedData
    case xcodeDeviceSupport
    case homebrewDownloads
    case npmCache
    case yarnClassicCache
    case pipCache
    case cargoRegistryCache
    case gradleCaches

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .developerCleanup: "Developer Cleanup"
        case .downloads: "Downloads"
        case .screenshots: "Screenshots"
        case .temporaryWorkspace: "Temporary Workspace"
        case .buildArtifacts: "Build Artifacts"
        case .xcodeDerivedData: "Xcode Derived Data"
        case .xcodeDeviceSupport: "Xcode Device Support"
        case .homebrewDownloads: "Homebrew Downloads"
        case .npmCache: "npm Cache"
        case .yarnClassicCache: "Yarn Classic Cache"
        case .pipCache: "pip Cache"
        case .cargoRegistryCache: "Cargo Registry Cache"
        case .gradleCaches: "Gradle Caches"
        }
    }

    public var summary: String {
        switch self {
        case .developerCleanup: "Dependencies, virtual environments, caches, and build output once a project goes quiet."
        case .downloads: "DMG installers after 7 days, ZIP archives after 14, everything else after 30."
        case .screenshots: "Screenshots 7 days after they are created."
        case .temporaryWorkspace: "Anything placed in the chosen folder expires after a set time."
        case .buildArtifacts: "dist, build, target, coverage, and .cache folders after 30 days of project inactivity."
        case .xcodeDerivedData: "Generated project folders after 60 days without modification; Xcode rebuilds them."
        case .xcodeDeviceSupport: "Device symbol folders after 180 days without modification; reconnect the matching device to restore them."
        case .homebrewDownloads: "Completed package downloads after 90 days without modification; Homebrew downloads them again."
        case .npmCache: "Package cache files after 90 days without modification; npm fetches missing packages again."
        case .yarnClassicCache: "Yarn 1 package caches after 90 days without modification; excludes project-local Yarn caches."
        case .pipCache: "HTTP and wheel cache files after 90 days without modification; pip downloads or rebuilds them."
        case .cargoRegistryCache: "Downloaded .crate archives after 90 days without modification; leaves sources, credentials, and tools alone."
        case .gradleCaches: "Generated and downloaded cache files after 90 days without modification; leaves Gradle settings and wrappers alone."
        }
    }

    /// Home-relative suggestion only; users must choose and authorize the actual folder.
    public var suggestedFolder: String? {
        switch self {
        case .xcodeDerivedData: "~/Library/Developer/Xcode/DerivedData"
        case .xcodeDeviceSupport: "~/Library/Developer/Xcode/iOS DeviceSupport"
        case .homebrewDownloads: "~/Library/Caches/Homebrew/downloads"
        case .npmCache: "~/.npm/_cacache"
        case .yarnClassicCache: "~/Library/Caches/Yarn"
        case .pipCache: "~/Library/Caches/pip"
        case .cargoRegistryCache: "~/.cargo/registry/cache"
        case .gradleCaches: "~/.gradle/caches"
        default: nil
        }
    }

    /// Developer and app-cache templates must start in Preview.
    public var isBroad: Bool {
        switch self {
        case .developerCleanup, .buildArtifacts, .xcodeDerivedData, .xcodeDeviceSupport,
             .homebrewDownloads, .npmCache, .yarnClassicCache, .pipCache,
             .cargoRegistryCache, .gradleCaches: true
        case .downloads, .screenshots, .temporaryWorkspace: false
        }
    }

    public func rules(in folderPath: String, state: RuleState, temporaryLifetime: TimeInterval = 3 * 86_400) throws -> [LifetimeRule] {
        let scope = try RuleScope(path: folderPath, recursive: self != .xcodeDerivedData && self != .xcodeDeviceSupport)
        let initialState: RuleState = isBroad && state == .active ? .preview : state
        let day: TimeInterval = 86_400

        func rule(_ name: String, kind: ItemKind, names: Set<String> = [], globs: Set<String> = [], basis: ExpiryBasis, days: TimeInterval) throws -> LifetimeRule {
            try LifetimeRule(
                name: name,
                scope: scope,
                matcher: ItemMatcher(itemKind: kind, exactNames: names, globPatterns: globs),
                expiryBasis: basis,
                lifetime: RuleDuration(seconds: days * day),
                action: .trashItem,
                state: initialState
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
        case .xcodeDerivedData:
            return [try rule("Old Xcode derived data", kind: .directory, basis: .modified, days: 60)]
        case .xcodeDeviceSupport:
            return [try rule("Old iOS device symbols", kind: .directory, basis: .modified, days: 180)]
        case .homebrewDownloads:
            return [try rule("Old completed Homebrew downloads", kind: .file, globs: ["*--*.tar.gz", "*--*.tar.xz", "*--*.tar.bz2", "*--*.zip", "*--*.dmg", "*--*.pkg"], basis: .modified, days: 90)]
        case .npmCache:
            return [try rule("Old npm cache files", kind: .file, basis: .modified, days: 90)]
        case .yarnClassicCache:
            return [try rule("Old Yarn Classic cache files", kind: .file, basis: .modified, days: 90)]
        case .pipCache:
            return [try rule("Old pip cache files", kind: .file, basis: .modified, days: 90)]
        case .cargoRegistryCache:
            return [try rule("Old downloaded crates", kind: .file, globs: ["**/*.crate"], basis: .modified, days: 90)]
        case .gradleCaches:
            return [try rule("Old Gradle cache files", kind: .file, basis: .modified, days: 90)]
        }
    }
}
