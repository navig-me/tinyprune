import SwiftUI
import AppKit
import TinyPruneDomain
import TinyPruneIPC

struct RulesPage: View {
    @EnvironmentObject private var model: AgentViewModel
    @EnvironmentObject private var router: AppRouter
    let overview: AgentOverviewSnapshot

    @State private var editorTarget: RuleEditorTarget?
    @State private var ruleToDelete: LifetimeRule?
    @State private var mutationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(overview.policy.rules.count) rule\(overview.policy.rules.count == 1 ? "" : "s"). New rules should begin in Preview.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("New rule") { editorTarget = .new(prefillPath: nil) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if overview.policy.rules.isEmpty {
                            ContentUnavailableView(
                                "No rules yet",
                                systemImage: "slider.horizontal.3",
                                description: Text("Start from a template or write a rule. New rules should begin in Preview.")
                            )
                            .frame(maxWidth: .infinity)
                            Button("Browse templates") { router.selection = .templates }
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(overview.policy.rules) { rule in
                            RuleRow(
                                rule: rule,
                                onEdit: { editorTarget = .edit(rule) },
                                onDelete: { ruleToDelete = rule },
                                perform: perform
                            )
                                .id(rule.id)
                            Divider()
                        }
                    }
                    .padding(32)
                }
                .onChange(of: router.focusedRuleID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            RuleEditorSheet(target: target, overview: overview)
        }
        .onAppear(perform: consumePendingPath)
        .onChange(of: router.pendingRulePath) { _, _ in consumePendingPath() }
        .confirmationDialog(
            "Delete \(ruleToDelete?.name ?? "rule")?",
            isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete rule", role: .destructive) {
                guard let rule = ruleToDelete else { return }
                perform { try await model.delete(rule) }
            }
        } message: {
            Text("Scheduled matches for this rule are cleared. Files already in Trash are not affected.")
        }
        .alert("Could not update rule", isPresented: Binding(get: { mutationError != nil }, set: { if !$0 { mutationError = nil } })) {
            Button("OK", role: .cancel) { mutationError = nil }
        } message: {
            Text(mutationError ?? "")
        }
    }

    private func consumePendingPath() {
        guard let path = router.pendingRulePath else { return }
        router.pendingRulePath = nil
        editorTarget = .new(prefillPath: path)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { mutationError = error.localizedDescription }
        }
    }
}

private struct RuleRow: View {
    @EnvironmentObject private var model: AgentViewModel
    @EnvironmentObject private var router: AppRouter
    let rule: LifetimeRule
    let onEdit: () -> Void
    let onDelete: () -> Void
    let perform: (@escaping () async throws -> Void) -> Void

    @StateObject private var preview = RulePreviewController()

