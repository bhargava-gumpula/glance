import Foundation

/// What the model gets about the last `Config.retentionMinutes`: an activity log (one line per visit, oldest first,
/// with an extracted gist) and the de-duplicated text of every distinct page or window. Built locally at question
/// time from the timeline, so it follows retention, Forget and Pause; it only leaves the Mac, redacted, through
/// `ContextPacket.send()`.
enum MemoryContext {
    struct Built: Equatable {
        var text: String
        var pages: Int
        var apps: Int
        /// Pages whose body was cut down to its key lines to fit `Config.memoryContextMaxChars`.
        var trimmedPages: Int
        /// Newest row included; a follow-up rebuilds only when something newer was stored.
        var newest: Double
    }

    private struct Page {
        let key: String, app: String, title: String?, url: String?
        var first: Double, last: Double
        var lines: [String] = []
        var heading: String { [app, title, url].compactMap { $0 }.joined(separator: " · ") }
    }

    static func build(rows: [Timeline.Snippet], now: Date = Date(), maxChars: Int = Config.memoryContextMaxChars) -> Built? {
        let rows = rows.sorted { $0.ts < $1.ts }
        guard let newest = rows.last?.ts else { return nil }

        // Visits: consecutive rows of the same page. Pages: every row of a page, newest text first.
        var visits: [(key: String, from: Double, to: Double)] = []
        var pages: [String: Page] = [:], order: [String] = []
        for r in rows {
            let key = "\(r.app)|\(r.title ?? "")|\(r.url ?? "")"
            if visits.last?.key == key { visits[visits.count - 1].to = r.ts } else { visits.append((key, r.ts, r.ts)) }
            if pages[key] == nil {
                pages[key] = Page(key: key, app: r.app, title: r.title, url: r.url, first: r.ts, last: r.ts)
                order.append(key)
            }
            pages[key]!.last = r.ts
        }
        for key in order {
            var seen = Set<String>(), lines: [String] = []
            for r in rows.reversed() where "\(r.app)|\(r.title ?? "")|\(r.url ?? "")" == key {
                for raw in r.text.split(separator: "\n") {
                    let l = raw.trimmingCharacters(in: .whitespaces)
                    if l.count >= 3, seen.insert(l).inserted { lines.append(l) }
                }
            }
            pages[key]!.lines = lines
        }

        func ago(_ ts: Double) -> String { "\(max(0, Int(now.timeIntervalSince1970 - ts) / 60)) min ago" }
        let activity = visits.map { v -> String in
            let p = pages[v.key]!
            let span = Int(v.to - v.from) >= 60 ? "\(ago(v.from)), for \(Int(v.to - v.from) / 60) min" : ago(v.from)
            let g = gist(p.lines).joined(separator: " | ")
            return "- \(span): \(p.heading)" + (g.isEmpty ? "" : " — \(g)")
        }.joined(separator: "\n")

        var bodies = order.map { key -> (head: String, full: String, key: String) in
            let p = pages[key]!
            return ("### \(p.heading)\n", p.lines.joined(separator: "\n"), gist(p.lines).joined(separator: "\n"))
        }
        let header = "Activity log (oldest first):\n\(activity)\n\nText of each page or window (newest version, repeats removed):\n"
        func total() -> Int { header.count + bodies.reduce(0) { $0 + $1.head.count + $1.full.count + 2 } }
        // Over budget: the oldest pages shrink to their key lines first; the activity log is never cut.
        var trimmed = 0
        for i in bodies.indices where total() > maxChars {
            bodies[i].full = bodies[i].key.isEmpty ? "(trimmed)" : bodies[i].key + "\n(trimmed)"
            trimmed += 1
        }
        var text = header + bodies.map { $0.head + $0.full }.joined(separator: "\n\n")
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n(cut to fit)" }
        if trimmed > 0 { log.notice("memory context: trimmed \(trimmed, privacy: .public) of \(order.count, privacy: .public) pages to fit") }
        return Built(text: text, pages: order.count, apps: Set(order.map { pages[$0]!.app }).count,
                     trimmedPages: trimmed, newest: newest)
    }

    /// Key lines, extracted on-device without a model: prices, specs and model or chip names. At most 4 lines.
    static func gist(_ lines: [String]) -> [String] {
        let pattern = #"[€$£]\s?\d|\b\d+(\.\d+)?\s?(GB|TB|MB|-core|core|inch|-inch|"|hours?|hrs?|Hz|kg|g|nits|W|Wh|mAh|MP|K)\b|\b(M\d( Pro| Max| Ultra)?|Intel|Ryzen|Snapdragon|Core Ultra|RTX|OLED|Retina)\b"#
        return Array(lines.filter { $0.count <= 120 && $0.range(of: pattern, options: .regularExpression) != nil }.prefix(4))
    }
}
