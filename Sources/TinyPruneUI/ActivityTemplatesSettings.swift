import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import TinyPruneDomain
import TinyPruneIPC

// MARK: - Activity

package struct ActivitySummary {
    package let movedCount: Int
    package let safetySkippedCount: Int
    package let lastCleanup: Date?

    package init(events: [AgentActivityItem]) {
        var moved = 0
        var skipped = 0
        var last: Date?
        for event in events {
            if event.kind == .movedToTrash {
                moved += 1
                last = max(last ?? event.occurredAt, event.occurredAt)
            } else if event.kind == .safetySkipped {
                skipped += 1
            }
        }
        movedCount = moved
        safetySkippedCount = skipped
        lastCleanup = last
    }

    package var text: String {
        let cleanup = lastCleanup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none recorded"
        return "In loaded activity: \(movedCount.formatted()) \(movedCount == 1 ? "item" : "items") moved to Trash; \(safetySkippedCount.formatted()) \(safetySkippedCount == 1 ? "item" : "items") skipped for safety. Last cleanup: \(cleanup)."
    }
}

/// Reveals only the destination recorded by the agent; never restores or moves an item.
@MainActor
package struct ActivityTrashReveal {
    private let exists: (String) -> Bool
    private let reveal: ([URL]) -> Void

    package init(
        exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.exists = exists
        self.reveal = reveal
    }

    package func destination(for item: AgentActivityItem) -> URL? {
        guard item.kind == .movedToTrash, let path = item.detail, path.hasPrefix("/"), exists(path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    package func show(_ item: AgentActivityItem) -> Bool {
        guard let url = destination(for: item) else { return false }
        reveal([url])
        return true
    }
}

package struct ActivityTrashRecovery: View {
    package let item: AgentActivityItem
    private let action: ActivityTrashReveal
    private let shortcut: KeyboardShortcut?
    @Environment(\.scenePhase) private var scenePhase
    @State private var available = false

    package init(item: AgentActivityItem, action: ActivityTrashReveal = ActivityTrashReveal(), shortcut: KeyboardShortcut? = nil) {
        self.item = item
        self.action = action
        self.shortcut = shortcut
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let path = item.detail { PathText(path: path) }
            Button("Show in Trash") { available = action.show(item) }
                .buttonStyle(PruneButtonStyle())
                .keyboardShortcut(shortcut)
                .disabled(!available)
                .accessibilityLabel("Show \(item.identity?.pathHint ?? "item") in Trash")
                .help("Reveal the recorded Trash location in Finder. This does not restore the item.")
            if !available {
                Text("No longer in Trash").font(.manropeCaption).foregroundStyle(.secondary)
            }
            Text("To restore, use Finder’s Put Back in Trash, if available. TinyPrune does not restore items.")
                .font(.manropeCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { available = action.destination(for: item) != nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { available = action.destination(for: item) != nil }
        }
    }
}

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
                Text(ActivitySummary(events: model.activity).text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
                if model.activity.isEmpty {
                    PruneEmptyState(title: "A quiet beginning", message: "Rule changes, protections, and every move to Trash are recorded here. Audit history stays on this Mac.", symbol: "list.bullet.rectangle")
                }
                ForEach(days, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(group.day.formatted(date: .complete, time: .omitted)).padding(.bottom, 8)
                        ForEach(group.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Image(systemName: item.kind == .movedToTrash ? "checkmark.circle.fill" : item.isAttention ? "exclamationmark.circle" : "circle")
                                    .foregroundStyle(item.kind == .movedToTrash ? PrunePalette.safe : item.isAttention ? PrunePalette.caution : PrunePalette.plum)
                                    .pruneBounce(value: model.isLoading)
                                    .accessibilityHidden(true)
                                Text(item.occurredAt.formatted(date: .omitted, time: .shortened))
                                    .font(Typography.mono(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).foregroundStyle(item.isAttention ? PrunePalette.caution : .primary)
                                    if let path = item.identity?.pathHint { PathText(path: path) }
                                    if item.isAttention, let detail = item.detail {
                                        Text(detail).font(.manropeCaption).foregroundStyle(.secondary)
                                    }
                                    if item.kind == .movedToTrash {
                                        ActivityTrashRecovery(item: item)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .pruneHover()
                            .transition(.opacity)
                            Divider()
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pruneAnimation(value: model.activity.map(\.id))
        .sensoryFeedback(.success, trigger: model.activity.filter { $0.kind == .movedToTrash }.count)
        .font(.manropeBody)
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
                            .accessibilityLabel("Use \(template.title) template")
                    }
                    .padding(.vertical, 16)
                    .pruneHover()
                    Divider()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.manropeBody)
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
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text(template.title).font(Typography.display(size: 27))
            Text(template.summary).foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder")
                    if let path = folder?.root.path ?? prefillPath {
                        PathText(path: path)
                    } else {
                        Text("Choose a folder to continue").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Choose folder…") { choose() }
            }
            if template == .temporaryWorkspace {
                Stepper("Expire after \(Int(temporaryDays)) day\(temporaryDays == 1 ? "" : "s")", value: $temporaryDays, in: 1...365)
                Label("Everything placed directly in this folder expires after this time, including items already there. Choose a dedicated scratch folder, never Desktop or Documents.", systemImage: "exclamationmark.triangle")
                    .font(.manropeSubheadline)
                    .foregroundStyle(PrunePalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if forcesPreview {
                Label(
                    template.isBroad
                        ? "This template reaches deep through project folders, so its rules always start in Preview."
                        : "This is a very broad folder, so the rules will start in Preview. Specific folders are recommended.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.manropeSubheadline)
                .foregroundStyle(PrunePalette.caution)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Start in Preview", isOn: $startInPreview)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create rules") { Task { await create() } }
                    .buttonStyle(PruneButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled((folder == nil && prefillPath == nil) || isSaving)
            }
        }
        .padding(28)
        }
        .font(.manropeBody)
        .frame(minWidth: 540, idealWidth: 540, maxWidth: 760, maxHeight: 700)
        .onAppear { startInPreview = previewByDefault || forcesPreview }
        .alert("Could not create rules", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func choose() {
        do {
            let start: URL? = switch template {
            case .downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            case .screenshots: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            default:
                // Presets for tools such as Xcode or pip name their usual folder; open there only if it exists.
                template.suggestedFolder
                    .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            }
            if let chosen = try ChosenFolder.choose(startingAt: start) { folder = chosen }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Broad templates and very broad folders may only start in Preview.
    private var forcesPreview: Bool {
        if template.isBroad { return true }
        if folder?.root.isVeryBroad == true { return true }
        let path = folder?.root.path ?? prefillPath
        return path.map { RuleScope.isVeryBroad(path: $0) } ?? false
    }

    @MainActor
    private func create() async {
        let scopePath = folder?.root.path ?? prefillPath
        guard let scopePath, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let state: RuleState = (forcesPreview || startInPreview) ? .preview : .active
            let rules = try template.rules(in: scopePath, state: state, temporaryLifetime: temporaryDays * 86_400)
            // One atomic policy write: either every rule (and its folder) is added, or nothing is.
            try await model.addRules(rules, folders: folder.map { [$0] } ?? [])
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

package struct ConfigExportReview {
    package let text: String
    package let exportedCount: Int
    package let skippedCount: Int
    package let omissions: [String]

    package init(policy: AgentPolicySnapshot) throws {
        text = ConfigDocument.render(policy: policy.rules, roots: policy.managedRoots, overrides: policy.overrides)
        let document = try ConfigDocument.parse(text, homeDirectory: NSHomeDirectory())
        // The config format writes each supported rule once for its roots, so rules are counted once, not per root.
        exportedCount = document.rules.count
        skippedCount = max(0, policy.rules.count - exportedCount)
        omissions = text.split(separator: "\n").filter { $0.hasPrefix("# - ") }.map { String($0.dropFirst(4)) }
    }

    package var summary: String {
        "\(exportedCount.formatted()) rules exported; \(skippedCount.formatted()) rules skipped." +
            (omissions.isEmpty ? "" : "\nNot exported:\n" + omissions.joined(separator: "\n"))
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @EnvironmentObject private var model: AgentViewModel
    let overview: AgentOverviewSnapshot

    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("checkForNewVersions") private var checkForNewVersions = true
    @AppStorage("previewBroadByDefault") private var previewByDefault = true
    @State private var launchesAtLogin = false
    @State private var errorMessage: String?
    @State private var backupMessage: String?
    @State private var isRebuilding = false
    @State private var pendingImport: ImportPreview?
    @State private var pendingRetention: Int?
    @State private var confirmsRebuild = false
    @State private var customGraceActive = false
    @State private var customGraceHours = ""
    @State private var copiedCommand = false

    private static let customGraceTag = -1.0
    private static let gracePresets: [Double] = [0, 3_600, 21_600, 86_400]
    private static let maximumGraceHours = 365.0 * 24

    private static func formatHours(_ seconds: Double) -> String {
        (seconds / 3_600).formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
    }

    private var graceSelection: Double {
        let current = model.settings.defaultGracePeriodSeconds
        if customGraceActive || !Self.gracePresets.contains(current) { return Self.customGraceTag }
        return current
    }

    private func selectGrace(_ value: Double) {
        if value == Self.customGraceTag {
            customGraceActive = true
            customGraceHours = Self.formatHours(model.settings.defaultGracePeriodSeconds)
        } else {
            customGraceActive = false
            updateSettings { $0.defaultGracePeriodSeconds = value }
        }
    }

    private func applyCustomGrace() {
        let text = customGraceHours.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Double(text) ?? (try? Double(text, format: .number))
        guard let hours = parsed, hours.isFinite, hours >= 0, hours <= Self.maximumGraceHours else {
            errorMessage = "Enter a grace period between 0 and 8,760 hours."
            return
        }
        customGraceActive = false
        updateSettings { $0.defaultGracePeriodSeconds = hours * 3_600 }
    }

    /// Shortening history deletes audit entries, so it is confirmed; lengthening is applied immediately.
    private func setRetention(_ days: Int) {
        let current = model.settings.activityRetentionDays
        let shrinks = days != 0 && (current == 0 || days < current)
        if shrinks { pendingRetention = days } else { updateSettings { $0.activityRetentionDays = days } }
    }

    private var installCommand: String {
        "mkdir -p /usr/local/bin && ln -s \"\(cliPath)\" /usr/local/bin/tinyprune"
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin }, set: { enabled in setLaunchAtLogin(enabled) }))
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle("Notify only when attention is needed", isOn: $notificationsEnabled)
                Toggle("Check for new versions", isOn: $checkForNewVersions)
                Text("TinyPrune checks for new versions using its verified update feed, or GitHub when in-app installation is unavailable. Nothing about your files or rules is sent, and nothing is installed without your click. Turn off to stop automatic update checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Background agent", value: agentStatus)
            }
            Section("Safety") {
                Toggle("Pause all rules", isOn: Binding(
                    get: { overview.policy.globallyPaused },
                    set: { paused in run { try await model.setGlobalPause(paused) } }
                ))
                Toggle("Start new template rules in Preview", isOn: $previewByDefault)
                Picker("Default grace period", selection: Binding(
                    get: { graceSelection },
                    set: { value in selectGrace(value) }
                )) {
                    Text("None").tag(0.0)
                    Text("1 hour").tag(3_600.0)
                    Text("6 hours").tag(21_600.0)
                    Text("1 day").tag(86_400.0)
                    Text("Custom…").tag(Self.customGraceTag)
                }
                if graceSelection == Self.customGraceTag {
                    HStack {
                        TextField("Hours", text: $customGraceHours)
                            .frame(width: 80)
                            .accessibilityLabel("Custom default grace period in hours")
                            .onSubmit(applyCustomGrace)
                        Text("hours")
                        Button("Set", action: applyCustomGrace)
                    }
                }
                Toggle("Protect hidden files", isOn: Binding(
                    get: { model.settings.protectHiddenFiles },
                    set: { value in updateSettings { $0.protectHiddenFiles = value } }
                ))
                Text("Hidden items are skipped unless a rule names a dot-folder such as .venv. Grace applies to rules that set none of their own.")
                    .font(.manropeCaption).foregroundStyle(.secondary)
                Text("Everything TinyPrune removes goes to the macOS Trash, where it stays until you or macOS empty it. Keep always takes precedence.")
                    .font(.manropeCaption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Scheduled items", value: overview.indexedItems.formatted())
                LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: overview.databaseBytes, countStyle: .file))
                Picker("Activity history", selection: Binding(
                    get: { model.settings.activityRetentionDays },
                    set: { value in setRetention(value) }
                )) {
                    Text("Keep forever").tag(0)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                    Text("7 days").tag(7)
                    if ![0, 90, 30, 7].contains(model.settings.activityRetentionDays) {
                        Text("\(model.settings.activityRetentionDays) days").tag(model.settings.activityRetentionDays)
                    }
                }
                HStack {
                    Button("Rebuild index") { confirmsRebuild = true }
                        .disabled(isRebuilding)
                    Button("Export activity log…", action: exportActivity)
                }
            }
            Section("Developer") {
                LabeledContent("Install CLI") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(installCommand)
                            .font(Typography.mono(size: 12, relativeTo: .caption))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .contextMenu {
                                Button("Copy install command") {
                                    NSPasteboard.general.clearContents()
                                    copiedCommand = NSPasteboard.general.setString(installCommand, forType: .string)
                                }
                            }
                        Text("Never replaces an existing tinyprune command; remove that one first to relink.")
                            .font(.manropeCaption).foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            copiedCommand = NSPasteboard.general.setString(installCommand, forType: .string)
                        } label: {
                            Label(copiedCommand ? "Copied" : "Copy command", systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                        }
                        .sensoryFeedback(.success, trigger: copiedCommand)
                        .pruneAnimation(value: copiedCommand)
                    }
                }
            }
            Section("Rule configuration") {
                HStack {
                    Button("Export rule config…", action: exportConfig)
                    Button("Import rules…", action: importConfig)
                }
                Text("This config format is not a complete backup: it exports only supported rules shared by every managed root, and Keep overrides. Review skipped items before exporting. Import reviews additions, changes, and removals before applying; folder access must already be granted and new rules start in Preview.")
                    .font(.manropeCaption).foregroundStyle(.secondary)
                Text("The same files work with `tinyprune config validate|preview|apply`.")
                    .font(.manropeCaption).foregroundStyle(.secondary)
                if let backupMessage {
                    Text(backupMessage).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .font(.manropeBody)
        .onAppear {
            launchesAtLogin = model.services.launchesAtLogin
            customGraceHours = Self.formatHours(model.settings.defaultGracePeriodSeconds)
        }
        .scrollContentBackground(.hidden)
        .alert("Settings", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(item: $pendingImport) { preview in
            ConfigImportSheet(preview: preview) { backupMessage = "Rules imported from \(preview.fileName). Review their state in Rules." }
        }
        .confirmationDialog("Shorten activity history?", isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }), titleVisibility: .visible) {
            Button("Remove older history", role: .destructive) {
                guard let days = pendingRetention else { return }
                pendingRetention = nil
                updateSettings { $0.activityRetentionDays = days }
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("Activity entries older than \(pendingRetention ?? 0) days are removed from this Mac's audit history. Files in the Trash are not affected.")
        }
        .confirmationDialog("Rebuild the index?", isPresented: $confirmsRebuild, titleVisibility: .visible) {
            Button("Rebuild index", role: .destructive) {
                isRebuilding = true
                run { defer { isRebuilding = false }; try await model.rebuildIndex() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("TinyPrune rescans every managed folder and recomputes scheduled matches. Nothing is moved to Trash, but Upcoming may be incomplete until the scan finishes, which can take a while on large folders.")
        }
    }

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tinyprune").path
    }

    private var agentStatus: String {
        switch model.registrationStatus {
        case .enabled: "Running"
        case .requiresApproval: "Needs approval in Login Items"
        case .notRegistered, .notFound: "Not installed"
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
        backupMessage = nil
        guard let policy = model.policy else { errorMessage = "Connect to the background agent before exporting rules."; return }
        do {
            let review = try ConfigExportReview(policy: policy)
            if !review.omissions.isEmpty || review.exportedCount == 0 {
                let alert = NSAlert()
                alert.messageText = review.exportedCount == 0 ? "No rules can be exported" : "Some items cannot be exported"
                alert.informativeText = review.summary + "\n\nThis is not a complete rule-set backup. Export this partial configuration anyway?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Export partial config…")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "tinyprune.yml"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try review.text.write(to: url, atomically: true, encoding: .utf8)
            backupMessage = "Configuration exported to \(url.path).\n" + review.summary
        } catch { errorMessage = "Could not export rules: \(error.localizedDescription)" }
    }

    private func importConfig() {
        backupMessage = nil
        guard let policy = model.policy else { errorMessage = "Connect to the background agent before importing rules."; return }
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

    private let onImported: () -> Void

    package init(preview: ImportPreview, onImported: @escaping () -> Void = {}) {
        self.preview = preview
        self.onImported = onImported
    }

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
            Text("Review the changes above before applying. Matching configuration rules may be updated; configuration rules absent from the file may be removed within its roots. App-created rules are kept.")
                .font(.manropeCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    isApplying = true
                    Task {
                        defer { isApplying = false }
                        do { _ = try await model.applyConfig(preview.plan); onImported(); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(PruneButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.plan.isApplicable || isApplying)
            }
        }
        .padding(28)
        .font(.manropeBody)
        .frame(minWidth: 560, idealWidth: 560, maxWidth: 820, minHeight: 420, idealHeight: 520, maxHeight: 760)
    }
}
