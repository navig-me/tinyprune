import Foundation
import Testing
@testable import TinyPruneIPC

@Suite struct ReleaseFeedTests {
    private func feed(_ releases: [(tag: String, draft: Bool, pre: Bool, url: String, assets: [(String, String)])]) -> Data {
        let items = releases.map { release -> [String: Any] in
            [
                "tag_name": release.tag, "draft": release.draft, "prerelease": release.pre, "html_url": release.url,
                "assets": release.assets.map { ["name": $0.0, "browser_download_url": $0.1] },
            ]
        }
        return try! JSONSerialization.data(withJSONObject: items)
    }

    private let repo = "https://github.com/navig-me/tinyprune"

    @Test func comparesNumericallyNotLexically() {
        #expect(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!)
        #expect(ReleaseVersion("v1.0")! == ReleaseVersion("1.0.0")!)
        #expect(ReleaseVersion("0.1.1-beta.2")! == ReleaseVersion("0.1.1")!)
        #expect(ReleaseVersion("latest") == nil)
        #expect(ReleaseVersion("1..2") == nil)
    }

    @Test func offersNewestNonDraftAndDirectDiskImage() throws {
        let data = feed([
            ("v0.1.1", false, true, "\(repo)/releases/tag/v0.1.1", [("TinyPrune-0.1.1.dmg", "\(repo)/releases/download/v0.1.1/TinyPrune-0.1.1.dmg"), ("TinyPrune-0.1.1-homebrew.dmg", "\(repo)/releases/download/v0.1.1/TinyPrune-0.1.1-homebrew.dmg")]),
            ("v0.2.0", true, false, "\(repo)/releases/tag/v0.2.0", []),
            ("v0.1.0", false, true, "\(repo)/releases/tag/v0.1.0", []),
        ])
        let release = try #require(ReleaseFeed.newestRelease(from: data, newerThan: "0.1.0"))
        #expect(release.version == "0.1.1")
        #expect(release.downloadURL?.lastPathComponent == "TinyPrune-0.1.1.dmg")
        #expect(ReleaseFeed.newestRelease(from: data, newerThan: "0.1.1") == nil)
    }

    @Test func neverOffersLinksOutsideTheRepository() throws {
        let data = feed([
            ("v0.3.0", false, false, "https://evil.example/navig-me/tinyprune/releases/tag/v0.3.0", []),
        ])
        #expect(ReleaseFeed.newestRelease(from: data, newerThan: "0.1.0") == nil)
        let mixed = feed([
            ("v0.3.0", false, false, "\(repo)/releases/tag/v0.3.0", [("TinyPrune-0.3.0.dmg", "https://evil.example/TinyPrune-0.3.0.dmg")]),
        ])
        let release = try #require(ReleaseFeed.newestRelease(from: mixed, newerThan: "0.1.0"))
        #expect(release.downloadURL == nil)
        #expect(release.releasePage.host == "github.com")
    }

    @Test func malformedFeedOrVersionYieldsNoUpdate() {
        #expect(ReleaseFeed.newestRelease(from: Data("not json".utf8), newerThan: "0.1.0") == nil)
        #expect(ReleaseFeed.newestRelease(from: feed([]), newerThan: "garbage") == nil)
    }
}
