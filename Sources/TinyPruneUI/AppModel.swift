import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import TinyPruneDomain
import TinyPruneIPC

package enum PrunePalette {
    package static let plum = adaptive(light: (0.29, 0.12, 0.24), dark: (0.91, 0.70, 0.83))
    package static let canvas = adaptive(light: (0.985, 0.975, 0.96), dark: (0.12, 0.11, 0.12))
    package static let sidebar = adaptive(light: (0.955, 0.94, 0.92), dark: (0.16, 0.15, 0.16))
    package static let row = adaptive(light: (0.995, 0.99, 0.98), dark: (0.19, 0.18, 0.19))
    package static let safe = adaptive(light: (0.16, 0.45, 0.27), dark: (0.60, 0.82, 0.66))
    /// Dark amber remains readable on warm light surfaces; dark mode uses a lighter amber.
    package static let caution = adaptive(light: (0.55, 0.30, 0.0), dark: (0.96, 0.73, 0.43))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }
}

package enum PolicyMutationError: Error, LocalizedError {
    case policyUnavailable
    case agentRejected(String)
    case unexpectedResponse
    case dangerousFolder(String)
    /// Another writer changed the policy three times in a row.
    case policyConflict
    /// The request timed out or was interrupted after it was sent; the agent may have applied it.
    case outcomeUnknown
    case ruleMissing

    package var errorDescription: String? {
        switch self {
        case .policyUnavailable: "The current local policy is not loaded. Refresh and try again."
        case .agentRejected(let message): "The local agent rejected the change: \(message)"
        case .unexpectedResponse: "The local agent returned an unexpected response."
        case .dangerousFolder(let message): message
        case .policyConflict: "TinyPrune was changed somewhere else while you were editing. The latest state is loaded; review it and try again."
        case .outcomeUnknown: "The local agent did not confirm the change, so it may or may not have been applied. The latest state has been reloaded; check it before trying again."
        case .ruleMissing: "That rule no longer exists."
        }
    }
}

