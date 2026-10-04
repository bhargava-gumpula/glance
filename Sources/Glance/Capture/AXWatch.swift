import AppKit
import ApplicationServices

/// Follows a menu path (File › Export To › PDF…) as the user opens each menu, through AX notifications,
/// with a 150 ms poll for submenus whose AXMenuOpened never arrives. No model calls; it only reads titles and frames.
@MainActor
final class MenuFollower {
    enum Event {
        /// Point at this AX frame and say this.
        case point(CGRect, String)
        /// The user is in the wrong menu or let go early: re-point at path[0].
        case redirect(CGRect?, String)
        /// The last item was chosen and a window or sheet appeared.
        case done
    }

    private let pid: pid_t
    /// Normalized for matching; `titles` keeps the original words for speech.
    private let path: [String]
    private let titles: [String]
    private let barItem: AXUIElement?
    private let onEvent: (Event) -> Void
    private var observer: AXObserver?
    private var openMenus = 0
    private var reachedLast = false
    private var pending: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    /// Index of the path item Pip points at now (0 = the menu-bar title); repeats aren't re-announced.
    private var pointed = 0
    /// Last menu open/close, so Esc that closes a menu doesn't also stop Guide.
    private(set) var lastMenuActivity: Date?
    var menuOpen: Bool { openMenus > 0 }

    init(pid: pid_t, path: [String], barItem: AXUIElement?, onEvent: @escaping (Event) -> Void) {
        self.pid = pid
        self.path = path.map(AX.normalizeTitle)
        self.titles = path
        self.barItem = barItem
        self.onEvent = onEvent
    }

    private static let notes = [kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXSheetCreatedNotification,
                                kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]

