// Renders the app icon into an .iconset: a flat matte-black squircle with an off-white mark —
// four voice bars resolving into a text cursor (speech becoming text at the caret).
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let ink = NSColor(red: 0.953, green: 0.949, blue: 0.925, alpha: 1)      // off-white
let matte = NSColor(red: 0.086, green: 0.094, blue: 0.106, alpha: 1)    // #16181B

/// Draws the mark centred in `rect` (a square).
func drawMark(in rect: NSRect) {
    let w = rect.width
    let bar = w * 0.072, gap = w * 0.058
    let heights: [CGFloat] = [0.20, 0.38, 0.54, 0.30]
    let caretGap = w * 0.11, stem = w * 0.06, cap = w * 0.2, capThickness = w * 0.055, caretHeight = w * 0.62
    let total = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap + caretGap + cap
    var x = rect.midX - total / 2
    ink.setFill()
    for h in heights {
        let height = w * h
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: bar, height: height), xRadius: bar / 2, yRadius: bar / 2).fill()
        x += bar + gap
    }
    x += caretGap - gap
    // I-beam: stem plus top and bottom caps.
    let top = rect.midY + caretHeight / 2, bottom = rect.midY - caretHeight / 2
    let r = capThickness / 2
    NSBezierPath(roundedRect: NSRect(x: x + cap / 2 - stem / 2, y: bottom, width: stem, height: caretHeight), xRadius: stem / 2, yRadius: stem / 2).fill()
    NSBezierPath(roundedRect: NSRect(x: x, y: top - capThickness, width: cap, height: capThickness), xRadius: r, yRadius: r).fill()
    NSBezierPath(roundedRect: NSRect(x: x, y: bottom, width: cap, height: capThickness), xRadius: r, yRadius: r).fill()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: the squircle sits inside a ~10% margin.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    matte.setFill()
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).fill()
    // A barely-there top highlight keeps it matte rather than flat-dead.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.05), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225), angle: -90)
    drawMark(in: tile.insetBy(dx: tile.width * 0.17, dy: tile.width * 0.17))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
