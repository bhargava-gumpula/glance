import Foundation
import NaturalLanguage

/// Replaces sensitive values with tags like [CARD]. Runs on-device before anything is sent.
/// Rules are checked in order; earlier rules win (keys before cards, cards before phone numbers).
/// Phase 4 may move the patterns to Resources/redaction.json.
enum Redactor {
    private struct Rule {
        let tag: String
        let regex: NSRegularExpression
        /// Capture group to replace (0 = whole match). Label rules keep the label and hide the value.
        var group = 0
        var isMatch: (String) -> Bool = { _ in true }
    }

    private nonisolated(unsafe) static let rules: [Rule] = [
        // Secrets
        Rule(tag: "[KEY]", regex: re(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#)),
        Rule(tag: "[KEY]", regex: re(#"\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}|(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|whsec_[A-Za-z0-9+/=]{20,})"#)),
        Rule(tag: "[TOKEN]", regex: re(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#)),
        Rule(tag: "[TOKEN]", regex: re(#"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]{20,})"#), group: 1),
        Rule(tag: "[SECRET]", regex: re(#"(?i)(?<![A-Za-z0-9_])(?:[A-Za-z0-9]+_)*(?:password|passwd|pwd|passcode|pass code|secret|api[ _-]?key|access[ _]?key|access token|auth token|token|private[ _]?key|seed phrase|recovery phrase|secret phrase|mnemonic|security answer)(?:_[A-Za-z0-9]+)*\s*[:=]\s*([^\n]+)"#), group: 1),
        // Crypto wallets and private keys
        Rule(tag: "[KEY]", regex: re(#"\b(?:0x)?[a-fA-F0-9]{64}\b"#)),
        Rule(tag: "[WALLET]", regex: re(#"\b0x[a-fA-F0-9]{40}\b"#)),
        Rule(tag: "[WALLET]", regex: re(#"(?i)\b(?:bc1|tb1|ltc1)[02-9ac-hj-np-z]{11,71}\b"#)),
        Rule(tag: "[WALLET]", regex: re(#"\b[1-9A-HJ-NP-Za-km-z]{26,95}\b"#), isMatch: isMixedBase58),
        // Bank and government IDs
        Rule(tag: "[IBAN]", regex: re(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#), isMatch: iban),
        Rule(tag: "[EMAIL]", regex: re(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)),
        Rule(tag: "[SSN]", regex: re(#"\b\d{3}-\d{2}-\d{4}\b"#)),
        Rule(tag: "[PPSN]", regex: re(#"\b\d{7}[A-W][ABW]?\b"#), isMatch: ppsn),
        Rule(tag: "[CARD]", regex: re(#"(?<!\d)(?:\d[ -]?){12,18}?\d(?!\d)"#), isMatch: { luhn($0.filter(\.isNumber)) }),
        // Labelled values: account numbers (bank, brokerage, crypto exchange), IDs, codes
        Rule(tag: "[ID]", regex: re(#"(?i)\b(?:account|acct|a/c|sort code|routing|aba|bic|swift|member(?:ship)?|policy|passport|licen[cs]e|driver'?s licen[cs]e|customer|client|cvv2?|cvc|security code|pin|verification code|one[- ]time code|otp|2fa code|auth(?:entication)? code|tax id|ein|vat|nhs|medical record|patient|employee|student|portfolio|brokerage|wallet)\b(?:\s*(?:no\.?|number|num|#|id|code|address))?(?:\s+(?:is|was|ending in|ends in|ending))?\s*[:#=]?\s*(\d[\d -]{2,30}\d|[A-Z]{0,4}\d[A-Z0-9-]{2,40})"#), group: 1, isMatch: { $0.filter(\.isNumber).count >= 3 }),
        Rule(tag: "[DOB]", regex: re(#"(?i)\b(?:date of birth|birth ?date|dob|born)\b\s*[:=]?\s*([^\n]+)"#), group: 1, isMatch: { $0.contains(where: \.isNumber) }),
        Rule(tag: "[USERNAME]", regex: re(#"(?i)\b(?:user ?name|user ?id|account name|screen name|login|log-in|handle)\b\s*[:=]\s*([^\s:=][^\n]*)"#), group: 1),
        Rule(tag: "[USERNAME]", regex: re(#"(?i)\b(?:signed in as|logged in as)\b\s*[:=]?\s*([^\s:=][^\n]*)"#), group: 1),
        Rule(tag: "[NAME]", regex: re(#"(?i)\b(?:full name|first name|last name|surname|name on card|cardholder(?: name)?|account holder|mother'?s maiden name)\b\s*[:=]?\s*([^\s:=][^\n]*)"#), group: 1),
        Rule(tag: "[NAME]", regex: re(#"(?i)\b(?:recipient|ship to|bill to)\b\s*[:=]\s*([^\s:=][^\n]*)"#), group: 1),
        // Addresses
        Rule(tag: "[ADDRESS]", regex: re(#"(?i)\b(?:home |billing |shipping |delivery |postal |mailing |street )?address(?: line ?\d)?\s*[:=]\s*([^\n]+)"#), group: 1),
        Rule(tag: "[ADDRESS]", regex: re(#"\b\d{1,5}[A-Za-z]?,?\s+(?:[A-Z][a-zà-ÿ'’]+\s+){1,4}(?:Street|St|Road|Rd|Avenue|Ave|Lane|Ln|Drive|Dr|Court|Ct|Boulevard|Blvd|Way|Place|Pl|Terrace|Close|Crescent|Square|Sq|Park|Grove|Hill|Row|Quay|Parade|Gardens|Heights|Highway|Hwy)\b\.?"#)),
        Rule(tag: "[ADDRESS]", regex: re(#"\b(?:Apt|Apartment|Unit|Suite|Flat)\.?\s*#?\s*\d+[A-Za-z]?\b"#)),
        Rule(tag: "[ADDRESS]", regex: re(#"\b[AC-FHKNPRTV-Y]\d[0-9W] ?[0-9AC-FHKNPRTV-Y]{4}\b"#), isMatch: { $0.dropFirst(3).contains(where: \.isNumber) }), // Eircode
        // Contact and network
        Rule(tag: "[PHONE]", regex: re(#"(?<![\w+])\+?\(?\d[\d ().-]{7,18}\d(?![\w])"#), isMatch: isPhone),
        Rule(tag: "[IP]", regex: re(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#), isMatch: { $0.split(separator: ".").allSatisfy { Int($0) ?? 999 <= 255 } }),
        Rule(tag: "[USERNAME]", regex: re(#"(?<![\w.@])@[A-Za-z0-9_][A-Za-z0-9_.]{1,29}\b"#)),
        Rule(tag: "[USERNAME]", regex: re(#"(?<=/Users/|/home/)[^/\s]+"#)),
    ]

    /// Returns the text with sensitive values replaced, and how many were replaced.
    static func redact(_ text: String) -> (text: String, hits: Int) {
        var out = text
        var hits = 0
        for rule in rules {
            let ns = out as NSString
            for m in rule.regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let range = m.range(at: rule.group)
                guard range.location != NSNotFound else { continue }
                let found = ns.substring(with: range)
                guard rule.isMatch(found) else { continue }
                out = (out as NSString).replacingCharacters(in: range, with: rule.tag)
                hits += 1
            }
        }
        let codes = redactCodes(out)
        let names = redactNames(codes.text)
        return (names.text, hits + codes.hits + names.hits)
    }

    /// Personal names, found by Apple's on-device NaturalLanguage tagger.
    private static func redactNames(_ text: String) -> (text: String, hits: Int) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var ranges: [Range<String.Index>] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            // Two or more words only: single words ("Tue", "Mark") are too often not names.
            // Product and feature names ("Liquid Retina", "Neural Engine") get tagged as people; skip them.
            if tag == .personalName, text[range].contains(" "),
               !text[range].split(separator: " ").contains(where: { productWords.contains($0.lowercased()) }) {
                ranges.append(range)
            }
            return true
        }
        var out = text
        for range in ranges.reversed() { out.replaceSubrange(range, with: "[NAME]") }
        return (out, ranges.count)
    }

    /// True when the user explicitly asks Glance to look at data it would otherwise hide.
    static func userAskedToReveal(_ question: String) -> Bool {
        revealRegex.firstMatch(in: question, range: NSRange(location: 0, length: (question as NSString).length)) != nil
    }

    /// Only explicit requests about Glance's own redaction. Everyday UI words ("hidden files", "unhide",
    /// "stop hiding the Dock", "unmask") must not turn it off (audit A1).
    private nonisolated(unsafe) static let revealRegex = re(#"(?i)\b(?:don'?t|do not|no need to|stop|without)\s+(?:redact|redacting|censor|censoring)\b|\bun-?redact|\bno redaction\b|\bredaction off\b|\b(?:show|read|look at|see|use|include|tell me)\b.{0,40}\b(?:redacted|censored)\b|\b(?:it'?s|its|that'?s)\s+(?:ok|okay|fine|alright)\s+(?:to|for you to)\s+(?:see|read|look|use|share)"#)

    private static let productWords: Set<String> = [
        "retina", "liquid", "xdr", "neural", "engine", "touch", "magic", "pro", "max", "ultra", "air", "mini", "plus",
        "display", "oled", "amoled", "thunderbolt", "galaxy", "zenbook", "thinkpad", "surface", "pixel", "intel", "core",
        "ryzen", "geforce", "radeon", "snapdragon", "airpods", "macbook", "imac", "ipad", "iphone", "watch",
    ]

    /// A one-time code anywhere on a line that mentions a code (audit A7): "Your code is 482913", "G-482913 is your …".
    private nonisolated(unsafe) static let otpContext = re(#"(?i)\b(?:code|passcode|otp|verification)\b"#)
    private nonisolated(unsafe) static let otpToken = re(#"(?<![\w-])(?:[A-Z]-)?\d{4,8}(?![\w-])|(?<![\w-])\d{3}[- ]\d{3}(?![\w-])"#)

    private static func redactCodes(_ text: String) -> (text: String, hits: Int) {
        var hits = 0
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let ns = line as NSString
            guard otpContext.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { return line }
            var out = line
            for m in otpToken.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                out = (out as NSString).replacingCharacters(in: m.range, with: "[CODE]")
                hits += 1
            }
            return out
        }
        return (lines.joined(separator: "\n"), hits)
    }

    /// Redacts OCR lines with the context of their neighbours: the value under a bare "Password" label
    /// (audit A6), and every line of a PEM private key, not just its BEGIN line (audit A10).
    static func redactLines(_ lines: [String]) -> [(text: String, hits: Int)] {
        var out: [(text: String, hits: Int)] = []
        var inPEM = false, afterSecretLabel = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: .regularExpression) != nil { inPEM = true }
            if inPEM || (afterSecretLabel && !t.isEmpty) {
                out.append(("[SECRET]", 1))
                if t.range(of: #"-----END [A-Z ]*PRIVATE KEY-----"#, options: .regularExpression) != nil { inPEM = false }
                afterSecretLabel = false
                continue
            }
            afterSecretLabel = t.range(of: #"(?i)^(?:password|passcode|pin|cvv|cvc|security code)$"#, options: .regularExpression) != nil
            out.append(redact(line))
        }
        return out
    }

    // MARK: Validators

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

    /// IBAN mod-97 check.
    static func iban(_ raw: String) -> Bool {
        let s = raw.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(s.count) else { return false }
        let rearranged = s.dropFirst(4) + s.prefix(4)
        var remainder = 0
        for ch in rearranged {
            guard let v = ch.isNumber ? ch.wholeNumberValue : (ch.asciiValue.map { Int($0) - 55 }) else { return false }
            for d in String(v) { remainder = (remainder * 10 + d.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }

    /// Irish PPS number check character (weights 8..2 over 7 digits, 9 x the optional second letter, mod 23).
    static func ppsn(_ s: String) -> Bool {
        let chars = Array(s.uppercased())
        guard chars.count >= 8 else { return false }
        var sum = 0
        for i in 0..<7 { sum += (chars[i].wholeNumberValue ?? 0) * (8 - i) }
        if chars.count == 9, chars[8] != "W", let a = chars[8].asciiValue { sum += 9 * Int(a - 64) }
        let check = sum % 23
        let expected: Character = check == 0 ? "W" : Character(UnicodeScalar(64 + check)!)
        return chars[7] == expected
    }

    private static func isPhone(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count
        guard (9...15).contains(digits) else { return false }
        if s.hasPrefix("+") || s.hasPrefix("(") || s.hasPrefix("0") { return true }
        return s.range(of: #"^\d{3}[-. ]\d{3}[-. ]\d{4}$"#, options: .regularExpression) != nil
    }

    /// Base58 wallet addresses mix digits, upper and lower case; plain words don't.
    private static func isMixedBase58(_ s: String) -> Bool {
        s.contains(where: \.isNumber) && s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase)
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
