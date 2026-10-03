import AppKit
import ScreenCaptureKit

/// Phase 3 memory: every `Config.captureIntervalSeconds`, snapshot only the frontmost window, skip it if it is
/// excluded or unchanged, OCR it on-device and store the text plus a small thumbnail in the Timeline.
/// Exclusions are checked before capture and again before OCR, so a skipped frame is never read or stored.
@MainActor
final class MemoryRecorder {
    enum State: Equatable { case recording, paused, skipping(String), off(String) }

    private(set) var state: State = .recording { didSet { if state != oldValue { onChange?(state) } } }
    var onChange: ((State) -> Void)?
    let timeline: Timeline?

    private var timer: Timer?
    private var busy = false
    private var lastSignature: [UInt8] = []
    private var lastKey = ""
    private var lastTextHash = 0
    private var ticks = 0
    /// Bumped by forget/pause so a frame captured before them is never stored after them.
    private var generation = 0

    init() {
        do { timeline = try Timeline() } catch {
            timeline = nil
            log.error("memory off: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start() {
        guard let timeline else { state = .off("database unavailable"); return }
        try? timeline.trim(olderThan: Date().timeIntervalSince1970 - Double(Config.retentionMinutes * 60))
        timer = Timer.scheduledTimer(withTimeInterval: Config.captureIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
    }

    var paused: Bool {
        get { state == .paused }
        set {
            state = newValue ? .paused : .recording
            generation += 1
            lastSignature = []
        }
    }

    /// Deletes the last `Config.forgetMinutes` (rows, FTS entries, thumbnails). Returns how many rows went.
    @discardableResult
    func forgetRecent() -> Int {
        guard let timeline else { return 0 }
        let before = (try? timeline.count()) ?? 0
        try? timeline.forget(since: Date().timeIntervalSince1970 - Double(Config.forgetMinutes * 60))
        generation += 1
        lastSignature = []
        lastTextHash = 0
        return before - ((try? timeline.count()) ?? 0)
    }

    private func tick() {
        guard let timeline else { return }
        ticks += 1
        if ticks % 20 == 0 { // rolling deletion about once a minute, paused or not
            try? timeline.trim(olderThan: Date().timeIntervalSince1970 - Double(Config.retentionMinutes * 60))
        }
        guard state != .paused, !busy else { return }
        let (app, window) = ActiveApp.current()
        if let reason = Exclusions.memorySkipReason(window) { state = .skipping(reason); return }
        guard let app else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await capture(app: app, window: window, into: timeline) } catch {
                log.error("memory capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func capture(app: NSRunningApplication, window: Exclusions.Window, into timeline: Timeline) async throws {
        let started = Date()
        let generation = generation
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let windowID = Self.frontWindowID(pid: app.processIdentifier),
              let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return }
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width) // 1× points: enough for OCR, a quarter of the Retina pixels
        config.height = Int(scWindow.frame.height)
        config.showsCursor = false
        let frame = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)

        // Re-check after the capture: the user may have tabbed into a password field or switched windows meanwhile.
        let (nowApp, nowWindow) = ActiveApp.current()
        if let reason = Exclusions.memorySkipReason(nowWindow) { state = .skipping(reason); return }
        guard state != .paused, generation == self.generation, nowApp?.processIdentifier == app.processIdentifier, nowWindow.title == window.title
        else { return }

        let key = "\(window.bundleID ?? "")|\(window.title ?? "")|\(window.url ?? "")"
        let signature = Self.signature(frame)
        if key == lastKey, !Self.changed(lastSignature, signature) { state = .recording; return }
        lastKey = key
        lastSignature = signature

        let appName = app.localizedName ?? window.bundleID ?? "App"
        let read = try await Task.detached(priority: .utility) { () -> (text: String, thumb: Data?, ocr: Double) in
            let t = Date()
            let text = try OCR.lines(in: frame).map(\.text).joined(separator: "\n")
            return (text, text.isEmpty ? nil : Self.thumbnail(frame), Date().timeIntervalSince(t))
        }.value
        state = .recording
        // Paused while OCR ran, nothing readable, or the same text as the last row: store nothing.
        guard !paused, generation == self.generation, !read.text.isEmpty, read.text.hashValue != lastTextHash else { return }
        lastTextHash = read.text.hashValue
        try timeline.insert(app: appName, bundleID: window.bundleID, title: window.title, url: window.url,
                            text: read.text, thumb: read.thumb)
        log.notice("memory: stored a frame (OCR \(read.ocr, format: .fixed(precision: 2), privacy: .public) s, total \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s)")
    }

    /// The frontmost normal window of `pid` (CGWindowList is ordered front to back).
    static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return list.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
        }?[kCGWindowNumber as String] as? CGWindowID
    }

    // MARK: Cheap change detection and thumbnails (selftested)

    /// 128×72 grey copy of the frame.
    nonisolated static func signature(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 128 * 72)
        px.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 128,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            c.interpolationQuality = .medium
            c.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 72))
        }
        return px
    }

    nonisolated static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var cells = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 6 { cells += 1 }
        return Double(cells) / Double(a.count) > Config.frameChangeFraction
    }

    /// Small JPEG, longest side `Config.thumbnailMaxDimension`.
    nonisolated static func thumbnail(_ image: CGImage) -> Data? {
        let s = min(1, Double(Config.thumbnailMaxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        c.interpolationQuality = .medium
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage().flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        }
    }
}
