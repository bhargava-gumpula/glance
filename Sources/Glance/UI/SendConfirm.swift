import Foundation

/// Phase 4: the Send/Cancel step before anything with a high-risk item (or a reveal) leaves the Mac.
/// Reusable: Guide's full-screen consent calls `ask` too. The panel and Pip's bubble show `prompt` with
/// Send and Cancel; a spoken "send" / "cancel" answers it as well.
@MainActor
final class SendConfirm: ObservableObject {
    static let shared = SendConfirm()

    /// Non-nil while waiting for the user.
    @Published private(set) var prompt: String?
    private var waiting: CheckedContinuation<Bool, Never>?

    /// Returns true for Send. A newer `ask`, a cancelled task or Cancel returns false.
    func ask(_ prompt: String) async -> Bool {
        answer(false) // a newer question replaces an older one
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                waiting = c
                self.prompt = prompt
            }
        } onCancel: {
            Task { @MainActor in SendConfirm.shared.answer(false) }
        }
    }

    func answer(_ send: Bool) {
        let c = waiting
        waiting = nil
        prompt = nil
        c?.resume(returning: send)
    }

    // MARK: Policy (pure, selftested)

    /// Tags that need a tap before sending, with how they read in the prompt (singular, plural).
    nonisolated static let highRiskTags: [(tag: String, one: String, many: String)] = [
        ("[CARD]", "card number", "card numbers"), ("[IBAN]", "IBAN", "IBANs"), ("[PPSN]", "PPS number", "PPS numbers"),
        ("[SSN]", "SSN", "SSNs"), ("[PASSWORD]", "password", "passwords"), ("[PIN]", "PIN or security code", "PINs or security codes"),
        ("[KEY]", "key", "keys"), ("[SECRET]", "secret", "secrets"), ("[TOKEN]", "token", "tokens"),
        ("[WALLET]", "wallet address", "wallet addresses"),
    ]

    /// Counts high-risk tags in outgoing (already redacted) text.
    nonisolated static func highRisk(in texts: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for t in texts {
            for h in highRiskTags {
                let n = t.components(separatedBy: h.tag).count - 1
                if n > 0 { counts[h.tag, default: 0] += n }
            }
        }
        return counts
    }

    /// "Hid 2 card numbers, 1 IBAN and 3 other items. Send?" Nil when no tap is needed.
    nonisolated static func prompt(highRisk: [String: Int], total: Int, revealed: Bool) -> String? {
        if revealed { return "You asked Glance to look at hidden data, so this goes out unredacted. Send?" }
        guard !highRisk.isEmpty else { return nil }
        var parts = highRiskTags.compactMap { h in highRisk[h.tag].map { "\($0) \($0 == 1 ? h.one : h.many)" } }
        let others = total - highRisk.values.reduce(0, +)
        if others > 0 { parts.append("\(others) other item\(others == 1 ? "" : "s")") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "Hid \(list). Send?"
    }

    /// The fixed, local line spoken before an answer when anything was hidden. Never from the model.
    nonisolated static func hidLine(_ n: Int) -> String? {
        n > 0 ? "I hid \(n) sensitive item\(n == 1 ? "" : "s") before sending." : nil
    }

    /// A spoken reply to the prompt: true = send, false = cancel, nil = not an answer.
    nonisolated static func spokenAnswer(_ text: String) -> Bool? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return nil }
        if words.contains(where: { ["cancel", "stop", "no", "don", "dont", "nope"].contains($0) }) { return false }
        if words.contains(where: { ["send", "yes", "ok", "okay", "go", "sure"].contains($0) }) { return true }
        return nil
    }
}
