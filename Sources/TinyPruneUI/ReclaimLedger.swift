import SwiftUI
import TinyPruneIPC

/// Counts only actual Active deadlines. An unknown measurement is never silently treated as zero.
@MainActor
package struct ScheduledLedgerEstimate {
    package let items: Int
    package let bytes: Int64?
    package let pending: Bool
    package let partial: Bool

    package init(items candidates: [AgentUpcomingItem], sizes: [String: AgentViewModel.ItemSize], failures: Set<String> = []) {
        let active = candidates.filter { $0.explanation.disposition == .active }
            .sorted { $0.explanation.scheduledAt < $1.explanation.scheduledAt }
        items = active.count
        let measured = active.compactMap { sizes[AgentViewModel.ledgerKey($0)] }
        bytes = active.isEmpty ? 0 : measured.isEmpty ? nil : measured.reduce(0) { $0 + $1.bytes }
        pending = active.prefix(100).contains { sizes[AgentViewModel.ledgerKey($0)] == nil && !failures.contains(AgentViewModel.ledgerKey($0)) }
        partial = active.count > measured.count || measured.contains(where: \.truncated)
    }

    package var sizeText: String {
        guard let bytes else { return pending ? "Measuring size" : "Size unavailable" }
        let formatted = ledgerBytes(bytes)
        return partial && items > 0 ? "At least \(formatted)" : formatted
    }
}

package func ledgerBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct LedgerNumber: View {
    let value: Int64
    var isSize = true
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var displayed: Double = 0
    @State private var appeared = false

    var body: some View {
        CountUp(value: displayed, bytes: isSize)
            .font(Typography.display(size: 38, relativeTo: .largeTitle))
            .onAppear {
                guard !appeared else { return }
                appeared = true
                withAnimation(reduced ? nil : .easeOut(duration: 0.65)) { displayed = Double(value) }
            }
            .onChange(of: value) { old, new in
                withAnimation(!reduced && new > old ? .easeOut(duration: 0.45) : nil) { displayed = Double(new) }
            }
            .accessibilityLabel(isSize ? ledgerBytes(value) : value.formatted())
    }
}

struct ReclaimLedger: View {
    @EnvironmentObject private var model: AgentViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduced
    let overview: AgentOverviewSnapshot
    @State private var movedPulse = false

    private var measurementID: [String] { model.activeUpcomingByDeadline.prefix(100).map(AgentViewModel.ledgerKey) }
    private var moving: Bool {
        guard let attempt = model.activity.filter({ $0.kind == .trashAttempted }).max(by: { $0.occurredAt < $1.occurredAt }) else { return false }
        return !model.activity.contains { ($0.kind == .movedToTrash || $0.kind == .trashFailed) && $0.identity == attempt.identity && $0.occurredAt >= attempt.occurredAt }
    }

