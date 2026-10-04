import CoreGraphics

/// Pure screen geometry for Pip. All rects are in points (Cocoa/AX units), never pixels;
/// points are already scale-independent, so Retina and mixed-DPI displays need no special case.
enum PetGeometry {
    /// AX/CG global (origin top-left of the primary screen, y down) → Cocoa global (origin bottom-left
    /// of the primary screen, y up). `primaryHeight` is `NSScreen.screens.first!.frame.height`.
    static func cocoaRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Vision normalized rect (0–1, origin bottom-left) inside `region`, the captured area in Cocoa global points.
    static func cocoaRect(fromVision n: CGRect, in region: CGRect) -> CGRect {
        CGRect(x: region.minX + n.minX * region.width, y: region.minY + n.minY * region.height,
               width: n.width * region.width, height: n.height * region.height)
    }

    /// Pip's window position, where the sprite sits inside it (offset from the window's bottom-left)
    /// and whether the bubble goes below the sprite (no room above it on screen).
    struct Layout: Equatable {
        var origin: CGPoint
        var sprite: CGPoint
        var pointLeft: Bool
        var bubbleBelow: Bool
        func spriteRect(_ size: CGSize) -> CGRect { CGRect(origin: CGPoint(x: origin.x + sprite.x, y: origin.y + sprite.y), size: size) }
    }

    /// Where Pip goes to point at `target` (Cocoa global). The sprite is clamped onto the screen and the
    /// window is built around it, so Pip stays next to the target even at screen edges.
    /// Screen: the visible frame containing the target centre, else the largest overlap, else the nearest.
    static func placement(for target: CGRect, screens visibleFrames: [CGRect], window: CGSize, sprite: CGSize,
                          gap: CGFloat) -> Layout {
        let c = CGPoint(x: target.midX, y: target.midY)
        func rank(_ f: CGRect) -> (Int, CGFloat, CGFloat) {
            let i = f.intersection(target)
            return (f.contains(c) ? 0 : 1, i.isNull ? 0 : -i.width * i.height,
                    hypot(max(f.minX - c.x, 0, c.x - f.maxX), max(f.minY - c.y, 0, c.y - f.maxY)))
        }
        let vf = visibleFrames.min { rank($0) < rank($1) } ?? .infinite
        var s = CGPoint(x: target.maxX + gap, y: c.y - sprite.height / 2)
        var pointLeft = true
        if s.x + sprite.width > vf.maxX {
            if target.minX - gap - sprite.width >= vf.minX {
                s.x = target.minX - gap - sprite.width
                pointLeft = false
            } else { // too wide for either side: centred above the target, or below if the top has no room
                s.x = c.x - sprite.width / 2
                s.y = target.maxY + gap + sprite.height <= vf.maxY ? target.maxY + gap : target.minY - gap - sprite.height
            }
        }
        return layout(sprite: CGRect(origin: s, size: sprite), in: vf, window: window, pointLeft: pointLeft)
    }

    /// Pip's home: the top-right corner of `vf` (the visible frame, so below the menu bar); the bubble flips below.
    static func home(in vf: CGRect, window: CGSize, sprite: CGSize, inset: CGFloat = 16) -> Layout {
        layout(sprite: CGRect(x: vf.maxX - inset - sprite.width, y: vf.maxY - inset - sprite.height, width: sprite.width, height: sprite.height),
               in: vf, window: window, pointLeft: true)
    }

    /// Where Pip appears when Glance is shown, before it flies home: the centre of `vf`.
    static func center(in vf: CGRect, window: CGSize, sprite: CGSize) -> Layout {
        layout(sprite: CGRect(x: vf.midX - sprite.width / 2, y: vf.midY - sprite.height / 2, width: sprite.width, height: sprite.height),
               in: vf, window: window, pointLeft: true)
    }

    /// True when `sprite` (Cocoa global) is no longer on any screen, e.g. after a display was unplugged.
    static func isOffScreen(_ sprite: CGRect, screens: [CGRect]) -> Bool {
        !screens.contains { $0.contains(CGPoint(x: sprite.midX, y: sprite.midY)) }
    }

