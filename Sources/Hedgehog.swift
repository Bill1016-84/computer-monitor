import AppKit
import ImageIO

// MARK: - Menu bar animation (hedgehog by default)

/// The little animation in the menu bar; its speed follows CPU usage.
///
/// Built-in animations are bundled as `<file>@<frames>.png` strips (Resources/Animations), cut from the
/// sprite sheets by Tools/slice-hedgehog.py and Tools/slice-lemon.py. Users can add their own to `customFolder`:
///   - `name.gif`              animated GIF (frame count read from the file)
///   - `name@8.png`            horizontal strip of 8 equal-width frames
///   - `name/1.png, 2.png…`    a folder with one image per frame (natural sort order)
/// Any size works; frames are scaled to the menu bar height.
enum Hedgehog {
    static let height: CGFloat = 18
    private static let pixelHeight = 36   // @2x
    private static let maxFrames = 240

    struct Animation {
        let id: String
        let title: String
        let frames: [CGImage]
        /// Point size in the menu bar (widest frame, menu bar height)
        let size: NSSize
    }

    static let defaultID = "classic"
    /// Built-ins, grouped by character; `file` is the strip name before "@"
    private static let builtIns: [(id: String, title: String, file: String)] = [
        ("classic", "刺蝟・經典奔跑", "hedgehog-classic"), ("dash", "刺蝟・衝刺滑倒", "hedgehog-dash"),
        ("sleep", "刺蝟・跑累睡覺", "hedgehog-sleep"), ("ball", "刺蝟・滾球模式", "hedgehog-ball"),
        ("apple", "刺蝟・追逐蘋果", "hedgehog-apple"),
        ("lemon-plane", "檸檬・搭乘紙飛機", "lemon-plane"), ("lemon-rain", "檸檬・撐傘下雨", "lemon-rain"),
        ("lemon-eat", "檸檬・吃東西", "lemon-eat"), ("lemon-costume", "檸檬・變裝變形", "lemon-costume"),
        ("lemon-nap", "檸檬・打瞌睡休息", "lemon-nap"),
    ]
    private static let customPrefix = "custom:"

    static let customFolder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ComputerMonitor/Animations", isDirectory: true)

    /// Seconds per frame: a slow stroll when idle, a sprint at 100%
    static func frameDuration(cpu: Double) -> TimeInterval {
        0.2 - 0.17 * min(1, max(0, cpu))
    }

    // MARK: Listing

    struct Entry {
        let id: String
        let title: String
        let group: String   // character (built-ins) or "custom"; the menu puts a separator between groups
        let thumbnail: NSImage?
    }

    /// Built-ins, then whatever is in the custom folder right now (thumbnails only, frames load on use)
    static func entries() -> [Entry] {
        let builtIn = builtIns.compactMap { b in
            builtInURL(b.file).map {
                Entry(id: b.id, title: b.title, group: String(b.file.prefix { $0 != "-" }), thumbnail: thumbnail($0))
            }
        }
        let custom = customSources().map { url in
            Entry(id: customPrefix + url.lastPathComponent, title: displayName(url), group: "custom", thumbnail: thumbnail(url))
        }
        return builtIn + custom
    }

    /// Full animation for `id`, falling back to the default if it's missing or unreadable
    static func load(_ id: String) -> Animation {
        if let a = loadExact(id) { return a }
        return loadExact(defaultID) ?? Animation(id: defaultID, title: "", frames: [], size: .zero)
    }

    private static func loadExact(_ id: String) -> Animation? {
        let url: URL?, title: String
        if id.hasPrefix(customPrefix) {
            // A bare file name only — never let a stored setting point outside the custom folder
            let name = String(id.dropFirst(customPrefix.count))
            guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
            url = customFolder.appendingPathComponent(name)
            title = url.map(displayName) ?? id
        } else {
            let b = builtIns.first { $0.id == id }
            url = b.flatMap { builtInURL($0.file) }
            title = b?.title ?? id
        }
        guard let url, let frames = frames(url, firstOnly: false), !frames.isEmpty else { return nil }
        let width = frames.map { CGFloat($0.width) * height / CGFloat($0.height) }.max() ?? 0
        return Animation(id: id, title: title, frames: frames, size: NSSize(width: width, height: height))
    }

