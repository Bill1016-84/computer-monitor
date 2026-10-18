// Renders the app icon: swift Tools/make-icon.swift <out.png>
import AppKit

let S: CGFloat = 1024
func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
}
let blue = hex(0x3d8bff), orange = hex(0xff7a3d), aqua = hex(0x22d39a), violet = hex(0x9a8cff)
let gold = hex(0xd9b25a)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centered on a 1024 canvas
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -12)
sh.set(); hex(0x10162a).setFill(); squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [hex(0x1d2747), hex(0x0c1022)])!.draw(in: body, angle: -90)
// Soft center glow
NSGradient(colors: [hex(0x3d5bff, 0.28), hex(0x3d5bff, 0)])!.draw(fromCenter: NSPoint(x: 512, y: 512), radius: 0,
                                                                   toCenter: NSPoint(x: 512, y: 512), radius: 430, options: [])
// Faint PCB dot grid
hex(0xffffff, 0.05).setFill()
var gy: CGFloat = 132
while gy < 924 { var gx: CGFloat = 132; while gx < 924 { NSBezierPath(ovalIn: NSRect(x: gx - 3, y: gy - 3, width: 6, height: 6)).fill(); gx += 48 }; gy += 48 }

// Chip geometry
let chip = NSRect(x: 352, y: 352, width: 320, height: 320)

// Traces: per side 3 lines, each fanning out with a 45° bend to the edge
struct Side { let n: CGPoint; let t: CGPoint; let color: NSColor }
let sides = [Side(n: CGPoint(x: 0, y: 1), t: CGPoint(x: 1, y: 0), color: blue),     // top: CPU
             Side(n: CGPoint(x: 1, y: 0), t: CGPoint(x: 0, y: 1), color: orange),   // right: memory
             Side(n: CGPoint(x: 0, y: -1), t: CGPoint(x: 1, y: 0), color: aqua),    // bottom: GPU
             Side(n: CGPoint(x: -1, y: 0), t: CGPoint(x: 0, y: 1), color: violet)]  // left: network
var particles: [(CGPoint, NSColor, CGFloat)] = []
for side in sides {
    for (i, off) in [-100.0, 0.0, 100.0].enumerated() {
        let o = CGFloat(off)
        let p = CGPoint(x: 512 + side.n.x * 160 + side.t.x * o, y: 512 + side.n.y * 160 + side.t.y * o)
        let a = CGPoint(x: p.x + side.n.x * 40, y: p.y + side.n.y * 40)
        let shift = o * 0.9
        let b = CGPoint(x: a.x + side.n.x * abs(shift) + side.t.x * shift, y: a.y + side.n.y * abs(shift) + side.t.y * shift)
        let c = CGPoint(x: b.x + side.n.x * 400, y: b.y + side.n.y * 400)
        let path = NSBezierPath(); path.move(to: p); path.line(to: a); path.line(to: b); path.line(to: c)
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        // glow + core line
        NSGraphicsContext.saveGraphicsState()
        let g = NSShadow(); g.shadowColor = side.color.withAlphaComponent(0.9); g.shadowBlurRadius = 18; g.shadowOffset = .zero; g.set()
        side.color.withAlphaComponent(0.55).setStroke(); path.lineWidth = 10; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        // particle somewhere along the trace
        let frac: CGFloat = [0.55, 0.25, 0.75][i]
        let along = i == 1 ? CGPoint(x: a.x + (c.x - a.x) * frac * 0.5, y: a.y + (c.y - a.y) * frac * 0.5)
                           : CGPoint(x: b.x + (c.x - b.x) * (frac - 0.4), y: b.y + (c.y - b.y) * (frac - 0.4))
        particles.append((along, side.color, i == 1 ? 26 : 20))
        // gold pin
        let pin = NSBezierPath(); pin.move(to: p); pin.line(to: CGPoint(x: p.x + side.n.x * 26, y: p.y + side.n.y * 26))
        pin.lineWidth = 22; pin.lineCapStyle = .butt; gold.setStroke(); pin.stroke()
    }
}
for (pt, color, r) in particles {
    NSGraphicsContext.saveGraphicsState()
    let g = NSShadow(); g.shadowColor = color; g.shadowBlurRadius = 30; g.shadowOffset = .zero; g.set()
    color.blended(withFraction: 0.45, of: .white)!.setFill()
    NSBezierPath(ovalIn: NSRect(x: pt.x - r / 2, y: pt.y - r / 2, width: r, height: r)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

// Chip body
let chipPath = NSBezierPath(roundedRect: chip, xRadius: 44, yRadius: 44)
NSGraphicsContext.saveGraphicsState()
let cg = NSShadow(); cg.shadowColor = hex(0x5b7bff, 0.8); cg.shadowBlurRadius = 60; cg.shadowOffset = .zero; cg.set()
hex(0x161a2c).setFill(); chipPath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [hex(0x2a3150), hex(0x141828)])!.draw(in: chipPath, angle: -90)
// Gradient border cycling the four metric colors
NSGraphicsContext.saveGraphicsState()
let ring = NSBezierPath(roundedRect: chip.insetBy(dx: 4, dy: 4), xRadius: 40, yRadius: 40)
ring.lineWidth = 12
ctx.addPath(ring.cgPath); ctx.replacePathWithStrokedPath(); ctx.clip()
NSGradient(colors: [blue, violet, aqua, orange, blue])!.draw(in: chip, angle: -45)
NSGraphicsContext.restoreGraphicsState()
// Inner die
let die = NSBezierPath(roundedRect: chip.insetBy(dx: 46, dy: 46), xRadius: 22, yRadius: 22)
hex(0xffffff, 0.1).setStroke(); die.lineWidth = 5; die.stroke()

// Pulse line inside the die = "monitor"
let pulse = NSBezierPath()
let pts: [(CGFloat, CGFloat)] = [(0, 0), (0.28, 0), (0.38, 0.32), (0.5, -0.42), (0.62, 0.18), (0.7, 0), (1, 0)]
let pr = chip.insetBy(dx: 74, dy: 74)
for (k, (x, y)) in pts.enumerated() {
    let q = CGPoint(x: pr.minX + x * pr.width, y: pr.midY + y * pr.height)
    k == 0 ? pulse.move(to: q) : pulse.line(to: q)
}
pulse.lineWidth = 20; pulse.lineCapStyle = .round; pulse.lineJoinStyle = .round
NSGraphicsContext.saveGraphicsState()
let pg = NSShadow(); pg.shadowColor = hex(0x7fd4ff); pg.shadowBlurRadius = 24; pg.shadowOffset = .zero; pg.set()
NSColor.white.setStroke(); pulse.stroke()
NSGraphicsContext.restoreGraphicsState()
// pin-1 dot
hex(0xffffff, 0.45).setFill()
NSBezierPath(ovalIn: NSRect(x: chip.minX + 26, y: chip.maxY - 46, width: 20, height: 20)).fill()

// Top sheen
NSGradient(colors: [hex(0xffffff, 0.1), hex(0xffffff, 0)])!.draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Hairline edge
hex(0xffffff, 0.12).setStroke(); squircle.lineWidth = 3; squircle.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
