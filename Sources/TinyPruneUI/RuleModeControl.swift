import SwiftUI
import TinyPruneDomain

/// Activation still goes through the existing confirmation; the thumb never predicts a successful mutation.
struct RuleModeControl: View {
    let state: RuleState
    let canActivate: Bool
    let preview: () -> Void
    let activate: () -> Void
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 2) {
            segment("Preview", symbol: "eye", selected: state == .preview, action: preview)
            segment("Active", symbol: "clock", selected: state == .active, action: activate)
                .disabled(!canActivate)
        }
        .padding(3)
        .background(PrunePalette.sidebar, in: RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
        .animation(PruneDesign.motion(reduced), value: state)
    }

    private func segment(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Typography.body(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: PruneDesign.Radius.control)
                            .fill(PrunePalette.row)
                            .shadow(color: PruneDesign.shadow, radius: 2, y: 1)
                            .matchedGeometryEffect(id: "mode", in: thumb)
                    }
                }
                .overlay {
                    if selected && contrast == .increased {
                        RoundedRectangle(cornerRadius: PruneDesign.Radius.control).strokeBorder(PrunePalette.plum)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? PrunePalette.plum : .secondary)
        .accessibilityLabel("Set rule to \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
