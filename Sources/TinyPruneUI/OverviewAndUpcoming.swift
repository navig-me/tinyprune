import SwiftUI
import TinyPruneDomain
import TinyPruneIPC

func displayName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }


private func relativeDay(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if date <= now || calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    return date.formatted(.dateTime.weekday(.wide))
}

// MARK: - Overview

struct OverviewPage: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AgentViewModel
    let overview: AgentOverviewSnapshot

    private var places: [ManagedRoot] {
        overview.policy.managedRoots.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var needsAttention: Bool {
        model.activity.prefix(20).contains { $0.isAttention }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(Typography.display(size: 34))
                    Text(subline).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Managed places")
                    if places.isEmpty {
                        Text("No places are managed yet. Start from a template.")
                            .foregroundStyle(.secondary)
                        Button("Browse templates") { router.selection = .templates }
                    }
                    ForEach(places) { root in
                        let rules = overview.policy.rules.filter { $0.scope.path == root.path || $0.scope.path.hasPrefix(root.path + "/") }
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(root.displayName)
                                Text(rules.isEmpty ? "No rules" : rules.map(\.name).joined(separator: " · "))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                PathText(path: root.path)
                            }
                            Spacer()
                            if let state = dominantState(rules) { Pill(text: state.label, color: state.color) }
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Next to prune")
                    if overview.upcoming.isEmpty {
                        Text("Nothing is scheduled.").foregroundStyle(.secondary)
                    }
                    ForEach(overview.upcoming.prefix(3)) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(item.explanation.candidateIdentity.pathHint))
                                PathText(path: item.explanation.candidateIdentity.pathHint)
                            }
                            Spacer()
                            Text(relativeDay(item.explanation.scheduledAt)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    if overview.upcoming.count > 3 {
                        Button("See all \(overview.upcoming.count) in Upcoming") { router.selection = .upcoming }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: String {
        if needsAttention { return "Something needs a look." }
        if overview.policy.globallyPaused { return "TinyPrune is paused." }
        if places.isEmpty { return "Nothing is managed yet." }
        return "Everything is tidy."
    }

    private var subline: String {
        if needsAttention { return "A recent cleanup could not move an item to Trash. See Activity for details." }
        if overview.policy.globallyPaused { return "Nothing will move to Trash until you resume." }
        if overview.policy.rules.contains(where: { $0.state == .preview }) {
            return "TinyPrune is running quietly. Preview rules schedule matches but never touch your files."
        }
        if places.isEmpty { return "Choose a folder to give its contents a lifetime." }
        return "TinyPrune is running quietly."
    }

    private func dominantState(_ rules: [LifetimeRule]) -> RuleState? {
        if rules.contains(where: { $0.state == .preview }) { return .preview }
        if rules.contains(where: { $0.state == .active }) { return .active }
        return rules.isEmpty ? nil : .paused
    }
}

// MARK: - Upcoming

private enum UpcomingGroup: Int, CaseIterable {
    case today, tomorrow, nextSevenDays, later

    var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextSevenDays: "Next 7 days"
        case .later: "Later"
        }
    }

    init(_ date: Date, now: Date = Date()) {
        let calendar = Calendar.current
        if date <= now || calendar.isDateInToday(date) { self = .today }
        else if calendar.isDateInTomorrow(date) { self = .tomorrow }
        else if let week = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now)), date < week { self = .nextSevenDays }
        else { self = .later }
    }
}

struct UpcomingPage: View {
    @EnvironmentObject private var router: AppRouter
    let overview: AgentOverviewSnapshot
    @State private var sizes: [String: AgentViewModel.ItemSize] = [:]
    @EnvironmentObject private var model: AgentViewModel

    private var customPaths: Set<String> {
        Set(overview.policy.overrides.compactMap { override in
            if case .customExpiry = override.policy { return override.path }
            return nil
        })
    }

