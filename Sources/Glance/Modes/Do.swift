import Foundation

/// Do: "Save this comparison". The model drafts a Markdown table; Glance shows it and writes a file only after
/// the user clicks Save, never overwriting.
extension Mode {
    static let saveComparison = Mode(
        name: "Save comparison",
        system: """
        You are Glance, a helper on the user's Mac. The user wants to save the comparison from this conversation \
        as a file.
        Start with exactly this line: "Say: Here's the comparison. Click Save to keep it."
        Then a blank line, then only Markdown: a "# " heading naming what was compared, one table with a row per \
        item compared and columns for the details that mattered (for example price, memory, storage, battery, \
        weight, screen), then one short line per item on how it fits the user's needs or budget if they mentioned any. \
        Use only values from this conversation; write "—" when a value is unknown. Don't add links; Glance adds the sources.
        Values shown as [CARD], [EMAIL] or [NAME] were hidden for privacy; leave them out.
        """,
        followUps: [],
        matches: SaveComparison.isSaveRequest
    )
}

enum SaveComparison {
    @Sendable static func isSaveRequest(_ q: String) -> Bool {
        let t = q.lowercased()
        return t.range(of: #"\b(save|keep|export) (this|that|it|the|my)?\s*(comparison|table)?\b"#, options: .regularExpression) != nil
            && t.range(of: #"\b(save|keep|export) (this|that|it|the comparison|this comparison|comparison|the table)\b"#,
                       options: .regularExpression) != nil
    }

    /// Questions that compare things; their answers get a "Save comparison" button.
    static func isComparison(_ q: String) -> Bool {
        q.lowercased().range(of: #"compar|differen|differ\b|\bversus\b|\bvs\b|better|cheaper|which (one|is|should)|earlier ones"#,
                             options: .regularExpression) != nil
    }

    /// What the user sees before saving and what the file contains.
    struct Draft: Equatable {
        let markdown: String
        /// "- [Title](url)" lines from the timeline windows the answer used, already redacted.
        let sources: [String]
        let date: Date

        var fileText: String {
            var s = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sources.isEmpty { s += "\n\n## Sources\n" + sources.joined(separator: "\n") }
            let day = date.formatted(.iso8601.year().month().day())
            return s + "\n\n_Saved by Glance on \(day)._\n"
        }
    }

    static func fileName(_ date: Date, copy n: Int) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        return "Glance Comparison \(day)\(n > 1 ? " \(n)" : "").md"
    }

    /// Writes the draft into `dir` (the Desktop by default) under the first free name. Call only from the Save button.
    static func write(_ draft: Draft, to dir: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]) throws -> URL {
        let data = Data(draft.fileText.utf8)
        for n in 1...999 {
            let url = dir.appendingPathComponent(fileName(draft.date, copy: n))
            do {
                try data.write(to: url, options: .withoutOverwriting) // atomic no-overwrite, even if a file appears meanwhile
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Source lines for the file: title and link without query or fragment, redacted.
    static func sources(from snippets: [Timeline.Snippet]) -> [String] {
        var seen = Set<String>()
        return snippets.compactMap { s in
            let title = Redactor.redact(s.title ?? s.app).text
            var link: String?
            if let raw = s.url, var c = URLComponents(string: raw), c.scheme?.hasPrefix("http") == true {
                c.query = nil
                c.fragment = nil
                link = c.string.map { Redactor.redact($0).text }
            }
            let line = link.map { "- [\(title)](\($0))" } ?? "- \(title) (\(s.app))"
            return seen.insert(line).inserted ? line : nil
        }
    }
}
