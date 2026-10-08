import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI
import TinyPruneIPC
import TinyPruneUI

/// Only the application owns Sparkle. The agent's cross-process gate guards every Trash execution.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availabilityReason: String?
    @Published private(set) var safetyStatus: String?
    @Published private(set) var availableUpdateVersion: String?
    private var controller: SPUStandardUpdaterController?
    private let gate = UpdateInstallationGate()
    private var holdsInstallationGate = false
    private var installationScheduled = false
    private var retainsDownloadedUpdate = false
    private var releaseNeedsRetry = false
    private var cancellables = Set<AnyCancellable>()
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    /// Homebrew and builds without a valid feed key offer a manual-download notice instead.
    private var usesReleaseNotifier = false
    private let releases = ReleaseNotifier()

    override init() {
        super.init()
        defer { reconcileHaltStatus() }
        let bundle = Bundle.main
        let isDirect = bundle.object(forInfoDictionaryKey: "TinyPruneDistribution") as? String == "direct"
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let updatesEnabled = isDirect
            && bundle.object(forInfoDictionaryKey: "TinyPruneUpdatesEnabled") as? Bool == true
            && Data(base64Encoded: key)?.count == 32
        guard updatesEnabled else {
            usesReleaseNotifier = true
            availabilityReason = bundle.object(forInfoDictionaryKey: "TinyPruneDistribution") as? String == "homebrew"
                ? "This copy is managed by Homebrew. Update with brew upgrade --cask tinyprune. In-app checks and installations are disabled."
                : "This copy has no valid update verification public key or its update channel is disabled. Download a newer release manually."
            return
        }
        do {
            _ = try gate.recoverCompletedInstallation(currentVersion: currentVersion) {
                // Reconcile the bundled executable only if the user already enabled this agent.
                // The exclusive gate and durable marker remain intact until both calls succeed.
                let service = SMAppService.agent(plistName: "com.navig-me.tinyprune.agent.plist")
                if service.status == .enabled {
                    try service.unregister()
                    try service.register()
                }
            }
        } catch UpdateInstallationError.recoveryRequired {
            do {
                holdsInstallationGate = try gate.resumePendingInstallation(currentVersion: currentVersion)
                retainsDownloadedUpdate = holdsInstallationGate
                safetyStatus = "Pruning is stopped while a pending update is resumed. Check for Updates to finish it. If it cannot resume, manually install the intended newer release and launch that version; launching this old version alone will not resume pruning."
            } catch {
                availabilityReason = "The pending update could not be resumed safely: \(error.localizedDescription) Manually finish installing its intended newer release, then launch that version."
                return
            }
        } catch {
            availabilityReason = "Update safety coordination is unavailable: \(error.localizedDescription) If an update was interrupted, manually finish installing its intended newer release, then launch that version. The old version cannot resume pruning."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        synchronizeAutomaticChecks()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronizeAutomaticChecks() }
            }
            .store(in: &cancellables)
        do { try controller.updater.start() }
        catch { availabilityReason = "The updater could not start: \(error.localizedDescription)" }
    }

    func showSafetyStatus() {
        let alert = NSAlert()
        alert.messageText = "Update safety"
        alert.informativeText = safetyStatus ?? "No update is currently blocking pruning."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    var usesGitHubReleaseCheck: Bool { usesReleaseNotifier }

    func checkForUpdates() {
        if usesReleaseNotifier {
            if let availabilityReason {
                let alert = NSAlert()
                alert.messageText = "In-app installation unavailable"
                alert.informativeText = availabilityReason + "\n\nYou can still check GitHub for a release to install manually."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            releases.checkManually()
        } else if let availabilityReason {
            let alert = NSAlert()
            alert.messageText = "Updates unavailable"
            alert.informativeText = availabilityReason
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            controller?.checkForUpdates(nil)
        }
    }

    private func synchronizeAutomaticChecks() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "checkForNewVersions") == nil
            || defaults.bool(forKey: "checkForNewVersions")
        if controller?.updater.automaticallyChecksForUpdates != enabled {
            controller?.updater.automaticallyChecksForUpdates = enabled
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdateVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let availabilityReason {
            throw NSError(domain: "TinyPruneUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: availabilityReason])
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        // This abortable callback precedes download/extraction/installation. A relaunch callback alone
        // misses install-on-quit. The durable marker keeps the agent inhibited after this app exits.
        if updateItem.isInformationOnlyUpdate { return }
        try gate.beginInstallation(targetVersion: updateItem.versionString, currentVersion: currentVersion)
        holdsInstallationGate = true
        safetyStatus = "Pruning is stopped while this update is offered, downloaded, or installed. Dismiss or skip before downloading to resume pruning; after downloading, finish or skip the pending update. The installation interlock survives app termination."
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        retainsDownloadedUpdate = true
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if state.stage == .installing {
            installationScheduled = true
        } else if choice == .skip {
            // Sparkle clears any retained download before completing this cycle.
            retainsDownloadedUpdate = false
            availableUpdateVersion = nil
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationScheduled = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installationScheduled = true
        return false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // A successful cycle may leave an update scheduled for installation on quit.
        // Never remove that marker merely because Sparkle's check cycle finished.
        guard !installationScheduled && !retainsDownloadedUpdate else { return }
        releaseGate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Sparkle resumes downloaded updates without calling shouldProceedWithUpdate again.
        // A post-download error therefore must not reopen Trash while a resumable install exists.
        if installationScheduled || retainsDownloadedUpdate {
            safetyStatus = "The update did not finish. Pruning remains stopped for safety. Try Check for Updates to resume it, or finish installing the intended newer release manually and launch it. \(error.localizedDescription)"
        } else {
            releaseGate()
        }
    }

    private func releaseGate() {
        guard holdsInstallationGate else { return }
        do {
            try gate.finishInstallation()
            holdsInstallationGate = false
            installationScheduled = false
            retainsDownloadedUpdate = false
            releaseNeedsRetry = false
            safetyStatus = nil
            reconcileHaltStatus()
        } catch {
            // Never leave pruning stopped without telling anyone, and never give up: retry whenever the app is activated.
            releaseNeedsRetry = true
            safetyStatus = "Pruning remains stopped because update safety coordination could not finish: \(error.localizedDescription) TinyPrune will retry when you return to the app. If this persists, quit and reopen TinyPrune."
        }
    }

    /// Retries a release that failed earlier. Safe to call at any time.
    private func retryPendingRelease() {
        guard releaseNeedsRetry, !installationScheduled, !retainsDownloadedUpdate else { return }
        releaseGate()
    }

    /// The durable marker is the truth: if it still exists while this process is not mid-update, pruning is stopped and
    /// the UI must say so; if it is gone, any stale notice is cleared.
    private func reconcileHaltStatus() {
        guard !holdsInstallationGate else { return }
        do {
            if try gate.hasPendingInstallation() {
                if safetyStatus == nil {
                    safetyStatus = "Pruning is stopped because an app update was started and not finished. Check for Updates to resume it, or manually install the intended newer release and launch that version."
                }
            } else if safetyStatus != nil {
                safetyStatus = nil
            }
        } catch {
            safetyStatus = "Update safety status could not be read: \(error.localizedDescription)"
        }
    }

    /// Publishes the halt state to the app model (Overview headline, header pill, menu bar) and keeps it current.
    func bind(to model: AgentViewModel) {
        releases.bind(to: model)
        if usesReleaseNotifier { releases.startAutomaticChecks() }
        $safetyStatus
            .removeDuplicates()
            .sink { [weak self, weak model] status in
                MainActor.assumeIsolated {
                    guard let model else { return }
                    model.pruningHaltedReason = status
                    model.pruningHaltResolution = status.map { _ in
                        PruningHaltResolution(title: "Review Update…") { [weak self] in self?.reviewPendingUpdate() }
                    }
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retryPendingRelease()
                    self?.reconcileHaltStatus()
                }
            }
            .store(in: &cancellables)
    }

    private func reviewPendingUpdate() {
        if availabilityReason == nil, controller != nil { controller?.checkForUpdates(nil) } else { showSafetyStatus() }
    }

}

struct UpdateCommand: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(updater.availabilityReason == nil && !updater.canCheckForUpdates)
            .help(updater.availabilityReason ?? "Check the EdDSA-verified direct-download update feed")
        if let version = updater.availableUpdateVersion {
            Button("Update Now — TinyPrune \(version)") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        if updater.safetyStatus != nil {
            Button("Update Safety Status…") { updater.showSafetyStatus() }
        }
    }
}
