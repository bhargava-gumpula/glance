import AppKit
import SwiftUI

/// Pip the 8-bit penguin: a 20×15 pixel grid (a headroom row, then 14 rows of penguin), drawn per state.
enum PipSprite {
    static let width = 20, height = 15
    /// Left half of each row; the right half is its mirror. Row 0 is headroom for the bob and the "…".
    static let halves = [
        "..........", "......oooo", ".....opppp", "....oppppp", "....opplll", "...opplell", "...oplllly", "...oplllll",
        "..opplllll", ".oppllllll", ".oppllllll", "..opllllll", "..opllllll", "...ooooooo", "....yyy...",
    ]
    static let palette: [Character: Color] = [
        "o": rgb(0x1B1B2E), "p": rgb(0x2C2C44), "l": rgb(0xF4F4F0), "e": rgb(0x1B1B2E),
        "y": rgb(0xEF9F27), "t": rgb(0xED93B1), "a": accent,
    ]
    static let accent = rgb(0x185FA5)

    /// `tick` advances 5 times a second. `pointLeft`: the target is to Pip's left.
    /// `reduceMotion`: no bob or flap, one pose per state, and blinks last 0.6 s.
    static func grid(_ state: PetState, tick: Int, pointLeft: Bool, reduceMotion: Bool = false) -> [[Character]] {
        var g = halves.map { Array($0) + Array($0.reversed()) }
        func set(_ x: Int, _ y: Int, _ c: Character, mirrored: Bool = false) {
            let x = mirrored ? width - 1 - x : x
            if g.indices.contains(y), (0..<width).contains(x) { g[y][x] = c }
        }
        func both(_ pixels: [(Int, Int, Character)]) { for (x, y, c) in pixels { set(x, y, c); set(x, y, c, mirrored: true) } }
        let odd = !reduceMotion && tick % 2 == 1
        let slow = reduceMotion ? tick - tick % 3 : tick
        if state == .thinking { // eyes up, "…" growing above the head
            both([(7, 5, "l"), (8, 4, "e")])
            for i in 0..<(reduceMotion ? 3 : 1 + tick / 2 % 3) { set(15 + 2 * i, 0, "a") }
        } else if slow % 15 == 0 { // blink every 3 s
            both([(8, 5, "e")])
        }
        if state == .listening || (state == .talking && (odd || reduceMotion)) { // beak open
            both([(9, 7, "e"), (9, 8, "y")])
        }
        if state == .listening { // flap, and sound arcs that ripple outward
            if odd { both([(1, 9, "."), (1, 10, "."), (1, 8, "p"), (0, 8, "p"), (0, 7, "p")]) }
            both(odd ? [(18, 1, "a"), (19, 2, "a"), (19, 3, "a"), (19, 4, "a"), (18, 5, "a")] : [(17, 2, "a"), (18, 3, "a"), (17, 4, "a")])
        }
        if state == .pointing { // flipper raised toward the target
            let arm: [(Int, Int, Character)] = [(1, 9, "."), (1, 10, "."), (2, 7, "p"), (1, 7, "p"), (1, 6, "p"), (0, 6, "p"), (0, 5, "p")]
            for (x, y, c) in arm { set(x, y, c, mirrored: !pointLeft) }
        }
        if state == .idle, !reduceMotion, tick / 5 % 2 == 1 { g.append(g.removeFirst()) } // bob up into the headroom
        return g
    }

    /// Sprite checks for `--selftest`.
    static func selfTest(_ check: (Bool, String) -> Void) {
        let states: [PetState] = [.idle, .listening, .thinking, .talking, .pointing], ticks = 0..<20, flags = [true, false]
        func f(_ s: PetState, _ t: Int, left: Bool = true, rm: Bool = false) -> [[Character]] {
            grid(s, tick: t, pointLeft: left, reduceMotion: rm)
        }
        let all = states.flatMap { s in ticks.flatMap { t in flags.flatMap { l in flags.map { f(s, t, left: l, rm: $0) } } } }
        check(all.allSatisfy { $0.count == height && $0.allSatisfy { $0.count == width } }, "Pip: every frame is \(width)×\(height)")
        check(all.allSatisfy { $0.allSatisfy { $0.allSatisfy { $0 == "." || palette[$0] != nil } } }, "Pip: only palette colours")
        check(flags.allSatisfy { rm in ticks.allSatisfy { t in
            f(.pointing, t, left: true, rm: rm).map { Array($0.reversed()) } == f(.pointing, t, left: false, rm: rm)
        } }, "Pip: pointing right mirrors pointing left")
        func still(_ g: [[Character]]) -> [[Character]] { g.enumerated().filter { $0.offset != 5 }.map(\.element) } // row 5: eyes
        check(states.allSatisfy { s in ticks.allSatisfy { still(f(s, $0, rm: true)) == still(f(s, 0, rm: true)) } },
              "Pip: reduce motion holds one pose apart from the blink")
        check(ticks.contains { still(f(.idle, $0)) != still(f(.idle, 0)) }, "Pip: idle bobs without reduce motion")
        check(states.dropFirst().allSatisfy { s in flags.allSatisfy { rm in ticks.contains { f(s, $0, rm: rm) != f(.idle, $0, rm: rm) } } },
              "Pip: every state looks different from idle")
    }

    private static func rgb(_ hex: Int) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Pip drawn from its pixel grid, animated 5 frames a second, with a light halo for dark wallpapers.
struct PipSpriteView: View {
    let state: PetState
    let pointLeft: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let grid = PipSprite.grid(state, tick: Int(context.date.timeIntervalSinceReferenceDate * 5), pointLeft: pointLeft,
                                      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            Canvas { gc, size in
                let w = CGFloat(PipSprite.width), h = CGFloat(PipSprite.height)
                let px = max(1, floor(min(size.width / w, size.height / h))) // whole points keep the pixels crisp
                let x0 = floor((size.width - px * w) / 2), y0 = floor((size.height - px * h) / 2)
                var halo = Path(), cells: [(CGRect, Color)] = []
                for (y, row) in grid.enumerated() {
                    for (x, c) in row.enumerated() {
                        guard let color = PipSprite.palette[c] else { continue }
                        let r = CGRect(x: x0 + CGFloat(x) * px, y: y0 + CGFloat(y) * px, width: px, height: px)
                        halo.addRect(r.insetBy(dx: -1, dy: -1))
                        cells.append((r, color))
                    }
                }
                gc.fill(halo, with: .color(.white.opacity(0.6))) // one fill, so overlaps don't darken
                for (r, color) in cells { gc.fill(Path(r), with: .color(color)) }
            }
            .padding(-1) // room for the halo at the frame's edges
        }
    }
}