    /// Creates the custom folder (with a how-to file) and returns it
    @discardableResult
    static func prepareCustomFolder() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: customFolder, withIntermediateDirectories: true)
        let readme = customFolder.appendingPathComponent("使用說明.txt")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            把動畫放進這個資料夾，打開選單的「動畫樣式」就會出現（名稱就是檔名）。

            支援三種格式：
              1. GIF 動圖：           貓咪.gif
              2. 橫向連續格 PNG：     貓咪@8.png   （@ 後面是格數，每格同寬、由左到右）
              3. 一格一張的資料夾：   貓咪/1.png、2.png、3.png…（依檔名數字順序播放）

            小提醒：
              - 背景請用透明，在選單列上才好看。
              - 任何尺寸都可以，會自動等比例縮成選單列高度（18 點）；寬高比 1:1～3:1 最適合。
              - 播放速度由 CPU 使用率決定，GIF 本身設定的速度會被忽略。
              - 最多 \(maxFrames) 格。
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
        return customFolder
    }

    // MARK: Sources

    private static func builtInURL(_ file: String) -> URL? {
        Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil)?
            .first { $0.lastPathComponent.hasPrefix("\(file)@") }
    }

    private static let imageExtensions: Set<String> = ["png", "gif", "jpg", "jpeg", "heic", "webp", "tiff"]

    private static func customSources() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: customFolder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: .skipsHiddenFiles)) ?? []
        return items.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                || imageExtensions.contains(url.pathExtension.lowercased())
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// "貓咪@8.png" → "貓咪"
    private static func displayName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return stripCount(base)?.name ?? base
    }

    private static func stripCount(_ base: String) -> (name: String, count: Int)? {
        guard let at = base.lastIndex(of: "@"), let n = Int(base[base.index(after: at)...]), n > 0 else { return nil }
        return (String(base[..<at]), n)
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let f = frames(url, firstOnly: true)?.first else { return nil }
        return NSImage(cgImage: f, size: NSSize(width: CGFloat(f.width) * height / CGFloat(f.height), height: height))
    }

    // MARK: Decoding

    /// Decoded frames scaled to the menu bar height
    private static func frames(_ url: URL, firstOnly: Bool) -> [CGImage]? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)) ?? [])
                .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .prefix(firstOnly ? 1 : maxFrames)
            return files.compactMap { decode($0, firstOnly: true)?.first }.compactMap(scaled)
        }
        guard var images = decode(url, firstOnly: firstOnly), let first = images.first else { return nil }
        // A single image named name@N is a strip of N frames
        if images.count == 1, let n = stripCount(url.deletingPathExtension().lastPathComponent)?.count, n > 1 {
            let w = first.width / n
            guard w > 0 else { return nil }
            images = (0..<min(n, firstOnly ? 1 : maxFrames)).compactMap {
                first.cropping(to: CGRect(x: $0 * w, y: 0, width: w, height: first.height))
            }
        }
        return images.compactMap(scaled)
    }

    /// Every frame of an image file (several for GIF / APNG)
    private static func decode(_ url: URL, firstOnly: Bool) -> [CGImage]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(src), firstOnly ? 1 : maxFrames)
        let images = (0..<count).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
        return images.isEmpty ? nil : images
    }

    /// Scale to the @2x menu bar height so big source art doesn't sit in memory
    private static func scaled(_ img: CGImage) -> CGImage? {
        guard img.height != pixelHeight else { return img }
        let w = max(1, Int((CGFloat(img.width) * CGFloat(pixelHeight) / CGFloat(img.height)).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: pixelHeight))
        return ctx.makeImage()
    }
}
