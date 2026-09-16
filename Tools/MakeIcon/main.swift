import AppKit

// Renders AppIcon.iconset PNGs (run by build.sh, then converted with iconutil).
// Usage: MakeIcon <output-iconset-dir>

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(px)
    // macOS-style rounded square with a gradient, inset like system icons.
    let inset = size * 0.1
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                          xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.30, alpha: 1),
               ending: NSColor(calibratedRed: 0.62, green: 0.20, blue: 0.75, alpha: 1))!
        .draw(in: bg, angle: -60)
    NSColor.white.setStroke()
    let glyph = NSRect(x: size * 0.2, y: size * 0.2, width: size * 0.6, height: size * 0.6)
    StatusIcon.strokeTabArrow(in: glyph, lineWidth: size * 0.075)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
