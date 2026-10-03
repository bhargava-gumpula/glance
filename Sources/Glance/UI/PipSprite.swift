import SwiftUI

/// Pip the 8-bit penguin: a 20×14 pixel grid, drawn per state.
enum PipSprite {
    static let width = 20, height = 14
    /// Left half of each row; the right half is its mirror.
    static let halves = [
        "......oooo", ".....opppp", "....oppppp", "....opplll", "...opplell", "...oplllly", "...oplllll",
        "..opplllll", ".oppllllll", ".oppllllll", "..opllllll", "..opllllll", "...ooooooo", "....yyy...",
    ]
    static let palette: [Character: Color] = [
        "o": rgb(0x1B1B2E), "p": rgb(0x2C2C44), "l": rgb(0xF4F4F0), "e": rgb(0x1B1B2E),
        "y": rgb(0xEF9F27), "t": rgb(0xED93B1),
    ]
    static let accent = rgb(0x185FA5)

    /// `tick` advances 5 times a second. `pointLeft`: the target is to Pip's left.
    static func grid(_ state: PetState, tick: Int, pointLeft: Bool) -> [[Character]] {
        var g = halves.map { Array($0) + Array($0.reversed()) }
        func set(_ x: Int, _ y: Int, _ c: Character, mirrored: Bool = false) {
            let x = mirrored ? width - 1 - x : x
            if g.indices.contains(y), (0..<width).contains(x) { g[y][x] = c }
        }
        let odd = tick % 2 == 1
        if state == .listening, odd { // flap
            set(1, 8, "."); set(18, 8, "."); set(0, 7, "p"); set(19, 7, "p")
        }
        if tick % 14 == 0, state != .thinking { // blink
            set(7, 4, "l"); set(12, 4, "l"); set(6, 4, "o"); set(13, 4, "o")
        }
        if state == .thinking { // look up
            set(7, 4, "l"); set(12, 4, "l"); set(7, 3, "e"); set(12, 3, "e")
        }
        if (state == .talking && odd) || state == .listening { // beak open
            set(9, 6, "e"); set(10, 6, "e"); set(9, 7, "y"); set(10, 7, "y")
        }
        if state == .pointing { // flipper up toward the target
            let m = !pointLeft
            set(1, 8, ".", mirrored: m); set(1, 9, ".", mirrored: m)
            set(0, 7, "p", mirrored: m); set(0, 6, "p", mirrored: m); set(1, 7, "p", mirrored: m)
        }
        return g
    }

    private static func rgb(_ hex: Int) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Pip drawn from its pixel grid, animated 5 frames a second.
struct PipSpriteView: View {
    let state: PetState
    let pointLeft: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate * 5)
            let grid = PipSprite.grid(state, tick: tick, pointLeft: pointLeft)
            let bob: CGFloat = state == .idle && (tick / 5) % 2 == 1 ? 1 : 0
            Canvas { gc, size in
                let px = size.width / CGFloat(PipSprite.width)
                for (y, row) in grid.enumerated() {
                for (x, c) in row.enumerated() {
                    guard let color = PipSprite.palette[c] else { continue }
                    gc.fill(Path(CGRect(x: CGFloat(x) * px, y: (CGFloat(y) + bob) * px, width: px, height: px)), with: .color(color))
                }
                }
            }
        }
    }
}