    var body: some View {
        // Derived once per evaluation: the width-adaptive layout below instantiates each cell twice.
        let active = model.activeUpcomingByDeadline
        let cutoff = model.currentDate.addingTimeInterval(86_400)
        let soonEstimate = ScheduledLedgerEstimate(items: active.filter { $0.explanation.scheduledAt <= cutoff }, sizes: model.ledgerSizes, failures: model.ledgerSizeFailures)
        let scheduled = ScheduledLedgerEstimate(items: active, sizes: model.ledgerSizes, failures: model.ledgerSizeFailures)
        return VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                if !typeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 0) {
                        movedCell.frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
                        soonCell(soonEstimate).frame(minWidth: 195, maxWidth: .infinity, alignment: .leading)
                        scheduledCell(scheduled).frame(minWidth: 195, maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 20) {
                    movedCell
                    Divider()
                    soonCell(soonEstimate)
                    Divider()
                    scheduledCell(scheduled)
                }
            }
            Text("Space frees up when you empty the Trash.")
                .font(Typography.body(size: 11, relativeTo: .caption)).foregroundStyle(.secondary)
            if !overview.policy.rules.contains(where: { $0.state == .active }) {
                Button("Add an Active rule") { router.selection = .rules }
                    .buttonStyle(PruneLinkStyle()).font(.subheadline)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrunePalette.row, in: RoundedRectangle(cornerRadius: PruneDesign.Radius.panel))
        .overlay { RoundedRectangle(cornerRadius: PruneDesign.Radius.panel).strokeBorder(PrunePalette.plum.opacity(0.09)) }
        .pruneEntrance()
        .task(id: measurementID) { await model.measureLedgerSizes() }
        .task(id: movedPulse) {
            guard movedPulse else { return }
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(reduced ? nil : .easeOut(duration: 0.4)) { movedPulse = false }
        }
        .onChange(of: overview.reclaimed?.lifetimeItems) { old, new in
            if let old, let new, new > old { withAnimation(reduced ? nil : .easeIn(duration: 0.15)) { movedPulse = true } }
        }
    }

    private var movedCell: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Moved to Trash").font(Typography.body(size: 13, weight: .semibold)).foregroundStyle(PrunePalette.safe)
            if let summary = overview.reclaimed, summary.lifetimeItems > 0 {
                if summary.itemsWithKnownSize > 0 { LedgerNumber(value: summary.lifetimeBytes) }
                else { Text("Size not tracked").font(Typography.panelTitle).foregroundStyle(.secondary) }
                Text("\(summary.lifetimeItems.formatted()) items" + (summary.firstMovedAt.map { " since \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""))
                    .font(Typography.body(size: 13))
                if summary.weekItems > 0 {
                    Text(summary.weekBytes > 0 ? "This week: \(summary.weekItems) items, \(ledgerBytes(summary.weekBytes)) tracked" : "This week: \(summary.weekItems) items")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                sparkline(summary.days)
                if summary.itemsWithKnownSize < summary.lifetimeItems {
                    Text("Sizes tracked since this update").font(.caption2).foregroundStyle(.secondary)
                }
            } else if overview.reclaimed == nil {
                Text("History unavailable").font(Typography.panelTitle)
            } else {
                Text("Nothing moved yet").font(Typography.panelTitle)
            }
        }
        .padding(.trailing, 18)
        .padding(8)
        .background(PrunePalette.plum.opacity(movedPulse ? 0.12 : 0), in: RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
        .accessibilityElement(children: .combine)
    }

    private func soonCell(_ soonEstimate: ScheduledLedgerEstimate) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.unreadyRoots.isEmpty ? "Moving soon" : "Scheduled soon").font(Typography.body(size: 13, weight: .semibold))
            LedgerNumber(value: Int64(model.activeSoonCount), isSize: false)
            Text("in the next 24 hours").font(.subheadline).foregroundStyle(.secondary)
            sizeLine(soonEstimate)
            if moving {
                TimelineView(.animation(minimumInterval: 1, paused: reduced)) { context in
                    Label("Moving now", systemImage: "arrow.right.circle")
                        .font(.caption).foregroundStyle(PrunePalette.plum)
                        .opacity(reduced ? 1 : 0.7 + 0.3 * sin(context.date.timeIntervalSinceReferenceDate * 2))
                }
            }
        }
        .padding(8).padding(.trailing, 12)
        .accessibilityElement(children: .combine)
    }

    private func scheduledCell(_ scheduled: ScheduledLedgerEstimate) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Scheduled").font(Typography.body(size: 13, weight: .semibold))
            LedgerNumber(value: Int64(model.activeCount), isSize: false)
            Text("under Active rules").font(.subheadline).foregroundStyle(.secondary)
            sizeLine(scheduled)
            Text("Size from up to 100 sampled items.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func sizeLine(_ estimate: ScheduledLedgerEstimate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if estimate.bytes != nil || !estimate.pending {
                Text(estimate.sizeText).font(Typography.body(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            if estimate.pending {
                TimelineView(.animation(minimumInterval: 0.1, paused: reduced)) { context in
                    RoundedRectangle(cornerRadius: PruneDesign.Radius.control)
                        .fill(PrunePalette.plum.opacity(0.08))
                        .overlay {
                            if !reduced {
                                GeometryReader { geometry in
                                    Rectangle().fill(PrunePalette.plum.opacity(0.08))
                                        .frame(width: 28)
                                        .offset(x: CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4) * (geometry.size.width + 28) - 28)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: PruneDesign.Radius.control))
                            }
                        }
                        .frame(width: 100, height: 16)
                }.accessibilityLabel("Measuring size")
            }
        }
    }

    private func sparkline(_ days: [AgentReclaimedDay]) -> some View {
        let maximum = max(1, days.map(\.items).max() ?? 0)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                RoundedRectangle(cornerRadius: PruneDesign.Radius.control)
                    .fill(PrunePalette.plum.opacity(index == days.count - 1 ? 0.9 : 0.24))
                    .frame(width: 8, height: day.items == 0 ? 0 : max(3, 24 * CGFloat(day.items) / CGFloat(maximum)))
            }
        }
        .frame(height: 26, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 14 days: \(days.reduce(0) { $0 + $1.items }) items moved to Trash; today \(days.last?.items ?? 0)")
    }
}
