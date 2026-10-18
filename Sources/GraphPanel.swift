import AppKit

// MARK: - Colors

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    /// Separate light / dark steps of the same hue (not an automatic flip)
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

enum SeriesColor {
    static let cpu = NSColor.dynamic(light: 0x2a78d6, dark: 0x3987e5)   // blue
    static let mem = NSColor.dynamic(light: 0xeb6834, dark: 0xd95926)   // orange
    static let gpu = NSColor.dynamic(light: 0x1baf7a, dark: 0x199e70)   // aqua
    static let down = NSColor.dynamic(light: 0x4a3aa7, dark: 0x9085e9)  // violet
    static let up = NSColor.dynamic(light: 0xe87ba4, dark: 0xd55181)    // magenta
    static let pin = NSColor.dynamic(light: 0xb08d3a, dark: 0xc9a24a)   // gold contacts
    static let chip = NSColor.dynamic(light: 0x2b2d31, dark: 0x17181b)
}

// MARK: - Chip geometry

/// One circuit trace from a chip pin out to the card edge (points ordered pin → edge)
private struct Trace {
    let points: [NSPoint]
    let length: CGFloat
    let inbound: Bool
    let seed: CGFloat

    init(_ points: [NSPoint], inbound: Bool, seed: CGFloat) {
        self.points = points
        self.inbound = inbound
        self.seed = seed
        length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Point at distance `d` from the pin end
    func point(at d: CGFloat) -> NSPoint {
        var remaining = d
        for (a, b) in zip(points, points.dropFirst()) {
            let seg = hypot(b.x - a.x, b.y - a.y)
            if remaining <= seg, seg > 0 {
                let t = remaining / seg
                return NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= seg
        }
        return points.last!
    }
}

private enum ChipKind { case cpu, memory, gpu, network }

private struct Chip {
    let kind: ChipKind
    let card: NSRect
    let body: NSRect
    let traces: [Trace]
    let pins: [(NSPoint, NSPoint)]   // short metal stubs

    /// pins: number of pins on [top, right, bottom, left]
    init(kind: ChipKind, card: NSRect, size: NSSize, pins counts: [Int]) {
        self.kind = kind
        self.card = card
        body = NSRect(x: card.midX - size.width / 2, y: card.midY - size.height / 2 + 4,
                      width: size.width, height: size.height)
        var traces: [Trace] = [], pins: [(NSPoint, NSPoint)] = []
        // side: (outward normal, tangent, pin origin, side length, distance to card edge)
        let sides: [(NSPoint, NSPoint, NSPoint, CGFloat, CGFloat)] = [
            (NSPoint(x: 0, y: -1), NSPoint(x: 1, y: 0), NSPoint(x: body.minX, y: body.minY), body.width, body.minY - card.minY),
            (NSPoint(x: 1, y: 0), NSPoint(x: 0, y: 1), NSPoint(x: body.maxX, y: body.minY), body.height, card.maxX - body.maxX),
            (NSPoint(x: 0, y: 1), NSPoint(x: 1, y: 0), NSPoint(x: body.minX, y: body.maxY), body.width, card.maxY - body.maxY),
            (NSPoint(x: -1, y: 0), NSPoint(x: 0, y: 1), NSPoint(x: body.minX, y: body.minY), body.height, body.minX - card.minX),
        ]
        var index = 0
        for (side, (n, t, origin, length, reach)) in sides.enumerated() {
            let count = counts[side]
            guard count > 0 else { continue }
            for i in 0..<count {
                let along = length * CGFloat(i + 1) / CGFloat(count + 1)
                let p = NSPoint(x: origin.x + t.x * along, y: origin.y + t.y * along)
                // Fan the traces outward with a 45° bend, PCB style
                var shift = (along - length / 2) * 0.9
                shift = max(-(reach - 14), min(reach - 14, shift))
                let stub: CGFloat = 6
                let a = NSPoint(x: p.x + n.x * stub, y: p.y + n.y * stub)
                let b = NSPoint(x: a.x + n.x * abs(shift) + t.x * shift, y: a.y + n.y * abs(shift) + t.y * shift)
                let extra = reach - stub - abs(shift) + 2
                let c = NSPoint(x: b.x + n.x * extra, y: b.y + n.y * extra)
                traces.append(Trace([p, a, b, c], inbound: (side + i) % 2 == 0, seed: CGFloat(index) * 0.37))
                pins.append((p, NSPoint(x: p.x + n.x * 4, y: p.y + n.y * 4)))
                index += 1
            }
        }
        self.traces = traces
        self.pins = pins
    }
}

// MARK: - Panel

/// Dropdown panel: each metric is drawn as a chip, with data particles flowing
/// in along circuit traces from every side and back out again. Flow speed and
/// density follow the live usage.
final class GraphPanelView: NSView {
    private var cpu = 0.0, mem = 0.0, gpu: Double?, down = 0.0, up = 0.0

    private let margin: CGFloat = 12, gap: CGFloat = 10, header: CGFloat = 20
    private static let cardH: CGFloat = 140
    private var chips: [Chip] = []
    private var flow: [CGFloat] = [0, 0, 0, 0, 0]   // accumulated travel (px) per chip; [4] = network upload
    private var lastFrame: CFTimeInterval?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 12 + 20 + 6 + Self.cardH * 2 + 10 + 12))
        let cardW = (bounds.width - margin * 2 - gap) / 2
        let top = margin + header + 6
        func card(_ col: Int, _ row: Int) -> NSRect {
            NSRect(x: margin + CGFloat(col) * (cardW + gap), y: top + CGFloat(row) * (Self.cardH + gap),
                   width: cardW, height: Self.cardH)
        }
        chips = [
            Chip(kind: .cpu, card: card(0, 0), size: NSSize(width: 60, height: 60), pins: [3, 3, 3, 3]),
            Chip(kind: .memory, card: card(1, 0), size: NSSize(width: 92, height: 44), pins: [4, 1, 4, 1]),
            Chip(kind: .gpu, card: card(0, 1), size: NSSize(width: 70, height: 56), pins: [3, 2, 3, 2]),
            Chip(kind: .network, card: card(1, 1), size: NSSize(width: 70, height: 56), pins: [3, 2, 3, 2]),
        ]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(cpu: Double, mem: Double, gpu: Double?, down: Double, up: Double) {
        (self.cpu, self.mem, self.gpu, self.down, self.up) = (cpu, mem, gpu, down, up)
        needsDisplay = true
    }

