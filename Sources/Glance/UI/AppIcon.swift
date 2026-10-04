import AppKit
import SwiftUI

/// The 8-bit penguin app icon, rendered from Pip's own pixel grid. `Glance --make-iconset <dir>` writes the PNGs
/// that `iconutil` turns into AppIcon.icns (scripts/build-app.sh).
enum AppIcon {
    static let sizes: [(name: String, px: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// The 1024-px master: an icy rounded square (Apple's 824-pt content grid), a snow floor and Pip in whole pixels.
    static func master() -> CGImage? {
        let size = 1024, inset: CGFloat = 100, content = CGFloat(size) - 2 * inset
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let tile = CGRect(x: inset, y: inset, width: content, height: content)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.addPath(shape)
        ctx.clip()
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [rgb(0x9FD8F5), rgb(0x2F6FB5)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

        let rows = Array(PipSprite.grid(.idle, tick: 1, pointLeft: true, reduceMotion: true).dropFirst()) // no headroom row
        let px = floor(content * 0.7 / CGFloat(PipSprite.width))
        let x0 = floor(tile.midX - px * CGFloat(PipSprite.width) / 2)
        let floorTop = tile.minY + px * 5
        // Snow floor in big pixels, with a stepped edge.
        ctx.setFillColor(rgb(0xEAF4FB))
        ctx.fill(CGRect(x: tile.minX, y: tile.minY, width: content, height: floorTop - tile.minY))
        for step in stride(from: tile.minX, to: tile.maxX, by: px * 3) where Int(step / px) % 2 == 0 {
            ctx.fill(CGRect(x: step, y: floorTop, width: px * 3, height: px))
        }
        let y0 = floorTop - px // feet stand on the snow
        for (r, row) in rows.reversed().enumerated() {
            for (c, cell) in row.enumerated() {
                guard let color = PipSprite.palette[cell] else { continue }
                ctx.setFillColor(NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? .black)
                ctx.fill(CGRect(x: x0 + CGFloat(c) * px, y: y0 + CGFloat(r) * px, width: px, height: px))
            }
        }
        return ctx.makeImage()
    }

    static func scaled(_ image: CGImage, to px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = px >= 256 ? .none : .high // big sizes stay crisp pixel art
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        return ctx.makeImage()
    }

    /// Writes every iconset PNG into `dir`; returns how many were written.
    @discardableResult
    static func writeIconset(to dir: URL) -> Int {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let master = master() else { return 0 }
        var written = 0
        for (name, px) in sizes {
            guard let img = scaled(master, to: px),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]),
                  (try? png.write(to: dir.appendingPathComponent("\(name).png"))) != nil else { continue }
            written += 1
        }
        return written
    }

    private static func rgb(_ hex: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let m = master()
        check(m?.width == 1024 && m?.height == 1024, "icon: 1024 px master renders")
        if let m, let data = m.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            func alpha(_ x: Int, _ y: Int) -> UInt8 { p[y * m.bytesPerRow + x * 4 + 3] }
            check(alpha(10, 10) == 0 && alpha(512, 512) == 255, "icon: transparent corner, opaque tile")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-selftest-\(UUID().uuidString).iconset")
        check(writeIconset(to: dir) == sizes.count, "icon: all \(sizes.count) iconset PNGs written")
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The menu-bar glyph: a 16×16 template penguin with a state badge (paused bars, "!" for not saving, a slash for off).
enum MenuBarGlyph {
    static let penguin = [
        ".....XXXXXX.....", "....XXXXXXXX....", "...XXXXXXXXXX...", "...XX.XXXX.XX...",
        "...XXXXXXXXXX...", "..XXXX....XXXX..", "..XXX......XXX..", ".XXXX......XXXX.",
        ".XXX........XXX.", ".XXX........XXX.", "..XX........XX..", "..XX........XX..",
        "...XX......XX...", "....XXXXXXXX....", "...XXX....XXX...", "................",
    ]

    /// Rows top to bottom; true = ink.
    static func grid(_ state: MemoryRecorder.State) -> [[Bool]] {
        var g = penguin.map { $0.map { $0 == "X" } }
        func area(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>, _ on: Bool) { for y in ys { for x in xs { g[y][x] = on } } }
        switch state {
        case .recording: break
        case .paused:
            area(9...15, 8...15, false)
            area(10...11, 10...15, true); area(13...14, 10...15, true)
        case .skipping:
            area(10...15, 7...15, false)
            area(12...13, 8...12, true); area(12...13, 14...15, true)
        case .off:
            for y in 0..<16 { for x in 0..<16 {
                let d = x - y
                if d == -1 || d == 2 { g[y][x] = false }
                if d == 0 || d == 1 { g[y][x] = true }
            } }
        }
        return g
    }

    static func image(for state: MemoryRecorder.State, description: String) -> NSImage {
        let g = grid(state)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in g.enumerated() { for (x, on) in row.enumerated() where on {
                NSRect(x: 1 + x, y: 1 + y, width: 1, height: 1).fill()
            } }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let states: [MemoryRecorder.State] = [.recording, .paused, .skipping("x"), .off("x")]
        let grids = states.map(grid)
        check(grids.allSatisfy { $0.count == 16 && $0.allSatisfy { $0.count == 16 } }, "glyph: every state is 16×16")
        check(Set(grids.map { $0.map { $0.map { $0 ? "X" : "." }.joined() }.joined() }).count == states.count,
              "glyph: recording, paused, not saving and off all look different")
        check(MenuBarGlyph.image(for: .paused, description: "x").isTemplate, "glyph: template image (adapts to light/dark menu bar)")
    }
}
