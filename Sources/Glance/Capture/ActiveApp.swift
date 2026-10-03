import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The frontmost app's focused window, read through Accessibility (no Automation prompt).
enum ActiveApp {
    @MainActor
    static func current() -> (app: NSRunningApplication?, window: Exclusions.Window) {
        let app = NSWorkspace.shared.frontmostApplication
        var w = Exclusions.Window(bundleID: app?.bundleIdentifier, secureInput: secureInput())
        guard let app else { return (nil, w) }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let isBrowser = Config.browsers.contains(app.bundleIdentifier ?? "")
        // Chromium only builds its AX tree when asked (UNVERIFIED on current Chrome; harmless elsewhere).
        if isBrowser { AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        guard let win: AXUIElement = ax(el, kAXFocusedWindowAttribute) else { return (app, w) }
        w.title = ax(win, kAXTitleAttribute)
        w.url = ax(win, kAXDocumentAttribute)
        guard isBrowser else { return (app, w) }
        // The walk costs many AX calls, so it reruns only when the window or its title changes.
        let key = "\(app.processIdentifier)|\(w.title ?? "")|\(w.url ?? "")"
        if let cached = cache, cached.key == key {
            w.url = cached.url
            w.isPrivate = cached.isPrivate
            return (app, w)
        }
        // Walk the browser chrome (not the page) for the page URL and private-window markers.
        var isPrivate = Exclusions.looksPrivate(w.title ?? "")
        var queue = [win], visited = 0
        while !queue.isEmpty, visited < 300 {
            let e = queue.removeFirst()
            visited += 1
            let role: String? = ax(e, kAXRoleAttribute)
            if role == "AXWebArea" {
                if w.url == nil, let u: URL = ax(e, "AXURL") { w.url = u.absoluteString }
                continue
            }
            for attr in [kAXDescriptionAttribute, kAXTitleAttribute] {
                if let s: String = ax(e, attr), Exclusions.looksPrivate(s) { isPrivate = true }
            }
            queue += (ax(e, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        // Readable window = we could tell; unreadable stays nil (treated as private).
        w.isPrivate = isPrivate
        cache = (key, w.url, isPrivate)
        return (app, w)
    }

    @MainActor private static var cache: (key: String, url: String?, isPrivate: Bool)?

    /// A password field is focused anywhere: the focused AX element is a secure text field, or some app turned on
    /// secure keyboard entry (system-wide, so it errs on the side of skipping).
    static func secureInput() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let el: AXUIElement = ax(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return false }
        let role: String? = ax(el, kAXRoleAttribute), sub: String? = ax(el, kAXSubroleAttribute)
        return sub == kAXSecureTextFieldSubrole || role == kAXSecureTextFieldSubrole
    }

    private static func ax<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? T : nil
    }
}
