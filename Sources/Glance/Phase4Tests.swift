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

        localOnly(check)
        providerSpeed(check)
        speechInventory(check)
        mockBank(check)
        networkGate(check)
    }

    /// Owner rule: Glance speaks only the answer's "Say:" line (and Guide steps, Phase 5). Outside the speech engine
    /// (Voice/) and Guide, the only speech call is `speaker.answer`; Pip's bubble ignores notices.
    private static func speechInventory(_ check: (Bool, String) -> Void) {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .filter { url in
                let path = url.path
                return !path.contains("/Voice/") && !path.contains("/Guide/") && !url.lastPathComponent.hasPrefix("Guide")
                    && !["SelfTest.swift", "Phase4Tests.swift"].contains(url.lastPathComponent)
            }
        let speech = [".speak(", ".feed(", ".say(", "speaker.finish(", "AVSpeech", "NSSpeechSynthesizer", "speaker.begin(", "speaker.answer("]
        var sites: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for p in speech where code.contains(p) { sites.append("\(file.lastPathComponent):\(n + 1) \(p)") }
            }
        }
        let allowed = sites.filter { $0.hasPrefix("Panel.swift:") && ($0.hasSuffix("speaker.answer(") || $0.hasSuffix("speaker.begin(")) }
        check(sites.count == allowed.count && allowed.contains { $0.hasSuffix("speaker.answer(") },
              "speech inventory: outside Voice/ and Guide, only the answer's Say line is spoken  → \(sites.filter { !allowed.contains($0) })")
        let id = UUID()
        check(PetView.lastReply(in: [ChatModel.Turn(kind: .assistant, text: "Answer"), ChatModel.Turn(kind: .notice, text: "Using Mac voice."),
                                     ChatModel.Turn(kind: .notice, text: "The provider returned HTTP 500.")])?.text == "Answer",
              "speech inventory: Pip's bubble never shows notices or errors")
        check(PetView.bubbleText(state: .thinking, said: nil, reply: nil, spoken: nil, dismissed: nil) == "Thinking…"
              && PetView.bubbleText(state: .thinking, said: ("x", id), reply: nil, spoken: nil, dismissed: nil) == "Thinking…",
              "speech inventory: no filler beyond Listening… / Thinking…")
    }

    /// Slow answers (owner report, grok-4.6 on Azure): reasoning_effort low, dropped once a deployment rejects it,
    /// incremental SSE, a smaller memory budget, and the spoken "Say:" line first.
    private static func providerSpeed(_ check: (Bool, String) -> Void) {
        let base = "https://stub.test/openai/v1", model = "grok-test"
        ReasoningEffort.forget(baseURL: base, model: model)
        defer { ReasoningEffort.forget(baseURL: base, model: model) }
        func body(_ p: AIProvider) -> [String: Any] {
            let r = try? p.makeRequest(system: "s", messages: [ChatMessage(role: .user, text: "q")])
            return (r?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let fresh = OpenAICompatProvider(name: "T", apiKey: "k", baseURL: base, model: model, supportsImages: false,
                                         reasoningEffort: ReasoningEffort.lowest)
        check(body(fresh)["reasoning_effort"] as? String == "low", "speed: OpenAI-compatible requests ask for low reasoning effort")
        check(ReasoningEffort.rejected(status: 400, body: #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}"#)
              && !ReasoningEffort.rejected(status: 400, body: "maximum context length exceeded")
              && !ReasoningEffort.rejected(status: 401, body: "reasoning"), "speed: only a 4xx naming the parameter counts as a rejection")

        // A stub server: 400 when reasoning_effort is sent, else an SSE stream in separate chunks.
        URLProtocol.registerClass(StubSSE.self)
        defer { URLProtocol.unregisterClass(StubSSE.self) }
        StubSSE.requests = 0
        let text = blocking { () async -> String in
            var t = ""
            do { for try await d in fresh.stream(system: "s", messages: [ChatMessage(role: .user, text: "q")]) { t += d } } catch { t = "error: \(error)" }
            return t
        }
        check(text == "Say: Fine.\n\nFull answer.", "speed: rejected reasoning_effort → sent again without it  → \(text ?? "nil")")
        check(StubSSE.requests == 2 && ReasoningEffort.unsupported(baseURL: base, model: model), "speed: the rejection is remembered for this address and model")
        let next = OpenAICompatProvider(name: "T", apiKey: "k", baseURL: base, model: model, supportsImages: false,
                                        reasoningEffort: ReasoningEffort.unsupported(baseURL: base, model: model) ? nil : ReasoningEffort.lowest)
        check(body(next)["reasoning_effort"] == nil, "speed: later requests skip the parameter (no extra round trip)")
        let events = blocking { () async -> Int in
            var n = 0
            do { for try await _ in next.stream(system: "s", messages: [ChatMessage(role: .user, text: "q")]) { n += 1 } } catch {}
            return n
        }
        check(events == 4, "speed: SSE text arrives event by event, not at the end  → \(events ?? -1) events")
        check(Mode.explain.system.contains("Start every reply with one line: \"Say: \""), "speed: the model is told to put the Say line first")
    }

    /// Scope 3: local-only mode routes AI and voice to this Mac, and the gate refuses everything else.
    private static func localOnly(_ check: (Bool, String) -> Void) {
        let d = UserDefaults.standard
        let before = d.object(forKey: "localOnly")
        defer { d.set(before, forKey: "localOnly") }
        d.set(true, forKey: "localOnly")
        let (routed, stt) = MainActor.assumeIsolated { () -> (Bool, [String]) in
            let p = try? Providers.current()
            return (p is LocalOnlyProvider && (p as? LocalOnlyProvider)?.fallback is AppleOnDeviceProvider, Voice.sttChain().map(\.name))
        }
        check(routed, "local only: AI is Local, backed by Apple's on-device model")
        check(stt == ["on-device"], "local only: speech-to-text is Apple on-device")
        check(Voice.tts(muted: false, elevenLabsKey: nil, voiceID: "x", fallback: MacTTS.shared) != nil, "local only: Mac voice still speaks")
        let blocked = blocking { () async -> Bool in
            do { _ = try await Network.data(for: URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)); return false }
            catch { return error is Network.Blocked }
        }
        check(blocked == true, "local only: a cloud request is refused by the gate before it leaves")

        // Fallback: Ollama not answering → the on-device provider answers.
        d.set("http://localhost:9/v1", forKey: "baseURL.local") // nothing listens on port 9
        defer { d.removeObject(forKey: "baseURL.local") }
        let fallbackLocal = LocalOnlyProvider(local: Providers.make(id: "local", key: ""), fallback: CannedProvider(reply: "on-device answer"))
        let text = blocking { () async -> String in
            var text = ""
            do { for try await t in fallbackLocal.stream(system: "s", messages: [ChatMessage(role: .user, text: "hi")]) { text += t } } catch {}
            return text
        }
        check(text == "on-device answer", "local only: no Ollama → Apple's on-device model answers")
        let long = [ChatMessage(role: .user, text: String(repeating: "memory line\n", count: 3000) + "My question: is this good?")]
        let prompt = AppleOnDeviceProvider.prompt(long)
        check(prompt.count <= AppleOnDeviceProvider.maxPromptChars + 3 && prompt.hasSuffix("My question: is this good?"),
              "local only: on-device prompt fits its context and keeps the question")
        print("      Apple on-device model: \(AppleOnDeviceProvider.unavailableReason.map { "unavailable (\($0))" } ?? "available")")
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

/// Streams a fixed reply, standing in for the on-device model.
private struct CannedProvider: AIProvider {
    let reply: String
    var name: String { "Canned" }
    var supportsImages: Bool { false }
    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest { throw CancellationError() }
    func textDelta(fromEvent payload: String) throws -> String? { nil }
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield(reply); $0.finish() }
    }
}

/// Runs async work from the synchronous selftest (off the main thread) and waits for it.
private func blocking<T: Sendable>(timeout: Double = 10, _ op: @escaping @Sendable () async -> T) -> T? {
    let box = SendableBox<T>(), done = DispatchSemaphore(value: 0)
    Task.detached { box.value = await op(); done.signal() }
    _ = done.wait(timeout: .now() + timeout)
    return box.value
}

private final class SendableBox<T>: @unchecked Sendable { var value: T? }

/// Fake OpenAI-compatible endpoint at stub.test for the speed selftest.
private final class StubSSE: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let rejects = String(decoding: body, as: UTF8.self).contains("reasoning_effort")
        let response = HTTPURLResponse(url: request.url!, statusCode: rejects ? 400 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": rejects ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if rejects {
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}"#.utf8))
        } else {
            for piece in ["Say: ", "Fine.", "\\n\\n", "Full answer."] {
                let json = #"{"choices":[{"index":0,"delta":{"content":"\#(piece)"}}]}"#
                client?.urlProtocol(self, didLoad: Data("data: \(json)\n\n".utf8))
            }
            client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
