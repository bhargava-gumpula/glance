import AppKit

/// Phase 4 selftests (visible privacy + local-only). Called once from `SelfTest.run`.
enum Phase4Tests {
    /// Runs the main run loop until `done` or the timeout (send()'s confirm step lives on the main actor,
    /// so a semaphore wait on the main thread would deadlock).
    private static func pump(until done: () -> Bool, timeout: Double = 5) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func run(_ check: (Bool, String) -> Void) {
        // Send/Cancel policy
        let hr = SendConfirm.highRisk(in: ["Card [CARD] and [CARD]", "IBAN [IBAN], mail [EMAIL]"])
        check(hr == ["[CARD]": 2, "[IBAN]": 1], "confirm: counts high-risk tags only")
        check(SendConfirm.prompt(highRisk: hr, total: 3, revealed: false) == "Hid 2 card numbers and 1 IBAN. Send?",
              "confirm: prompt names the items")
        check(SendConfirm.prompt(highRisk: ["[PASSWORD]": 1], total: 3, revealed: false) == "Hid 1 password and 2 other items. Send?",
              "confirm: other hidden items are counted")
        check(SendConfirm.prompt(highRisk: SendConfirm.highRisk(in: ["[EMAIL] [NAME] [PHONE] [ADDRESS]"]), total: 4, revealed: false) == nil,
              "confirm: names, emails, phones and addresses don't ask")
        check(SendConfirm.prompt(highRisk: [:], total: 0, revealed: true) != nil, "confirm: a reveal always asks")
        for tag in ["[CARD]", "[IBAN]", "[PPSN]", "[SSN]", "[PASSWORD]", "[PIN]", "[KEY]", "[SECRET]", "[WALLET]"] {
            check(SendConfirm.prompt(highRisk: SendConfirm.highRisk(in: [tag]), total: 1, revealed: false) != nil, "confirm: \(tag) asks")
        }
        check(SendConfirm.hidLine(3) == "I hid 3 sensitive items before sending." && SendConfirm.hidLine(1) == "I hid 1 sensitive item before sending."
              && SendConfirm.hidLine(0) == nil, "hid line: fixed local text")
        check(SendConfirm.spokenAnswer("Send.") == true && SendConfirm.spokenAnswer("cancel") == false
              && SendConfirm.spokenAnswer("no, don't send") == false && SendConfirm.spokenAnswer("What does this card do?") == nil,
              "confirm: spoken send / cancel")
        check(Redactor.redact("PIN: 4821").text == "PIN: [PIN]" && Redactor.redact("Password: hunter2").text == "Password: [PASSWORD]",
              "redactor: PIN and password tags")

        // send(): the confirm step
        let img = Data([0xFF, 0xD8, 0xFF])
        func packet(_ redacted: String, _ raw: String, hits: Int, screen: Bool = false) -> ContextPacket {
            var p = ContextPacket(appName: "Safari", redacted: .init(selectionImage: img, selectedText: redacted),
                                  raw: .init(selectionImage: img, selectedText: raw), redactions: hits)
            p.isScreen = screen
            return p
        }
        let card = packet("Card [CARD]", "Card 4242 4242 4242 4242", hits: 1)
        let mailOnly = packet("Mail [EMAIL]", "Mail a@b.ie", hits: 1)
        /// Sends, answering the confirm with `answer` (nil = never shown). Returns what reached the provider,
        /// whether the confirm was shown, and the streamed text.
        func trySend(_ p: ContextPacket, question: String = "What is this?", reveal: Bool = false, answer: Bool?,
                     confirm: (@MainActor (ContextPacket.Preview) async -> Bool)? = nil) -> (sent: String, asked: String?, text: String) {
            MainActor.assumeIsolated {
                let provider = RecordingProvider4()
                var finished = false, text = "", asked: String?
                let stream = ContextPacket.send(p, history: [], question: question, reveal: reveal, announce: true,
                                                mode: .explain, provider: provider, showPreview: { _ in }, confirm: confirm)
                Task { @MainActor in
                    do { for try await d in stream { text += d } } catch {}
                    finished = true
                }
                pump(until: { SendConfirm.shared.prompt != nil || finished }, timeout: 2)
                asked = SendConfirm.shared.prompt
                if let answer, asked != nil { SendConfirm.shared.answer(answer) }
                pump(until: { finished })
                if !finished { SendConfirm.shared.answer(false); pump(until: { finished }) }
                return (provider.sent, asked, text)
            }
        }
        let cancelled = trySend(card, answer: false)
        check(cancelled.asked == "Hid 1 card number. Send?", "send(): a card asks Send/Cancel  → \(cancelled.asked ?? "nil")")
        check(cancelled.sent.isEmpty && cancelled.text.isEmpty, "send(): Cancel sends nothing")
        let approved = trySend(card, answer: true)
        check(approved.sent.contains("[CARD]") && !approved.sent.contains("4242"), "send(): Send sends the redacted packet")
        let quiet = trySend(mailOnly, answer: nil)
        check(quiet.asked == nil && quiet.sent.contains("[EMAIL]"), "send(): an email alone goes without a tap")
        let typedCard = trySend(mailOnly, question: "is 4242 4242 4242 4242 mine?", answer: false)
        check(typedCard.asked != nil && typedCard.sent.isEmpty, "send(): a card in the question asks too")
        let revealAsk = trySend(card, question: "Don't redact it", reveal: true, answer: false)
        check(revealAsk.asked != nil && revealAsk.sent.isEmpty, "send(): a reveal asks, Cancel sends nothing")
        let screen = trySend(packet("Card [CARD]", "Card 4242 4242 4242 4242", hits: 1, screen: true),
                             question: "Don't redact it", reveal: true, answer: true)
        check(!screen.sent.contains("4242") && screen.sent.contains("[CARD]"), "send(): a full-screen packet is never revealed")
        let consentCalls = Counter()
        let consent = trySend(mailOnly, answer: nil, confirm: { p in consentCalls.n += 1; return p.confirmPrompt != nil })
        check(consentCalls.n == 1 && consent.sent.isEmpty, "send(): a caller's confirm is always awaited; false sends nothing")

        mockBank(check)
        networkGate(check)
    }

