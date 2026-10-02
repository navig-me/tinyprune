import AppKit
import FinderSync
import TinyPruneDomain
import TinyPruneIPC
import UserNotifications

/// Thin Finder client. All policy decisions and mutations happen in the agent over XPC.
final class FinderSync: FIFinderSync {
    private enum Action: Int {
        case keep = 1, tonight, tomorrow, sevenDays, thirtyDays, inherit, why
        case folderLifetime, protectFolder, createRule, customExpiry
    }

    private let client = TinyPruneAgentClient()

    override init() {
        super.init()
        refreshMonitoredDirectories()
    }

    // MARK: Monitoring

    private func refreshMonitoredDirectories() {
        let client = self.client
        Task { @MainActor in
            do {
                let response = try await client.request(AgentRequest(operation: .loadPolicy))
                guard case .policy(let policy) = response.payload else {
                    throw FinderFailure.unexpected(response.payload)
                }
                FIFinderSyncController.default().directoryURLs = Set(policy.managedRoots.map {
                    URL(fileURLWithPath: $0.path, isDirectory: true)
                })
            } catch {
                // Menu invocation reports errors visibly; background refresh stays quiet
                // so Finder is not spammed while the agent is starting.
            }
        }
    }

    // MARK: Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind == .contextualMenuForItems else { return menu }
        refreshMonitoredDirectories()

