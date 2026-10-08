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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(monitoringContextChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(monitoringContextChanged(_:)),
            name: NSWorkspace.didMountNotification, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(monitoringContextChanged(_:)),
            name: Notification.Name("com.navig-me.tinyprune.managedRootsChanged"), object: nil
        )
        refreshMonitoredDirectories()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Monitoring

    override func beginObservingDirectory(at url: URL) {
        refreshMonitoredDirectories()
    }

    @objc private func monitoringContextChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didLaunchApplicationNotification {
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier == "com.navig-me.tinyprune" else { return }
        }
        refreshMonitoredDirectories()
    }

    private var refreshInFlight = false
    private var monitoredRoots: Set<URL> = []

    private func refreshMonitoredDirectories() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let client = self.client
        Task { @MainActor in
            defer { self.refreshInFlight = false }
            do {
                let response = try await client.request(AgentRequest(operation: .loadRoots))
                guard case .roots(let roots) = response.payload else {
                    throw FinderFailure.unexpected(response.payload)
                }
                let urls = Set(roots.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
                // Reassigning identical roots would make Finder call beginObservingDirectory again.
                if urls != self.monitoredRoots {
                    self.monitoredRoots = urls
                    FIFinderSyncController.default().directoryURLs = urls
                }
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
        // Roots are refreshed on launch, mount, and root-change notifications, never per menu build.

        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return menu }
        let submenu = NSMenu(title: "TinyPrune")
        submenu.autoenablesItems = false
        func add(_ title: String, _ action: Action, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            submenu.addItem(item)
            item.representedObject = urls
            item.isEnabled = enabled
        }
        add("Keep", .keep)
        add("Expire Tonight", .tonight)
        add("Tomorrow", .tomorrow)
        add("7 Days", .sevenDays)
        add("30 Days", .thirtyDays)
        // App handoffs open a single editor; never silently discard a multi-selection.
        add("Custom…", .customExpiry, enabled: urls.count == 1)
        add("Use Folder Rules", .inherit)
        add("Why will this expire?", .why)

        if urls.contains(where: Self.isDirectory) {
            submenu.addItem(.separator())
            add("Set Folder Lifetime…", .folderLifetime, enabled: urls.count == 1)
            add("Protect Folder (Keep Contents)", .protectFolder)
            add("Create Rule…", .createRule, enabled: urls.count == 1)
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
        let urls = sender.representedObject as? [URL] ?? []
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
            guard urls.count == 1, let url = urls.first, isDirectory(url) else {
                showAlert(title: "Select one folder", message: "Select a single folder to open its TinyPrune editor.")
                return
            }
            openApp(route: action == .createRule ? "rule" : "folder", path: url.path)
        case .customExpiry:
            guard urls.count == 1, let url = urls.first else {
                showAlert(title: "Select one item", message: "Select a single file or folder to set a custom expiry.")
                return
            }
            openApp(route: "expire", path: url.path)
        case .keep:
            await apply(.keep(protectDescendants: false), to: urls, client: client, success: "Kept")
        case .protectFolder:
            await apply(.keep(protectDescendants: true), to: urls.filter(isDirectory), client: client, success: "Protected")
        case .inherit:
            await apply(nil, to: urls, client: client, success: "Now uses folder rules for")
        case .tonight, .tomorrow, .sevenDays, .thirtyDays:
            let date = preset(for: action).date(from: Date(), calendar: .current)
            await apply(.customExpiry(date, state: .active), to: urls, client: client, success: "Expiry set for")
        case .why:
            await explain(urls, client: client)
        }
    }

    private static func preset(for action: Action) -> ExpiryPreset {
        switch action {
        case .tonight: return .tonight
        case .tomorrow: return .tomorrow
        case .sevenDays: return .days(7)
        default: return .days(30)
        }
    }

    /// One batched, atomic request for the whole selection. `policy == nil` clears the override.
    @MainActor
    private static func apply(
        _ policy: ItemOverridePolicy?,
        to urls: [URL],
        client: TinyPruneAgentClient,
        success: String
    ) async {
        guard !urls.isEmpty else { return }
        let changes = urls.map { AgentItemOverrideChange(path: $0.path, policy: policy) }
        let noun = "item\(urls.count == 1 ? "" : "s")"
        do {
            let response = try await client.request(AgentRequest(operation: .setItemOverrides(changes: changes)))
            switch response.payload {
            case .acknowledged: notify(title: "TinyPrune", body: "\(success) \(urls.count) \(noun).")
            case .failure(let failure): throw FinderFailure.service(failure)
            default: throw FinderFailure.unexpected(response.payload)
            }
        } catch {
            showAlert(title: "TinyPrune could not update \(urls.count) \(noun)", message: describe(error))
        }
    }

    @MainActor
    private static func explain(_ urls: [URL], client: TinyPruneAgentClient) async {
        var sections: [String] = []
        for url in urls.prefix(5) {
            do {
                let response = try await client.request(AgentRequest(operation: .explainItem(path: url.path)))
                if case .failure(let failure) = response.payload { throw FinderFailure.service(failure) }
                guard case .itemExplanation(let explanation) = response.payload else {
                    throw FinderFailure.unexpected(response.payload)
                }
                sections.append(ExplanationFormatter.summary(explanation, now: Date(), calendar: .current, locale: .current))
            } catch {
                sections.append("\(url.path)\nCould not explain: \(describe(error))")
            }
        }
        if urls.count > 5 { sections.append("…and \(urls.count - 5) more selected items.") }
        showAlert(title: "Why will this expire?", message: sections.joined(separator: "\n\n"))
    }

    // MARK: Presentation

    private enum FinderFailure: Error {
        case unexpected(AgentResponsePayload)
        case service(AgentServiceError)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case FinderFailure.service(let failure):
            return AgentErrorDescription.message(for: failure)
        case FinderFailure.unexpected:
            return "The agent returned an unexpected response."
        default:
            return AgentErrorDescription.message(for: error)
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