    /// Scope 6: demo/mock-bank.html, rendered and OCR'd, comes out fully tagged and asks before sending.
    private static func mockBank(_ check: (Bool, String) -> Void) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../demo/mock-bank.html")
        guard let html = try? Data(contentsOf: root),
              let page = NSAttributedString(html: html, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        else { check(false, "mock bank: page renders"); return }
        let size = NSSize(width: 900, height: 1100)
        let image = NSImage(size: size, flipped: true) { r in
            NSColor.white.setFill(); r.fill()
            let big = NSMutableAttributedString(attributedString: page)
            big.addAttribute(.font, value: NSFont.systemFont(ofSize: 22), range: NSRange(location: 0, length: big.length))
            big.draw(in: r.insetBy(dx: 30, dy: 30))
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let lines = try? OCR.lines(in: cg)
        else { check(false, "mock bank: OCR runs"); return }
        let red = Redactor.redactLines(lines.map(\.text))
        let out = red.map(\.text).joined(separator: "\n")
        for secret in ["4242", "IE29", "AIBK", "1234567T", "aoife.demo@example.ie", "demo-password-123", "Aoife Demo"] {
            check(!out.contains(secret), "mock bank: \(secret) hidden")
        }
        for tag in ["[CARD]", "[IBAN]", "[PPSN]", "[EMAIL]"] { check(out.contains(tag), "mock bank: tagged \(tag)") }
        let total = red.reduce(0) { $0 + $1.hits }
        let prompt = SendConfirm.prompt(highRisk: SendConfirm.highRisk(in: [out]), total: total, revealed: false) ?? ""
        check(prompt.contains("card number") && prompt.contains("IBAN") && prompt.contains("PPS number"),
              "mock bank: confirm appears  → \(prompt)")
        print("      mock bank OCR → \(out.replacingOccurrences(of: "\n", with: " | "))")
    }

    /// Scope 4: every request goes through Network; local-only blocks everything but localhost.
    private static func networkGate(_ check: (Bool, String) -> Void) {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !["Network.swift", "Phase4Tests.swift"].contains($0.lastPathComponent) }
        // Any of these outside Network.swift would open a connection without the gate.
        let banned = ["URLSession", "dataTask(", "bytes(for:", "data(for:", "upload(for:", "download(for:", "uploadTask(",
                      "downloadTask(", "streamTask(", "webSocketTask(", "NWConnection", "CFStream", "WKWebView"]
        var bypasses: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = (line.components(separatedBy: "//").first ?? "")
                    .replacingOccurrences(of: "Network.data(for:", with: "").replacingOccurrences(of: "Network.bytes(for:", with: "")
                for b in banned where code.contains(b) { bypasses.append("\(file.lastPathComponent):\(n + 1) \(b)") }
            }
        }
        check(files.count > 20, "network inventory: scanned \(files.count) source files")
        check(bypasses.isEmpty, "network inventory: no request bypasses Network.swift  → \(bypasses.joined(separator: ", "))")
        check(Network.allowed(URL(string: "http://localhost:11434/v1/chat/completions")!, localOnly: true)
              && Network.allowed(URL(string: "http://127.0.0.1:1234/v1")!, localOnly: true)
              && Network.allowed(URL(string: "http://[::1]:11434")!, localOnly: true), "network gate: localhost allowed in local-only")
        check(!Network.allowed(URL(string: "https://api.anthropic.com/v1/messages")!, localOnly: true)
              && !Network.allowed(URL(string: "https://api.elevenlabs.io/")!, localOnly: true)
              && !Network.allowed(URL(string: "http://localhost.evil.com/")!, localOnly: true), "network gate: other hosts blocked in local-only")
        check(Network.allowed(URL(string: "https://api.anthropic.com/v1/messages")!, localOnly: false), "network gate: open when local-only is off")
    }
}

/// Captures what send() would transmit, without any network.
private final class RecordingProvider4: AIProvider, @unchecked Sendable {
    var sent = ""
    var name: String { "Test" }
    var supportsImages: Bool { false }
    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest {
        sent = messages.map(\.text).joined(separator: "\n")
        throw CancellationError()
    }
    func textDelta(fromEvent payload: String) throws -> String? { nil }
}

private final class Counter: @unchecked Sendable { var n = 0 }
