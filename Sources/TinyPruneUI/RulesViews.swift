import SwiftUI
import AppKit
import TinyPruneDomain
import TinyPruneIPC

struct RulesPage: View {
    @EnvironmentObject private var model: AgentViewModel
    @EnvironmentObject private var router: AppRouter
    let overview: AgentOverviewSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var previews = RulePreviewStore()
    @State private var editorTarget: RuleEditorTarget?
    @State private var ruleToDelete: LifetimeRule?
    @State private var ruleToActivate: LifetimeRule?
    @State private var mutationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(overview.policy.rules.count) rule\(overview.policy.rules.count == 1 ? "" : "s"). New rules should begin in Preview.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("New rule") { editorTarget = .new(prefillPath: nil) }
                    .buttonStyle(PruneButtonStyle(prominent: true))
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if overview.policy.rules.isEmpty {
                            PruneEmptyState(title: "A lifetime starts with a rule", message: "Choose a template or write your own. Begin in Preview to see the matches before anything moves.", symbol: "slider.horizontal.3")
                            Button("Browse templates") { router.selection = .templates }
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(overview.policy.rules) { rule in
                            RuleRow(
                                rule: rule,
                                preview: previews.controller(for: rule.id),
                                onEdit: { editorTarget = .edit(rule) },
                                onDelete: { ruleToDelete = rule },
                                onActivate: { ruleToActivate = rule },
                                perform: perform
                            )
                                .id(rule.id)
                            Divider()
                        }
                    }
                    .padding(32)
                    .pruneAnimation(value: overview.policy.rules.map(\.id))
                }
                .onChange(of: router.focusedRuleID) { _, id in
                    guard let id else { return }
                    withAnimation(PruneDesign.motion(reduceMotion)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .font(.manropeBody)
        .sheet(item: $editorTarget) { target in
            RuleEditorSheet(target: target, overview: overview)
        }
        .onAppear(perform: consumePendingPath)
        .onChange(of: router.pendingRulePath) { _, _ in consumePendingPath() }
        // A path that arrived while another editor was open is queued; open it once that editor closes.
        .onChange(of: editorTarget?.id) { _, id in if id == nil { consumePendingPath() } }
        .onChange(of: overview.policy.rules.map(\.id)) { _, ids in previews.prune(keeping: Set(ids)) }
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
        .confirmationDialog(
            "Activate \(ruleToActivate?.name ?? "rule")?",
            isPresented: Binding(get: { ruleToActivate != nil }, set: { if !$0 { ruleToActivate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Activate rule", role: .destructive) {
                guard let rule = ruleToActivate else { return }
                perform { try await model.setState(.active, for: rule) }
            }
            Button("Cancel", role: .cancel) { ruleToActivate = nil }
        } message: {
            Text(activationMessage(for: ruleToActivate))
        }
        .alert("Could not update rule", isPresented: Binding(get: { mutationError != nil }, set: { if !$0 { mutationError = nil } })) {
            Button("OK", role: .cancel) { mutationError = nil }
        } message: {
            Text(mutationError ?? "")
        }
    }

    private func activationMessage(for rule: LifetimeRule?) -> String {
        guard let rule else { return "" }
        var lines: [String] = []
        if let result = previews.controller(for: rule.id).finishedResult(for: rule) {
            lines.append("Last preview: \(RulePreviewText.headline(result)).")
            if result.truncated { lines.append("That scan was cut short, so the real numbers may be higher.") }
        } else {
            lines.append("This rule has not been previewed since it last changed. Run Preview matches first to see what would be pruned.")
        }
        lines.append("Once active, matching items move to the Trash when they expire. Items stay in the Trash until you or macOS empty it. Use Put Back in Finder to restore.")
        if rule.isBroad { lines.append("This rule is broad: review its matches carefully before activating.") }
        return lines.joined(separator: "\n\n")
    }

    private func consumePendingPath() {
        guard editorTarget == nil, let path = router.pendingRulePath else { return }
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
    @ObservedObject var preview: RulePreviewController
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onActivate: () -> Void
    let perform: (@escaping () async throws -> Void) -> Void

    var body: some View {
        let stats = model.stats(for: rule)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(rule.name).font(Typography.display(size: 20))
                Pill(text: rule.state.label, color: rule.state.color)
                Spacer()
                if let stats {
                    Text("\(stats.matches) match\(stats.matches == 1 ? "" : "es") · \(stats.due) eligible")
                        .font(.manropeSubheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(rule.naturalDescription())
            PathText(path: rule.scope.path)
            if rule.state == .preview {
                Text(rule.isVeryBroad
                    ? "This folder is very broad, so the rule can only run in Preview. Preview schedules matches but never moves anything to Trash."
                    : "Preview schedules matches but never moves anything to Trash.")
                    .font(.manropeCaption)
                    .foregroundStyle(PrunePalette.caution)
            } else if rule.state == .active && rule.isVeryBroad {
                Text("This folder is very broad. Return the rule to Preview; very broad rules cannot stay Active.")
                    .font(.manropeCaption)
                    .foregroundStyle(PrunePalette.caution)
            }
            // Primary actions on the left, the rule's mode on the right, and everything occasional or destructive
            // behind one overflow menu so the row stays one line and Delete is never next to a frequent action.
            actionBar

            if preview.phase != .idle {
                VStack(alignment: .leading, spacing: 8) {
                    RulePreviewResultView(controller: preview)
                    if case .finished(let result) = preview.phase, result.matches > 0 {
                        Button("Show scheduled matches in Upcoming") { router.previewMatches(of: rule.id) }
                            .buttonStyle(PruneLinkStyle())
                            .accessibilityLabel("Show scheduled matches of \(rule.name) in Upcoming")
                    }
                }
                .padding(12)
                .background(PrunePalette.plum.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(router.focusedRuleID == rule.id ? PrunePalette.plum.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .pruneHover()
        .accessibilityLabel("\(rule.name), \(rule.state.label)")
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("Preview matches") { preview.start(rule, model: model) }
                .disabled(preview.isRunning)
                .accessibilityLabel("Preview matches for \(rule.name)")
                .help("Run a read-only scan of this rule's folder now")
            Button("Edit", action: onEdit)
                .accessibilityLabel("Edit \(rule.name)")
            Spacer(minLength: 12)
            if rule.state == .paused {
                Button("Resume in Preview") { perform { try await model.setState(.preview, for: rule) } }
                    .accessibilityLabel("Resume \(rule.name) in Preview")
            } else {
                RuleModeControl(
                    state: rule.state, canActivate: !rule.isVeryBroad,
                    preview: { perform { try await model.setState(.preview, for: rule) } },
                    activate: onActivate
                )
            }
            Menu {
                if rule.state != .paused {
                    Button("Pause") { perform { try await model.setState(.paused, for: rule) } }
                }
                Button("Duplicate") { perform { try await model.duplicate(rule) } }
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(rule.name)")
            .help("Pause, duplicate or delete this rule")
        }
        .buttonStyle(PruneButtonStyle())
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

/// Longest lifetime the editor accepts: 100 years.
private let maximumLifetimeSeconds: TimeInterval = 100 * 365 * 86_400
/// Longest grace period the editor accepts: one year.
private let maximumGraceHours: Double = 365 * 24

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

/// Everything the user can change in the editor, for unsaved-changes detection.
private struct EditorFields: Equatable {
    var name = ""
    var scopePath = ""
    var recursive = true
    var kind: ItemKind = .fileOrDirectory
    var names = ""
    var globs = ""
    var basis: ExpiryBasis = .modified
    var amountText = ""
    var unit: DurationUnit = .days
    var graceText = ""
    var exceptions: [String] = []
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
    @State private var amountText = "30"
    @State private var unit: DurationUnit = .days
    @State private var graceText = "0"
    @State private var exceptions: [String] = []
    /// Exceptions that already existed when the editor opened; only differences from this set are written.
    @State private var originalExceptions: [String] = []
    /// Existing exceptions the user explicitly removed (as opposed to ones hidden by moving the folder).
    @State private var removedExceptions: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingActivation = false
    @State private var confirmsDiscard = false
    @State private var editing: LifetimeRule?
    @State private var initialFields: EditorFields?

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editing == nil ? "New rule" : "Edit rule")
                .font(Typography.display(size: 27))
                .padding(.bottom, 14)
            if let draft = currentDraft {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.quote").foregroundStyle(PrunePalette.plum).accessibilityHidden(true)
                    Text(draft.naturalDescription()).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(PrunePalette.plum.opacity(0.05), in: RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
                .padding(.bottom, 16)
                .pruneAnimation(value: draft.naturalDescription())
            }

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
                        if isVeryBroad {
                            Label("This folder is very broad. The rule can only run in Preview.", systemImage: "exclamationmark.triangle")
                                .font(.manropeSubheadline)
                                .foregroundStyle(PrunePalette.caution)
                        } else if isBroad {
                            Label("This rule is broad. Review its matches in Preview before activating it.", systemImage: "exclamationmark.triangle")
                                .font(.manropeSubheadline)
                                .foregroundStyle(PrunePalette.caution)
                        }
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
                            .font(.manropeCaption).foregroundStyle(.secondary)
                    }

                    editorSection("When") {
                        Picker("Counted from", selection: $basis) {
                            ForEach(selectableBases, id: \.self) { Text($0.pickerLabel).tag($0) }
                        }
                        HStack {
                            TextField("Amount", text: $amountText)
                                .frame(width: 80)
                                .accessibilityLabel("Amount of time before an item expires")
                            Picker("Unit", selection: $unit) {
                                ForEach(DurationUnit.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                        if let amountIssue {
                            Text(amountIssue).font(.manropeCaption).foregroundStyle(PrunePalette.caution)
                        }
                        HStack {
                            Text("Grace period")
                            TextField("Hours", text: $graceText)
                                .frame(width: 60)
                                .accessibilityLabel("Grace period in hours")
                            Text("hours (0 for none)").foregroundStyle(.secondary)
                        }
                        if let graceIssue {
                            Text(graceIssue).font(.manropeCaption).foregroundStyle(PrunePalette.caution)
                        }
                    }

                    editorSection("Then") {
                        Text("Move the matching item to Trash")
                        Text("Items go to the macOS Trash, never permanently deleted. They stay there until you or macOS empty it; use Put Back in Finder to restore.")
                            .font(.manropeCaption).foregroundStyle(.secondary)
                    }

                    editorSection("Except") {
                        ForEach(exceptions, id: \.self) { path in
                            HStack {
                                PathText(path: path)
                                Spacer()
                                Button { removeException(path) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove exception \(path)")
                            }
                        }
                        Button("Add exception…", action: addException)
                        Text("Exceptions are Keep protections for the item and everything inside it.")
                            .font(.manropeCaption).foregroundStyle(.secondary)
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
                Button("Cancel", role: .cancel, action: requestCancel)
                    .keyboardShortcut(.cancelAction)
                ForEach(secondaryActions, id: \.self) { state in
                    Button(secondaryLabel(for: state)) { requestSave(state) }
                        .disabled(!canSave)
                }
                Button(primaryLabel) { requestSave(primaryState) }
                    .buttonStyle(PruneButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 14)
        }
        .font(.manropeBody)
        .padding(28)
        .frame(minWidth: 620, idealWidth: 620, maxWidth: 820, minHeight: 480, idealHeight: 720, maxHeight: 900)
        .interactiveDismissDisabled(isDirty || isSaving)
        .onAppear { load(); nameIsFocused = true }
        .onDisappear { preview.cancel() }
        .confirmationDialog(activationTitle, isPresented: $pendingActivation, titleVisibility: .visible) {
            Button(editing?.state == .active ? "Save changes" : "Activate rule", role: .destructive) { Task { await save(state: .active) } }
            Button("Save as Preview instead") { Task { await save(state: .preview) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(activationMessage)
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("This rule has unsaved changes.")
        }
        .alert("Could not save rule", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Impact preview

    private var impactPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Impact preview").font(.manropeHeadline).foregroundStyle(PrunePalette.plum)
                Spacer()
                Button(preview.phase == .idle ? "Preview matches" : "Preview again", action: startPreview)
                    .disabled(!canSave || preview.isRunning)
                    .accessibilityIdentifier("preview-matches")
                    .keyboardShortcut("p", modifiers: .command)
                    .help("Run a read-only scan of this rule's folder now (⌘P)")
            }
            if let editing, let stats = model.stats(for: editing) {
                Text("Currently \(stats.matches) scheduled match\(stats.matches == 1 ? "" : "es"), \(stats.due) eligible now. Saving re-evaluates affected items.")
                    .font(.manropeSubheadline).foregroundStyle(.secondary)
            }
            if preview.phase == .idle {
                Text("Preview matches runs a read-only scan of this folder when you click it. Nothing is changed and nothing moves to Trash.")
                    .font(.manropeSubheadline).foregroundStyle(.secondary)
            }
            RulePreviewResultView(controller: preview, isStale: previewIsStale)
        }
    }

    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typography.panelTitle).foregroundStyle(PrunePalette.plum)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    // MARK: Validation and derived state

    private static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value }
        return try? Double(trimmed, format: .number)
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
    }

    private var parsedAmount: Double? { Self.parse(amountText) }

    /// An empty grace field means none.
    private var parsedGrace: Double? {
        graceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Self.parse(graceText)
    }

    private var amountIssue: String? {
        guard let amount = parsedAmount else { return "Enter a number of hours or days, for example 30." }
        guard amount.isFinite, amount > 0 else { return "The amount must be greater than zero." }
        if amount * unit.seconds > maximumLifetimeSeconds { return "The amount is too large. The longest lifetime is 100 years." }
        return nil
    }

    private var graceIssue: String? {
        guard let grace = parsedGrace else { return "Grace period must be a number of hours, or 0 for none." }
        guard grace.isFinite, grace >= 0 else { return "Grace period cannot be negative." }
        if grace > maximumGraceHours { return "Grace period is too long. The longest is 8,760 hours (one year)." }
        return nil
    }

    /// The rule as currently drafted, or nil while the fields are incomplete or invalid.
    private var currentDraft: LifetimeRule? {
        try? draftRule(state: .preview)
    }

    private var isVeryBroad: Bool {
        (currentDraft?.isVeryBroad ?? false) || (chosenFolder?.root.isVeryBroad ?? false)
            || (!scopePath.isEmpty && RuleScope.isVeryBroad(path: scopePath))
    }

    private var isBroad: Bool {
        isVeryBroad || (currentDraft?.isBroad ?? false)
    }

    private var canSave: Bool {
        !isSaving && !scopePath.isEmpty && amountIssue == nil && graceIssue == nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentFields: EditorFields {
        EditorFields(
            name: name, scopePath: scopePath, recursive: recursive, kind: kind, names: names, globs: globs,
            basis: basis, amountText: amountText, unit: unit, graceText: graceText, exceptions: exceptions
        )
    }

    private var isDirty: Bool {
        guard let initialFields else { return false }
        return currentFields != initialFields
    }

    // MARK: Save buttons

    /// The state a plain save keeps: new rules begin in Preview, existing rules keep theirs.
    private var baseState: RuleState { editing?.state ?? .preview }

    private func resolved(_ state: RuleState) -> RuleState { isVeryBroad && state == .active ? .preview : state }

    private var primaryState: RuleState { resolved(baseState) }

    private var primaryLabel: String {
        if editing == nil || primaryState != baseState { return "Save as Preview" }
        return "Save"
    }

    private var secondaryActions: [RuleState] {
        var states: [RuleState] = []
        if primaryState != .preview { states.append(.preview) }
        if primaryState != .active && !isVeryBroad { states.append(.active) }
        return states
    }

    private func secondaryLabel(for state: RuleState) -> String {
        state == .active ? "Activate rule" : "Save as Preview"
    }

    private func requestCancel() {
        if isDirty && !isSaving { confirmsDiscard = true } else { dismiss() }
    }

    private func requestSave(_ requested: RuleState) {
        let state = resolved(requested)
        if needsActivationConfirmation(state) { pendingActivation = true } else { Task { await save(state: state) } }
    }

    /// Activation, or edits that change what an already Active rule would trash, are confirmed.
    private func needsActivationConfirmation(_ state: RuleState) -> Bool {
        guard state == .active else { return false }
        guard let editing, editing.state == .active, let draft = currentDraft else { return true }
        return !(draft.scope == editing.scope && draft.matcher == editing.matcher
            && draft.expiryBasis == editing.expiryBasis && draft.lifetime == editing.lifetime
            && draft.gracePeriod == editing.gracePeriod)
    }

    private var activationTitle: String {
        editing?.state == .active ? "Save changes to an Active rule?" : "Activate this rule?"
    }

    private var activationMessage: String {
        var lines: [String] = []
        if let draft = try? draftRule(state: .preview), let result = preview.finishedResult(for: draft) {
            lines.append("Last preview: \(RulePreviewText.headline(result)).")
            if result.truncated { lines.append("That scan was cut short, so the real numbers may be higher.") }
        } else {
            lines.append("This rule has not been previewed with these settings. Run Preview matches to see what would be pruned.")
        }
        lines.append("Active rules move matching items to the Trash when they expire. Items stay in the Trash until you or macOS empty it.")
        if isBroad { lines.append("This rule is broad. Review its matches carefully.") }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Loading

    private func load() {
        guard initialFields == nil else { return }
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
                unit = .days; amountText = Self.format(rule.lifetime.seconds / 86_400)
            } else {
                unit = .hours; amountText = Self.format(rule.lifetime.seconds / 3_600)
            }
            graceText = Self.format((rule.gracePeriod?.seconds ?? 0) / 3_600)
            let kept = model.overrides(under: rule.scope.path).compactMap { override -> String? in
                if case .keep = override.policy { override.path } else { nil }
            }
            exceptions = kept.sorted()
            originalExceptions = exceptions
        case .new(let prefill):
            if let prefill { scopePath = prefill }
        }
        initialFields = currentFields
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
                // Exceptions only make sense inside the new folder; the stored Keeps for the old folder stay untouched.
                exceptions.removeAll { !($0 == scopePath || $0.hasPrefix(scopePath + "/")) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeException(_ path: String) {
        exceptions.removeAll { $0 == path }
        if originalExceptions.contains(path) { removedExceptions.insert(path) }
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
        removedExceptions.remove(path)
        if !exceptions.contains(path) { exceptions.append(path) }
    }

    // MARK: Drafting, preview, save

    private func draftRule(state: RuleState) throws -> LifetimeRule {
        guard let amount = parsedAmount, let grace = parsedGrace else { throw RuleValidationError.invalidDuration }
        return try LifetimeRule(
            id: editing?.id ?? draftID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: RuleScope(path: scopePath, recursive: recursive),
            matcher: ItemMatcher(itemKind: kind, exactNames: split(names), globPatterns: split(globs)),
            expiryBasis: basis,
            lifetime: RuleDuration(seconds: amount * unit.seconds),
            gracePeriod: grace > 0 ? RuleDuration(seconds: grace * 3_600) : nil,
            action: editing?.action ?? .trashItem,
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
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let rule = try draftRule(state: resolved(state))
            let added = exceptions.filter { !originalExceptions.contains($0) }
            let removed = originalExceptions.filter { removedExceptions.contains($0) && !exceptions.contains($0) }
            // One atomic agent operation: the rule, its root, and its exceptions are saved together or not at all.
            try await model.saveRule(rule, folder: chosenFolder, keepPaths: added, unkeepPaths: removed)
            initialFields = currentFields
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