    private var protectedOverrides: [ItemPolicyOverride] {
        overview.policy.overrides.filter { if case .keep = $0.policy { return true } else { return false } }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var filterRule: LifetimeRule? {
        router.upcomingRuleFilter.flatMap { id in overview.policy.rules.first { $0.id == id } }
    }

    private var items: [AgentUpcomingItem] {
        guard let id = router.upcomingRuleFilter else { return overview.upcoming }
        return overview.upcoming.filter { $0.explanation.matchedRuleID == id }
    }

    private var selectedItem: AgentUpcomingItem? { items.first { $0.id == router.inspectedItemID } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                if let rule = filterRule {
                    HStack {
                        Pill(text: "Matches of \(rule.name)")
                        Button("Show all") { router.upcomingRuleFilter = nil }.buttonStyle(.link)
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView(
                        "Nothing scheduled",
                        systemImage: "clock",
                        description: Text("Matches appear here once a rule finds items. Preview rules list them without touching your files.")
                    )
                    .frame(maxWidth: .infinity)
                }
                ForEach(UpcomingGroup.allCases, id: \.rawValue) { group in
                    let rows = items.filter { UpcomingGroup($0.explanation.scheduledAt) == group }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle(group.title).padding(.bottom, 8)
                            ForEach(rows) { item in
                                Button {
                                    router.inspectedItemID = item.id
                                } label: {
                                    UpcomingRow(
                                        item: item,
                                        isSelected: router.inspectedItemID == item.id,
                                        isCustom: customPaths.contains(item.explanation.candidateIdentity.pathHint),
                                        size: sizes[item.explanation.candidateIdentity.pathHint]
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Why will \(displayName(item.explanation.candidateIdentity.pathHint)) be pruned?")
                                .accessibilityValue("\(item.explanation.candidateIdentity.pathHint), \(item.explanation.matchedRuleName), \(item.explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened)), \(item.explanation.disposition == .preview ? "Preview" : "Active")")
                                .accessibilityAddTraits(router.inspectedItemID == item.id ? [.isSelected] : [])
                                Divider()
                            }
                        }
                    }
                }
                if router.upcomingRuleFilter == nil && !protectedOverrides.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle("Protected").padding(.bottom, 8)
                        ForEach(protectedOverrides) { override in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(displayName(override.path))
                                    PathText(path: override.path)
                                }
                                Spacer()
                                if case .keep(let descendants) = override.policy {
                                    Pill(text: descendants ? "Protected with contents" : "Protected", color: PrunePalette.safe)
                                }
                                Button("Stop protecting") { Task { try? await model.inherit(path: override.path) } }
                                    .buttonStyle(.link)
                            }
                            .padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inspector(isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { router.inspectedItemID = nil } })) {
            if let item = selectedItem {
                WhyInspector(item: item, close: { router.inspectedItemID = nil }, onSize: { sizes[item.explanation.candidateIdentity.pathHint] = $0 })
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
            }
        }
    }
}

private struct UpcomingRow: View {
    let item: AgentUpcomingItem
    let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    let isCustom: Bool
    let size: AgentViewModel.ItemSize?

    var body: some View {
        let explanation = item.explanation
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(explanation.candidateIdentity.pathHint))
                PathText(path: explanation.candidateIdentity.pathHint)
                Text(explanation.matchedRuleName).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                if let size {
                    Text("\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file))\(size.truncated ? "+" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Pill(
                    text: isCustom ? "Custom" : explanation.disposition == .preview ? "Preview" : "Inherited",
                    color: isCustom ? PrunePalette.plum : explanation.disposition == .preview ? PrunePalette.caution : PrunePalette.safe
                )
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(isSelected ? PrunePalette.plum.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isSelected && contrast == .increased {
                RoundedRectangle(cornerRadius: 8).strokeBorder(PrunePalette.plum, lineWidth: 2)
            }
        }
    }
}

// MARK: - Why inspector

