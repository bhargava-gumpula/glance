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
    private var busySince: Date?
    private var lastSignature: [UInt8] = []
    private var lastKey = ""
    private var lastTextHash = 0
    private var ticks = 0
    /// Bumped by forget/pause so a frame captured before them is never stored after them.
    private var generation = 0
    /// Display asleep, screen locked or user switched out: no capture at all.
    private var suspended = false
    /// Backoff for windows that keep changing pixels but not text (video, spinners): no OCR before this.
    private var noOCRUntil = Date.distantPast
    private var wastedOCRs = 0
    /// ScreenCaptureKit's window list is expensive; reused while the same window is in front at the same frame.
    private var cachedWindow: (id: CGWindowID, frame: CGRect, window: SCWindow)?

    init() {
        do { timeline = try Timeline() } catch {
            timeline = nil
            log.error("memory off: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start() {
        guard let timeline else { state = .off("database unavailable"); return }
        ActiveApp.limitAXWaits()
        trim(timeline)
        timer = Timer.scheduledTimer(withTimeInterval: Config.captureIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1
        let ws = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                              (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = value }
            }
        }
        let dist = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            dist.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = value }
            }
        }
    }

    var paused: Bool {
        get { state == .paused }
        set {
            generation += 1
            lastSignature = []
            state = newValue ? .paused : .recording
        }
    }

    /// Deletes the last `Config.forgetMinutes` (rows, FTS entries, thumbnails). Returns how many rows went.
    @discardableResult
    func forgetRecent() -> Int {
        guard let timeline else { return 0 }
        generation += 1
        let before = (try? timeline.count()) ?? 0
        try? timeline.forget(since: Date().timeIntervalSince1970 - Double(Config.forgetMinutes * 60))
        lastSignature = []
        lastTextHash = 0
        return before - ((try? timeline.count()) ?? 0)
    }

    private func trim(_ timeline: Timeline) {
        let cutoff = Date().timeIntervalSince1970 - Double(Config.retentionMinutes * 60)
        Task.detached(priority: .utility) { try? timeline.trim(olderThan: cutoff) }
    }

    /// State changes from a capture only count if nothing (pause, forget) happened since it started.
    private func report(_ s: State, generation g: Int) {
        if g == generation, !paused { state = s }
    }

    private func tick() {
        guard let timeline else { return }
        ticks += 1
        if ticks % 20 == 0 { trim(timeline) } // rolling deletion about once a minute, paused or not
        if let since = busySince {
            guard Date().timeIntervalSince(since) > 15 else { return }
            log.error("memory: a capture hung for 15 s; starting over")
            cachedWindow = nil
        }
        guard !paused, !suspended else { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled, ticks % 3 != 0 { return }
        guard CGPreflightScreenCaptureAccess() else { state = .off("needs Screen Recording permission"); return }
        let (app, window, axWindow) = ActiveApp.current()
        if let reason = Exclusions.memorySkipReason(window) { state = .skipping(reason); return }
        guard let app, let axWindow else { return }
        let g = generation
        busySince = Date()
        Task {
            defer { if self.generation == g || self.busySince != nil { self.busySince = nil } }
            do { try await capture(app: app, window: window, axWindow: axWindow, generation: g, into: timeline) } catch {
                cachedWindow = nil
                report(.skipping("capture failed"), generation: g)
                log.error("memory capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func capture(app: NSRunningApplication, window: Exclusions.Window, axWindow: AXUIElement, generation g: Int,
                         into timeline: Timeline) async throws {
        let started = Date()
        guard let scWindow = try await scWindow(pid: app.processIdentifier, title: window.title, axWindow: axWindow) else {
            report(.skipping("window not found"), generation: g)
            return
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        // A tiny capture first: most ticks end here because nothing changed.
        let small = SCStreamConfiguration()
        small.width = 256
        small.height = max(1, Int(256 * scWindow.frame.height / max(1, scWindow.frame.width)))
        small.showsCursor = false
        let preview = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: small)
        let key = "\(window.bundleID ?? "")|\(window.title ?? "")|\(window.url ?? "")"
        let signature = Self.signature(preview)
        guard g == generation, !paused else { return }
        if key == lastKey, !Self.changed(lastSignature, signature) { report(.recording, generation: g); return }
        if key == lastKey, Date() < noOCRUntil { report(.recording, generation: g); return }

        // 1× points, longest side capped: enough for OCR and a fraction of the Retina pixels.
        let full = SCStreamConfiguration()
        let scale = min(1, Double(Config.memoryMaxCaptureDimension) / max(scWindow.frame.width, scWindow.frame.height))
        full.width = Int(scWindow.frame.width * scale)
        full.height = Int(scWindow.frame.height * scale)
        full.showsCursor = false
        let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: full)

        // Re-check after the capture: the user may have tabbed into a password field or switched windows meanwhile.
        let (nowApp, nowWindow, nowAX) = ActiveApp.current()
        guard g == generation, !paused else { return }
        if let reason = Exclusions.memorySkipReason(nowWindow) { state = .skipping(reason); return }
        guard nowApp?.processIdentifier == app.processIdentifier, nowWindow.title == window.title,
              nowWindow.url == window.url, let nowAX, CFEqual(nowAX, axWindow) else { return }
        if key != lastKey { wastedOCRs = 0; noOCRUntil = .distantPast }
        lastKey = key
        lastSignature = signature

        let appName = app.localizedName ?? window.bundleID ?? "App"
        let read = try await Task.detached(priority: .utility) { () -> (text: String, thumb: Data?, ocr: Double) in
            let t = Date()
            let text = try OCR.lines(in: frame, languageCorrection: false).map(\.text).joined(separator: "\n")
            return (text, text.isEmpty ? nil : Self.thumbnail(frame), Date().timeIntervalSince(t))
        }.value
        // Paused or forgotten while OCR ran: store nothing, and leave the indicator alone.
        guard g == generation, !paused else { return }
        state = .recording
        guard !read.text.isEmpty, read.text.hashValue != lastTextHash else {
            wastedOCRs += 1 // pixels changed, text didn't: back off up to 30 s for this window
            noOCRUntil = Date().addingTimeInterval(min(30, Config.captureIntervalSeconds * pow(2, Double(wastedOCRs))))
            return
        }
        wastedOCRs = 0
        lastTextHash = read.text.hashValue
        try timeline.insert(app: appName, bundleID: window.bundleID, title: window.title, url: window.url,
                            text: read.text, thumb: read.thumb)
        log.notice("memory: stored a frame (OCR \(read.ocr, format: .fixed(precision: 2), privacy: .public) s, total \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s)")
    }

    /// The ScreenCaptureKit window that is the AX focused window: same app, same frame. If more than one matches,
    /// the frontmost one; if none, nothing is captured.
    private func scWindow(pid: pid_t, title: String?, axWindow: AXUIElement) async throws -> SCWindow? {
        guard let axFrame = ActiveApp.frame(of: axWindow) else { return nil }
        let frontID = Self.frontWindowID(pid: pid)
        if let c = cachedWindow, c.id == frontID, c.frame == axFrame { return c.window }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && close($0.frame, axFrame)
        }
        let match = candidates.count == 1 ? candidates[0] : candidates.first { $0.windowID == frontID }
        cachedWindow = match.map { ($0.windowID, axFrame, $0) }
        return match
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
