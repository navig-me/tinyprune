import AppKit
import Foundation
import TinyPruneIPC
import TinyPruneUI

/// Tells the user a newer release exists when Sparkle cannot install it (unsigned previews, Homebrew copies,
/// development builds). It only ever opens a link or copies a command; it never downloads or installs.
///
/// Network use is deliberate and narrow: one HTTPS GET of the public release list on github.com, either when the
/// user chooses "Check for Updates…" or, only if they opted in, at most once a day. No identifiers are sent.
@MainActor
final class ReleaseNotifier {
    private static let automaticKey = "checkForNewVersions"
    private static let lastCheckKey = "lastReleaseCheck"
    private static let skippedKey = "skippedReleaseVersion"
    private static let interval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersion: String
    private let isHomebrew: Bool
    private weak var model: AgentViewModel?
    private var automaticTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        let bundle = Bundle.main
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        isHomebrew = bundle.object(forInfoDictionaryKey: "TinyPruneDistribution") as? String == "homebrew"
    }

    func bind(to model: AgentViewModel) { self.model = model }

    /// Starts the opt-in daily check. The setting is read each time, so turning it off takes effect immediately.
    func startAutomaticChecks() {
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.defaults.bool(forKey: Self.automaticKey), self.isDue() {
                    await self.check(manual: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func isDue() -> Bool {
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= Self.interval
    }

    /// A manual check always answers: an update, "up to date", or the reason it could not check.
    func checkManually() {
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        defaults.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: ReleaseFeed.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TinyPrune/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            if let release = ReleaseFeed.newestRelease(from: data, newerThan: currentVersion) {
                if manual || defaults.string(forKey: Self.skippedKey) != release.version {
                    present(release)
                }
            } else if manual {
                alert("TinyPrune is up to date", "You have the latest published version (\(currentVersion)).")
            }
        } catch {
            if manual {
                alert("Could not check for updates", "TinyPrune could not reach github.com (\(error.localizedDescription)). Your rules and files are unaffected; try again later or see the Releases page.")
            }
        }
    }

    private func present(_ release: AvailableRelease) {
        guard let model else { return }
        let notes = UpdateNotice.Action(title: "Release Notes") { NSWorkspace.shared.open(release.releasePage) }
        let primary: UpdateNotice.Action
        let message: String
        if isHomebrew {
            primary = .init(title: "Copy Upgrade Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ReleaseFeed.homebrewUpgradeCommand, forType: .string)
            }
            message = "Run \(ReleaseFeed.homebrewUpgradeCommand) in Terminal to update this Homebrew copy."
        } else if let download = release.downloadURL {
            primary = .init(title: "Download") { NSWorkspace.shared.open(download) }
            message = "Download the disk image, quit TinyPrune, then drag the new TinyPrune into Applications. Your rules and settings are kept. You are on \(currentVersion)."
        } else {
            primary = notes
            message = "Open the release page to download it. You are on \(currentVersion)."
        }
        model.updateNotice = UpdateNotice(
            version: release.version,
            message: message,
            primary: primary,
            secondary: primary.title == notes.title ? nil : notes,
            skipVersion: { [defaults] in defaults.set(release.version, forKey: Self.skippedKey) },
            remindLater: {}
        )
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
