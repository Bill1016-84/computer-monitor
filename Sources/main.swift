import AppKit
import IOKit
import IOKit.ps
import ServiceManagement

// MARK: - App

enum Metric: String, CaseIterable {
    case hedgehog, cpu, mem, gpu, net, battery
    var title: String {
        switch self {
        case .hedgehog: "跑步動畫"; case .cpu: "CPU"; case .mem: "記憶體"; case .gpu: "GPU"; case .net: "網路速度"; case .battery: "電池"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let cpu = CPUMonitor()
    private let net = NetworkMonitor()
    private var timer: Timer?
    private let menu = NSMenu()
    private var infoItems: [String: NSMenuItem] = [:]
    private let defaults = UserDefaults.standard
    private let panel = GraphPanelView()
    private var animTimer: Timer?
    private var menuOpen = false
    private var disk: (used: Int64, total: Int64)?
    private var diskCheckedAt = Date.distantPast
    private var cpuLevel = 0.0
    private var hedgehogFrame = 0
    private var hedgehogTimer: Timer?
    private let hedgehogLayer = CALayer()
    private lazy var animation = Hedgehog.load(animationID)
    private let styleMenu = NSMenu()

    private var interval: TimeInterval {
        get { let v = defaults.double(forKey: "interval"); return v > 0 ? v : 2 }
        set { defaults.set(newValue, forKey: "interval") }
    }
    private var animationID: String {
        get { defaults.string(forKey: "hedgehogStyle") ?? Hedgehog.defaultID }
        set { defaults.set(newValue, forKey: "hedgehogStyle") }
    }
    private func isShown(_ m: Metric) -> Bool {
        defaults.object(forKey: "show.\(m.rawValue)") as? Bool ?? (m == .hedgehog || m == .cpu || m == .mem || m == .net)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        statusItem.menu = menu
        _ = cpu.sample(); _ = net.sample()
        startTimer()
        stepHedgehog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)   // keep updating while the menu is open
        timer = t
    }

    /// Advance the menu bar hedgehog one frame; the next frame comes sooner the busier the CPU is
    /// Stops (no timer at all) while the hedgehog is hidden
    private func stepHedgehog() {
        hedgehogTimer?.invalidate()
        guard isShown(.hedgehog) else {
            statusItem.button?.image = nil
            hedgehogLayer.removeFromSuperlayer()
            return
        }
        if let button = statusItem.button, !animation.frames.isEmpty {
            // The button only holds a blank placeholder to reserve space; frames are swapped on a
            // layer above it, so the status item isn't re-laid out and redrawn on every frame
            if button.image?.size != animation.size {
                button.image = NSImage(size: animation.size)
                button.imagePosition = .imageLeft
            }
            if hedgehogLayer.superlayer == nil {
                button.wantsLayer = true
                hedgehogLayer.contentsGravity = .resizeAspect
                hedgehogLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
                button.layer?.addSublayer(hedgehogLayer)
            }
            hedgehogLayer.contentsScale = button.window?.backingScaleFactor ?? 2
            hedgehogLayer.frame = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
            hedgehogLayer.contents = animation.frames[hedgehogFrame % animation.frames.count]
            hedgehogFrame = (hedgehogFrame + 1) % animation.frames.count
        }
        let t = Timer(timeInterval: Hedgehog.frameDuration(cpu: cpuLevel), repeats: false) { [weak self] _ in self?.stepHedgehog() }
        RunLoop.main.add(t, forMode: .common)
        hedgehogTimer = t
    }

    private func buildMenu() {
        menu.delegate = self
        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())
        for key in ["cpu", "load", "gpu", "mem", "memDetail", "swap", "disk", "net", "battery", "uptime"] {
            let item = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            infoItems[key] = item
            menu.addItem(item)
            if key == "load" || key == "gpu" || key == "swap" || key == "disk" || key == "net" { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())

        let showMenu = NSMenu()
        for m in Metric.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            item.representedObject = m.rawValue
            item.target = self
            showMenu.addItem(item)
        }
        let showItem = NSMenuItem(title: "在選單列顯示", action: nil, keyEquivalent: "")
        showItem.submenu = showMenu
        menu.addItem(showItem)

        styleMenu.delegate = self   // filled in when it opens, so new custom animations show up
        let styleItem = NSMenuItem(title: "動畫樣式", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let intervalMenu = NSMenu()
        for s in [1.0, 2.0, 5.0] {
            let item = NSMenuItem(title: "\(Int(s)) 秒", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.representedObject = s
            item.target = self
            intervalMenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "更新頻率", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let login = NSMenuItem(title: "登入時自動啟動", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.tag = 99
        menu.addItem(login)

        let am = NSMenuItem(title: "打開活動監視器…", action: #selector(openActivityMonitor), keyEquivalent: "a")
        am.target = self
        menu.addItem(am)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Built-in animations, then the user's own from the custom folder
    private func rebuildStyleMenu() {
        styleMenu.removeAllItems()
        let entries = Hedgehog.entries()
        for (i, e) in entries.enumerated() {
            if i > 0, e.group != entries[i - 1].group { styleMenu.addItem(.separator()) }
            let item = NSMenuItem(title: e.title, action: #selector(setHedgehogStyle(_:)), keyEquivalent: "")
            item.representedObject = e.id
            item.image = e.thumbnail
            item.state = e.id == animation.id ? .on : .off
            item.target = self
            styleMenu.addItem(item)
        }
        styleMenu.addItem(.separator())
        let open = NSMenuItem(title: "打開自訂動畫資料夾…", action: #selector(openAnimationFolder), keyEquivalent: "")
        open.target = self
        styleMenu.addItem(open)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === styleMenu { rebuildStyleMenu(); return }
        menuOpen = true
        refresh()
        // Redraw ~30 fps while open so the charts scroll smoothly
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.panel.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
        for item in menu.items {
            if let sub = item.submenu {
                for s in sub.items {
                    if let raw = s.representedObject as? String, let m = Metric(rawValue: raw) {
                        s.state = isShown(m) ? .on : .off
                    } else if let sec = s.representedObject as? Double {
                        s.state = sec == interval ? .on : .off
                    }
                }
            }
            if item.tag == 99 { item.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu !== styleMenu else { return }
        animTimer?.invalidate()
        animTimer = nil
        menuOpen = false
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Metric(rawValue: raw) else { return }
        defaults.set(!isShown(m), forKey: "show.\(m.rawValue)")
        sender.state = isShown(m) ? .on : .off
        if m == .hedgehog { stepHedgehog() }
        refresh()
    }

    @objc private func setHedgehogStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        animationID = id
        animation = Hedgehog.load(id)
        hedgehogFrame = 0
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == animation.id ? .on : .off }
    }

    @objc private func openAnimationFolder() {
        NSWorkspace.shared.open(Hedgehog.prepareCustomFolder())
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Double else { return }
        interval = s
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? Double) == s ? .on : .off }
        startTimer()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "無法設定登入項目"
            alert.informativeText = "\(error.localizedDescription)\n請先把 App 移到「應用程式」資料夾再試一次。"
            alert.runModal()
        }
        sender.state = service.status == .enabled ? .on : .off
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    private func refresh() {
        let c = cpu.sample()
        cpuLevel = c.total
        let m = sampleMemory()
        let g = sampleGPU()
        let n = net.sample()
        let b = sampleBattery()
        let memFrac = m.total > 0 ? Double(m.used) / Double(m.total) : 0
        // Menu bar title
        var parts: [(String, String, Double?)] = []   // label, value, fraction (for coloring)
        if isShown(.cpu) { parts.append(("CPU", pct(c.total), c.total)) }
        if isShown(.mem) { parts.append(("MEM", pct(memFrac), memFrac)) }
        if isShown(.gpu), let g { parts.append(("GPU", pct(g), g)) }
        if isShown(.net) { parts.append(("↓", shortRate(n.down), nil)); parts.append(("↑", shortRate(n.up), nil)) }
        if isShown(.battery), let b { parts.append((b.charging ? "⚡︎" : "BAT", "\(b.percent)%", nil)) }
        let newTitle = title(parts)
        if let button = statusItem.button {
            if parts.isEmpty && !isShown(.hedgehog) {
                if button.title != "⌁" { button.title = "⌁" }
            } else if !button.attributedTitle.isEqual(to: newTitle) {
                button.attributedTitle = newTitle
            }
        }

        // Everything below is only visible while the menu is open
        guard menuOpen else { return }
        panel.update(cpu: c.total, mem: memFrac, gpu: g, down: n.down, up: n.up)
        let ncpu = ProcessInfo.processInfo.activeProcessorCount
        set("cpu", "CPU：\(pct(c.total))　(使用者 \(pct(c.user))，系統 \(pct(c.system)))　\(ncpu) 核心")
        let la = loadAverage()
        set("load", String(format: "平均負載：%.2f  %.2f  %.2f", la[0], la[1], la[2]))
        set("gpu", "GPU：\(g.map(pct) ?? "無法取得")")
        set("mem", "記憶體：\(fmtBytes(Double(m.used))) / \(fmtBytes(Double(m.total)))　(\(pct(memFrac)))")
        set("memDetail", "　已壓縮 \(fmtBytes(Double(m.compressed)))，固定 \(fmtBytes(Double(m.wired)))")
        set("swap", "Swap：\(fmtBytes(Double(m.swapUsed)))")
        // Disk capacity barely changes and is the slowest query (~6 ms), so check it at most every 30 s
        if Date().timeIntervalSince(diskCheckedAt) > 30 { disk = sampleDisk(); diskCheckedAt = Date() }
        if let d = disk {
            set("disk", "磁碟 (/)：\(fmtBytes(Double(d.used))) / \(fmtBytes(Double(d.total)))　剩餘 \(fmtBytes(Double(d.total - d.used)))")
        }
        set("net", "網路：↓ \(fmtRate(n.down))　↑ \(fmtRate(n.up))")
        if let b {
            var s = "電池：\(b.percent)%"
            s += b.charging ? "　充電中" : (b.pluggedIn ? "　已接電源" : "　使用電池")
            if let mins = b.minutesLeft { s += b.charging ? "（\(mins / 60):\(String(format: "%02d", mins % 60)) 後充滿）" : "（剩 \(mins / 60):\(String(format: "%02d", mins % 60))）" }
            set("battery", s)
        } else {
            set("battery", "電池：無")
        }
        set("uptime", "開機時間：\(fmtUptime(ProcessInfo.processInfo.systemUptime))")
    }

    private func set(_ key: String, _ text: String) { infoItems[key]?.title = text }

    private func shortRate(_ b: Double) -> String {
        if b < 1024 { return String(format: "%.0fB", b) }
        if b < 1024 * 1024 { return String(format: "%.0fK", b / 1024) }
        let mb = b / 1024 / 1024
        return mb < 10 ? String(format: "%.1fM", mb) : String(format: "%.0fM", mb)
    }

    private func title(_ parts: [(String, String, Double?)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for (i, (label, value, frac)) in parts.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: valueFont])) }
            out.append(NSAttributedString(string: label + " ", attributes: [.font: labelFont, .foregroundColor: NSColor.white]))
            var color = NSColor.labelColor
            if let frac { if frac >= 0.9 { color = .systemRed } else if frac >= 0.75 { color = .systemOrange } }
            // Pad to fixed width so the menu bar doesn't jitter
            let padded = String(repeating: " ", count: max(0, 4 - value.count)) + value
            out.append(NSAttributedString(string: padded, attributes: [.font: valueFont, .foregroundColor: color]))
        }
        return out
    }
}

// `ComputerMonitor --print` dumps one sample to stdout (handy for checking values)
if CommandLine.arguments.contains("--print") {
    let cpu = CPUMonitor(), net = NetworkMonitor()
    _ = cpu.sample(); _ = net.sample()
    Thread.sleep(forTimeInterval: 1)
    let c = cpu.sample(), m = sampleMemory(), n = net.sample()
    print("CPU \(pct(c.total))  user \(pct(c.user))  sys \(pct(c.system))")
    print("MEM \(fmtBytes(Double(m.used))) / \(fmtBytes(Double(m.total)))  swap \(fmtBytes(Double(m.swapUsed)))")
    print("GPU \(sampleGPU().map(pct) ?? "n/a")")
    print("NET ↓ \(fmtRate(n.down))  ↑ \(fmtRate(n.up))")
    if let d = sampleDisk() { print("DISK \(fmtBytes(Double(d.used))) / \(fmtBytes(Double(d.total)))") }
    if let b = sampleBattery() { print("BAT \(b.percent)% charging=\(b.charging) plugged=\(b.pluggedIn) mins=\(b.minutesLeft ?? -1)") }
    exit(0)
}

// `ComputerMonitor --snapshot out.png` renders the panel with demo data (light + dark)
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let view = GraphPanelView()
    view.update(cpu: 0.42, mem: 0.63, gpu: 0.18, down: 2.4e6, up: 1.3e5)
    let w = view.bounds.width, h = view.bounds.height
    let out = NSImage(size: NSSize(width: w * 2 + 20, height: h))
    out.lockFocus()
    for (j, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            NSColor(hex: j == 0 ? 0xf2f2f2 : 0x262626).setFill()
            NSRect(x: CGFloat(j) * (w + 20), y: 0, width: w, height: h).fill()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.appearance = NSAppearance(named: name)
            view.cacheDisplay(in: view.bounds, to: rep)
            rep.draw(in: NSRect(x: CGFloat(j) * (w + 20), y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    out.unlockFocus()
    let png = NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
