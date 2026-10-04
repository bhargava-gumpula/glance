import AppKit
import ScreenCaptureKit

/// Phase 3 memory: every `Config.checkIntervalSeconds` (1 s) the frontmost window is checked against the
/// exclusions, captured and OCR'd on-device. Every `Config.snapshotIntervalSeconds` (3 s) the most recent read is
/// stored (text plus a small thumbnail), unless it is identical to the last stored text for that window.
/// Exclusions are checked before capture and again before OCR, so a skipped frame is never read or stored.
@MainActor
final class MemoryRecorder {
    enum State: Equatable { case recording, paused, skipping(String), off(String) }

    private(set) var state: State = .recording { didSet { if state != oldValue { onChange?(state) } } }
    var onChange: ((State) -> Void)?
    let timeline: Timeline?

    private var timer: Timer?
    private var busySince: Date?
    private var ticks = 0
    private var snapshots = SnapshotGate()
    /// Bumped by forget/pause so a frame captured before them is never stored after them.
    private var generation = 0
    /// Display asleep, screen locked or user switched out: no capture at all.
    private var suspended = false
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
        timer = Timer.scheduledTimer(withTimeInterval: Config.checkIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
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
        snapshots = SnapshotGate()
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
        if ticks % 60 == 0 { trim(timeline) } // rolling deletion about once a minute, paused or not
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

        let key = "\(window.bundleID ?? "")|\(window.title ?? "")|\(window.url ?? "")"

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

        let appName = app.localizedName ?? window.bundleID ?? "App"
        let read = try await Task.detached(priority: .utility) { () -> (text: String, ocr: Double) in
            let t = Date()
            let text = try OCR.lines(in: frame, languageCorrection: false).map(\.text).joined(separator: "\n")
            return (text, Date().timeIntervalSince(t))
        }.value
        // Paused or forgotten while OCR ran: store nothing, and leave the indicator alone.
        guard g == generation, !paused else { return }
        state = .recording
        // Every check reads; only one read per snapshot interval is stored, and never a duplicate of the last row.
        guard snapshots.admit(key: key, text: read.text, now: Date()) else { return }
        let thumb = await Task.detached(priority: .utility) { Self.thumbnail(frame) }.value
        guard g == generation, !paused else { return }
        try timeline.insert(app: appName, bundleID: window.bundleID, title: window.title, url: window.url,
                            text: read.text, thumb: thumb)
        log.notice("memory: stored a snapshot (OCR \(read.ocr, format: .fixed(precision: 2), privacy: .public) s, check \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s)")
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

    /// Decides which reads become rows: at most one per `Config.snapshotIntervalSeconds`, and none whose text is
    /// identical to the last row stored for the same window (saves storage). Selftested.
    struct SnapshotGate {
        private var lastAt = Date.distantPast
        private var lastText: [String: Int] = [:]

        mutating func admit(key: String, text: String, now: Date) -> Bool {
            guard !text.isEmpty, now.timeIntervalSince(lastAt) >= Config.snapshotIntervalSeconds - 0.25 else { return false }
            lastAt = now // this snapshot slot is used even when the text is a duplicate
            guard lastText[key] != text.hashValue else { return false }
            lastText[key] = text.hashValue
            return true
        }
    }

    // MARK: Thumbnails (selftested)

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
