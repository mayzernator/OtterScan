// Renders the 1024px app icon: the otter on a radar-ring tile. Usage: make_icon otter.svg out.png
import Cocoa

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.13, green: 0.68, blue: 0.72, alpha: 1),
           ending: NSColor(red: 0.04, green: 0.36, blue: 0.52, alpha: 1))!.draw(in: tile, angle: -90)
tile.addClip()
NSColor(white: 1, alpha: 0.16).setStroke()
for r in [210.0, 320.0, 430.0, 540.0] {
    let ring = NSBezierPath(ovalIn: NSRect(x: 512 - r, y: 512 - r, width: r * 2, height: r * 2))
    ring.lineWidth = 14
    ring.stroke()
}

guard let otter = NSImage(contentsOfFile: CommandLine.arguments[1]) else { fatalError("can't read the svg") }
otter.draw(in: NSRect(x: 172, y: 150, width: 680, height: 680))
NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
