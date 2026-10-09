import SwiftUI
import TinyPruneIPC

/// The menu-bar popover's headline card: how many items are due to move to Trash, the next one with its own
/// lifetime ring, and a way into Upcoming. The count eases up on first appearance and whenever it grows, so a
/// refresh that adds work is visible without being loud. Reduce Motion sets the value instantly.
struct PopoverTally: View {
    let active: [AgentUpcomingItem]
    let previewCount: Int
    let now: Date
    let open: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var shown: Double = 0
    @State private var hovered = false

    private var countLabel: String {
        active.count == 1 ? "item will move to Trash" : "items will move to Trash"
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CountUp(value: shown)
                        .font(Typography.display(size: 38))
                        .monospacedDigit()
                        .foregroundStyle(PrunePalette.plum)
                    Text(countLabel).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PrunePalette.plum.opacity(hovered ? 0.9 : 0.35))
                        .offset(x: hovered && !reduced ? 2 : 0)
                        .accessibilityHidden(true)
                }
                if let next = active.first {
                    HStack(spacing: 10) {
                        DeadlineRing(
                            deadline: next.explanation.scheduledAt, basis: next.explanation.basisDate,
                            now: now, preview: false
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: next.explanation.candidateIdentity.pathHint).lastPathComponent)
                                .font(Typography.path).lineLimit(1).truncationMode(.middle)
                            Text("Next, \(relative(next.explanation.scheduledAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("Nothing is due. Items appear here as their time comes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if previewCount > 0 {
                    Text("\(previewCount.formatted()) more in Preview. Nothing is moved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PrunePalette.row, in: RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
            .overlay {
                RoundedRectangle(cornerRadius: PruneDesign.Radius.row)
                    .strokeBorder(PrunePalette.plum.opacity(hovered ? 0.28 : 0.10), lineWidth: 1)
            }
            .shadow(color: hovered ? PruneDesign.shadow : .clear, radius: 6, y: 3)
            .offset(y: hovered && !reduced ? -1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(PruneDesign.motion(reduced), value: hovered)
        .onAppear { setShown(Double(active.count)) }
        .onChange(of: active.count) { _, new in setShown(Double(new)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Opens Upcoming")
        .accessibilityAddTraits(.isButton)
    }

    private func setShown(_ target: Double) {
        if reduced { shown = target } else { withAnimation(.smooth(duration: 0.7)) { shown = target } }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private var accessibilitySummary: String {
        var parts = ["\(active.count) \(countLabel)"]
        if let next = active.first {
            let name = URL(fileURLWithPath: next.explanation.candidateIdentity.pathHint).lastPathComponent
            parts.append("Next: \(name), \(relative(next.explanation.scheduledAt))")
        }
        if previewCount > 0 { parts.append("\(previewCount) in Preview, nothing is moved") }
        return parts.joined(separator: ". ")
    }
}
