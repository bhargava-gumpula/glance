import Foundation

/// Phase 1 redaction: card numbers (Luhn-checked), emails and API keys.
/// Phase 4 moves the rules to Resources/redaction.json and adds IBAN, PPSN, JWTs, etc.
enum Redactor {
    private struct Rule {
        let label: String
        let regex: NSRegularExpression
        var isMatch: (String) -> Bool = { _ in true }
    }

    // Order matters: keys before cards so long digit runs inside keys aren't split.
    private nonisolated(unsafe) static let rules: [Rule] = [
        Rule(label: "[KEY]", regex: re(#"\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})"#)),
        Rule(label: "[EMAIL]", regex: re(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)),
        Rule(label: "[CARD]", regex: re(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#), isMatch: { luhn($0.filter(\.isNumber)) }),
    ]

    /// Returns the text with sensitive values replaced, and how many were replaced.
    static func redact(_ text: String) -> (text: String, hits: Int) {
        var out = text
        var hits = 0
        for rule in rules {
            let ns = out as NSString
            for m in rule.regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let found = ns.substring(with: m.range)
                guard rule.isMatch(found) else { continue }
                out = (out as NSString).replacingCharacters(in: m.range, with: rule.label)
                hits += 1
            }
        }
        return (out, hits)
    }

    static func luhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