    var body: some View {
        let stats = model.stats(for: rule)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(rule.name).font(Typography.display(size: 20))
                Pill(text: rule.state.label, color: rule.state.color)
                Spacer()
                if let stats {
                    Text("\(stats.matches) match\(stats.matches == 1 ? "" : "es") · \(stats.due) eligible")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(rule.naturalDescription())
            PathText(path: rule.scope.path)
            if rule.state == .preview {
                Text("Preview schedules matches but never moves anything to Trash.")
                    .font(.caption)
                    .foregroundStyle(PrunePalette.caution)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 12) {
                Button("Edit", action: onEdit)
                Button("Preview matches") { preview.start(rule, model: model) }
                    .disabled(preview.isRunning)
                    .help("Run a read-only scan of this rule's folder now")
                if rule.state == .paused {
                    Button("Resume in Preview") { perform { try await model.setState(.preview, for: rule) } }
                } else {
                    Button("Pause") { perform { try await model.setState(.paused, for: rule) } }
                }
                if rule.state == .preview {
                    Button("Activate") { perform { try await model.setState(.active, for: rule) } }
                } else if rule.state == .active {
                    Button("Return to Preview") { perform { try await model.setState(.preview, for: rule) } }
                }
                Button("Duplicate") { perform { try await model.duplicate(rule) } }
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.link)

            if preview.phase != .idle {
                VStack(alignment: .leading, spacing: 8) {
                    RulePreviewResultView(controller: preview)
                    if case .finished(let result) = preview.phase, result.matches > 0 {
                        Button("Show scheduled matches in Upcoming") { router.previewMatches(of: rule.id) }
                            .buttonStyle(.link)
                    }
                }
                .padding(12)
                .background(PrunePalette.plum.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(router.focusedRuleID == rule.id ? PrunePalette.plum.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

package enum RuleEditorTarget: Identifiable {
    case new(prefillPath: String?)
    case edit(LifetimeRule)

    package var id: String {
        switch self {
        case .new(let path): "new-\(path ?? "")"
        case .edit(let rule): rule.id.uuidString
        }
    }
}

private enum DurationUnit: String, CaseIterable, Identifiable {
    case hours = "Hours", days = "Days"
    var id: String { rawValue }
    var seconds: TimeInterval { self == .hours ? 3_600 : 86_400 }
}

private let selectableBases: [ExpiryBasis] = [.modified, .created, .firstObserved, .observedActivity, .accessed, .projectActivity]

private extension ExpiryBasis {
    var pickerLabel: String {
        switch self {
        case .modified: "Last modified"
        case .created: "Created"
        case .firstObserved: "Added to the folder"
        case .observedActivity: "Last observed activity"
        case .accessed: "Last accessed"
        case .projectActivity: "Project activity"
        case .explicitDate: "Explicit date"
        }
    }
}

package struct RuleEditorSheet: View {
    @EnvironmentObject private var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameIsFocused: Bool

    let target: RuleEditorTarget
    let overview: AgentOverviewSnapshot

    /// `preview` lets tooling observe the explicit impact preview; production callers use the default.
    package init(target: RuleEditorTarget, overview: AgentOverviewSnapshot, preview: RulePreviewController = RulePreviewController()) {
        self.target = target
        self.overview = overview
        _preview = StateObject(wrappedValue: preview)
    }

    @StateObject private var preview: RulePreviewController
    @State private var draftID = UUID()

    @State private var name = "New rule"
    @State private var scopePath = ""
    @State private var chosenFolder: ChosenFolder?
    @State private var recursive = true
    @State private var kind: ItemKind = .fileOrDirectory
    @State private var names = ""
    @State private var globs = ""
    @State private var basis: ExpiryBasis = .modified
    @State private var amount = 30.0
    @State private var unit: DurationUnit = .days
    @State private var graceHours = 0.0
    @State private var exceptions: [String] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsBroadActivation = false
    @State private var editing: LifetimeRule?

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editing == nil ? "New rule" : "Edit rule")
                .font(Typography.display(size: 27))
                .padding(.bottom, 14)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("Rule name", text: $name)
                        .focused($nameIsFocused)

                    editorSection("Where") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if scopePath.isEmpty {
                                    Text("Choose a folder to continue").foregroundStyle(.secondary)
                                } else {
                                    PathText(path: scopePath)
                                }
                            }
                            Spacer()
                            Button("Choose folder…", action: chooseFolder)
                        }
                        Toggle("Include subfolders", isOn: $recursive)
                    }

                    editorSection("What") {
                        Picker("Items", selection: $kind) {
                            Text("Files and folders").tag(ItemKind.fileOrDirectory)
                            Text("Files").tag(ItemKind.file)
                            Text("Folders").tag(ItemKind.directory)
                        }
                        TextField("Exact names", text: $names, prompt: Text(verbatim: "Exact names, comma separated (node_modules, .venv)"))
                        // Verbatim: the glob example contains `**`, which Markdown-aware Text would swallow.
                        TextField("Glob patterns", text: $globs, prompt: Text(verbatim: "Glob patterns, comma separated (*.dmg, **/.cache/**)"))
                        Text("Leave both empty to match every \(kind == .file ? "file" : kind == .directory ? "folder" : "item").")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    editorSection("When") {
                        Picker("Counted from", selection: $basis) {
                            ForEach(selectableBases, id: \.self) { Text($0.pickerLabel).tag($0) }
                        }
                        HStack {
                            TextField("Amount", value: $amount, format: .number)
                                .frame(width: 80)
                            Picker("Unit", selection: $unit) {
                                ForEach(DurationUnit.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                        HStack {
                            Text("Grace period")
                            TextField("Hours", value: $graceHours, format: .number)
                                .frame(width: 60)
                                .accessibilityLabel("Grace period in hours")
                            Text("hours (0 for none)").foregroundStyle(.secondary)
                        }
                    }

                    editorSection("Then") {
                        Text("Move the matching item to Trash")
                        Text("Items always go to the macOS Trash, never permanently deleted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    editorSection("Except") {
                        ForEach(exceptions, id: \.self) { path in
                            HStack {
                                PathText(path: path)
                                Spacer()
                                Button { exceptions.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove exception \(path)")
                            }
                        }
                        Button("Add exception…", action: addException)
                        Text("Exceptions are Keep protections for the item and everything inside it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    impactPreview.id("impact")
                }
                .padding(.trailing, 8)
            }
            .onChange(of: preview.phase) { _, phase in
                // The result sits below the fold of a long form; bring it into view after the user's explicit click.
                if phase != .idle {
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("impact", anchor: .top) }
                }
            }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Activate rule") {
                    if isBroad { confirmsBroadActivation = true } else { Task { await save(state: .active) } }
                }
                .disabled(!canSave)
                Button("Save as Preview") { Task { await save(state: .preview) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 14)
        }
        .padding(28)
        .frame(minWidth: 620, idealWidth: 620, maxWidth: 820, minHeight: 480, idealHeight: 720, maxHeight: 900)
        .onAppear { load(); nameIsFocused = true }
        .confirmationDialog("Activate a broad rule?", isPresented: $confirmsBroadActivation, titleVisibility: .visible) {
            Button("Activate anyway", role: .destructive) { Task { await save(state: .active) } }
            Button("Save as Preview instead") { Task { await save(state: .preview) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This rule covers your whole home folder or reaches deep through a tree. Review its matches in Preview first.")
        }
        .alert("Could not save rule", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var impactPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("IMPACT PREVIEW").font(.caption.weight(.bold)).foregroundStyle(PrunePalette.plum)
                Spacer()
                Button(preview.phase == .idle ? "Preview matches" : "Preview again", action: startPreview)
                    .disabled(!canSave || preview.isRunning)
                    .accessibilityIdentifier("preview-matches")
                    .keyboardShortcut("p", modifiers: .command)
                    .help("Run a read-only scan of this rule's folder now (⌘P)")
            }
            if let editing, let stats = model.stats(for: editing) {
                Text("Currently \(stats.matches) scheduled match\(stats.matches == 1 ? "" : "es"), \(stats.due) eligible now. Saving re-evaluates affected items.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if preview.phase == .idle {
                Text("Preview matches runs a read-only scan of this folder when you click it. Nothing is changed and nothing moves to Trash.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            RulePreviewResultView(controller: preview, isStale: previewIsStale)
        }
    }

    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(PrunePalette.plum)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var isBroad: Bool {
        scopePath == NSHomeDirectory() || (chosenFolder?.isVeryBroad ?? false) || (basis == .projectActivity && recursive)
    }

    private var canSave: Bool {
        !isSaving && !scopePath.isEmpty && amount > 0
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        switch target {
        case .edit(let rule):
            editing = rule
            name = rule.name
            scopePath = rule.scope.path
            recursive = rule.scope.recursive
            kind = rule.matcher.itemKind
            names = rule.matcher.exactNames.sorted().joined(separator: ", ")
            globs = rule.matcher.globPatterns.sorted().joined(separator: ", ")
            basis = rule.expiryBasis
            if rule.lifetime.seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
                unit = .days; amount = rule.lifetime.seconds / 86_400
            } else {
                unit = .hours; amount = rule.lifetime.seconds / 3_600
            }
            graceHours = (rule.gracePeriod?.seconds ?? 0) / 3_600
        case .new(let prefill):
            if let prefill { scopePath = prefill }
        }
    }

    private func split(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private func chooseFolder() {
        do {
            let start = scopePath.isEmpty ? nil : URL(fileURLWithPath: scopePath)
            if let folder = try ChosenFolder.choose(startingAt: start) {
                chosenFolder = folder
                scopePath = folder.root.path
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func addException() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Protect"
        if !scopePath.isEmpty { panel.directoryURL = URL(fileURLWithPath: scopePath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(scopePath + "/") || path == scopePath else {
            errorMessage = "Exceptions must be inside the rule’s folder."
            return
        }
        if !exceptions.contains(path) { exceptions.append(path) }
    }

    private func draftRule(state: RuleState) throws -> LifetimeRule {
        try LifetimeRule(
            id: editing?.id ?? draftID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: RuleScope(path: scopePath, recursive: recursive),
            matcher: ItemMatcher(itemKind: kind, exactNames: split(names), globPatterns: split(globs)),
            expiryBasis: basis,
            lifetime: RuleDuration(seconds: amount * unit.seconds),
            gracePeriod: graceHours > 0 ? RuleDuration(seconds: graceHours * 3_600) : nil,
            action: .trashItem,
            state: state,
            matchMode: editing?.matchMode ?? .scoped
        )
    }

    private func startPreview() {
        do { preview.start(try draftRule(state: .preview), model: model) }
        catch { errorMessage = error.localizedDescription }
    }

    /// The preview is stale once any field differs from what was previewed; it is never refreshed automatically.
    private var previewIsStale: Bool {
        guard let previewed = preview.previewedRule, let current = try? draftRule(state: .preview) else { return false }
        return previewed != current
    }

    @MainActor
    private func save(state: RuleState) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let forcedState: RuleState = (chosenFolder?.isVeryBroad ?? false) ? .preview : state
            let rule = try draftRule(state: forcedState)
            try await model.upsert(rule: rule, folder: chosenFolder)
            for path in exceptions { try await model.keep(path: path, protectDescendants: true) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