    /// Network bytes/s → 0...1 on a log scale (1 KB/s ≈ 0.06, 1 MB/s ≈ 0.6, 100 MB/s = 1)
    private func netLevel(_ bytes: Double) -> Double { min(1, log10(1 + bytes / 1024) / 5) }

    private func speed(_ u: Double) -> CGFloat { 10 + 75 * CGFloat(u) }

    /// Advance particle positions; driven by the menu's 30 fps redraw timer
    private func advance() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.1, now - (lastFrame ?? now)))
        lastFrame = now
        let levels = [cpu, mem, gpu ?? 0, netLevel(down), netLevel(up)]
        for i in flow.indices { flow[i] += dt * speed(levels[i]) }
    }

    override func draw(_ dirtyRect: NSRect) {
        advance()
        let title = "即時硬體監控" as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        let ts = title.size(withAttributes: titleAttrs)
        title.draw(at: NSPoint(x: (bounds.width - ts.width) / 2, y: margin), withAttributes: titleAttrs)

        draw(chips[0], color: SeriesColor.cpu, level: cpu, flowIn: flow[0], name: "CPU", lines: [pct(cpu)])
        draw(chips[1], color: SeriesColor.mem, level: mem, flowIn: flow[1], name: "MEMORY", lines: [pct(mem)])
        draw(chips[2], color: SeriesColor.gpu, level: gpu ?? 0, flowIn: flow[2], name: "GPU", lines: [gpu.map(pct) ?? "—"])
        draw(chips[3], color: SeriesColor.down, level: max(netLevel(down), netLevel(up)), flowIn: flow[3], name: "NET",
             lines: ["↓ " + compactRate(down), "↑ " + compactRate(up)],
             outColor: SeriesColor.up, outLevel: netLevel(up), flowOut: flow[4], inLevel: netLevel(down))
    }

    // MARK: Chip drawing

    private func draw(_ chip: Chip, color: NSColor, level: Double, flowIn: CGFloat, name: String, lines: [String],
                      outColor: NSColor? = nil, outLevel: Double? = nil, flowOut: CGFloat? = nil, inLevel: Double? = nil) {
        let card = NSBezierPath(roundedRect: chip.card, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        card.fill()

        NSGraphicsContext.saveGraphicsState()
        card.addClip()

        // Circuit traces
        for trace in chip.traces {
            let path = NSBezierPath()
            path.move(to: trace.points[0])
            trace.points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            (trace.inbound ? color : (outColor ?? color)).withAlphaComponent(0.22).setStroke()
            path.stroke()
        }

        // Particles: inbound travel edge → pin, outbound pin → edge
        for trace in chip.traces {
            let pc = trace.inbound ? color : (outColor ?? color)
            let u = trace.inbound ? (inLevel ?? level) : (outLevel ?? level)
            let travel = trace.inbound ? flowIn : (flowOut ?? flowIn)
            let active = 1 + CGFloat(u) * 2   // 1...3 particles per trace
            for k in 0..<3 {
                let visible = min(1, max(0, active - CGFloat(k)))
                guard visible > 0 else { continue }
                var s = (travel + trace.length * (trace.seed + CGFloat(k) / 3)).truncatingRemainder(dividingBy: trace.length)
                if trace.inbound { s = trace.length - s }
                let fade = sqrt(sin(.pi * s / trace.length))   // appear / vanish softly at the ends
                let base = k == 0 ? 0.4 + 0.6 * min(1, CGFloat(u) * 4) : 1
                drawParticle(trace.point(at: s), pc, alpha: visible * fade * base)
            }
        }

        // Pins
        let pinPath = NSBezierPath()
        for (a, b) in chip.pins { pinPath.move(to: a); pinPath.line(to: b) }
        pinPath.lineWidth = 3
        SeriesColor.pin.setStroke()
        pinPath.stroke()
        if chip.kind == .memory { drawContacts(chip.body) }

        // Body with a glow that grows with usage
        let body = NSBezierPath(roundedRect: chip.body, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.25 + 0.6 * CGFloat(level))
        glow.shadowBlurRadius = 3 + 12 * CGFloat(level)
        glow.shadowOffset = .zero
        glow.set()
        SeriesColor.chip.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()
        body.lineWidth = 1.5
        color.setStroke()
        body.stroke()
        drawDecoration(chip)

        // Label + value inside the chip
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.6), .kern: 1]
        let valueSize: CGFloat = lines.count > 1 ? 10.5 : 16
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        let nameSize = (name as NSString).size(withAttributes: nameAttrs)
        let lineSizes = lines.map { ($0 as NSString).size(withAttributes: valueAttrs) }
        let totalH = nameSize.height + lineSizes.reduce(0) { $0 + $1.height } - 1
        var y = chip.body.midY - totalH / 2
        (name as NSString).draw(at: NSPoint(x: chip.body.midX - nameSize.width / 2, y: y), withAttributes: nameAttrs)
        y += nameSize.height - 1
        for (line, size) in zip(lines, lineSizes) {
            (line as NSString).draw(at: NSPoint(x: chip.body.midX - size.width / 2, y: y), withAttributes: valueAttrs)
            y += size.height - 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawParticle(_ p: NSPoint, _ color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(0.25 * alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)).fill()
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
    }

    /// Small details that make each chip read as what it is
    private func drawDecoration(_ chip: Chip) {
        let faint = NSColor.white.withAlphaComponent(0.12)
        let r = chip.body
        switch chip.kind {
        case .cpu:
            let die = NSBezierPath(roundedRect: r.insetBy(dx: 7, dy: 7), xRadius: 3, yRadius: 3)
            faint.setStroke(); die.lineWidth = 1; die.stroke()
            NSColor.white.withAlphaComponent(0.35).setFill()   // pin-1 marker
            NSBezierPath(ovalIn: NSRect(x: r.minX + 4, y: r.minY + 4, width: 3, height: 3)).fill()
        case .memory:
            NSColor.white.withAlphaComponent(0.07).setFill()   // DRAM packages along the module
            let w = (r.width - 16) / 4
            for i in 0..<4 where i != 1 && i != 2 {
                NSBezierPath(roundedRect: NSRect(x: r.minX + 5 + CGFloat(i) * (w + 2), y: r.minY + 6, width: w, height: r.height - 12),
                             xRadius: 2, yRadius: 2).fill()
            }
        case .gpu:
            faint.setFill()   // core grid
            for row in 0..<3 { for col in 0..<2 {
                let x = col == 0 ? r.minX + 5 : r.maxX - 9
                NSBezierPath(rect: NSRect(x: x, y: r.minY + 12 + CGFloat(row) * 12, width: 4, height: 4)).fill()
            } }
        case .network:
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.maxX - 9, y: r.minY + 11), radius: 5, startAngle: 200, endAngle: 340)
            NSColor.white.withAlphaComponent(0.3).setStroke(); arc.lineWidth = 1.2; arc.stroke()
        }
    }

    /// Gold edge connector on the memory module
    private func drawContacts(_ r: NSRect) {
        SeriesColor.pin.withAlphaComponent(0.8).setFill()
        var x = r.minX + 6
        while x < r.maxX - 8 {
            if abs(x - (r.minX + r.width * 0.38)) > 4 {   // keying notch
                NSBezierPath(rect: NSRect(x: x, y: r.maxY - 1, width: 2, height: 4)).fill()
            }
            x += 4
        }
    }

    private func compactRate(_ b: Double) -> String {
        if b < 1024 { return String(format: "%.0f B", b) }
        if b < 1024 * 1024 { return String(format: "%.0f K", b / 1024) }
        let mb = b / 1024 / 1024
        return mb < 10 ? String(format: "%.1f M", mb) : String(format: "%.0f M", mb)
    }
}
