import AppKit
import ApplicationServices

/// Follows a menu path (File › Export To › PDF…) as the user opens each menu, through AX notifications only.
/// No model calls; it only reads titles and frames.
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
        }, &obs) == .success, let obs else { log.error("guide: AXObserverCreate failed"); return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Config.axTimeout)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notes { AXObserverAddNotification(obs, app, n as CFString, me) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    func stop() {
        pending?.cancel()
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    private func handle(_ note: String, _ el: AXUIElement) {
        switch note {
        case kAXMenuOpenedNotification:
            openMenus += 1
            pending?.cancel()
            menuOpened(el)
        case kAXMenuClosedNotification:
            openMenus = max(0, openMenus - 1)
            guard openMenus == 0 else { return }
            pending?.cancel()
            let last = reachedLast
            // Sliding across the menu bar closes one menu and opens the next; wait before calling it a stop.
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(last ? 2 : 0.4))
                guard let self, !Task.isCancelled, self.openMenus == 0 else { return }
                self.reachedLast = false
                self.onEvent(.redirect(self.barItem.flatMap(AX.frame), "Start at \(self.title(0)) again."))
            }
        default: // a sheet or window appeared, or focus moved to one
            if reachedLast && openMenus == 0 {
                pending?.cancel()
                reachedLast = false
                onEvent(.done)
            }
        }
    }

    private func menuOpened(_ menu: AXUIElement) {
        guard let parent: AXUIElement = AX.value(menu, kAXParentAttribute) else { return }
        let parentTitle = AX.normalizeTitle(AX.value(parent, kAXTitleAttribute) ?? "")
        let items: [AXUIElement] = AX.value(menu, kAXChildrenAttribute) ?? []
        if let i = path.firstIndex(of: parentTitle), i + 1 < path.count,
           let item = items.first(where: { AX.normalizeTitle(AX.value($0, kAXTitleAttribute) ?? "") == path[i + 1] }),
           let frame = AX.frame(of: item) {
            let isLast = i + 2 == path.count
            reachedLast = isLast
            let hasSub = !((AX.value(item, kAXChildrenAttribute) as [AXUIElement]?) ?? []).isEmpty
            let label = title(i + 1)
            onEvent(.point(frame, isLast ? "Click \(label)." : hasSub ? "Hover \(label)." : "Now \(label)."))
            return
        }
        // Another top menu: fine while sliding across the bar, wrong if it stays open.
        let role: String? = AX.value(parent, kAXRoleAttribute)
        guard role == kAXMenuBarItemRole as String, parentTitle != path.first else { return }
        let shown = AX.value(parent, kAXTitleAttribute) ?? "that"
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, self.openMenus > 0 else { return }
            self.onEvent(.redirect(self.barItem.flatMap(AX.frame), "That's \(shown). Close it and click \(self.title(0))."))
        }
    }

    private func title(_ i: Int) -> String { titles[i] }
}
