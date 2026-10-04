import AppKit
import ApplicationServices

/// "What's on screen now" for a question without a selection: the text of the front non-Glance window, from the
/// newest memory row when it is fresh, else read now through `ContextPacket.capture`. Text only; exclusions apply.
@MainActor
enum ScreenNow {
    struct Read: Equatable { let app: String; let title: String?; let text: String }

    /// The newest memory row of this window, if it is at most `maxAge` seconds old.
    nonisolated static func fromMemory(_ rows: [Timeline.Snippet], app: String, title: String?, now: Double,
                                       maxAge: Double = Config.screenNowMaxAge) -> Timeline.Snippet? {
        rows.filter { $0.app == app && $0.title == title && now - $0.ts <= maxAge }.max { $0.ts < $1.ts }
    }

    static func read(timeline: Timeline?) async -> Read? {
        guard let app = Guide.targetApp() else { return nil }
        let (_, window, ax) = ActiveApp.current(app)
        if let reason = Exclusions.memorySkipReason(window) {
            log.notice("screen now: skipped (\(reason, privacy: .public))")
            return nil
        }
        let name = app.localizedName ?? window.bundleID ?? "App"
        let now = Date().timeIntervalSince1970
        if let rows = try? timeline?.recent(since: now - Config.screenNowMaxAge),
           let row = fromMemory(rows, app: name, title: window.title, now: now) {
            log.notice("screen now: newest memory row (\(now - row.ts, format: .fixed(precision: 1), privacy: .public) s old)")
            return Read(app: name, title: window.title, text: row.text)
        }
        guard let ax, let f = ActiveApp.frame(of: ax) else { return nil }
        let h0 = NSScreen.screens.first?.frame.height ?? 0
        let rect = PetGeometry.cocoaRect(fromAX: f, primaryHeight: h0)
        guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }),
              !screen.frame.intersection(rect).isEmpty else { return nil }
        do {
            let started = Date()
            let p = try await ContextPacket.capture(selection: screen.frame.intersection(rect), on: screen, appName: name)
            log.notice("screen now: fresh read in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s")
            return Read(app: name, title: window.title, text: p.raw.selectedText)
        } catch {
            log.error("screen now: capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
