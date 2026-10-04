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

    package var errorDescription: String? {
        switch self {
        case .policyUnavailable: "The current local policy is not loaded. Refresh and try again."
        case .agentRejected(let message): "The local agent rejected the change: \(message)"
        case .unexpectedResponse: "The local agent returned an unexpected response."
        case .dangerousFolder(let message): message
        }
    }
}

/// A folder the user picked, converted to a security-scoped managed root.
package struct ChosenFolder {
    package let root: ManagedRoot
    /// Home folders and similarly wide scopes must start in Preview.
    package let isVeryBroad: Bool

    package init(root: ManagedRoot, isVeryBroad: Bool) {
        self.root = root
        self.isVeryBroad = isVeryBroad
    }

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
        let home = NSHomeDirectory()
        return ChosenFolder(root: root, isVeryBroad: path == home || path == "/Users" || path == "/Volumes")
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
    @Published package private(set) var errorMessage: String?
    @Published package private(set) var refreshedAt: Date?
    @Published package private(set) var registrationStatus: SMAppService.Status = .notRegistered

    private let transport: any AgentTransport
    package let services: any AgentSystemServices
    private let now: @Sendable () -> Date
    private var notifiedFailureIDs: Set<UUID> = []
    private var hasSeededNotifications = false
    private let postsNotifications: Bool

    package init(
        transport: any AgentTransport = TinyPruneAgentClient(),
        services: any AgentSystemServices = SMAppSystemServices(),
        postsNotifications: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.services = services
        self.postsNotifications = postsNotifications
        self.now = now
    }

    package var policy: AgentPolicySnapshot? { overview?.policy }

    // MARK: Agent registration

    package func refreshRegistrationStatus() { registrationStatus = services.agentStatus }

    package func registerAgent() async {
        do {
            try services.registerAgent()
            refreshRegistrationStatus()
            await refresh()
        } catch {
            errorMessage = "Could not register the TinyPrune background agent: \(error)"
        }
    }

    package func openLoginItems() { services.openLoginItems() }

    // MARK: Requests

    private func send(_ operation: AgentOperation) async throws -> AgentResponsePayload {
        let response = try await transport.request(AgentRequest(operation: operation))
        if case .failure(let error) = response.payload {
            let message: String
            switch error {
            case .invalidRequest(let detail), .storageUnavailable(let detail): message = detail
            case .unsupportedProtocol:
                message = "The app and background agent use different protocol versions. Quit and reopen TinyPrune to load the matching agent."
            }
            throw PolicyMutationError.agentRejected(message)
        }
        return response.payload
    }

    private func mutate(_ operation: AgentOperation) async throws {
        guard case .acknowledged = try await send(operation) else { throw PolicyMutationError.unexpectedResponse }
        await refresh()
    }

    package func refresh() async {
        registrationStatus = services.agentStatus
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard case .overview(let overview) = try await send(.loadOverview) else {
                self.overview = nil
                errorMessage = "The TinyPrune agent returned an unexpected response."
                return
            }
            let previousRoots = self.overview?.policy.managedRoots
            self.overview = overview
            if previousRoots != overview.policy.managedRoots {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.navig-me.tinyprune.managedRootsChanged"),
                    object: nil, userInfo: nil, deliverImmediately: true
                )
            }
            errorMessage = nil
            refreshedAt = now()
            if case .settings(let loaded) = try await send(.loadSettings) { settings = loaded }
            if case .activity(let items) = try await send(.loadActivity(limit: 200)) {
                activity = items
                await notifyAboutFailures(items)
            }
        } catch let error as PolicyMutationError {
            overview = nil
            errorMessage = "The TinyPrune agent could not load local state: \(error.localizedDescription)"
        } catch {
            overview = nil
            errorMessage = "The local TinyPrune agent is unavailable."
        }
    }

    // MARK: Policy edits

    package func replacePolicy(rules: [LifetimeRule]? = nil, roots: [ManagedRoot]? = nil) async throws {
        guard let current = overview?.policy else { throw PolicyMutationError.policyUnavailable }
        try await mutate(.replacePolicy(AgentPolicySnapshot(
            rules: rules ?? current.rules,
            overrides: current.overrides,
            managedRoots: roots ?? current.managedRoots,
            globallyPaused: current.globallyPaused
        )))
    }

    /// Adds `root` when it is not already covered by a managed root.
    package func mergedRoots(adding root: ManagedRoot) -> [ManagedRoot] {
        let existing = overview?.policy.managedRoots ?? []
        if existing.contains(where: { $0.path == root.path }) { return existing }
        return existing + [root]
    }

    package func addRules(_ newRules: [LifetimeRule], in folder: ChosenFolder?) async throws {
        guard let current = overview?.policy else { throw PolicyMutationError.policyUnavailable }
        try await replacePolicy(rules: current.rules + newRules, roots: folder.map { mergedRoots(adding: $0.root) })
    }

    package func upsert(rule: LifetimeRule, folder: ChosenFolder?) async throws {
        guard let current = overview?.policy else { throw PolicyMutationError.policyUnavailable }
        var rules = current.rules
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        try await replacePolicy(rules: rules, roots: folder.map { mergedRoots(adding: $0.root) })
    }

    package func setState(_ state: RuleState, for rule: LifetimeRule) async throws {
        try await upsert(rule: rule.with(state: state), folder: nil)
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
        try await upsert(rule: copy, folder: nil)
    }

    package func delete(_ rule: LifetimeRule) async throws { try await mutate(.deleteRule(rule.id)) }
    package func setGlobalPause(_ paused: Bool) async throws { try await mutate(.setGlobalPause(paused)) }
    package func pause(until date: Date) async throws { try await mutate(.pauseUntil(date)) }

    package func updateSettings(_ updated: AgentSettings) async throws {
        guard case .settings(let saved) = try await send(.updateSettings(updated)) else { throw PolicyMutationError.unexpectedResponse }
        settings = saved
        await refresh()
    }

    package struct ItemSize { package let bytes: Int64; package let items: Int; package let truncated: Bool }

    /// Sizes are computed only when the user asks for them.
    package func size(of path: String) async throws -> ItemSize {
        guard case .itemSize(_, let bytes, let items, let truncated) = try await send(.itemSize(path: path)) else {
            throw PolicyMutationError.unexpectedResponse
        }
        return ItemSize(bytes: bytes, items: items, truncated: truncated)
    }

    /// Applies an imported configuration with the same plan the CLI uses. Returns a short summary.
    package func applyConfig(_ plan: ConfigPlan) async throws -> String {
        guard plan.isApplicable else { throw PolicyMutationError.dangerousFolder("Add these folders in TinyPrune first: \(plan.unmanagedRoots.joined(separator: ", "))") }
        if plan.hasRuleChanges { try await replacePolicy(rules: plan.merged) }
        for override in plan.newExceptions {
            try await mutate(.setItemOverride(path: override.path, policy: override.policy))
        }
        return "\(plan.added.count) added, \(plan.changed.count) changed, \(plan.removed.count) removed, \(plan.newExceptions.count) exception(s) set."
    }
    /// Explicit, user-requested dry run. Nothing is persisted and nothing is moved to Trash.
    package func previewRule(_ rule: LifetimeRule) async throws -> AgentRulePreview {
        guard case .rulePreview(let preview) = try await send(.previewRule(rule)) else { throw PolicyMutationError.unexpectedResponse }
        return preview
    }

    package func rebuildIndex() async throws { try await mutate(.rebuildIndex) }
    package func keep(path: String, protectDescendants: Bool) async throws {
        try await mutate(.setItemOverride(path: path, policy: .keep(protectDescendants: protectDescendants)))
    }
    package func setExpiry(path: String, at date: Date, state: RuleState) async throws {
        try await mutate(.setItemOverride(path: path, policy: .customExpiry(date, state: state)))
    }
    package func inherit(path: String) async throws { try await mutate(.clearItemOverride(path: path)) }

    package func explain(path: String) async throws -> AgentItemExplanation {
        guard case .itemExplanation(let explanation) = try await send(.explainItem(path: path)) else {
            throw PolicyMutationError.unexpectedResponse
        }
        return explanation
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
    var body: some View {
        Text(path)
            .font(Typography.mono(size: 12, relativeTo: .caption))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .contextMenu {
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typography.display(size: 22))
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