package struct WhyInspectorContent: View {
    @EnvironmentObject private var model: AgentViewModel
    @EnvironmentObject private var router: AppRouter
    let item: AgentUpcomingItem
    let close: () -> Void
    let onSize: (AgentViewModel.ItemSize) -> Void

    package init(item: AgentUpcomingItem, close: @escaping () -> Void = {}, onSize: @escaping (AgentViewModel.ItemSize) -> Void = { _ in }) {
        self.item = item
        self.close = close
        self.onSize = onSize
    }

    @State private var explanation: AgentItemExplanation?
    @State private var failure: String?
    @State private var size: AgentViewModel.ItemSize?
    @State private var isMeasuring = false

    private var path: String { item.explanation.candidateIdentity.pathHint }

    package var body: some View {
        VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Why will this be pruned?")
                        .font(Typography.display(size: 19))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Close inspector")
                        .keyboardShortcut(.cancelAction)
                }
                PathText(path: path)

                if let explanation { details(explanation) }
                else if let failure { Text(failure).foregroundStyle(PrunePalette.caution) }
                else { ProgressView("Loading explanation") }
        }
        .padding(20)
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private func details(_ explanation: AgentItemExplanation) -> some View {
        switch explanation.resolution {
        case .scheduled(let scheduled):
            field("Scheduled", scheduled.scheduledAt.formatted(date: .complete, time: .shortened))
            field("Matched rule", scheduled.matchedRuleName)
            field("Reason", "\(scheduled.expiryBasis.phrase.capitalizedFirst) — basis date \(scheduled.basisDate.formatted(date: .abbreviated, time: .shortened))")
            if scheduled.disposition == .preview {
                field("Mode", "Preview — nothing will move to Trash")
            }
        case .customExpiry(let custom):
            field("Scheduled", custom.expiresAt.formatted(date: .complete, time: .shortened))
            field("Reason", "An explicit expiry is set on this item")
        case .protected(let protected):
            field("Protected", "Keep on \(protected.protectedPath)\(protected.protectsDescendants ? " including everything inside" : "")")
        case .suppressed(let reason):
            field("Not scheduled", reason.userExplanation)
        case .noRule:
            field("Not scheduled", "No rule applies any more")
        case .ambiguousRules(let ids):
            field("Not scheduled", "\(ids.count) rules tie. TinyPrune will not guess.")
        case .ambiguousOverrides:
            field("Not scheduled", "Conflicting overrides on this item")
        }
        field("Overrides", explanation.overrides.isEmpty ? "None" : explanation.overrides.map(\.path).joined(separator: "\n"))
        VStack(alignment: .leading, spacing: 3) {
            Text("Size").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let size {
                Text("\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file))\(size.truncated ? " or more" : "") · \(size.items.formatted()) item\(size.items == 1 ? "" : "s")")
            } else {
                Button(isMeasuring ? "Measuring…" : "Calculate size") {
                    isMeasuring = true
                    Task {
                        defer { isMeasuring = false }
                        do { let measured = try await model.size(of: path); size = measured; onSize(measured) }
                        catch { failure = error.localizedDescription }
                    }
                }
                .buttonStyle(.link)
                .disabled(isMeasuring)
                .help("Measure this item's size on disk")
            }
        }

        if let error = failure { Text(error).foregroundStyle(PrunePalette.caution) }

        Divider()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Keep") { run { try await model.keep(path: path, protectDescendants: false) } }
                Button("+7 days") { run { try await extend(by: 7) } }
                    .accessibilityLabel("Extend expiry by 7 days")
                Button("+30 days") { run { try await extend(by: 30) } }
                    .accessibilityLabel("Extend expiry by 30 days")
            }
            if case .scheduled(let scheduled) = explanation.resolution {
                Button("Open rule") { router.openRule(scheduled.matchedRuleID) }.buttonStyle(.link)
            }
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func extend(by days: Double) async throws {
        let base = max(item.explanation.scheduledAt, Date())
        try await model.setExpiry(
            path: path,
            at: base.addingTimeInterval(days * 86_400),
            state: item.explanation.disposition == .preview ? .preview : .active
        )
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); failure = nil; await load() }
            catch { failure = error.localizedDescription }
        }
    }

    private func load() async {
        do { explanation = try await model.explain(path: path); failure = nil }
        catch { failure = error.localizedDescription }
    }
}

/// The "Why will this be pruned?" inspector. `WhyInspectorContent` is separate so tooling can rasterize it
/// without the scroll container.
package struct WhyInspector: View {
    let item: AgentUpcomingItem
    let close: () -> Void
    let onSize: (AgentViewModel.ItemSize) -> Void

    package init(item: AgentUpcomingItem, close: @escaping () -> Void = {}, onSize: @escaping (AgentViewModel.ItemSize) -> Void = { _ in }) {
        self.item = item
        self.close = close
        self.onSize = onSize
    }

    package var body: some View {
        ScrollView { WhyInspectorContent(item: item, close: close, onSize: onSize) }
    }
}

extension EvaluationSuppression {
    /// Plain-language reason shown in the inspector instead of the raw case name.
    var userExplanation: String {
        switch self {
        case .itemDoesNotMatch: "No rule matches this item."
        case .missingExpiryTimestamp: "TinyPrune has not recorded the date this rule counts from yet."
        case .pausedRule: "The matching rule is paused."
        case .globalPause: "TinyPrune is paused, so nothing is scheduled."
        case .previewOnly: "The matching rule is in Preview."
        case .hiddenProtected: "Hidden items are protected by your safety settings."
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

package struct PathItem: Identifiable, Equatable {
    package let path: String
    package init(path: String) { self.path = path }
    package var id: String { path }
}

/// Opened from Finder's "Custom…" menu item.
package struct CustomExpirySheet: View {
    @EnvironmentObject private var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    let path: String

    package init(path: String) { self.path = path }

    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var errorMessage: String?

    package var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set expiry").font(Typography.display(size: 27))
            PathText(path: path)
            DatePicker("Move to Trash after", selection: $date, in: Date()...)
            Text("This item moves to Trash at that time unless you Keep it first.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(PrunePalette.caution) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set expiry") {
                    Task {
                        do { try await model.setExpiry(path: path, at: date, state: .active); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 460, idealWidth: 460, maxWidth: 680)
    }
}
