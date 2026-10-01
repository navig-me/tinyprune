import SwiftUI
import AppKit
import TinyPruneDomain
import TinyPruneIPC
import ServiceManagement

@main
struct TinyPruneApp: App {
    var body: some Scene {
        WindowGroup {
            TinyPruneWindow()
                .frame(minWidth: 820, minHeight: 560)
                .tint(PrunePalette.plum)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case rules = "Rules"
    case upcoming = "Upcoming"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .rules: "slider.horizontal.3"
        case .upcoming: "clock"
        }
    }
}

private enum PrunePalette {
    static let plum = Color(red: 0.29, green: 0.12, blue: 0.24)
    static let canvas = Color(red: 0.985, green: 0.975, blue: 0.96)
    static let sidebar = Color(red: 0.955, green: 0.94, blue: 0.92)
}

@MainActor
private final class AgentViewModel: ObservableObject {
    @Published private(set) var overview: AgentOverviewSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshedAt: Date?

    private let client = TinyPruneAgentClient()
    private let launchAgent = SMAppService.agent(plistName: "com.navig-me.tinyprune.agent.plist")
    @Published private(set) var registrationStatus: SMAppService.Status = .notRegistered

    func refreshRegistrationStatus() {
        registrationStatus = launchAgent.status
    }

    func registerAgent() async {
        do {
            try launchAgent.register()
            refreshRegistrationStatus()
            await refresh()
        } catch {
            errorMessage = "Could not register the TinyPrune background agent: \(error)"
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
    func addPreviewRule(name: String, root: ManagedRoot, recursive: Bool) async throws {
        guard let current = overview?.policy else { throw PolicyMutationError.policyUnavailable }
        let rule = try LifetimeRule(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: RuleScope(path: root.path, recursive: recursive),
            matcher: ItemMatcher(itemKind: .fileOrDirectory, exactNames: []),
            expiryBasis: .modified,
            lifetime: RuleDuration(seconds: 30 * 86_400),
            action: .trashItem,
            state: .preview
        )
        try await replacePolicy(AgentPolicySnapshot(
            rules: current.rules + [rule],
            overrides: current.overrides,
            managedRoots: current.managedRoots + [root],
            globallyPaused: current.globallyPaused
        ))
        await refresh()
    }

    func setRuleState(_ ruleID: UUID, state: RuleState) async throws {
        guard let current = overview?.policy,
              let index = current.rules.firstIndex(where: { $0.id == ruleID }) else {
            throw PolicyMutationError.policyUnavailable
        }
        let old = current.rules[index]
        let updatedRule = try LifetimeRule(
            id: old.id,
            name: old.name,
            scope: old.scope,
            matcher: old.matcher,
            expiryBasis: old.expiryBasis,
            lifetime: old.lifetime,
            gracePeriod: old.gracePeriod,
            action: old.action,
            state: state,
            matchMode: old.matchMode
        )
        var rules = current.rules
        rules[index] = updatedRule
        try await replacePolicy(AgentPolicySnapshot(rules: rules, overrides: current.overrides, managedRoots: current.managedRoots, globallyPaused: current.globallyPaused))
        await refresh()
    }

    private func replacePolicy(_ snapshot: AgentPolicySnapshot) async throws {
        let response = try await client.request(AgentRequest(operation: .replacePolicy(snapshot)))
        switch response.payload {
        case .acknowledged:
            return
        case .failure(let error):
            throw PolicyMutationError.agentRejected(String(describing: error))
        default:
            throw PolicyMutationError.unexpectedResponse
        }
    }

    func refresh() async {
        registrationStatus = launchAgent.status
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await client.request(AgentRequest(operation: .loadOverview))
            switch response.payload {
            case .overview(let overview):
                self.overview = overview
                errorMessage = nil
                refreshedAt = Date()
            case .failure(let error):
                overview = nil
                errorMessage = "The TinyPrune agent could not load local state: \(error)"
            default:
                overview = nil
                errorMessage = "The TinyPrune agent returned an unexpected response."
            }
        } catch {
            overview = nil
            errorMessage = "The local TinyPrune agent is unavailable."
        }
    }
}
private enum PolicyMutationError: Error, LocalizedError {
    case policyUnavailable
    case agentRejected(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .policyUnavailable: "The current local policy is not loaded. Refresh and try again."
        case .agentRejected(let message): "The local agent rejected the policy update: \(message)"
        case .unexpectedResponse: "The local agent returned an unexpected response to the policy update."
        }
    }
}

