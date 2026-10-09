import SwiftUI

/// A single physical vocabulary for the desktop: quiet surfaces, crisp edges, short responses.
package enum PruneDesign {
    package enum Radius {
        package static let control: CGFloat = 6
        package static let row: CGFloat = 8
        package static let panel: CGFloat = 12
        package static let sheet: CGFloat = 16
    }
    package enum Space {
        package static let small: CGFloat = 8
        package static let gutter: CGFloat = 16
        package static let section: CGFloat = 24
        package static let canvas: CGFloat = 32
    }
    package static let shadow = Color(red: 0.29, green: 0.12, blue: 0.24).opacity(0.10)
    package static func motion(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.30, dampingFraction: 0.86)
    }
}

package struct PruneButtonStyle: ButtonStyle {
    package var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    package init(prominent: Bool = false) { self.prominent = prominent }

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(prominent ? PrunePalette.canvas : PrunePalette.plum)
            .background(prominent ? PrunePalette.plum : PrunePalette.row, in: RoundedRectangle(cornerRadius: PruneDesign.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: PruneDesign.Radius.control)
                    .strokeBorder(PrunePalette.plum.opacity(contrast == .increased ? 1 : prominent ? 0 : 0.18), lineWidth: 1)
            }
            .shadow(color: enabled && hovered ? PruneDesign.shadow : .clear, radius: 4, y: 2)
            .brightness(enabled && hovered ? 0.025 : 0)
            .scaleEffect(reduced ? 1 : configuration.isPressed ? 0.97 : 1)
            .offset(y: reduced ? 0 : configuration.isPressed ? 1 : enabled && hovered ? -1 : 0)
            .opacity(enabled ? 1 : 0.45)
            .animation(PruneDesign.motion(reduced), value: configuration.isPressed)
            .animation(PruneDesign.motion(reduced), value: hovered)
            .onHover { hovered = $0 }
    }
}

struct PruneLinkStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(PrunePalette.plum)
            .opacity(enabled ? configuration.isPressed ? 0.7 : 1 : 0.45)
            .scaleEffect(!reduced && configuration.isPressed ? 0.97 : 1)
            .animation(PruneDesign.motion(reduced), value: configuration.isPressed)
    }
}

private struct HoverWash: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(PrunePalette.plum.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
            .animation(PruneDesign.motion(reduced), value: hovered)
            .onHover { hovered = $0 }
    }
}

private struct Entrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var appeared = false
    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduced ? 1 : 0)
            .offset(y: appeared || reduced ? 0 : 6)
            .onAppear {
                withAnimation(reduced ? nil : .easeOut(duration: 0.22).delay(Double(min(index, 5)) * 0.035)) { appeared = true }
            }
    }
}

extension View {
    package func pruneHover() -> some View { modifier(HoverWash()) }
    package func pruneEntrance(_ index: Int = 0) -> some View { modifier(Entrance(index: index)) }
    package func pruneAnimation<Value: Equatable>(value: Value) -> some View { modifier(StateMotion(value: value)) }
    package func pruneBounce(value: Bool) -> some View { modifier(SymbolResponse(value: value)) }
}

private struct StateMotion<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View { content.animation(PruneDesign.motion(reduced), value: value) }
}

private struct SymbolResponse: ViewModifier {
    let value: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        if reduced { content }
        else { content.symbolEffect(.bounce, options: .nonRepeating, value: value) }
    }
}

package struct PruneCount: View {
    let count: Int
    package init(_ count: Int) { self.count = count }
    package var body: some View {
        Text(count.formatted()).monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .pruneAnimation(value: count)
    }
}

/// The remaining fraction of the actual rule lifetime, not an invented urgency score.
struct DeadlineRing: View {
    let deadline: Date
    let basis: Date
    let now: Date
    var preview = false
    private var remaining: Double {
        let lifetime = deadline.timeIntervalSince(basis)
        return lifetime > 0 ? min(1, max(0, deadline.timeIntervalSince(now) / lifetime)) : 0
    }
    var body: some View {
        ZStack {
            Circle().stroke(PrunePalette.plum.opacity(0.12), lineWidth: 2)
            Circle().trim(from: 0, to: remaining)
                .stroke(PrunePalette.plum, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: preview ? "eye" : "clock").font(.system(size: 11)).foregroundStyle(PrunePalette.plum)
        }
        .frame(width: 30, height: 30)
        .pruneAnimation(value: remaining)
        .accessibilityHidden(true)
    }
}

struct PruneEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(PrunePalette.plum).accessibilityHidden(true)
            Text(title).font(Typography.panelTitle).accessibilityAddTraits(.isHeader)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(PrunePalette.row, in: RoundedRectangle(cornerRadius: PruneDesign.Radius.panel))
    }
}

/// Interpolates an honest measured value; callers decide when an increase deserves motion.
package struct CountUp: View, Animatable {
    nonisolated package var value: Double
    nonisolated package var bytes: Bool
    package init(value: Double, bytes: Bool = false) { self.value = value; self.bytes = bytes }
    nonisolated package var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    package var body: some View {
        Text(bytes
             ? ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
             : Int64(max(0, value)).formatted())
    }
}
