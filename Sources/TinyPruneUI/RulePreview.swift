import SwiftUI
import TinyPruneDomain
import TinyPruneIPC

/// Manrope-backed text styles for the editor surfaces (system fallback when the font is not registered).
extension Font {
    static var manropeBody: Font { Typography.body(size: 13, relativeTo: .body) }
    static var manropeSubheadline: Font { Typography.body(size: 12, relativeTo: .subheadline) }
    static var manropeCaption: Font { Typography.body(size: 11, relativeTo: .caption) }
    static var manropeCaptionBold: Font { Typography.body(size: 11, weight: .bold, relativeTo: .caption) }
    static var manropeCaptionSemibold: Font { Typography.body(size: 11, weight: .semibold, relativeTo: .caption) }
    static var manropeHeadline: Font { Typography.body(size: 13, weight: .semibold, relativeTo: .headline) }
}

/// Wording for an `AgentRulePreview`, shared by the editor, the Rules rows, and the snapshot harness.
package enum RulePreviewText {
    package static func headline(_ preview: AgentRulePreview) -> String {
        let prefix = preview.truncated ? "At least " : ""
        let matches = "\(prefix)\(preview.matches.formatted()) match\(preview.matches == 1 && !preview.truncated ? "" : "es")"
        let now = "\(preview.eligibleNow.formatted()) would be pruned now"
        let bytes = "\(ByteCountFormatter.string(fromByteCount: preview.estimatedBytes, countStyle: .file)) estimated"
        return [matches, now, bytes].joined(separator: " · ")
    }

    package static func truncationNote(_ preview: AgentRulePreview) -> String? {
        guard preview.truncated else { return nil }
        return "The scan stopped after \(preview.scannedEntries.formatted()) entries, so these counts are lower bounds. Narrow the folder or add a name or pattern for exact numbers."
    }

    package static func scanNote(_ preview: AgentRulePreview) -> String {
        let seconds = preview.durationSeconds < 0.1 ? "under 0.1 s" : String(format: "%.1f s", preview.durationSeconds)
        return "Scanned \(preview.scannedEntries.formatted()) entries in \(seconds). Read-only: nothing was changed."
    }
}

/// Owns one explicit, user-requested preview. Never refreshes on its own.
@MainActor
package final class RulePreviewController: ObservableObject {
    package enum Phase: Equatable {
        case idle
        case running
        case finished(AgentRulePreview)
        case failed(String)
        case cancelled
    }

    @Published package private(set) var phase: Phase = .idle
    /// The exact rule that was previewed, so the UI can say when the draft has since changed.
    @Published package private(set) var previewedRule: LifetimeRule?

    private var generation = 0
    private var task: Task<Void, Never>?

    private weak var model: AgentViewModel?

    package init() {}

    package var isRunning: Bool { phase == .running }

    /// The finished preview, only when it was run for this rule's current definition (state is irrelevant to matching).
    package func finishedResult(for rule: LifetimeRule) -> AgentRulePreview? {
        guard case .finished(let result) = phase, let previewed = previewedRule,
              previewed.id == rule.id, previewed.scope == rule.scope, previewed.matcher == rule.matcher,
              previewed.expiryBasis == rule.expiryBasis, previewed.lifetime == rule.lifetime,
              previewed.gracePeriod == rule.gracePeriod else { return nil }
        return result
    }

    package func start(_ rule: LifetimeRule, model: AgentViewModel) {
        generation += 1
        self.model = model
        let current = generation
        task?.cancel()
        previewedRule = rule
        phase = .running
        task = Task { [weak self] in
            do {
                let result = try await model.previewRule(rule)
                guard let self, self.generation == current else { return }
                self.phase = .finished(result)
            } catch {
                guard let self, self.generation == current else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops waiting locally and asks the agent to stop its running scan.
    package func cancel() {
        guard phase == .running else { return }
        generation += 1
        task?.cancel()
        task = nil
        phase = .cancelled
        if let model {
            Task { await model.cancelPreview() }
        }
    }
}

/// Holds one preview controller per rule for the whole Rules page, so results survive row recycling by the lazy list.
@MainActor
package final class RulePreviewStore: ObservableObject {
    private var controllers: [UUID: RulePreviewController] = [:]

    package init() {}

    package func controller(for ruleID: UUID) -> RulePreviewController {
        if let existing = controllers[ruleID] { return existing }
        let created = RulePreviewController()
        controllers[ruleID] = created
        return created
    }

    /// Drops controllers of rules that no longer exist; running scans are cancelled.
    package func prune(keeping ids: Set<UUID>) {
        for (id, controller) in controllers where !ids.contains(id) {
            controller.cancel()
            controllers[id] = nil
        }
    }
}

/// Progress, result, and the soonest sample paths for a preview.
struct RulePreviewResultView: View {
    @ObservedObject var controller: RulePreviewController
    /// True when the draft no longer equals the previewed rule.
    var isStale = false
    var body: some View {
        content.font(.manropeBody)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 10) {
                ProgressView("Scanning matching items").labelsHidden().controlSize(.small)
                Text("Scanning matching items…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .accessibilityLabel("Cancel preview")
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop this preview (⌘.)")
            }
        case .cancelled:
            Text("Preview cancelled. Nothing was changed.").font(.manropeSubheadline).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.manropeSubheadline)
                .foregroundStyle(PrunePalette.caution)
                .fixedSize(horizontal: false, vertical: true)
        case .finished(let preview):
            VStack(alignment: .leading, spacing: 10) {
                Text(RulePreviewText.headline(preview)).font(.manropeHeadline)
                if let note = RulePreviewText.truncationNote(preview) {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.manropeSubheadline)
                        .foregroundStyle(PrunePalette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isStale {
                    Text("The rule has changed since this preview. Preview again to refresh.")
                        .font(.manropeSubheadline).foregroundStyle(PrunePalette.caution)
                }
                if preview.samples.isEmpty {
                    Text("Nothing matches right now.").foregroundStyle(.secondary)
                } else {
                    Text("Soonest \(preview.samples.count) to be pruned")
                        .font(.manropeCaptionSemibold).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(preview.samples.enumerated()), id: \.offset) { _, sample in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                PathText(path: sample.path)
                                Spacer(minLength: 8)
                                if let bytes = sample.bytes {
                                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                        .font(.manropeCaption).foregroundStyle(.secondary)
                                }
                                Text(sample.scheduledAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.manropeCaption).foregroundStyle(.secondary)
                                    .frame(minWidth: 62, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
                Text(RulePreviewText.scanNote(preview)).font(.manropeCaption).foregroundStyle(.secondary)
            }
        }
    }
}
