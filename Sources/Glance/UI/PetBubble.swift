import SwiftUI

/// Pip's pixel speech bubble. Hugs short text; long answers show their latest part and scroll.
struct PetBubbleView: View {
    let text: String
    /// The tail sits near the right edge (bubble right-aligned, Pip pointing left).
    var tailOnRight = true
    /// Phase 4: Send / Cancel buttons under the text while a confirm is waiting.
    var onSend: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// "Show more": opens the full chat panel.
    var onMore: (() -> Void)? = nil
    let onClose: () -> Void

    /// Text area cap: with the tag, padding and tail the bubble stays under ~150 pt.
    static let maxTextHeight: CGFloat = 104
    /// PipSprite.accent (#185FA5) in light mode, a lighter blue in dark mode.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x73 / 255.0, green: 0xAB / 255.0, blue: 0xEB / 255.0, alpha: 1)
            : NSColor(srgbRed: 0x18 / 255.0, green: 0x5F / 255.0, blue: 0xA5 / 255.0, alpha: 1)
    })

    /// Trimmed, blank-line runs collapsed, headings unmarked, and only the last `maxChars` kept.
    nonisolated static func displayText(_ raw: String, maxChars: Int = 600) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(?:\\n[ \\t]*){2,}\\n", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^#{1,6}[ \\t]+", with: "", options: .regularExpression)
        return s.count > maxChars ? "…" + s.suffix(maxChars) : s
    }

    /// Inline markdown (bold, italics, code); plain text if it doesn't parse.
    nonisolated static func rendered(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    var body: some View {
        let message = Self.rendered(Self.displayText(text))
        let line = Text(message).font(.system(size: 13)).foregroundStyle(Color(nsColor: .labelColor))
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: tailOnRight ? .trailing : .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PIP").font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(Self.accent)
                ViewThatFits(in: .vertical) {
                    line
                    ScrollView { line.frame(maxWidth: .infinity, alignment: .leading) }
                        .defaultScrollAnchor(.bottom).defaultScrollAnchor(.bottom, for: .sizeChanges)
                        .scrollIndicators(.never)
                        .frame(height: Self.maxTextHeight)
                }
                .frame(maxHeight: Self.maxTextHeight)
                if let onSend, let onCancel {
                    HStack {
                        Spacer()
                        Button("Cancel", action: onCancel)
                        Button("Send", action: onSend).buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                if let onMore {
                    HStack {
                        Spacer()
                        Button("Show more", action: onMore).buttonStyle(.link).font(.system(size: 11, weight: .semibold))
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().strokeBorder(Self.accent, lineWidth: 3))
            tail.padding(tailOnRight ? .trailing : .leading, 36)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260, alignment: tailOnRight ? .trailing : .leading)
        .onTapGesture { onClose() }
        .help("Click to close")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pip says: \(String(message.characters))")
        .accessibilityHint("Click to close")
        .accessibilityAction(named: "Close") { onClose() }
    }

    /// Stacked 3-pt pixels pointing down at Pip.
    private var tail: some View {
        VStack(spacing: 0) {
            ForEach([5, 3, 1], id: \.self) { Self.accent.frame(width: CGFloat($0) * 3, height: 3) }
        }
    }

    nonisolated static func selfTest(_ check: (Bool, String) -> Void) {
        check(displayText("") == "", "Bubble: empty text stays empty")
        check(displayText("  \n hi there \n\t") == "hi there", "Bubble: whitespace is trimmed")
        check(displayText("a\n\n\n\nb\n \n\t\nc\n\nd") == "a\n\nb\n\nc\n\nd", "Bubble: 3+ newlines collapse to one blank line")
        check(displayText("## Title\nbody") == "Title\nbody", "Bubble: heading marks are dropped")
        let long = String(repeating: "x", count: 700) + "END"
        let shown = displayText(long, maxChars: 600)
        check(shown.hasPrefix("…") && shown.hasSuffix("END") && shown.count == 601, "Bubble: long text keeps its tail after …")
        check(displayText("Listening…") == "Listening…", "Bubble: short text is unchanged")
        check(String(rendered("**hi** _there_").characters) == "hi there", "Bubble: inline markdown is rendered")
    }
}
