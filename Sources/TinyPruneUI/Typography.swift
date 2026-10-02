import AppKit
import SwiftUI

/// Bundled typefaces: Newsreader (display), Manrope (UI/body), JetBrains Mono (paths).
/// Fonts are registered by `ATSApplicationFontsPath` in the packaged app; when they are not
/// registered (e.g. `swift run`), each helper falls back to a system design.
package enum Typography {
    package static let displayFamily = "Newsreader"
    package static let bodyFamily = "Manrope"
    package static let monoFamily = "JetBrains Mono"

    package static func display(size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        guard isAvailable(displayFamily, size: size) else {
            return .system(size: size, weight: .medium, design: .serif)
        }
        return .custom(displayFamily, size: size, relativeTo: style).weight(.medium)
    }

    package static func body(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        guard isAvailable(bodyFamily, size: size) else {
            return .system(size: size, weight: weight, design: .default)
        }
        return .custom(bodyFamily, size: size, relativeTo: style).weight(weight)
    }

    package static func mono(size: CGFloat, relativeTo style: Font.TextStyle = .callout) -> Font {
        guard isAvailable(monoFamily, size: size) else {
            return .system(size: size, weight: .regular, design: .monospaced)
        }
        return .custom(monoFamily, size: size, relativeTo: style)
    }

    private static func isAvailable(_ family: String, size: CGFloat) -> Bool {
        NSFont(name: family, size: size) != nil
            || NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false
    }
}
