import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import TinyPruneDomain
import TinyPruneIPC

// MARK: - Activity

struct ActivityPage: View {
    @EnvironmentObject private var model: AgentViewModel

    private var days: [(day: Date, items: [AgentActivityItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.activity) { calendar.startOfDay(for: $0.occurredAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0, default: []].sorted { $0.occurredAt > $1.occurredAt }) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if model.activity.isEmpty {
                    ContentUnavailableView(
                        "No activity yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Rule changes, protections, and every move to Trash are recorded here. Audit history stays on this Mac.")
                    )
                    .frame(maxWidth: .infinity)
                }
                ForEach(days, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(group.day.formatted(date: .complete, time: .omitted)).padding(.bottom, 8)
                        ForEach(group.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(item.occurredAt.formatted(date: .omitted, time: .shortened))
                                    .font(Typography.mono(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).foregroundStyle(item.isAttention ? PrunePalette.caution : .primary)
                                    if let path = item.identity?.pathHint { PathText(path: path) }
                                    if item.isAttention, let detail = item.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Templates

struct TemplatesPage: View {
    @State private var applying: RuleTemplate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Templates create ordinary rules you can edit, pause, or delete. Nothing is hidden.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 18)
                ForEach(RuleTemplate.allCases) { template in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(template.title).font(Typography.display(size: 20))
                                if template.isBroad { Pill(text: "Starts in Preview", color: PrunePalette.caution) }
                            }
                            Text(template.summary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use template…") { applying = template }
                    }
                    .padding(.vertical, 16)
                    Divider()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $applying) { TemplateApplySheet(template: $0) }
    }
}

package struct TemplateApplySheet: View {
    @EnvironmentObject private var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("previewBroadByDefault") private var previewByDefault = true

    let template: RuleTemplate
    /// A folder already inside a managed root (from Finder's "Set Folder Lifetime…"); no new bookmark is needed.
    var prefillPath: String? = nil

    package init(template: RuleTemplate, prefillPath: String? = nil) {
        self.template = template
        self.prefillPath = prefillPath
    }

    @State private var folder: ChosenFolder?
    @State private var startInPreview = true
    @State private var temporaryDays = 3.0
    @State private var isSaving = false
    @State private var errorMessage: String?

    package var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(template.title).font(Typography.display(size: 27))
            Text(template.summary).foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder")
                    Text(folder?.root.path ?? prefillPath ?? "Choose a folder to continue")
                        .font(Typography.mono(size: 12, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose folder…") { choose() }
            }
            if template == .temporaryWorkspace {
                Stepper("Expire after \(Int(temporaryDays)) day\(temporaryDays == 1 ? "" : "s")", value: $temporaryDays, in: 1...365)
            }
            if folder?.isVeryBroad == true {
                Label("This is a very broad folder, so the rules will start in Preview. Specific folders are recommended.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(PrunePalette.caution)
            } else {
                Toggle("Start in Preview", isOn: $startInPreview)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create rules") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled((folder == nil && prefillPath == nil) || isSaving)
            }
        }
        .padding(28)
        .frame(width: 540)
        .onAppear { startInPreview = previewByDefault || template.isBroad }
        .alert("Could not create rules", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func choose() {
        do {
            let start: URL? = switch template {
            case .downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            case .screenshots: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            default: nil
            }
            if let chosen = try ChosenFolder.choose(startingAt: start) { folder = chosen }
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func create() async {
        let scopePath = folder?.root.path ?? prefillPath
        guard let scopePath else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let state: RuleState = (startInPreview || folder?.isVeryBroad == true) ? .preview : .active
            let rules = try template.rules(in: scopePath, state: state, temporaryLifetime: temporaryDays * 86_400)
            try await model.addRules(rules, in: folder)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @EnvironmentObject private var model: AgentViewModel
    let overview: AgentOverviewSnapshot

    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("previewBroadByDefault") private var previewByDefault = true
    @State private var launchesAtLogin = false
    @State private var errorMessage: String?
    @State private var isRebuilding = false
    @State private var pendingImport: ImportPreview?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin }, set: { enabled in setLaunchAtLogin(enabled) }))
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle("Notify only when attention is needed", isOn: $notificationsEnabled)
                LabeledContent("Background agent", value: agentStatus)
            }
            Section("Safety") {
                Toggle("Pause all rules", isOn: Binding(
                    get: { overview.policy.globallyPaused },
                    set: { paused in run { try await model.setGlobalPause(paused) } }
                ))
                Toggle("Start new template rules in Preview", isOn: $previewByDefault)
                Picker("Default grace period", selection: Binding(
                    get: { model.settings.defaultGracePeriodSeconds },
                    set: { value in updateSettings { $0.defaultGracePeriodSeconds = value } }
                )) {
                    Text("None").tag(0.0)
                    Text("1 hour").tag(3_600.0)
                    Text("6 hours").tag(21_600.0)
                    Text("1 day").tag(86_400.0)
                }
                Toggle("Protect hidden files", isOn: Binding(
                    get: { model.settings.protectHiddenFiles },
                    set: { value in updateSettings { $0.protectHiddenFiles = value } }
                ))
                Text("Hidden items are skipped unless a rule names a dot-folder such as .venv. Grace applies to rules that set none of their own.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Everything TinyPrune removes goes to the macOS Trash. Keep always takes precedence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Scheduled items", value: overview.indexedItems.formatted())
                LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: overview.databaseBytes, countStyle: .file))
                Picker("Activity history", selection: Binding(
                    get: { model.settings.activityRetentionDays },
                    set: { value in updateSettings { $0.activityRetentionDays = value } }
                )) {
                    Text("Keep forever").tag(0)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                    Text("7 days").tag(7)
                }
                HStack {
                    Button("Rebuild index") {
                        isRebuilding = true
                        run { defer { isRebuilding = false }; try await model.rebuildIndex() }
                    }
                    .disabled(isRebuilding)
                    Button("Export activity log…", action: exportActivity)
                }
            }
            Section("Developer") {
                LabeledContent("Install CLI") {
                    Text("ln -sf \"\(cliPath)\" /usr/local/bin/tinyprune")
                        .font(Typography.mono(size: 12, relativeTo: .caption))
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Export configuration…", action: exportConfig)
                    Button("Import configuration…", action: importConfig)
                }
                Text("The same files work with `tinyprune config validate|preview|apply`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchesAtLogin = model.services.launchesAtLogin }
        .scrollContentBackground(.hidden)
        .alert("Settings", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(item: $pendingImport) { preview in
            ConfigImportSheet(preview: preview)
        }
    }

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tinyprune").path
    }

    private var agentStatus: String {
        switch model.registrationStatus {
        case .enabled: "Running"
        case .requiresApproval: "Needs approval in Login Items"
        case .notRegistered: "Not installed"
        case .notFound: "Unavailable in this build"
        @unknown default: "Unknown"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try model.services.setLaunchAtLogin(enabled)
        } catch {
            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
        }
        launchesAtLogin = model.services.launchesAtLogin
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func updateSettings(_ change: @escaping (inout AgentSettings) -> Void) {
        var updated = model.settings
        change(&updated)
        run { try await model.updateSettings(updated) }
    }

    private func exportConfig() {
        guard let policy = model.policy else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tinyprune.yml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ConfigDocument.render(policy: policy.rules, roots: policy.managedRoots, overrides: policy.overrides)
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = "Could not export the configuration: \(error.localizedDescription)" }
    }

    private func importConfig() {
        guard let policy = model.policy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let document = try ConfigDocument.parse(text, homeDirectory: NSHomeDirectory())
            try document.validate()
            let plan = try ConfigPlan.make(
                document: document, currentRules: policy.rules, currentRoots: policy.managedRoots,
                currentOverrides: policy.overrides, activate: false
            )
            pendingImport = ImportPreview(fileName: url.lastPathComponent, plan: plan)
        } catch let error as ConfigError {
            errorMessage = "\(url.lastPathComponent): \(error.description)"
        } catch {
            errorMessage = "Could not read the configuration: \(error.localizedDescription)"
        }
    }

    private func exportActivity() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TinyPrune-activity.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(model.activity).write(to: url, options: .atomic) }
        catch { errorMessage = "Could not export the activity log: \(error.localizedDescription)" }
    }
}

package struct ImportPreview: Identifiable {
    package let id = UUID()
    let fileName: String
    let plan: ConfigPlan

    package init(fileName: String, plan: ConfigPlan) {
        self.fileName = fileName
        self.plan = plan
    }
}

package struct ConfigImportSheet: View {
    @EnvironmentObject private var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    let preview: ImportPreview

    package init(preview: ImportPreview) { self.preview = preview }

    @State private var errorMessage: String?
    @State private var isApplying = false

    package var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import \(preview.fileName)").font(Typography.display(size: 27))
            ScrollView {
                Text(preview.plan.summaryLines.joined(separator: "\n"))
                    .font(Typography.mono(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            if !preview.plan.isApplicable {
                Label("Add the unmanaged folders in TinyPrune first. Only the app can grant folder access.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(PrunePalette.caution)
            } else if preview.plan.addsPreviewRules {
                Text("New rules start in Preview.").foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(PrunePalette.caution) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    isApplying = true
                    Task {
                        defer { isApplying = false }
                        do { _ = try await model.applyConfig(preview.plan); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!preview.plan.isApplicable || isApplying)
            }
        }
        .padding(28)
        .frame(width: 560, height: 420)
    }
}
