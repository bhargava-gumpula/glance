import AppKit
import ApplicationServices

/// Guide v2: notices what the user's click changed. Observe only: AX notifications on the target app plus a
/// session-only global leftMouseDown monitor; it never clicks and never consumes an event.
@MainActor
final class GuideWatcher {
    /// What happened since the last settle: the click (AX point and the pid under it) and the AX notes.
    struct Observation {
        var click: CGPoint?
        var clickPid: pid_t?
        var strong = false   // a window or sheet appeared, the front window changed, or an element died
        var weak = false     // focus or selection moved
        var opened: String?  // title of the window or sheet that appeared
    }

    private let pid: pid_t
    /// Clicks while this returns true are ignored (MenuFollower owns menu hops).
    private let ignoreClicks: () -> Bool
    private let onSettle: (Observation) -> Void
    private var observer: AXObserver?
    private var mouse: Any?
    private var current = Observation()
    private var debounce: Task<Void, Never>?

    static let strongNotes: Set<String> = [kAXWindowCreatedNotification, kAXSheetCreatedNotification,
                                           kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification,
                                           kAXMenuOpenedNotification]
    static let weakNotes: Set<String> = [kAXFocusedUIElementChangedNotification, kAXSelectedChildrenChangedNotification]

    init(pid: pid_t, ignoreClicks: @escaping () -> Bool, onSettle: @escaping (Observation) -> Void) {
        self.pid = pid
        self.ignoreClicks = ignoreClicks
        self.onSettle = onSettle
    }

    func start() {
        var obs: AXObserver?
        if AXObserverCreate(pid, { _, element, note, refcon in
            guard let refcon else { return }
            let w = Unmanaged<GuideWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let name = note as String
            MainActor.assumeIsolated { w.note(name, element) }
        }, &obs) == .success, let obs {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Config.axTimeout)
            let me = Unmanaged.passUnretained(self).toOpaque()
            for n in Self.strongNotes.union(Self.weakNotes) { _ = AXObserverAddNotification(obs, app, n as CFString, me) }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observer = obs
        } else {
            log.error("guide: watcher AXObserverCreate failed; only clicks are watched")
        }
        mouse = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.click() }
        }
    }

    func stop() {
        debounce?.cancel()
        if let mouse { NSEvent.removeMonitor(mouse) }
        mouse = nil
        current = Observation()
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    /// Forget anything seen so far (a new step was just shown).
    func reset() {
        debounce?.cancel()
        current = Observation()
    }

    private func click() {
        guard !ignoreClicks() else { return }
        let h0 = NSScreen.screens.first?.frame.height ?? 0
        let p = Guide.axPoint(NSEvent.mouseLocation, h0: h0)
        var el: AXUIElement?
        var hitPid: pid_t = 0
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, let el {
            AXUIElementGetPid(el, &hitPid)
        }
        // Sandboxed apps (Pages) show open/save panels from an AppKit XPC service; those clicks belong to the app.
        if hitPid != pid, NSRunningApplication(processIdentifier: hitPid)?.bundleIdentifier?.hasPrefix("com.apple.appkit.xpc") == true {
            hitPid = pid
        }
        // A new click starts a new observation; notes that arrive after it belong to it.
        current = Observation(click: p, clickPid: hitPid)
        settleLater()
    }

    private func note(_ name: String, _ el: AXUIElement) {
        if Self.strongNotes.contains(name) {
            current.strong = true
            // A menu has no title of its own: name it after its menu-bar item ("Edit").
            let titled: AXUIElement? = name == kAXMenuOpenedNotification ? AX.value(el, kAXParentAttribute) : el
            if name != kAXUIElementDestroyedNotification, let titled, let t: String = AX.value(titled, kAXTitleAttribute), !t.isEmpty {
                current.opened = current.opened ?? t
            }
        } else if Self.weakNotes.contains(name) {
            current.weak = true
        }
        settleLater()
    }

    private func settleLater() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Config.guideDebounce))
            guard let self, !Task.isCancelled else { return }
            let o = self.current
            self.current = Observation()
            self.onSettle(o)
        }
    }
}

/// The local verdict on a step (pure; selftested).
enum GuideVerdict: Equatable {
    case success
    case wrong(opened: String?)
    case inconclusive
    case ignore

    enum Hit: Equatable { case right, wrong, outside, none }

    /// Where the click landed relative to the target (AX coordinates; 4 pt of slack).
    static func hit(click: CGPoint?, clickPid: pid_t?, pid: pid_t, target: CGRect?) -> Hit {
        guard let click else { return .none }
        guard clickPid == pid else { return .outside }
        guard let target else { return .wrong }
        return target.insetBy(dx: -4, dy: -4).contains(click) ? .right : .wrong
    }

    static func judge(_ hit: Hit, strong: Bool, weak: Bool, opened: String?) -> GuideVerdict {
        switch hit {
        case .right: return strong || weak ? .success : .inconclusive
        case .wrong: return strong ? .wrong(opened: opened) : .ignore   // a stray click that opened nothing is fine
        case .none: return strong ? .inconclusive : .ignore             // e.g. a keyboard shortcut changed the window
        case .outside: return .ignore
        }
    }

    static func correction(opened: String?, label: String) -> String {
        let what = opened.map { "That opened \($0)." } ?? "That's not it."
        return "\(what) Press Esc, then click \(label)."
    }
}

/// One model re-check per 3 s, at most 20 per session (on top of the consent limits).
struct RecheckLimiter {
    var gap = 3.0
    var cap = 20
    private(set) var last: Date?
    private(set) var count = 0

    /// Seconds to wait before the next re-check, or nil when the session's re-checks are used up.
    func delay(now: Date) -> TimeInterval? {
        guard count < cap else { return nil }
        guard let last else { return 0 }
        return max(0, gap - now.timeIntervalSince(last))
    }

    mutating func record(now: Date) {
        last = now
        count += 1
    }
}
