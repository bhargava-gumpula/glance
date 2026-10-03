import AppKit

enum Exclusions {
    static func isExcluded(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Config.excludedApps.contains(id)
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