/// A button the application offers beside `pruningHaltedReason` to resolve it.
package struct PruningHaltResolution {
    package let title: String
    package let perform: @MainActor () -> Void

    package init(title: String, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// A newer release found by the optional, user-controlled version check (for builds without in-app installation).
/// Nothing here installs anything: the actions only open a link or copy a command.
package struct UpdateNotice {
    package struct Action {
        package let title: String
        package let perform: @MainActor () -> Void
        package init(title: String, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    package let version: String
    package let message: String
    package let primary: Action
    package let secondary: Action?
    package let skipVersion: @MainActor () -> Void
    package let remindLater: @MainActor () -> Void

    package init(version: String, message: String, primary: Action, secondary: Action?, skipVersion: @escaping @MainActor () -> Void, remindLater: @escaping @MainActor () -> Void) {
        self.version = version
        self.message = message
        self.primary = primary
        self.secondary = secondary
        self.skipVersion = skipVersion
        self.remindLater = remindLater
    }
}

/// A folder the user picked, converted to a security-scoped managed root.
package struct ChosenFolder {
    package let root: ManagedRoot
    /// Home folders and similarly wide scopes: Domain's definition, never a local copy.
    package var isVeryBroad: Bool { root.isVeryBroad }

    package init(root: ManagedRoot) { self.root = root }

    @MainActor
    static func choose(startingAt directory: URL? = nil, prompt: String = "Use Folder") throws -> ChosenFolder? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try make(from: url)
    }

    package static func make(from url: URL) throws -> ChosenFolder {
        let path = url.standardizedFileURL.path
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root: ManagedRoot
        do {
            root = try ManagedRoot(displayName: url.lastPathComponent, path: path, bookmarkData: bookmark)
        } catch ManagedRootValidationError.dangerousPath {
            throw PolicyMutationError.dangerousFolder("TinyPrune does not manage system locations such as \(path).")
        }
        // Very broad roots are allowed but flagged (`isVeryBroad`) so rules on them can only be Previews.
        return ChosenFolder(root: root)
    }
}

/// How the model reaches the local agent. Production uses XPC; the snapshot harness calls an in-process handler.
package protocol AgentTransport: Sendable {
    func request(_ request: AgentRequest) async throws -> AgentResponse
}

extension TinyPruneAgentClient: AgentTransport {}

/// Login-item and LaunchAgent registration, kept behind a protocol so tooling never touches launchd.
@MainActor
package protocol AgentSystemServices: AnyObject {
    var agentStatus: SMAppService.Status { get }
    func registerAgent() throws
    func restartAgent() throws
    func reconcileAgentAfterUpdate() throws -> Bool
    func openLoginItems()
    var launchesAtLogin: Bool { get }
    func setLaunchAtLogin(_ enabled: Bool) throws
}

@MainActor
package final class SMAppSystemServices: AgentSystemServices {
    private let launchAgent = SMAppService.agent(plistName: "com.navig-me.tinyprune.agent.plist")

    package init() {}

    package var agentStatus: SMAppService.Status { launchAgent.status }
    package func registerAgent() throws { try launchAgent.register() }
    package func restartAgent() throws {
        try? launchAgent.unregister()
        try launchAgent.register()
    }

    /// `brew upgrade` and direct replacement leave macOS listing the agent as enabled while launchd has lost or
    /// cannot spawn the job, and the first request then hangs. Re-register once whenever the installed app build
    /// differs from the one that last registered, before anything talks to the agent. Returns true if it did.
    package func reconcileAgentAfterUpdate() throws -> Bool {
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let key = "agentRegisteredByBuild"
        let defaults = UserDefaults.standard
        guard launchAgent.status == .enabled else { return false }
        if defaults.string(forKey: key) == build { return false }
        try restartAgent()
        defaults.set(build, forKey: key)
        return true
    }
    package func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    package var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    package func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
package final class AgentViewModel: ObservableObject {
    @Published package private(set) var overview: AgentOverviewSnapshot?
    @Published package private(set) var activity: [AgentActivityItem] = []
    @Published package private(set) var settings = AgentSettings.default
    @Published package private(set) var isLoading = false
    /// Why the last refresh failed. The previous good `overview` is kept while this is set.
    @Published package private(set) var connectionIssue: String?
    @Published package private(set) var refreshedAt: Date?
    @Published package private(set) var registrationStatus: SMAppService.Status = .notRegistered
    /// Set by the application when the updater has stopped pruning (an update is offered, downloaded, or installing).
    @Published package var pruningHaltedReason: String?
    /// Optional one-tap way out of `pruningHaltedReason`, supplied by the application (for example "Review Update…").
    @Published package var pruningHaltResolution: PruningHaltResolution?
    /// A newer release is available. Set by the application; independent of pruning safety.
    @Published package var updateNotice: UpdateNotice?
    /// Failure of the last menu-bar or quick action, shown where the action was offered.
    @Published package private(set) var actionError: String?
    @Published private var attentionSeenAt: Date?
    @Published package private(set) var ledgerSizes: [String: ItemSize] = [:]
    @Published package private(set) var ledgerSizeFailures: Set<String> = []

    /// First load failure or a lost connection with nothing cached.
    package var errorMessage: String? { overview == nil ? connectionIssue : nil }

    private let transport: any AgentTransport
    private let probeTransport: (any AgentTransport)?
    package let services: any AgentSystemServices
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults
    private var notifiedFailureIDs: Set<UUID> = []
    private var hasSeededNotifications = false
    private let postsNotifications: Bool
    private var isRefreshing = false
    private var refreshPending = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundTask: Task<Void, Never>?

    private static let onboardingKey = "onboardingCompleted"
    private static let attentionSeenKey = "attentionSeenAt"
    private static let maxPolicyAttempts = 3

    package init(
        transport: any AgentTransport = TinyPruneAgentClient(),
        probeTransport: (any AgentTransport)? = nil,
        services: any AgentSystemServices = SMAppSystemServices(),
        postsNotifications: Bool = true,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.probeTransport = probeTransport
        self.services = services
        self.postsNotifications = postsNotifications
        self.defaults = defaults
        self.now = now
        attentionSeenAt = defaults.object(forKey: Self.attentionSeenKey) as? Date
    }

    /// Says what the first launch is waiting for, so a restart of the background agent is not a silent spinner.
    @Published package private(set) var startupNote: String?

    /// `health` with a short timeout. A stale launchd registration after an upgrade makes a normal request hang for the
    /// full client timeout; probing quickly lets the app repair the registration in seconds instead.
    private func agentAnswers() async -> Bool {
        guard case .health? = try? await (probeTransport ?? transport).request(AgentRequest(operation: .health)).payload else { return false }
        return true
    }

    /// Before the first load, make sure the agent actually answers: probe briefly, re-register once if it does not,
    /// then give the freshly started job a few seconds to come up. Never runs once an overview is cached.
    private func waitUntilAgentAnswers() async {
        guard overview == nil, registrationStatus == .enabled else { return }
        for attempt in 0..<2 {
            if await agentAnswers() { return }
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        guard !repairedAgentThisSession else { return }
        repairedAgentThisSession = true
        startupNote = "Starting the background agent after the update…"
        defer { startupNote = nil }
        guard (try? services.restartAgent()) != nil else { return }
        for _ in 0..<8 {
            if await agentAnswers() { return }
            try? await Task.sleep(for: .milliseconds(750))
        }
    }

    package var policy: AgentPolicySnapshot? { overview?.policy }
    package var currentDate: Date { now() }

    /// True while no managed folder or rule exists and the user has not finished onboarding.
    /// Derived from the latest policy every time, so it follows refreshes instead of latching.
    package var needsOnboarding: Bool {
        guard let policy = overview?.policy else { return false }
        return !defaults.bool(forKey: Self.onboardingKey) && policy.managedRoots.isEmpty && policy.rules.isEmpty
    }

    package func completeOnboarding() { defaults.set(true, forKey: Self.onboardingKey) }

    // MARK: Background refresh

    /// Keeps the model honest while the window is closed or the Mac was asleep: refreshes on a timer and
    /// whenever the app becomes active. Idempotent.
    package func startBackgroundRefresh(interval: Duration = .seconds(30), busyInterval: Duration = .seconds(2)) {
        guard backgroundTask == nil else { return }
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                // While the agent indexes or recovers a folder, matches keep arriving; poll quickly until it settles.
                let busy = await self?.agentIsWorking ?? false
                try? await Task.sleep(for: busy ? busyInterval : interval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// True while any managed folder is still being indexed or recovered.
    package var agentIsWorking: Bool {
        overview?.rootStatuses.contains { $0.state == .indexing || $0.state == .recovering } ?? false
    }

    // MARK: Agent registration

    package func refreshRegistrationStatus() { registrationStatus = services.agentStatus }

    private var repairedAgentThisSession = false
    private var reconciledAgentThisSession = false

    package func registerAgent() async {
        do {
            try services.registerAgent()
            refreshRegistrationStatus()
            await refresh()
        } catch {
            connectionIssue = "Could not register the TinyPrune background agent: \(error)"
        }
    }

    /// Re-registers an agent macOS lists as enabled but launchd is not running (for example after `brew upgrade`).
    package func restartAgent() async {
        do {
            try services.restartAgent()
            refreshRegistrationStatus()
            await refresh()
        } catch {
            connectionIssue = "Could not restart the TinyPrune background agent: \(error)"
        }
    }

    package func openLoginItems() { services.openLoginItems() }

    // MARK: Requests

    /// `mutating` requests that end in a timeout or interruption may still have been applied by the agent.
    private func send(_ operation: AgentOperation, mutating: Bool = false) async throws -> AgentResponsePayload {
        let response: AgentResponse
        do {
            response = try await transport.request(AgentRequest(operation: operation))
        } catch let error as AgentClientError where mutating && (error == .timedOut || error == .interrupted) {
            await refresh()
            throw PolicyMutationError.outcomeUnknown
        }
        if case .failure(let error) = response.payload {
            switch error {
            case .invalidRequest(let detail), .storageUnavailable(let detail): throw PolicyMutationError.agentRejected(detail)
            case .unsupportedProtocol:
                throw PolicyMutationError.agentRejected("The app and background agent use different protocol versions. Quit and reopen TinyPrune to load the matching agent.")
            case .policyConflict: throw PolicyMutationError.policyConflict
            case .rootUnavailable(let path):
                throw PolicyMutationError.agentRejected("The folder \(path) is not available. Reopen TinyPrune or choose the folder again.")
            }
        }
        return response.payload
    }

    private func mutate(_ operation: AgentOperation) async throws {
        guard case .acknowledged = try await send(operation, mutating: true) else { throw PolicyMutationError.unexpectedResponse }
        await refresh()
    }

    private static func describe(_ error: any Error) -> String {
        if let client = error as? AgentClientError {
            switch client {
            case .unavailable: return "The local TinyPrune agent is unavailable."
            case .timedOut: return "The local TinyPrune agent did not answer in time."
            case .interrupted: return "The connection to the local TinyPrune agent was interrupted."
            default: return "The local TinyPrune agent returned an unreadable reply."
            }
        }
        if let mutation = error as? PolicyMutationError {
            return "The TinyPrune agent could not load local state: \(mutation.localizedDescription)"
        }
        return "The local TinyPrune agent is unavailable."
    }

    /// Reloads agent state. Concurrent calls coalesce: a call made while a load is running schedules exactly one
    /// more load and returns when it has finished, so callers always observe state at least as new as their call.
    /// A failed load keeps the last good overview and sets `connectionIssue`.
    package func refresh() async {
        registrationStatus = services.agentStatus
        if !reconciledAgentThisSession {
            reconciledAgentThisSession = true
            if (try? services.reconcileAgentAfterUpdate()) == true { registrationStatus = services.agentStatus }
        }
        if isRefreshing {
            refreshPending = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        // Only the very first load is "loading". Later refreshes (timer, page change, activation) are silent, so the
        // header and icons do not flicker every few seconds.
        isLoading = overview == nil
        repeat {
            refreshPending = false
            await waitUntilAgentAnswers()
            await loadState()
        } while refreshPending
        isLoading = false
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func loadState(allowRepair: Bool = true) async {
        do {
            guard case .overview(let loaded) = try await send(.loadOverview) else {
                connectionIssue = "The TinyPrune agent returned an unexpected response."
                return
            }
            let previousRoots = overview?.policy.managedRoots
            overview = loaded
            if previousRoots != loaded.policy.managedRoots {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.navig-me.tinyprune.managedRootsChanged"),
                    object: nil, userInfo: nil, deliverImmediately: true
                )
            }
            connectionIssue = nil
            refreshedAt = now()
        } catch is CancellationError {
            return
        } catch {
            // SMAppService can say "enabled" while launchd has no job: Homebrew's cask unloads the agent on every
            // upgrade and macOS keeps the stale registration. Re-register once per session and try again.
            if allowRepair, overview == nil, !repairedAgentThisSession, registrationStatus == .enabled {
                repairedAgentThisSession = true
                if (try? services.restartAgent()) != nil {
                    await loadState(allowRepair: false)
                    return
                }
            }
            connectionIssue = Self.describe(error)
            return
        }
        // Secondary loads never discard the overview that just loaded.
        if case .settings(let loaded)? = try? await send(.loadSettings) { settings = loaded }
        if case .activity(let items)? = try? await send(.loadActivity(limit: 200)) {
            activity = items
            await notifyAboutFailures(items)
        }
    }

    /// Runs a quick action, remembering its failure for the surface that offered it.
    package func perform(_ action: () async throws -> Void) async {
        actionError = nil
        do { try await action() }
        catch { actionError = error.localizedDescription }
    }

    package func clearActionError() { actionError = nil }

    // MARK: Policy edits

    private func loadFreshPolicy() async throws -> AgentPolicySnapshot {
        guard case .policy(let policy) = try await send(.loadPolicy) else { throw PolicyMutationError.unexpectedResponse }
        return policy
    }

    /// Reads the agent's current policy, applies `transform`, and writes it back against the revision that was read.
    /// A concurrent change (`policyConflict`) reloads and reapplies the transform, at most three times.
    package func updatePolicy(_ transform: (inout AgentPolicySnapshot) throws -> Void) async throws {
        for _ in 0..<Self.maxPolicyAttempts {
            let fresh = try await loadFreshPolicy()
            var edited = fresh
            try transform(&edited)
            let proposal = AgentPolicySnapshot(
                rules: edited.rules,
                overrides: edited.overrides,
                managedRoots: edited.managedRoots,
                globallyPaused: edited.globallyPaused,
                pausedUntil: edited.pausedUntil,
                revision: fresh.revision
            )
            do {
                guard case .acknowledged = try await send(.replacePolicy(proposal), mutating: true) else { throw PolicyMutationError.unexpectedResponse }
                await refresh()
                return
            } catch PolicyMutationError.policyConflict {
                continue
            }
        }
        await refresh()
        throw PolicyMutationError.policyConflict
    }

    /// Atomically saves one rule, optionally adds its folder, and applies Keep exceptions in a single agent transaction.
    package func saveRule(_ rule: LifetimeRule, folder: ChosenFolder?, keepPaths: [String], unkeepPaths: [String]) async throws {
        for _ in 0..<Self.maxPolicyAttempts {
            let fresh = try await loadFreshPolicy()
            let roots = folder.map { Self.merge(fresh.managedRoots, adding: $0.root) }
            do {
                guard case .acknowledged = try await send(
                    .saveRule(rule: rule, roots: roots, keepPaths: keepPaths, unkeepPaths: unkeepPaths, revision: fresh.revision),
                    mutating: true
                ) else { throw PolicyMutationError.unexpectedResponse }
                await refresh()
                return
            } catch PolicyMutationError.policyConflict {
                continue
            }
        }
        await refresh()
        throw PolicyMutationError.policyConflict
    }

    private static func merge(_ existing: [ManagedRoot], adding root: ManagedRoot) -> [ManagedRoot] {
        existing.contains(where: { $0.path == root.path }) ? existing : existing + [root]
    }

    /// Adds rules and their folders in one atomic replace. Rules already present (same id) are left alone.
    package func addRules(_ newRules: [LifetimeRule], folders: [ChosenFolder]) async throws {
        try await updatePolicy { policy in
            var rules = policy.rules
            let known = Set(rules.map(\.id))
            rules.append(contentsOf: newRules.filter { !known.contains($0.id) })
            var roots = policy.managedRoots
            for folder in folders { roots = Self.merge(roots, adding: folder.root) }
            policy = AgentPolicySnapshot(
                rules: rules, overrides: policy.overrides, managedRoots: roots,
                globallyPaused: policy.globallyPaused, pausedUntil: policy.pausedUntil, revision: policy.revision
            )
        }
    }

    package func setState(_ state: RuleState, for rule: LifetimeRule) async throws {
        try await updatePolicy { policy in
            guard let index = policy.rules.firstIndex(where: { $0.id == rule.id }) else { throw PolicyMutationError.ruleMissing }
            var rules = policy.rules
            rules[index] = try rules[index].with(state: state)
            policy = AgentPolicySnapshot(
                rules: rules, overrides: policy.overrides, managedRoots: policy.managedRoots,
                globallyPaused: policy.globallyPaused, pausedUntil: policy.pausedUntil, revision: policy.revision
            )
        }
    }

    package func duplicate(_ rule: LifetimeRule) async throws {
        let copy = try LifetimeRule(
            name: "\(rule.name) copy",
            scope: rule.scope,
            matcher: rule.matcher,
            expiryBasis: rule.expiryBasis,
            lifetime: rule.lifetime,
            gracePeriod: rule.gracePeriod,
            action: rule.action,
            state: .preview,
            matchMode: rule.matchMode
        )
        try await addRules([copy], folders: [])
    }

    package func delete(_ rule: LifetimeRule) async throws { try await mutate(.deleteRule(rule.id)) }
    package func setGlobalPause(_ paused: Bool) async throws { try await mutate(.setGlobalPause(paused)) }
    package func pause(until date: Date) async throws { try await mutate(.pauseUntil(date)) }

    package func updateSettings(_ updated: AgentSettings) async throws {
        guard case .settings(let saved) = try await send(.updateSettings(updated), mutating: true) else { throw PolicyMutationError.unexpectedResponse }
        settings = saved
        await refresh()
    }

    package struct ItemSize: Sendable {
        package let bytes: Int64
        package let items: Int
        package let truncated: Bool
        package init(bytes: Int64, items: Int, truncated: Bool) {
            self.bytes = bytes; self.items = items; self.truncated = truncated
        }
    }

    /// Sizes are computed only when the user asks for them.
    package func size(of path: String) async throws -> ItemSize {
        guard case .itemSize(_, let bytes, let items, let truncated) = try await send(.itemSize(path: path)) else {
            throw PolicyMutationError.unexpectedResponse
        }
        return ItemSize(bytes: bytes, items: items, truncated: truncated)
    }

    package static func ledgerKey(_ item: AgentUpcomingItem) -> String {
        "\(item.explanation.candidateIdentity.pathHint)|\(item.explanation.scheduledAt.timeIntervalSinceReferenceDate)"
    }

    /// A bounded, lazy metadata ledger. Cached deadlines survive ordinary overview refreshes.
    private var ledgerMeasurementRunning = false
    private var ledgerMeasurementWaiters: [CheckedContinuation<Void, Never>] = []

    package func measureLedgerSizes() async {
        // Replacement SwiftUI tasks can overlap while cancelled XPC calls settle. Serialize batches
        // across those invocations too, so the agent never sees more than four ledger requests.
        while ledgerMeasurementRunning {
            await withCheckedContinuation { ledgerMeasurementWaiters.append($0) }
        }
        guard !Task.isCancelled else { return }
        ledgerMeasurementRunning = true
        defer {
            ledgerMeasurementRunning = false
            let waiters = ledgerMeasurementWaiters
            ledgerMeasurementWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let candidates = activeUpcoming.sorted { $0.explanation.scheduledAt < $1.explanation.scheduledAt }.prefix(100)
        let missing = candidates.filter {
            let key = Self.ledgerKey($0)
            return ledgerSizes[key] == nil && !ledgerSizeFailures.contains(key)
        }
        for start in stride(from: 0, to: missing.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = missing[start..<min(start + 4, missing.count)]
            await withTaskGroup(of: (String, ItemSize?).self) { group in
                for item in batch {
                    let key = Self.ledgerKey(item)
                    let path = item.explanation.candidateIdentity.pathHint
                    group.addTask { [self] in
                        guard !Task.isCancelled else { return (key, nil) }
                        return (key, try? await size(of: path))
                    }
                }
                for await (key, result) in group {
                    guard !Task.isCancelled else { group.cancelAll(); continue }
                    if let result { ledgerSizes[key] = result }
                    else { ledgerSizeFailures.insert(key) }
                }
            }
        }
    }

    /// Applies an imported configuration with the same plan the CLI uses. Returns a short summary.
    /// The plan's rule delta (not its precomputed merge) is applied to the freshest policy, so concurrent edits survive.
    package func applyConfig(_ plan: ConfigPlan) async throws -> String {
        guard plan.isApplicable else { throw PolicyMutationError.dangerousFolder("Add these folders in TinyPrune first: \(plan.unmanagedRoots.joined(separator: ", "))") }
        if plan.hasRuleChanges {
            try await updatePolicy { policy in
                let removedIDs = Set(plan.removed.map(\.id))
                let replacements = Dictionary(plan.changed.map { ($0.after.id, $0.after) }, uniquingKeysWith: { _, last in last })
                var rules: [LifetimeRule] = policy.rules
                    .filter { !removedIDs.contains($0.id) }
                    .map { replacements[$0.id] ?? $0 }
                let known = Set(rules.map(\.id))
                rules.append(contentsOf: plan.added.filter { !known.contains($0.id) })
                policy = AgentPolicySnapshot(
                    rules: rules, overrides: policy.overrides, managedRoots: policy.managedRoots,
                    globallyPaused: policy.globallyPaused, pausedUntil: policy.pausedUntil, revision: policy.revision
                )
            }
        }
        if !plan.newExceptions.isEmpty {
            try await mutate(.setItemOverrides(changes: plan.newExceptions.map { AgentItemOverrideChange(path: $0.path, policy: $0.policy) }))
        }
        return "\(plan.added.count) added, \(plan.changed.count) changed, \(plan.removed.count) removed, \(plan.newExceptions.count) exception(s) set."
    }

    /// Explicit, user-requested dry run. Nothing is persisted and nothing is moved to Trash.
    package func previewRule(_ rule: LifetimeRule) async throws -> AgentRulePreview {
        guard case .rulePreview(let preview) = try await send(.previewRule(rule)) else { throw PolicyMutationError.unexpectedResponse }
        return preview
    }

    /// Asks the agent to stop a running preview scan.
    package func cancelPreview() async {
        _ = try? await send(.cancelPreview)
    }

    package func rebuildIndex() async throws { try await mutate(.rebuildIndex) }
    package func keep(path: String, protectDescendants: Bool) async throws {
        try await mutate(.setItemOverride(path: path, policy: .keep(protectDescendants: protectDescendants)))
    }
    package func setExpiry(path: String, at date: Date, state: RuleState) async throws {
        try await mutate(.setItemOverride(path: path, policy: .customExpiry(date, state: state)))
    }
    package func inherit(path: String) async throws { try await mutate(.clearItemOverride(path: path)) }

    /// Keep overrides inside `scopePath`, from the latest overview, for the editor's Except list.
    package func overrides(under scopePath: String) -> [ItemPolicyOverride] {
        let prefix = scopePath.hasSuffix("/") ? scopePath : scopePath + "/"
        return (overview?.policy.overrides ?? []).filter { override in
            guard case .keep = override.policy else { return false }
            return override.path == scopePath || override.path.hasPrefix(prefix)
        }
    }

    package func explain(path: String) async throws -> AgentItemExplanation {
        guard case .itemExplanation(let explanation) = try await send(.explainItem(path: path)) else {
            throw PolicyMutationError.unexpectedResponse
        }
        return explanation
    }

    // MARK: Derived honesty

    /// Matches that will really move to Trash.
    package var activeUpcoming: [AgentUpcomingItem] { overview?.upcoming.filter { $0.explanation.disposition == .active } ?? [] }
    /// Matches from Preview rules, which never touch files.
    package var previewUpcoming: [AgentUpcomingItem] { overview?.upcoming.filter { $0.explanation.disposition == .preview } ?? [] }

    /// Trash failures from the last 24 hours that the user has not seen in Activity and that were not later resolved.
    package var attentionItems: [AgentActivityItem] {
        let cutoff = max(now().addingTimeInterval(-86_400), attentionSeenAt ?? .distantPast)
        let recent = activity.filter { $0.occurredAt > cutoff }
        return recent.filter { failure in
            guard failure.isAttention else { return false }
            guard let identity = failure.identity else { return true }
            return !recent.contains { $0.kind == .movedToTrash && $0.identity == identity && $0.occurredAt > failure.occurredAt }
        }
    }

    package var needsAttention: Bool { !attentionItems.isEmpty }

    /// Called when the user opens Activity from the attention notice.
    package func acknowledgeAttention() {
        let date = now()
        attentionSeenAt = date
        defaults.set(date, forKey: Self.attentionSeenKey)
    }

    package func stats(for rule: LifetimeRule) -> AgentRuleStats? {
        overview?.ruleStats.first { $0.ruleID == rule.id }
    }

    // MARK: Attention-only notifications

    private var notificationsEnabled: Bool { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true }

    private func notifyAboutFailures(_ items: [AgentActivityItem]) async {
        let failures = items.filter { $0.kind == .trashFailed }
        defer {
            notifiedFailureIDs.formUnion(failures.map(\.id))
            hasSeededNotifications = true
        }
        // Do not announce failures that predate this launch.
        guard hasSeededNotifications, notificationsEnabled, postsNotifications, Bundle.main.bundleIdentifier != nil else { return }
        let fresh = failures.filter { !notifiedFailureIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cleanup blocked"
        content.body = fresh.count == 1
            ? "TinyPrune could not move \(fresh[0].identity.map { URL(fileURLWithPath: $0.pathHint).lastPathComponent } ?? "an item") to Trash."
            : "TinyPrune could not move \(fresh.count) items to Trash. See Activity."
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension LifetimeRule {
    package func with(state: RuleState) throws -> LifetimeRule {
        try LifetimeRule(
            id: id, name: name, scope: scope, matcher: matcher, expiryBasis: expiryBasis,
            lifetime: lifetime, gracePeriod: gracePeriod, action: action, state: state, matchMode: matchMode
        )
    }
}

struct Pill: View {
    let text: String
    var color: Color = PrunePalette.plum
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .overlay {
                if contrast == .increased { Capsule().strokeBorder(color, lineWidth: 1) }
            }
    }
}

struct PathText: View {
    let path: String
    @State private var copied = false
    var body: some View {
        Text(path)
            .font(Typography.path)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .contextMenu {
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(path, forType: .string)
                }
            }
            .overlay(alignment: .trailing) {
                if copied {
                    Label("Copied", systemImage: "checkmark").font(.caption)
                        .foregroundStyle(PrunePalette.safe)
                        .padding(4).background(PrunePalette.row, in: Capsule())
                        .onHover { if !$0 { copied = false } }
                }
            }
            .sensoryFeedback(.success, trigger: copied)
            .pruneAnimation(value: copied)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typography.sectionTitle)
            .accessibilityAddTraits(.isHeader)
    }
}

extension RuleState {
    var label: String {
        switch self {
        case .preview: "Preview"
        case .active: "Active"
        case .paused: "Paused"
        }
    }

    var color: Color {
        switch self {
        case .preview: PrunePalette.caution
        case .active: PrunePalette.safe
        case .paused: .secondary
        }
    }
}

extension AgentActivityItem {
    var title: String {
        let name = identity.map { URL(fileURLWithPath: $0.pathHint).lastPathComponent } ?? detail.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "item"
        switch kind {
        case .policyReplaced: return "Settings saved"
        case .ruleCreated: return "Rule created: \(detail ?? "")"
        case .ruleEdited: return "Rule edited: \(detail ?? "")"
        case .rulePaused: return "Rule paused: \(detail ?? "")"
        case .ruleDeleted: return "Rule deleted\(detail.map { ": \($0)" } ?? "")"
        case .itemProtected: return "Protected \(name)"
        case .itemUnprotected: return "\(name) now follows its rule"
        case .expiryChanged: return "Expiry changed for \(name)"
        case .globalPauseChanged:
            if detail == "paused" { return "TinyPrune paused" }
            if detail?.hasPrefix("paused until") == true { return "TinyPrune paused for a while" }
            if detail == "resumed automatically" { return "Pause ended; TinyPrune resumed" }
            return "TinyPrune resumed"
        case .settingsChanged: return "Safety settings changed"
        case .previewSkipped: return "Preview match: \(name)"
        case .notDue: return "\(name) was not yet due"
        case .safetySkipped: return "Skipped \(name): \(detail ?? "safety check")"
        case .trashAttempted: return "Moving \(name) to Trash"
        case .movedToTrash: return "Moved \(name) to Trash"
        case .trashFailed: return "Could not move \(name) to Trash"
        }
    }

    var isAttention: Bool { kind == .trashFailed }
}
