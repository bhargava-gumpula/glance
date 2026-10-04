import AppKit
import ApplicationServices

/// Guide's read-only Accessibility helpers. Nothing here presses, clicks or reads a field's value.
enum AX {
    static func value<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if T.self == AXValue.self, CFGetTypeID(v) == AXValueGetTypeID() { return (v as! T) }
        return v as? T
    }

    /// Several attributes in one round trip; missing ones come back nil.
    static func values(_ el: AXUIElement, _ attrs: [String]) -> [Any?] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, [], &out) == .success,
              let list = out as? [Any], list.count == attrs.count else { return attrs.map { _ in nil } }
        return list.map { v in
            let cf = v as CFTypeRef
            // Per-attribute errors come back as AXValue of type .axError.
            if CFGetTypeID(cf) == AXValueGetTypeID(), AXValueGetType(cf as! AXValue) == .axError { return nil }
            return v
        }
    }

    /// Global AX frame (top-left of the primary display, y down).
    static func frame(of el: AXUIElement) -> CGRect? {
        frame(position: value(el, kAXPositionAttribute), size: value(el, kAXSizeAttribute))
    }

    static func frame(position: Any?, size: Any?) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = position, let sv = size,
              CFGetTypeID(pv as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(sv as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// At least 2×2 and on some screen (AX frames compared against screens converted to AX space).
    static func isUsable(_ r: CGRect, screens: [CGRect]) -> Bool {
        r.width >= 2 && r.height >= 2 && screens.contains { $0.intersects(r) }
    }

    /// Screens in AX coordinates.
    @MainActor static var screenFrames: [CGRect] {
        let h0 = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { PetGeometry.cocoaRect(fromAX: $0.frame, primaryHeight: h0) } // the flip is its own inverse
    }

    /// Lowercase; "..." → "…"; drop a trailing "…", "›" or ":"; collapse whitespace.
    static func normalizeTitle(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "...", with: "…")
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = t.last, "…›:".contains(last) { t.removeLast(); t = t.trimmingCharacters(in: .whitespaces) }
        return t
    }
}

/// Menu-bar items flattened to paths. Only items inside menus get ids; the top titles are kept to point at.
struct MenuIndex: @unchecked Sendable {
    struct Node {
        var title: String
        var enabled = true
        var element: AXUIElement?
        var children: [Node] = []
    }

    struct Entry {
        let path: [String]
        let element: AXUIElement?
        let hasSubmenu: Bool
        var display: String { path.joined(separator: " > ") }
    }

    /// Ids M1… index into this (depth ≥ 2).
    private(set) var entries: [Entry] = []
    /// path[0] titles → the menu-bar item.
    private(set) var bar: [(title: String, element: AXUIElement?)] = []

    /// `items[0]` is the Apple menu and is skipped. Skipped menus are dropped with everything under them.
    init(bar items: [Node], maxDepth: Int = 3, cap: Int = Config.guideMaxMenuItems) {
        var out: [Entry] = []
        func walk(_ n: Node, _ path: [String]) {
            for c in n.children where out.count < cap {
                let title = c.title.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, c.enabled || !c.children.isEmpty,
                      !Config.guideSkippedMenus.contains(AX.normalizeTitle(title)) else { continue }
                out.append(Entry(path: path + [title], element: c.element, hasSubmenu: !c.children.isEmpty))
                if path.count + 1 < maxDepth { walk(c, path + [title]) }
            }
        }
        for top in items.dropFirst() where !Config.guideSkippedMenus.contains(AX.normalizeTitle(top.title)) {
            bar.append((top.title, top.element))
            walk(top, [top.title])
        }
        entries = out
    }

    /// The full path (normalized), else a unique last-title match. nil when missing or ambiguous.
    func resolve(_ path: [String]) -> Entry? {
        let want = path.map(AX.normalizeTitle)
        guard let last = want.last else { return nil }
        if let e = entries.first(where: { $0.path.map(AX.normalizeTitle) == want }) { return e }
        let byLast = entries.filter { AX.normalizeTitle($0.path.last ?? "") == last }
        return byLast.count == 1 ? byLast[0] : nil
    }

    func barItem(_ title: String) -> AXUIElement? {
        bar.first { AX.normalizeTitle($0.title) == AX.normalizeTitle(title) }?.element
    }
}

