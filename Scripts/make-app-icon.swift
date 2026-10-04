import AppKit
import Foundation

// Renders the canonical TinyPrune plum (website/assets/tinyprune-plum.svg) into a macOS .icns:
//   swift Scripts/make-app-icon.swift <mark.svg> <output.icns>
guard CommandLine.arguments.count == 3,
      let mark = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <mark.svg> <output.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPruneIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func render(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let side = CGFloat(pixels)
    // Apple's template: an 824/1024 tile centred in the canvas, leaving room for the system shadow.
    let tile = NSRect(x: side * 0.0977, y: side * 0.0977, width: side * 0.8047, height: side * 0.8047)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = side * 0.018
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.010)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.992, green: 0.984, blue: 0.972, alpha: 1), NSColor(red: 0.929, green: 0.906, blue: 0.871, alpha: 1)])?
        .draw(in: shape, angle: -90)
    let markSide = tile.width * 0.74
    mark.draw(in: NSRect(x: tile.midX - markSide / 2, y: tile.midY - markSide / 2 - tile.width * 0.01, width: markSide, height: markSide))
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
