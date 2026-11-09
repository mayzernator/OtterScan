// Renders the DMG window background (660x400 pt, @2x): a blueprint of an otter + network.
// Usage: make_dmg_bg otter.svg out.png      Keep ICON_L / ICON_R / ICON_Y in sync with make_dmg.sh.
import Cocoa

let W = 660.0, H = 400.0
let ICON_L = 180.0, ICON_R = 480.0, ICON_Y = 210.0   // icon centres; y measured from the bottom here (Finder y = 190)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 144 dpi, so Finder shows it sharp
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }
let line = c(0.62, 0.85, 1)            // blueprint white-blue
func stroke(_ p: NSBezierPath, _ w: Double, _ color: NSColor, dash: [CGFloat]? = nil) {
    p.lineWidth = w; color.setStroke()
    if let d = dash { p.setLineDash(d, count: d.count, phase: 0) }
    p.stroke()
}
func seg(_ a: NSPoint, _ b: NSPoint) -> NSBezierPath { let p = NSBezierPath(); p.move(to: a); p.line(to: b); return p }

// Paper
NSGradient(starting: c(0.03, 0.20, 0.42), ending: c(0.05, 0.30, 0.58))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
// Grid: fine every 20pt, bold every 100pt
for x in stride(from: 0.0, through: W, by: 20) { stroke(seg(NSPoint(x: x, y: 0), NSPoint(x: x, y: H)), x.truncatingRemainder(dividingBy: 100) == 0 ? 0.8 : 0.4, line.withAlphaComponent(x.truncatingRemainder(dividingBy: 100) == 0 ? 0.20 : 0.08)) }
for y in stride(from: 0.0, through: H, by: 20) { stroke(seg(NSPoint(x: 0, y: y), NSPoint(x: W, y: y)), y.truncatingRemainder(dividingBy: 100) == 0 ? 0.8 : 0.4, line.withAlphaComponent(y.truncatingRemainder(dividingBy: 100) == 0 ? 0.20 : 0.08)) }

// Network: seeded nodes joined to near neighbours, kept clear of the icons, arrow, otter and text
var seed: UInt64 = 11
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
func blocked(_ p: NSPoint) -> Bool {
    (abs(p.x - ICON_L) < 100 || abs(p.x - ICON_R) < 100) && p.y > 100 && p.y < 310
        || (p.x > 200 && p.x < 460 && p.y > 170 && p.y < 250)
        || (abs(p.x - 330) < 75 && p.y > 285)
        || (p.y < 85 && p.x > 90 && p.x < 570)
}
var nodes: [NSPoint] = []
while nodes.count < 30 {
    let p = NSPoint(x: 14 + rnd() * (W - 28), y: 14 + rnd() * (H - 28))
    if !blocked(p) && !nodes.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 62 }) { nodes.append(p) }
}
for (i, a) in nodes.enumerated() {
    for b in nodes[(i + 1)...] where hypot(a.x - b.x, a.y - b.y) < 135 {
        let mid = NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if !blocked(mid) { stroke(seg(a, b), 0.9, line.withAlphaComponent(0.35)) }
    }
}
for (i, p) in nodes.enumerated() {   // hollow nodes with registration ticks, like survey marks
    let r = i % 4 == 0 ? 6.0 : 4.0
    c(0.04, 0.24, 0.48).setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
    stroke(NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), 1.1, i % 4 == 0 ? c(1, 0.85, 0.45) : line)
    if i % 4 == 0 {
        stroke(seg(NSPoint(x: p.x - r - 5, y: p.y), NSPoint(x: p.x + r + 5, y: p.y)), 0.8, c(1, 0.85, 0.45, 0.8))
        stroke(seg(NSPoint(x: p.x, y: p.y - r - 5), NSPoint(x: p.x, y: p.y + r + 5)), 0.8, c(1, 0.85, 0.45, 0.8))
    }
}

// Light plates behind each icon so Finder's black labels stay readable; dashed drafting outline
for cx in [ICON_L, ICON_R] {
    let plate = NSRect(x: cx - 82, y: ICON_Y - 92, width: 164, height: 168)
    let path = NSBezierPath(roundedRect: plate, xRadius: 14, yRadius: 14)
    c(0.92, 0.97, 1, 0.96).setFill(); path.fill()
    stroke(NSBezierPath(roundedRect: plate.insetBy(dx: -7, dy: -7), xRadius: 19, yRadius: 19), 1, line.withAlphaComponent(0.8), dash: [5, 4])
}

// Dimension arrow between the plates, centred on the window
let gap0 = ICON_L + 100, gap1 = ICON_R - 100, ay = ICON_Y
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: gap0, y: ay)); arrow.line(to: NSPoint(x: gap1, y: ay))
stroke(arrow, 1.6, line)
for (x, dir) in [(gap0, 1.0), (gap1, -1.0)] {   // arrowheads pointing outward at both ends, dimension-line style
    let h = NSBezierPath(); h.move(to: NSPoint(x: x + dir * 9, y: ay + 5)); h.line(to: NSPoint(x: x, y: ay)); h.line(to: NSPoint(x: x + dir * 9, y: ay - 5))
    stroke(h, 1.6, line)
    stroke(seg(NSPoint(x: x, y: ay - 14), NSPoint(x: x, y: ay + 14)), 1.2, line)
}
let para = NSMutableParagraphStyle(); para.alignment = .center
func label(_ s: String, in r: NSRect, size: Double, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
    s.draw(in: r, withAttributes: [
        .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: para])
}
let mid = (gap0 + gap1) / 2
c(0.03, 0.22, 0.45).setFill(); NSRect(x: mid - 30, y: ay - 8, width: 60, height: 16).fill()
label("DRAG", in: NSRect(x: mid - 30, y: ay - 8, width: 60, height: 14), size: 10, weight: .semibold, color: c(1, 0.85, 0.45), mono: true)

// Otter on a drafting circle, top centre
let oc = NSPoint(x: W / 2, y: 346)
c(0.92, 0.97, 1, 0.96).setFill(); NSBezierPath(ovalIn: NSRect(x: oc.x - 46, y: oc.y - 46, width: 92, height: 92)).fill()
stroke(NSBezierPath(ovalIn: NSRect(x: oc.x - 53, y: oc.y - 53, width: 106, height: 106)), 1, line.withAlphaComponent(0.8), dash: [5, 4])
NSImage(contentsOfFile: CommandLine.arguments[1])?.draw(in: NSRect(x: oc.x - 40, y: oc.y - 41, width: 80, height: 80))

// Title block, bottom centre
let box = NSRect(x: 130, y: 22, width: 400, height: 54)
stroke(NSBezierPath(rect: box), 1.2, line)
stroke(seg(NSPoint(x: box.minX, y: box.midY + 1), NSPoint(x: box.maxX, y: box.midY + 1)), 0.8, line.withAlphaComponent(0.6))
label("Drag OtterScan into Applications", in: NSRect(x: box.minX, y: box.midY + 4, width: box.width, height: 22), size: 16, weight: .semibold, color: .white)
label("FIRST LAUNCH  ·  RIGHT-CLICK THE APP  ›  OPEN", in: NSRect(x: box.minX, y: box.minY + 7, width: box.width, height: 14), size: 10, weight: .regular, color: c(1, 0.85, 0.45), mono: true)

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
