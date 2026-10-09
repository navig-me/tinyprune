import AppKit
import SwiftUI
import TinyPruneUI

/// Hosts SwiftUI views in offscreen windows and rasterizes them with AppKit.
/// No Screen Recording permission or window-server capture is involved.
@MainActor
final class Snapshotter {
    let outputDirectory: URL
    private(set) var written: [URL] = []
    var unlabeled: [String] = []
    private(set) var axInventory: [String: Int] = [:]
    var dynamicTypeSizes: [DynamicTypeSize?] = [nil]
    var scales: [CGFloat] = [1, 2]
    var colorScheme: ColorScheme = .light
    var increasedContrast = false

    init(outputDirectory: URL) { self.outputDirectory = outputDirectory }

    final class Hosted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        init(window: NSWindow, host: NSHostingView<AnyView>) {
            self.window = window
            self.host = host
        }
    }

    func host<V: View>(_ view: V, size: CGSize, dynamicType: DynamicTypeSize? = nil) async -> Hosted {
        let root = AnyView(
            view
                .environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, dynamicType ?? .large)
                .frame(width: size.width, height: size.height)
        )
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let appearance: NSAppearance.Name = increasedContrast
            ? (colorScheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (colorScheme == .dark ? .darkAqua : .aqua)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        await pump(0.35)
        host.layoutSubtreeIfNeeded()
        return Hosted(window: window, host: host)
    }

    /// Renders `hosted` to PNGs. Returns the written URLs.
    @discardableResult
    func snapshot(_ hosted: Hosted, name: String, dynamicType: DynamicTypeSize? = nil) async -> [URL] {
        // Together with host settling, let the ledger's 0.65-second count-up reach its final value.
        await pump(0.4)
        hosted.host.layoutSubtreeIfNeeded()
        hosted.host.setNeedsDisplay(hosted.host.bounds)
        hosted.window.displayIfNeeded()
        await pump(0.1)
        let bounds = hosted.host.bounds
        var urls: [URL] = []
        for scale in scales {
            let pixelsWide = Int(bounds.width * scale)
            let pixelsHigh = Int(bounds.height * scale)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else {
                Check.fail("could not allocate bitmap for \(name)")
                continue
            }
            rep.size = bounds.size
            hosted.host.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                Check.fail("could not encode PNG for \(name)")
                continue
            }
            let suffix = dynamicType.map { "-dyn-\($0)" } ?? ""
            let url = outputDirectory.appendingPathComponent("\(name)\(suffix)@\(Int(scale))x.png")
            do {
                try png.write(to: url)
                written.append(url)
                urls.append(url)
            } catch {
                Check.fail("could not write \(url.lastPathComponent): \(error)")
            }
        }
        return urls
    }

    /// Hosts, renders at every configured scale and Dynamic Type size, and audits accessibility once.
    func capture<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 1100, height: 760)) async {
        for (index, dynamicType) in dynamicTypeSizes.enumerated() {
            let hosted = await host(view, size: size, dynamicType: dynamicType)
            await snapshot(hosted, name: name, dynamicType: dynamicType)
            if index == 0 {
                audit(hosted.host, screen: name)
                if dumpControlsMode { dumpControls(hosted.host) }
            }
            hosted.window.contentView = nil
            hosted.window.close()
        }
    }

    // MARK: Accessibility and interaction
    //
    // SwiftUI only materializes its own accessibility nodes for a connected assistive client, which an offscreen
    // harness does not have (`accessibilityChildren()` of a hosting view is empty). The audit therefore walks the
    // AppKit view tree that SwiftUI produces and checks every AppKit-backed control.

    func allViews(_ root: NSView) -> [NSView] {
        var result: [NSView] = []
        func visit(_ view: NSView) {
            result.append(view)
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return result
    }

    private func isAuditedControl(_ view: NSView) -> Bool {
        switch view {
        case is NSButton, is NSSlider, is NSStepper, is NSSegmentedControl, is NSDatePicker, is NSComboBox, is NSColorWell, is NSSwitch:
            return true
        case let field as NSTextField:
            return field.isEditable
        default:
            return false
        }
    }

    func label(of view: NSView) -> String {
        let candidates: [String?] = [
            view.accessibilityLabel(),
            view.accessibilityTitle(),
            (view as? NSButton)?.title,
            (view as? NSButton)?.alternateTitle,
            view.toolTip,
            (view as? NSTextField)?.placeholderString,
        ]
        return candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    private(set) var swiftUIHostedControls = 0

    func audit(_ view: NSView, screen: String) {
        var audited = 0
        var hosted = 0
        for candidate in allViews(view) where isAuditedControl(candidate) {
            let className = String(describing: type(of: candidate))
            // SwiftUI-hosted controls keep their accessibility label in SwiftUI's own node tree, which only exists
            // for a connected assistive client. Only plain AppKit controls can be judged from the view tree.
            guard className.hasPrefix("AppKit") else { hosted += 1; continue }
            audited += 1
            if label(of: candidate).isEmpty {
                let frame = candidate.convert(candidate.bounds, to: view)
                unlabeled.append("\(screen): \(className) at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) has no label or title")
            }
        }
        swiftUIHostedControls += hosted
        axInventory[screen] = audited
        print("  a11y \(screen): \(audited) AppKit controls audited, \(hosted) SwiftUI-hosted not observable")
    }

    /// Lists AppKit-backed controls (for diagnosing what SwiftUI hosts as real views).
    func dumpControls(_ view: NSView) {
        for candidate in allViews(view) where isAuditedControl(candidate) {
            print("    \(type(of: candidate)) label='\(label(of: candidate))' id='\(candidate.accessibilityIdentifier())'")
        }
    }

    /// SwiftUI hosts `Button` as `SwiftUIAppKitButton` without a title, accessibility label, or identifier at the
    /// AppKit layer, so the harness finds buttons by on-screen order (top to bottom, then left to right).
    func buttons(in view: NSView, where filter: (CGRect) -> Bool = { _ in true }) -> [NSButton] {
        var found: [(button: NSButton, frame: CGRect)] = []
        for candidate in allViews(view) {
            guard let button = candidate as? NSButton, String(describing: type(of: button)) == "SwiftUIAppKitButton" else { continue }
            let frame = button.convert(button.bounds, to: view)
            if filter(frame) { found.append((button, frame)) }
        }
        found.sort { (lhs: (button: NSButton, frame: CGRect), rhs: (button: NSButton, frame: CGRect)) -> Bool in
            let sameRow = abs(lhs.frame.minY - rhs.frame.minY) <= 2
            return sameRow ? lhs.frame.minX < rhs.frame.minX : lhs.frame.minY < rhs.frame.minY
        }
        return found.map { $0.button }
    }

    /// Delivers a real key-equivalent event to the hosted window (how SwiftUI `.keyboardShortcut` fires).
    func sendKeyEquivalent(_ characters: String, modifiers: NSEvent.ModifierFlags, to hosted: Hosted) -> Bool {
        hosted.window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        hosted.window.makeKeyAndOrderFront(nil)
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        ) else { return false }
        return hosted.window.performKeyEquivalent(with: event)
    }

    /// Performs a real `NSButton` click. Returns false when the button is missing or disabled.
    func click(_ button: NSButton?) -> Bool {
        guard let button, button.isEnabled else { return false }
        button.performClick(nil)
        return true
    }
}