private struct TinyPruneWindow: View {
    @StateObject private var model = AgentViewModel()
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .tag(section as AppSection?)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Label("TinyPrune", systemImage: "leaf.fill")
                    .font(.headline)
                    .foregroundStyle(PrunePalette.plum)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
            .background(PrunePalette.sidebar)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(PrunePalette.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            model.refreshRegistrationStatus()
            await model.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selection?.rawValue ?? "Overview")
                    .font(.system(size: 30, weight: .regular, design: .serif))
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.overview == nil {
            ProgressView("Connecting to the local agent")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Label("Agent unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                switch model.registrationStatus {
                case .notRegistered:
                    Button("Install background agent") { Task { await model.registerAgent() } }
                case .requiresApproval:
                    Button("Open Login Items") { model.openLoginItems() }
                case .notFound:
                    Text("This development executable has no embedded LaunchAgent. Package and open TinyPrune.app to install the helper.")
                        .foregroundStyle(.secondary)
                case .enabled:
                    EmptyView()
                @unknown default:
                    EmptyView()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let overview = model.overview {
            switch selection ?? .overview {
            case .overview: OverviewPage(overview: overview)
            case .rules:
                RulesPage(
                    rules: overview.policy.rules,
                    onAddPreviewRule: { name, root, recursive in
                        try await model.addPreviewRule(name: name, root: root, recursive: recursive)
                    },
                    onSetRuleState: { ruleID, state in
                        try await model.setRuleState(ruleID, state: state)
                    }
                )
            case .upcoming: UpcomingPage(items: overview.upcoming)
            }
        } else {
            ContentUnavailableView("No local state", systemImage: "leaf", description: Text("Refresh to load TinyPrune rules."))
        }
    }

    private var statusText: String {
        if model.isLoading { return "Refreshing local state" }
        if let refreshedAt = model.refreshedAt {
            return "Local agent connected · Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "Local-first file lifetimes"
    }
}

private struct OverviewPage: View {
    let overview: AgentOverviewSnapshot

    private var places: [ManagedRoot] {
        overview.policy.managedRoots.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    metric("Managed places", value: "\(places.count)")
                    metric("Rules", value: "\(overview.policy.rules.count)")
                    metric("Preview", value: "\(overview.policy.rules.filter { $0.state == .preview }.count)")
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Managed places").font(.system(size: 22, weight: .regular, design: .serif))
                    if places.isEmpty {
                        Text("No managed places are configured yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(places) { root in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(PrunePalette.plum)
                                VStack(alignment: .leading) {
                                    Text(root.displayName)
                                    Text(root.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(overview.policy.rules.filter { $0.scope.path == root.path || $0.scope.path.hasPrefix(root.path + "/") }.count) rules")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Next to prune").font(.system(size: 22, weight: .regular, design: .serif))
                    if let next = overview.upcoming.first {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(next.explanation.candidateIdentity.pathHint)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Text("\(next.explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened)) · \(next.explanation.matchedRuleName) · \(next.explanation.disposition.rawValue.capitalized)")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No items are scheduled.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 28, weight: .regular, design: .serif))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RulesPage: View {
    let rules: [LifetimeRule]
    let onAddPreviewRule: (String, ManagedRoot, Bool) async throws -> Void
    let onSetRuleState: (UUID, RuleState) async throws -> Void

    @State private var isShowingEditor = false
    @State private var mutationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rules")
                    .font(.system(size: 22, weight: .regular, design: .serif))
                Spacer()
                Button("New Preview rule") { isShowingEditor = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if rules.isEmpty {
                        Text("No rules configured. Add a scoped rule and review it in Preview.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                    }
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(rule.name)
                                    .font(.system(size: 20, weight: .regular, design: .serif))
                                Spacer()
                                Text(rule.state.rawValue.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(PrunePalette.sidebar, in: Capsule())
                                Button(rule.state == .paused ? "Resume in Preview" : "Pause") {
                                    let newState: RuleState = rule.state == .paused ? .preview : .paused
                                    Task {
                                        do { try await onSetRuleState(rule.id, newState) }
                                        catch { mutationError = String(describing: error) }
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(description(for: rule))
                            Text(rule.scope.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(32)
            }
        }
        .sheet(isPresented: $isShowingEditor) {
            NewPreviewRuleSheet(onSave: onAddPreviewRule)
        }
        .alert("Could not update rule", isPresented: Binding(
            get: { mutationError != nil },
            set: { if !$0 { mutationError = nil } }
        )) {
            Button("OK", role: .cancel) { mutationError = nil }
        } message: {
            Text(mutationError ?? "")
        }
    }

    private func description(for rule: LifetimeRule) -> String {
        let names = (rule.matcher.exactNames.sorted() + rule.matcher.globPatterns.sorted()).joined(separator: ", ")
        let target = names.isEmpty ? "all \(rule.matcher.itemKind.rawValue) items" : names
        let action: String
        switch rule.action {
        case .trashItem: action = "move matches to Trash"
        case .emptyContents: action = "empty folder contents to Trash"
        case .trashMatchingChildren: action = "move matching children to Trash"
        }
        let stateText = rule.state == .preview ? "Preview only: would" : rule.state == .paused ? "Paused: would" : "When due, will"
        return "\(stateText) match \(target) based on \(rule.expiryBasis.rawValue) for \(duration(rule.lifetime.seconds)), then \(action)."
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let day: TimeInterval = 86_400
        if seconds.truncatingRemainder(dividingBy: day) == 0 { return "\(Int(seconds / day)) days" }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600)) hours" }
        return "\(Int(seconds)) seconds"
    }
}

private struct NewPreviewRuleSheet: View {
    let onSave: (String, ManagedRoot, Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = "Temporary items"
    @State private var selectedFolder: URL?
    @State private var recursive = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New Preview rule")
                    .font(.system(size: 27, weight: .regular, design: .serif))
                Text("Stores a Preview-only rule. Folder indexing and live match previews are not enabled yet.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Rule name", text: $name)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Managed folder")
                        Text(selectedFolder?.path ?? "Choose a folder to continue")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Choose folder…", action: chooseFolder)
                }
                Toggle("Include subfolders", isOn: $recursive)
                LabeledContent("Match", value: "All files and folders")
                LabeledContent("Expiry", value: "30 days after last modification")
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save as Preview") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFolder == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(28)
        .frame(width: 560, height: 430)
        .alert("Could not save Preview rule", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK { selectedFolder = panel.url }
    }

    @MainActor
    private func save() async {
        guard let selectedFolder else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let path = selectedFolder.standardizedFileURL.path
            let bookmark = try selectedFolder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let root = try ManagedRoot(displayName: selectedFolder.lastPathComponent, path: path, bookmarkData: bookmark)
            try await onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), root, recursive)
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private struct UpcomingPage: View {
    let items: [AgentUpcomingItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("No items are scheduled.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.explanation.candidateIdentity.pathHint)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("\(item.explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened)) · \(item.explanation.matchedRuleName) · \(item.explanation.disposition.rawValue.capitalized)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                    Divider()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