    /// Clamps the sprite into `vf`, then fits the window around it with the bubble above (or below near the top).
    static func layout(sprite r: CGRect, in vf: CGRect, window: CGSize, pointLeft: Bool) -> Layout {
        let s = CGPoint(x: min(max(r.minX, vf.minX), vf.maxX - r.width), y: min(max(r.minY, vf.minY), vf.maxY - r.height))
        let below = s.y + window.height > vf.maxY
        var x = min(max(s.x + r.width / 2 - window.width / 2, vf.minX), vf.maxX - window.width)
        x = min(max(x, s.x + r.width - window.width), s.x)
        let y = below ? s.y + r.height - window.height : s.y
        return Layout(origin: CGPoint(x: x, y: y), sprite: CGPoint(x: s.x - x, y: s.y - y), pointLeft: pointLeft, bubbleBelow: below)
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(cocoaRect(fromAX: CGRect(x: 100, y: 50, width: 200, height: 40), primaryHeight: 900)
              == CGRect(x: 100, y: 810, width: 200, height: 40), "pet: AX rect flips to Cocoa")
        check(cocoaRect(fromAX: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryHeight: 900).minY == 900,
              "pet: AX display above the primary maps above it")
        check(cocoaRect(fromVision: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), in: CGRect(x: 100, y: 200, width: 400, height: 300))
              == CGRect(x: 200, y: 350, width: 200, height: 75), "pet: Vision rect maps into capture region")

        let win = CGSize(width: 300, height: 260), spr = CGSize(width: 120, height: 90)
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
        func place(_ t: CGRect, _ screens: [CGRect]) -> Layout {
            placement(for: t, screens: screens, window: win, sprite: spr, gap: 8)
        }
        func sprite(_ l: Layout) -> CGRect { l.spriteRect(spr) }
        func near(_ l: Layout, _ t: CGRect) -> Bool { // sprite touches the target's side within the gap
            let s = sprite(l)
            return abs(s.minX - t.maxX) <= 8 || abs(t.minX - s.maxX) <= 8 || abs(s.minY - t.maxY) <= 8 || abs(t.minY - s.maxY) <= 8
        }
        func fits(_ l: Layout) -> Bool { CGRect(origin: .zero, size: win).contains(CGRect(origin: l.sprite, size: spr)) }

        var t = CGRect(x: 400, y: 400, width: 200, height: 50)
        var p = place(t, [main])
        check(p.pointLeft && sprite(p) == CGRect(x: 608, y: 380, width: 120, height: 90) && !p.bubbleBelow && fits(p),
              "pet: sits right of target, pointing left, bubble above")

        t = CGRect(x: 1300, y: 400, width: 100, height: 50)
        p = place(t, [main])
        check(!p.pointLeft && sprite(p).maxX == t.minX - 8 && main.contains(sprite(p)), "pet: sits left when the right has no room")

        let leftScreen = CGRect(x: -1920, y: -100, width: 1920, height: 1055)
        t = CGRect(x: -1000, y: 300, width: 200, height: 40)
        p = place(t, [main, leftScreen])
        check(p.pointLeft && leftScreen.contains(sprite(p)) && near(p, t), "pet: second display at negative x")

        // A15: near edges the sprite stays next to the target; only the transparent window may spill over.
        t = CGRect(x: 1380, y: 830, width: 40, height: 30) // top-right toolbar button
        p = place(t, [main])
        check(main.contains(sprite(p)) && near(p, t) && p.bubbleBelow && fits(p), "pet A15: top-right toolbar target, sprite beside it, bubble below")
        t = CGRect(x: 5, y: 400, width: 40, height: 30) // left edge
        p = place(t, [main])
        check(sprite(p).minX == t.maxX + 8 && fits(p), "pet A15: left-edge target, sprite right beside it")
        t = CGRect(x: 400, y: 2, width: 100, height: 20) // bottom edge
        p = place(t, [main])
        check(sprite(p).minY == main.minY && sprite(p).minX == t.maxX + 8, "pet A15: bottom-edge target, sprite clamped onto screen next to it")

        let rightScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        p = place(CGRect(x: 1300, y: 500, width: 400, height: 40), [main, rightScreen])
        check(rightScreen.contains(sprite(p)), "pet: target spanning two screens uses the one holding its centre")
        p = place(CGRect(x: 1500, y: 1060, width: 30, height: 20), [main, rightScreen])
        check(rightScreen.contains(sprite(p)), "pet: target in a menu bar uses the nearest screen")

        t = CGRect(x: 0, y: 300, width: 1440, height: 100)
        p = place(t, [main])
        check(sprite(p).minY == t.maxY + 8 && abs(sprite(p).midX - t.midX) < 1, "pet: full-width target puts Pip above it")

        let h = home(in: main, window: win, sprite: spr)
        check(sprite(h) == CGRect(x: 1304, y: 875 - 16 - 90, width: 120, height: 90) && h.pointLeft && h.bubbleBelow && fits(h)
              && main.contains(CGRect(origin: h.origin, size: win)), "pet: home is the top-right corner, bubble below, window on screen")
        let c = center(in: main, window: win, sprite: spr)
        check(sprite(c) == CGRect(x: 660, y: 392.5, width: 120, height: 90) && fits(c), "pet: appears in the centre of the screen")
        check(isOffScreen(CGRect(x: 2000, y: 16, width: 120, height: 90), screens: [main])
              && !isOffScreen(sprite(h), screens: [main]), "pet: home off every screen is detected")
    }
}
