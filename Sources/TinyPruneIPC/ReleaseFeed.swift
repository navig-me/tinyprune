import Foundation

/// A dotted numeric version such as `0.1.1`. A leading `v` and any `-suffix` / `+build` are ignored.
public struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<cut]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0, value < 1_000_000 else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A newer published release, with only links on the project's own GitHub repository.
public struct AvailableRelease: Equatable, Sendable {
    public let version: String
    public let releasePage: URL
    /// The direct-download disk image, when the release has one.
    public let downloadURL: URL?
    public let isPrerelease: Bool

    public init(version: String, releasePage: URL, downloadURL: URL?, isPrerelease: Bool) {
        self.version = version
        self.releasePage = releasePage
        self.downloadURL = downloadURL
        self.isPrerelease = isPrerelease
    }
}

/// Reads the public GitHub releases list. Network access lives in the app; this type only parses and decides,
/// so it is deterministic and testable.
public enum ReleaseFeed {
    public static let endpoint = URL(string: "https://api.github.com/repos/navig-me/tinyprune/releases?per_page=10")!
    public static let repositoryPathPrefix = "/navig-me/tinyprune/"

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let assets: [Asset]
    }

    /// Only https links on github.com inside this repository are ever offered to the user.
    static func trustedURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.path.hasPrefix(repositoryPathPrefix), url.user == nil, url.port == nil else { return nil }
        return url
    }

    /// The highest non-draft release that is strictly newer than `currentVersion`, or nil.
    /// Prereleases are included: every TinyPrune release so far is one.
    public static func newestRelease(from data: Data, newerThan currentVersion: String) -> AvailableRelease? {
        guard let current = ReleaseVersion(currentVersion),
              let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        var best: (version: ReleaseVersion, release: Release)?
        for release in releases where !release.draft {
            guard let version = ReleaseVersion(release.tag_name), version > current else { continue }
            if best == nil || version > best!.version { best = (version, release) }
        }
        guard let best, let page = trustedURL(best.release.html_url) else { return nil }
        let expectedName = "TinyPrune-\(best.version).dmg"
        let download = best.release.assets
            .first { $0.name == expectedName }
            .flatMap { trustedURL($0.browser_download_url) }
        return AvailableRelease(version: best.version.description, releasePage: page, downloadURL: download, isPrerelease: best.release.prerelease)
    }

    public static let homebrewUpgradeCommand = "brew upgrade --cask tinyprune"
}
