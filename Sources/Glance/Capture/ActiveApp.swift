import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The frontmost app's focused window, read through Accessibility (no Automation prompt).
@MainActor
enum ActiveApp {
    /// A hung app must not freeze Glance: every AX call gives up after this long (the default is 6 s).
    static func limitAXWaits() { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25) }

    static func current() -> (app: NSRunningApplication?, window: Exclusions.Window, ax: AXUIElement?) {
        let app = NSWorkspace.shared.frontmostApplication
        var w = Exclusions.Window(bundleID: app?.bundleIdentifier, secureInput: secureInput())
        guard let app else { return (nil, w, nil) }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let isBrowser = Config.browsers.contains(app.bundleIdentifier ?? "")
        // Chromium only builds its AX tree when asked (UNVERIFIED on current Chrome). Once per process: it makes
        // Chrome keep a full tree.
        if isBrowser, manualAXSet.insert(app.processIdentifier).inserted {
            AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let win: AXUIElement = ax(el, kAXFocusedWindowAttribute) else { return (app, w, nil) }
        w.title = ax(win, kAXTitleAttribute)
        w.url = ax(win, kAXDocumentAttribute)
        guard isBrowser else { return (app, w, win) }

        // The walk costs many AX calls, so its result is reused for the same window element and title, for 15 s.
        if let c = cache, CFEqual(c.window, win), c.title == w.title, Date().timeIntervalSince(c.at) < 15 {
            w.url = w.url ?? c.url
            w.isPrivate = c.isPrivate
            return (app, w, win)
        }
        // Walk the browser chrome (not the page) for the page URL and private-window markers.
        var isPrivate = Exclusions.looksPrivate(w.title ?? "")
        var queue = [win], next = 0, sawWebArea = false
        while next < queue.count, next < 300 {
            let e = queue[next]
            next += 1
            let role: String? = ax(e, kAXRoleAttribute)
            if role == "AXWebArea" {
                sawWebArea = true
                if w.url == nil, let u: URL = ax(e, "AXURL") { w.url = u.absoluteString }
                continue
            }
            for attr in [kAXDescriptionAttribute, kAXTitleAttribute] {
                if let s: String = ax(e, attr), Exclusions.looksPrivate(s) { isPrivate = true }
            }
            queue += (ax(e, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        // Owner decision: a readable window without private markers is a normal window, even when the walk didn't
        // reach the page or its URL. It is stored without a URL (the blocklist still checks the title).
        w.isPrivate = isPrivate
        if !sawWebArea || next < queue.count {
            log.notice("memory: browser window only partly readable (page reached: \(sawWebArea, privacy: .public)); no private markers seen")
        }
        cache = (win, w.title, w.url, isPrivate, Date())
        return (app, w, win)
    }

    private static var cache: (window: AXUIElement, title: String?, url: String?, isPrivate: Bool, at: Date)?
    private static var manualAXSet = Set<pid_t>()

    /// The focused window's frame in global top-left coordinates, to match it to a ScreenCaptureKit window.
    static func frame(of win: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv: AXValue = ax(win, kAXPositionAttribute), let sv: AXValue = ax(win, kAXSizeAttribute),
              AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// A password field is focused anywhere: the focused AX element is a secure text field, or some app turned on
    /// secure keyboard entry (system-wide, so it errs on the side of skipping).
    nonisolated static func secureInput() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let el: AXUIElement = ax(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return false }
        let role: String? = ax(el, kAXRoleAttribute), sub: String? = ax(el, kAXSubroleAttribute)
        return sub == kAXSecureTextFieldSubrole || role == kAXSecureTextFieldSubrole
    }

    nonisolated private static func ax<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if T.self == AXValue.self, CFGetTypeID(v) == AXValueGetTypeID() { return (v as! T) }
        return v as? T
    }
}
