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

    // MARK: Semantic styles
    //
    // Every size scales with Dynamic Type through its `relativeTo` text style. Views use these instead of
    // fixed point sizes so hierarchy stays consistent and readable at large accessibility sizes.

    /// Onboarding hero lines.
    package static var hero: Font { display(size: 40, relativeTo: .largeTitle) }
    /// The Overview headline.
    package static var headline: Font { display(size: 34, relativeTo: .largeTitle) }
    /// The window header title.
    package static var pageTitle: Font { display(size: 30, relativeTo: .title) }
    /// A step or sheet title.
    package static var sheetTitle: Font { display(size: 27, relativeTo: .title2) }
    /// A section heading inside a page.
    package static var sectionTitle: Font { display(size: 22, relativeTo: .title2) }
    /// A panel or inspector heading.
    package static var panelTitle: Font { display(size: 19, relativeTo: .title3) }
    /// The sidebar brand name.
    package static var brand: Font { display(size: 17, relativeTo: .headline) }
    /// Paths and identifiers.
    package static var path: Font { mono(size: 12, relativeTo: .caption) }

    private static func isAvailable(_ family: String, size: CGFloat) -> Bool {
        NSFont(name: family, size: size) != nil
            || NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false
    }
}