        let submenu = NSMenu(title: "TinyPrune")
        func add(_ title: String, _ action: Action) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            submenu.addItem(item)
        }
        add("Keep", .keep)
        add("Expire Tonight", .tonight)
        add("Tomorrow", .tomorrow)
        add("7 Days", .sevenDays)
        add("30 Days", .thirtyDays)
        add("Custom…", .customExpiry)
        add("Use Folder Rules", .inherit)
        add("Why will this expire?", .why)

        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        if urls.contains(where: Self.isDirectory) {
            submenu.addItem(.separator())
            add("Set Folder Lifetime…", .folderLifetime)
            add("Protect Folder (Keep Contents)", .protectFolder)
            add("Create Rule…", .createRule)
        }

        let root = NSMenuItem(title: "TinyPrune", action: nil, keyEquivalent: "")
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: Actions

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = Action(rawValue: sender.tag) else { return }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else {
            Self.showAlert(title: "Nothing selected", message: "TinyPrune could not read the Finder selection.")
            return
        }
        let client = self.client
        Task { @MainActor in
            await Self.run(action, urls: urls, client: client)
        }
    }

    @MainActor
    private static func run(_ action: Action, urls: [URL], client: TinyPruneAgentClient) async {
        switch action {
        case .folderLifetime, .createRule:
            let directories = urls.filter(isDirectory)
            for url in directories {
                openApp(route: action == .createRule ? "rule" : "folder", path: url.path)
            }
        case .customExpiry:
            for url in urls.prefix(1) { openApp(route: "expire", path: url.path) }
        case .keep:
            await mutate(urls, client: client, success: "Kept") { .setItemOverride(path: $0, policy: .keep(protectDescendants: false)) }
        case .protectFolder:
            await mutate(urls.filter(isDirectory), client: client, success: "Protected") {
                .setItemOverride(path: $0, policy: .keep(protectDescendants: true))
            }
        case .inherit:
            await mutate(urls, client: client, success: "Now uses folder rules for") { .clearItemOverride(path: $0) }
        case .tonight, .tomorrow, .sevenDays, .thirtyDays:
            let date = expiry(for: action, now: Date())
            await mutate(urls, client: client, success: "Expiry set for") {
                .setItemOverride(path: $0, policy: .customExpiry(date, state: .active))
            }
        case .why:
            await explain(urls, client: client)
        }
    }

    private static func expiry(for action: Action, now: Date) -> Date {
        let calendar = Calendar.current
        switch action {
        case .tonight:
            let tonight = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
            return tonight > now ? tonight : now.addingTimeInterval(3_600)
        case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        case .sevenDays: return now.addingTimeInterval(7 * 86_400)
        default: return now.addingTimeInterval(30 * 86_400)
        }
    }

    @MainActor
    private static func mutate(
        _ urls: [URL],
        client: TinyPruneAgentClient,
        success: String,
        operation: (String) -> AgentOperation
    ) async {
        var failures: [String] = []
        var succeeded = 0
        for url in urls {
            do {
                let response = try await client.request(AgentRequest(operation: operation(url.path)))
                switch response.payload {
                case .acknowledged: succeeded += 1
                default: throw FinderFailure.unexpected(response.payload)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(describe(error))")
            }
        }
        if !failures.isEmpty {
            showAlert(
                title: "TinyPrune could not update \(failures.count) item\(failures.count == 1 ? "" : "s")",
                message: failures.joined(separator: "\n")
            )
        } else if succeeded > 0 {
            notify(title: "TinyPrune", body: "\(success) \(succeeded) item\(succeeded == 1 ? "" : "s").")
        }
    }

    @MainActor
    private static func explain(_ urls: [URL], client: TinyPruneAgentClient) async {
        var sections: [String] = []
        for url in urls.prefix(5) {
            do {
                let response = try await client.request(AgentRequest(operation: .explainItem(path: url.path)))
                guard case .itemExplanation(let explanation) = response.payload else {
                    throw FinderFailure.unexpected(response.payload)
                }
                sections.append(summary(explanation))
            } catch {
                sections.append("\(url.path)\nCould not explain: \(describe(error))")
            }
        }
        if urls.count > 5 { sections.append("…and \(urls.count - 5) more selected items.") }
        showAlert(title: "Why will this expire?", message: sections.joined(separator: "\n\n"))
    }

    private static func summary(_ explanation: AgentItemExplanation) -> String {
        var lines = [explanation.path]
        switch explanation.resolution {
        case .scheduled(let item):
            lines.append("Scheduled: \(item.scheduledAt.formatted(date: .abbreviated, time: .shortened)) (\(item.disposition.rawValue))")
            lines.append("Matched rule: \(item.matchedRuleName)")
            lines.append("Reason: \(item.expiryBasis.rawValue) since \(item.basisDate.formatted(date: .abbreviated, time: .shortened))")
        case .customExpiry(let item):
            lines.append("Scheduled: \(item.expiresAt.formatted(date: .abbreviated, time: .shortened)) (\(item.disposition.rawValue))")
            lines.append("Reason: explicit expiry set on this item")
        case .protected(let item):
            lines.append("Protected by Keep on \(item.protectedPath)\(item.protectsDescendants ? " (including descendants)" : "")")
        case .suppressed(let reason):
            lines.append("Not scheduled: \(reason.rawValue)")
        case .noRule:
            lines.append("No rule applies; TinyPrune will do nothing.")
        case .ambiguousRules(let ids):
            lines.append("Not scheduled: \(ids.count) rules tie; TinyPrune will not guess.")
        case .ambiguousOverrides(let ids):
            lines.append("Not scheduled: \(ids.count) conflicting overrides.")
        }
        if explanation.globallyPaused { lines.append("TinyPrune is paused globally.") }
        return lines.joined(separator: "\n")
    }

    // MARK: Presentation

    private enum FinderFailure: Error {
        case unexpected(AgentResponsePayload)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case AgentClientError.unavailable:
            return "The TinyPrune agent is not running or is unreachable. Open TinyPrune and make sure its background agent is enabled."
        case AgentClientError.unsupportedProtocol(let version):
            return "The agent speaks protocol version \(version), which this Finder extension does not support. Update TinyPrune."
        case AgentClientError.invalidReply, AgentClientError.encodingFailed:
            return "The agent sent an unreadable reply."
        case FinderFailure.unexpected(.failure(let failure)):
            switch failure {
            case .invalidRequest(let message): return "The agent rejected the request: \(message)"
            case .storageUnavailable(let message): return "The agent's storage is unavailable: \(message)"
            case .unsupportedProtocol(let expected, let received):
                return "Protocol mismatch (agent expects \(expected), extension sent \(received))."
            }
        case FinderFailure.unexpected:
            return "The agent returned an unexpected response."
        default:
            return error.localizedDescription
        }
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Success confirmation only; failures always use a modal alert. Delivery is best effort
    /// because the user may not have granted notification permission to the extension.
    private static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func openApp(route: String, path: String) {
        var components = URLComponents()
        components.scheme = "tinyprune"
        components.host = route
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            showAlert(title: "TinyPrune could not be opened", message: "No application handles tinyprune:// URLs. Install TinyPrune.app and open it once.")
            return
        }
    }
}