/// The front app's menus and the clickable controls of its focused window (and sheets), read once per step.
struct AXSnapshot: @unchecked Sendable {
    struct Control {
        let role: String     // button | popup | checkbox | tab | link | other
        let label: String
        let isDefault: Bool
        let frame: CGRect    // AX global
        let element: AXUIElement
        var display: String { "\(role) \"\(label)\"" + (isDefault ? " (default)" : "") }
    }

    var menus = MenuIndex(bar: [])
    var controls: [Control] = []
    var windowTitle: String?
    var sheetTitle: String?

    static let keptRoles: [String: String] = [
        "AXButton": "button", "AXPopUpButton": "popup", "AXMenuButton": "popup", "AXCheckBox": "checkbox",
        "AXRadioButton": "tab", "AXTab": "tab", "AXComboBox": "popup", "AXLink": "link", "AXDisclosureTriangle": "other",
    ]

    /// Which elements become controls: kept roles only, never secure fields, enabled, with a usable frame.
    static func keep(role: String?, subrole: String?, enabled: Bool, frame: CGRect?, screens: [CGRect]) -> String? {
        guard let role, subrole != kAXSecureTextFieldSubrole, role != kAXSecureTextFieldSubrole,
              let kind = keptRoles[role], enabled, let frame, AX.isUsable(frame, screens: screens) else { return nil }
        return kind
    }

    /// Off the main thread; every call times out after `Config.axTimeout`.
    static func take(pid: pid_t, screens: [CGRect]) async -> AXSnapshot {
        await Task.detached(priority: .userInitiated) { build(pid: pid, screens: screens) }.value
    }

    private static func build(pid: pid_t, screens: [CGRect]) -> AXSnapshot {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Config.axTimeout)
        var snap = AXSnapshot()
        if let menuBar: AXUIElement = AX.value(app, kAXMenuBarAttribute) {
            snap.menus = MenuIndex(bar: menuNodes(menuBar, depth: 0))
        }
        guard let win: AXUIElement = AX.value(app, kAXFocusedWindowAttribute) else { return snap }
        snap.windowTitle = AX.value(win, kAXTitleAttribute)
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute]
        var defaults: [AXUIElement] = []
        var queue = [win], next = 0
        while next < queue.count, next < 3000, snap.controls.count < Config.guideMaxControls {
            let el = queue[next]
            next += 1
            let v = AX.values(el, attrs)
            let role = v[0] as? String
            if role == kAXSheetRole as String {
                snap.sheetTitle = snap.sheetTitle ?? (v[2] as? String)
                if let d: AXUIElement = AX.value(el, kAXDefaultButtonAttribute) { defaults.append(d) }
            }
            if role == kAXWindowRole as String, let d: AXUIElement = AX.value(el, kAXDefaultButtonAttribute) { defaults.append(d) }
            let frame = AX.frame(position: v[5], size: v[6])
            if let kind = keep(role: role, subrole: v[1] as? String, enabled: (v[4] as? Bool) ?? false, frame: frame, screens: screens) {
                let label = [v[2], v[3]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let label, let frame {
                    snap.controls.append(Control(role: kind, label: label, isDefault: defaults.contains { CFEqual($0, el) },
                                                 frame: frame, element: el))
                }
            }
            if v[1] as? String != kAXSecureTextFieldSubrole as String, let kids = v[7] as? [AXUIElement] { queue += kids }
        }
        // A sheet's default button can be listed before the sheet is reached; mark it afterwards too.
        snap.controls = snap.controls.map { c in
            Control(role: c.role, label: c.label, isDefault: c.isDefault || defaults.contains { CFEqual($0, c.element) },
                    frame: c.frame, element: c.element)
        }
        return snap
    }

    private static func menuNodes(_ el: AXUIElement, depth: Int) -> [MenuIndex.Node] {
        guard depth < 4, let kids: [AXUIElement] = AX.value(el, kAXChildrenAttribute) else { return [] }
        var out: [MenuIndex.Node] = []
        for k in kids {
            let v = AX.values(k, [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute])
            let role = v[0] as? String
            if role == kAXMenuRole as String { out += menuNodes(k, depth: depth); continue } // a menu holds the items
            let title = (v[1] as? String) ?? ""
            // Skipped titles (and the Apple menu at the top level) aren't walked at all.
            let skip = Config.guideSkippedMenus.contains(AX.normalizeTitle(title)) || (depth == 0 && out.isEmpty)
            out.append(MenuIndex.Node(title: title, enabled: (v[2] as? Bool) ?? true, element: k,
                                      children: skip ? [] : menuNodes(k, depth: depth + 1)))
        }
        return out
    }
}
