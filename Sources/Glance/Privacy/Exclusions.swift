import AppKit

enum Exclusions {
    static func isExcluded(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Config.excludedApps.contains(id)
    }

    /// What the memory recorder knows about the frontmost window before it captures anything.
    struct Window: Sendable {
        var bundleID: String?
        var title: String?
        var url: String?
        /// nil = couldn't tell (e.g. the browser's window isn't readable through Accessibility).
        var isPrivate: Bool?
        var secureInput: Bool
    }

    /// Why a frame must not be OCR'd or stored, or nil if it may be. Checked before capture and again after.
    static func memorySkipReason(_ w: Window) -> String? {
        guard let id = w.bundleID else { return "no frontmost app" }
        if id == Config.bundleID { return "Glance itself" }
        if Config.excludedApps.contains(id) { return "excluded app" }
        if w.secureInput { return "password field" }
        guard Config.browsers.contains(id) else { return nil }
        if w.isPrivate != false { return "private window" }
        if isBlocked(url: w.url, title: w.title) { return "blocked site" }
        if w.url == nil { return "unknown page" } // can't check the blocklist without a URL
        return nil
    }

    /// URL blocklist, checked against the URL and the window title.
    static func isBlocked(url: String?, title: String?) -> Bool {
        let text = [url, title].compactMap { $0?.lowercased() }.joined(separator: "\n")
        return Config.blockedURLKeywords.contains { text.contains($0.lowercased()) }
    }

    static func looksPrivate(_ text: String) -> Bool {
        let t = text.lowercased()
        return Config.privateWindowMarkers.contains { t.contains($0) }
    }

    /// The app that owns the frontmost normal window at a point (AppKit global coordinates), ignoring Glance.
    static func app(at point: NSPoint) -> NSRunningApplication? {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let cgPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y) // CG window bounds use a top-left origin
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  info[kCGWindowLayer as String] as? Int == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(cgPoint) else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }
}
