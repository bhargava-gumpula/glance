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

    /// Where Pip's window goes to point at `target` (Cocoa global). The sprite sits in the window's bottom-right
    /// corner when `pointLeft`, bottom-left otherwise; the rest of the window is bubble space above it.
    /// Screen: the visible frame containing the target centre, else the largest overlap, else the nearest.
    static func placement(for target: CGRect, screens visibleFrames: [CGRect], window: CGSize, sprite: CGSize,
                          gap: CGFloat) -> (origin: CGPoint, pointLeft: Bool) {
        let c = CGPoint(x: target.midX, y: target.midY)
        func rank(_ f: CGRect) -> (Int, CGFloat, CGFloat) {
            let i = f.intersection(target)
            return (f.contains(c) ? 0 : 1, i.isNull ? 0 : -i.width * i.height,
                    hypot(max(f.minX - c.x, 0, c.x - f.maxX), max(f.minY - c.y, 0, c.y - f.maxY)))
        }
        let vf = visibleFrames.min { rank($0) < rank($1) } ?? .infinite
        func clamped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: min(max(x, vf.minX), vf.maxX - window.width), y: max(min(y, vf.maxY - window.height), vf.minY))
        }
        let y = c.y - sprite.height / 2
        if target.maxX + gap + sprite.width <= vf.maxX {
            return (clamped(target.maxX + gap + sprite.width - window.width, y), true)
        }
        if target.minX - gap - sprite.width >= vf.minX {
            return (clamped(target.minX - gap - sprite.width, y), false)
        }
        // Too wide for either side: sprite centred above the target, or below if the top has no room.
        let above = target.maxY + gap
        return (clamped(c.x + sprite.width / 2 - window.width,
                        above + sprite.height <= vf.maxY ? above : target.minY - gap - sprite.height), true)
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
        func place(_ t: CGRect, _ screens: [CGRect]) -> (origin: CGPoint, pointLeft: Bool) {
            placement(for: t, screens: screens, window: win, sprite: spr, gap: 8)
        }
        func inside(_ o: CGPoint, _ f: CGRect) -> Bool { f.contains(CGRect(origin: o, size: win)) }

        var p = place(CGRect(x: 400, y: 400, width: 200, height: 50), [main])
        check(p.pointLeft && p.origin == CGPoint(x: 428, y: 380), "pet: sits right of target, pointing left")

        let nearRight = CGRect(x: 1300, y: 400, width: 100, height: 50)
        p = place(nearRight, [main])
        check(!p.pointLeft && p.origin.x + spr.width <= nearRight.minX && inside(p.origin, main),
              "pet: sits left when the right has no room")

        let leftScreen = CGRect(x: -1920, y: -100, width: 1920, height: 1055)
        p = place(CGRect(x: -1000, y: 300, width: 200, height: 40), [main, leftScreen])
        check(p.pointLeft && p.origin == CGPoint(x: -972, y: 275) && inside(p.origin, leftScreen),
              "pet: second display at negative x")

        p = place(CGRect(x: 400, y: 850, width: 100, height: 20), [main])
        check(p.origin.y == 875 - 260 && inside(p.origin, main), "pet: target near top edge is clamped down")

        let below = CGRect(x: 200, y: -1080, width: 1920, height: 1080)
        p = place(CGRect(x: 300, y: -1070, width: 100, height: 20), [main, below])
        check(p.origin == CGPoint(x: 228, y: -1080), "pet: target near bottom of a display below is clamped up")

        let rightScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        p = place(CGRect(x: 1300, y: 500, width: 400, height: 40), [main, rightScreen])
        check(inside(p.origin, rightScreen), "pet: target spanning two screens uses the one holding its centre")
        p = place(CGRect(x: 1500, y: 1060, width: 30, height: 20), [main, rightScreen])
        check(inside(p.origin, rightScreen), "pet: target in a menu bar uses the nearest screen")

        p = place(CGRect(x: 0, y: 300, width: 1440, height: 100), [main])
        check(p.origin == CGPoint(x: 480, y: 408), "pet: full-width target puts Pip above it")
    }
}
