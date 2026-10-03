import Foundation

/// "Where was I?": a recap of the last few minutes from the on-device timeline, sent only as redacted text.
extension Mode {
    static let recap = Mode(
        name: "Where was I?",
        system: """
        You are Glance, a helper on the user's Mac. The user asked where they were. You get a list of the windows \
        they looked at in the last few minutes (app, title, site, a few distinctive lines), oldest first, from \
        Glance's on-device memory. Use only that list; don't invent anything.
        Start with one line: "Say: " then 1-2 short spoken sentences (under 35 words, no markdown): what they were \
        doing and the obvious next step. Then a blank line, then:
        **Goal:** one line, your best guess at what they were trying to do.
        **Seen:** one bullet per item, oldest first: what it was (site or app) and the key detail.
        **Next step:** one line.
        Values shown as [CARD], [EMAIL], [NAME] and similar were hidden for privacy; don't ask for them.
        """,
        followUps: [.init(label: "Explain more", prompt: "Tell me more about what I was doing.")],
        matches: Recap.isRecapQuestion
    )
}

enum Recap {
    @Sendable static func isRecapQuestion(_ q: String) -> Bool {
        let t = q.lowercased().replacingOccurrences(of: "[^a-z' ]", with: " ", options: .regularExpression)
        return t.range(of: #"\b(where was i|where were we|what was i (doing|looking at|working on|up to)|where did i (leave|get) (off|to)|catch me up|recap)\b"#,
                       options: .regularExpression) != nil
    }

    /// Newest row per window, oldest first, keeping only lines that don't appear in the other windows
    /// (menus and toolbars repeat; the distinctive text is what the user was reading).
    static func windows(from rows: [Timeline.Snippet]) -> [Timeline.Snippet] {
        var seen = Set<String>(), newest: [Timeline.Snippet] = []
        for row in rows.sorted(by: { $0.ts > $1.ts }) where seen.insert("\(row.app)|\(row.title ?? "")").inserted {
            newest.append(row)
            if newest.count == Config.recapWindowLimit { break }
        }
        func lines(_ s: Timeline.Snippet) -> [String] {
            s.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }
        }
        var counts: [String: Int] = [:]
        for w in newest { for l in Set(lines(w)) { counts[l, default: 0] += 1 } }
        return newest.reversed().map { w in
            var text = ""
            for l in lines(w) where counts[l] == 1 && !text.contains(l) {
                if text.count + l.count > Config.recapCharsPerWindow { break }
                text += l + "\n"
            }
            return Timeline.Snippet(ts: w.ts, app: w.app, title: w.title, url: w.url,
                                    text: text.trimmingCharacters(in: .newlines))
        }
    }
}
