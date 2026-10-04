import AppKit
import SwiftUI

/// An answer split into blocks the panel draws properly: paragraphs, headings, fenced code and pipe tables.
enum AnswerBlock: Equatable {
    case text(String)
    case heading(String)
    case code(lang: String, body: String)
    case table(header: [String], rows: [[String]])

    /// Tolerates a stream cut mid-block: an unclosed fence is code to the end, a table without its separator yet is text.
    static func parse(_ s: String) -> [AnswerBlock] {
        var out: [AnswerBlock] = [], text: [String] = []
        func flush() {
            let t = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append(.text(t)) }
            text = []
        }
        let lines = s.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[i]); i += 1 }
                out.append(.code(lang: lang, body: body.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let r = cells(lines[i])
                    rows.append(Array((r + Array(repeating: "", count: header.count)).prefix(header.count)))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }
                if title.hasPrefix(" ") { flush(); out.append(.heading(title.trimmingCharacters(in: .whitespaces))); i += 1; continue }
            }
            text.append(lines[i])
            i += 1
        }
        flush()
        return out
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline markdown, with list markers shown as bullets.
    static func inline(_ s: String) -> AttributedString {
        let bulleted = s.components(separatedBy: "\n").map { line -> String in
            let body = line.drop { $0 == " " }
            let indent = String(repeating: " ", count: line.count - body.count)
            return body.hasPrefix("- ") || body.hasPrefix("* ") ? indent + "• " + body.dropFirst(2) : line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(bulleted)
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let a = parse("Intro **bold**\n\n## Specs\n| Part | GB |\n|---|:-:|\n| RAM | 16 |\n| SSD |\n\n```swift\nlet x = 1\n```\nDone")
        check(a == [.text("Intro **bold**"), .heading("Specs"), .table(header: ["Part", "GB"], rows: [["RAM", "16"], ["SSD", ""]]),
                    .code(lang: "swift", body: "let x = 1"), .text("Done")], "answer: text, heading, table, code blocks")
        check(parse("Look:\n```\nhalf a") == [.text("Look:"), .code(lang: "", body: "half a")], "answer: unclosed fence while streaming is code")
        check(parse("| a | b |") == [.text("| a | b |")], "answer: a table header without its separator stays text")
        check(parse("#hashtag") == [.text("#hashtag")], "answer: #word is not a heading")
        check(String(inline("- one\n  * two").characters) == "• one\n  • two", "answer: list markers become bullets")
    }
}

/// An assistant answer drawn block by block.
struct AnswerView: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            Text("…").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(AnswerBlock.parse(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let s):
                        Text(AnswerBlock.inline(s)).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    case .heading(let s):
                        Text(AnswerBlock.inline(s)).font(.headline).padding(.top, 2)
                    case .code(let lang, let body):
                        CodeBlock(lang: lang, code: body)
                    case .table(let header, let rows):
                        TableBlock(header: header, rows: rows)
                    }
                }
            }
        }
    }
}

private struct CodeBlock: View {
    let lang: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption2) }
                    .buttonStyle(.borderless).help("Copy code")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ScrollView(.horizontal) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(8).fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text(AnswerBlock.inline($0.element)).bold() } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text(AnswerBlock.inline($0.element)) } }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .padding(8)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