    func start() {
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, element, note, refcon in
            guard let refcon else { return }
            let follower = Unmanaged<MenuFollower>.fromOpaque(refcon).takeUnretainedValue()
            let name = note as String
            MainActor.assumeIsolated { follower.handle(name, element) }
        }, &obs) == .success, let obs else { log.error("guide: AXObserverCreate failed; menu hops won't be followed"); return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Config.axTimeout)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notes {
            let err = AXObserverAddNotification(obs, app, n as CFString, me)
            if err != .success { log.error("guide: can't observe \(n, privacy: .public): AX error \(err.rawValue, privacy: .public)") }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        log.notice("guide: follower started, path \(self.titles.joined(separator: " › "), privacy: .public)")
        resumeMidPath()
    }

    func stop() {
        pending?.cancel()
        poll?.cancel()
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    /// The user already has part of the path open (e.g. File is open): continue from the deepest open hop.
    private func resumeMidPath() {
        var levels = 0
        var el = barItem
        var deepestMenu: AXUIElement?
        while let e = el, levels < path.count - 1, AX.value(e, kAXSelectedAttribute) == true,
              let menu = (AX.value(e, kAXChildrenAttribute) as [AXUIElement]?)?.first {
            levels += 1
            deepestMenu = menu
            el = item(path[levels], in: menu)
        }
        guard let menu = deepestMenu, Self.resumeHop(openLevels: levels, pathCount: path.count) != nil else { return }
        log.notice("guide: resuming mid-path, \(levels, privacy: .public) menu level(s) already open")
        openMenus = levels
        menuOpened(menu)
    }

    /// How many path menus are open → the path index to point at next, or nil when nothing is open.
    nonisolated static func resumeHop(openLevels: Int, pathCount: Int) -> Int? {
        openLevels > 0 && pathCount > 1 ? min(openLevels, pathCount - 1) : nil
    }

    private func item(_ title: String, in menu: AXUIElement) -> AXUIElement? {
        (AX.value(menu, kAXChildrenAttribute) as [AXUIElement]? ?? [])
            .first { AX.normalizeTitle(AX.value($0, kAXTitleAttribute) ?? "") == title }
    }

    private func handle(_ note: String, _ el: AXUIElement) {
        log.notice("guide: AX \(note, privacy: .public) (open menus before: \(self.openMenus, privacy: .public))")
        switch note {
        case kAXMenuOpenedNotification:
            lastMenuActivity = Date()
            openMenus += 1
            pending?.cancel()
            menuOpened(el)
        case kAXMenuClosedNotification:
            lastMenuActivity = Date()
            openMenus = max(0, openMenus - 1)
            guard openMenus == 0 else { return }
            pending?.cancel()
            poll?.cancel()
            let last = reachedLast
            // Sliding across the menu bar closes one menu and opens the next; wait before calling it a stop.
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(last ? 2 : 0.4))
                guard let self, !Task.isCancelled, self.openMenus == 0 else { return }
                // Counts can drift when an app skips a note: trust the menu bar if File is still open.
                if !last, let bar = self.barItem, AX.value(bar, kAXSelectedAttribute) == true { return }
                log.notice("guide: menus closed without finishing (reached last: \(last, privacy: .public)); back to path[0]")
                self.reachedLast = false
                self.pointed = 0
                self.onEvent(.redirect(self.barItem.flatMap(AX.frame), "Start at \(self.titles[0]) again."))
            }
        default: // a sheet or window appeared, or focus moved to one
            if reachedLast && openMenus == 0 {
                log.notice("guide: menu step finished (\(note, privacy: .public))")
                pending?.cancel()
                reachedLast = false
                onEvent(.done)
            }
        }
    }

    private func menuOpened(_ menu: AXUIElement) {
        guard let parent: AXUIElement = AX.value(menu, kAXParentAttribute) else { return }
        let parentTitle = AX.normalizeTitle(AX.value(parent, kAXTitleAttribute) ?? "")
        if let i = path.firstIndex(of: parentTitle), i + 1 < path.count {
            guard let item = item(path[i + 1], in: menu) else {
                log.error("guide: \(self.titles[i + 1], privacy: .public) not found in \(self.titles[i], privacy: .public)")
                return
            }
            guard let frame = AX.frame(of: item), AX.isUsable(frame, screens: AX.screenFrames) else {
                log.error("guide: \(self.titles[i + 1], privacy: .public) has no usable frame")
                return
            }
            let isLast = i + 2 == path.count
            reachedLast = isLast
            let hasSub = !((AX.value(item, kAXChildrenAttribute) as [AXUIElement]?) ?? []).isEmpty
            guard Self.shouldAnnounce(hop: i + 1, pointed: pointed) else { return }
            pointed = i + 1
            let label = titles[i + 1]
            log.notice("guide: hop \(i + 1, privacy: .public) → \(label, privacy: .public) ax \(NSStringFromRect(frame), privacy: .public)")
            onEvent(.point(frame, hasSub && !isLast ? "Hover \(label)." : "Click \(label)."))
            if hasSub && !isLast { watchSubmenu(of: item, hop: i + 1) }
            return
        }
        // Another top menu: fine while sliding across the bar, wrong if it stays open.
        let role: String? = AX.value(parent, kAXRoleAttribute)
        guard role == kAXMenuBarItemRole as String else { return }
        let shown = AX.value(parent, kAXTitleAttribute) ?? "that"
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, self.openMenus > 0 else { return }
            log.notice("guide: wrong menu \(shown, privacy: .public) stayed open; redirecting")
            self.pointed = 0
            self.onEvent(.redirect(self.barItem.flatMap(AX.frame), "That's \(shown). Close it and click \(self.titles[0])."))
        }
    }

    /// Fallback for apps that don't post AXMenuOpened for submenus: every 150 ms, see whether the pointed item's
    /// submenu is showing (its menu has a usable, non-zero on-screen frame). Stops once the hop moves on.
    private func watchSubmenu(of item: AXUIElement, hop: Int) {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, self.pointed == hop else { return }
                guard let menu = (AX.value(item, kAXChildrenAttribute) as [AXUIElement]?)?.first,
                      let f = AX.frame(of: menu), f.origin != .zero, AX.isUsable(f, screens: AX.screenFrames) else { continue }
                log.notice("guide: submenu seen by poll (no AXMenuOpened)")
                self.lastMenuActivity = Date() // not counted: apps without the opened note rarely send the closed one
                self.menuOpened(menu)
                return
            }
        }
    }

    /// Only a new hop is announced; a repeat (poll + notification, or reopening) stays quiet.
    nonisolated static func shouldAnnounce(hop: Int, pointed: Int) -> Bool { hop != pointed }

    /// Esc stops Guide only when it wasn't closing a menu (no menu open now or within the last 0.6 s).
    nonisolated static func escStops(menuOpen: Bool, lastMenuActivity: Date?, now: Date) -> Bool {
        guard !menuOpen else { return false }
        guard let last = lastMenuActivity else { return true }
        return now.timeIntervalSince(last) > 0.6
    }
}
