import AppKit

/// `Glance --selftest`: assert-style checks, non-zero exit on failure.
/// Each phase adds its checks here.
enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }

        // Phase 2: OCR warm-up. Runs first, like the app: a cold Vision load after NaturalLanguage work (the
        // Redactor) can fail with CRImageReaderError 1 and leave OCR empty for the whole process.
        let warm = OCR.warmUp()
        print("      OCR warm-up: \(String(format: "%.1f", warm.seconds)) s (cold); first attempt \(warm.first); recognized \"\(warm.text)\"")
        check(warm.text.contains("Glance"), "OCR warm-up actually runs recognition")
        check(OCR.warmUp().seconds < 3, "OCR is fast once warmed up")

        check(Config.captureIntervalSeconds > 0, "capture interval is positive")
        check(Config.retentionMinutes > 0, "retention is positive")
        check(Config.excludedApps.contains("com.apple.keychainaccess"), "Keychain Access is excluded by default")
        check(["claude", "deepseek", "openai", "local"].contains(Config.provider), "default provider is known")

        // Phase 1: redactor
        func red(_ s: String) -> String { Redactor.redact(s).text }
        check(red("Card 4242 4242 4242 4242 exp 12/29") == "Card [CARD] exp 12/29", "Luhn-valid card is redacted")
        check(red("4111-1111-1111-1111") == "[CARD]", "dashed card is redacted")
        check(red("Order 1234 5678 9012 3456") == "Order 1234 5678 9012 3456", "Luhn-invalid 16 digits are kept")
        check(red("mail aoife.k@example.ie now") == "mail [EMAIL] now", "email is redacted")
        check(red("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123") == "key [KEY]", "Anthropic-style key is redacted")
        check(red("AKIAABCDEFGHIJKLMNOP") == "[KEY]", "AWS access key is redacted")
        let product = "16 GB unified memory, 512 GB SSD, 2560 x 1664 display, 18-hour battery, €1,299.00, model A3113"
        check(red(product) == product, "normal product specs are untouched")

        // Phase 1: request format per provider (fake key, nothing is sent)
        let img = Data([0xFF, 0xD8, 0xFF])
        let msgs = [ChatMessage(role: .user, text: "What is this?", images: [img])]
        func body(_ r: URLRequest?) -> [String: Any] {
            (r?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let claude = try? Providers.make(id: "claude", key: "test-key").makeRequest(system: "sys", messages: msgs)
        let cb = body(claude)
        let cContent = ((cb["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        check(claude?.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Claude: endpoint")
        check(claude?.value(forHTTPHeaderField: "x-api-key") == "test-key"
              && claude?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Claude: auth + version headers")
        check(cb["model"] as? String == "claude-opus-5-5" && cb["stream"] as? Bool == true
              && cb["system"] as? String == "sys" && cb["max_tokens"] != nil, "Claude: model, stream, system, max_tokens")
        check(cContent.first?["type"] as? String == "image"
              && (cContent.first?["source"] as? [String: Any])?["media_type"] as? String == "image/jpeg"
              && cContent.last?["text"] as? String == "What is this?", "Claude: image block then text block")
        check(cb["thinking"] == nil && cb["temperature"] == nil, "Claude: no rejected thinking/sampling params")
        check(try! AnthropicProvider(apiKey: "", baseURL: "", model: "")
              .textDelta(fromEvent: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#) == "Hi",
              "Claude: parses text_delta")

        let openai = try? Providers.make(id: "openai", key: "test-key").makeRequest(system: "sys", messages: msgs)
        let ob = body(openai)
        let oMsgs = (ob["messages"] as? [[String: Any]]) ?? []
        let oParts = (oMsgs.last?["content"] as? [[String: Any]]) ?? []
        check(openai?.url?.absoluteString == "https://api.openai.com/v1/chat/completions", "OpenAI: endpoint")
        check(openai?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "OpenAI: bearer auth")
        check(oMsgs.first?["role"] as? String == "system" && ob["stream"] as? Bool == true, "OpenAI: system message, stream")
        check(((oParts.last?["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true,
              "OpenAI: image as data URL")

        let deepseek = try? Providers.make(id: "deepseek", key: "test-key").makeRequest(system: "sys", messages: msgs)
        let dMsgs = (body(deepseek)["messages"] as? [[String: Any]]) ?? []
        check(deepseek?.url?.absoluteString == "https://api.deepseek.com/chat/completions", "DeepSeek: endpoint")
        check(dMsgs.last?["content"] as? String == "What is this?", "DeepSeek: text-only, images dropped")
        check(try! OpenAICompatProvider(name: "", apiKey: "", baseURL: "", model: "", supportsImages: false)
              .textDelta(fromEvent: #"{"choices":[{"index":0,"delta":{"content":"Hi"}}]}"#) == "Hi",
              "OpenAI-compatible: parses delta.content")

        check(Config.normalizedBaseURL("https://x.services.ai.azure.com/openai/v1/chat/completions\nsecret\n")
              == "https://x.services.ai.azure.com/openai/v1", "pasted full endpoint is trimmed to a base URL")
        let azure = try? OpenAICompatProvider(name: "", apiKey: "k", baseURL: "https://x.services.ai.azure.com/openai/v1",
                                              model: "m", supportsImages: false).makeRequest(system: "s", messages: msgs)
        check(azure?.url?.absoluteString == "https://x.services.ai.azure.com/openai/v1/chat/completions"
              && azure?.value(forHTTPHeaderField: "api-key") == "k", "Azure endpoint: path and api-key header")

        let local = try? Providers.make(id: "local", key: "").makeRequest(system: "sys", messages: msgs)
        check(local?.url?.host == "localhost" && local?.value(forHTTPHeaderField: "Authorization") == nil,
              "Local: localhost, no auth header")

        let content = ContextPacket.Content(selectionImage: img, selectedText: "M4 chip")
        let packet = ContextPacket(appName: "Safari", redacted: content, raw: content, redactions: 0)
        check(packet.firstMessage(content, question: "q", imagesAllowed: false).images.isEmpty
              && packet.firstMessage(content, question: "q", imagesAllowed: false).text.contains("M4 chip"),
              "text-only packet carries the selection's OCR text, no images")
        check(packet.firstMessage(content, question: "q", imagesAllowed: true).images.count == 1,
              "vision packet carries only the selection image")

        // Expanded redaction: each sample must lose its secret and gain its tag
        let cases: [(String, String, String)] = [
            ("IBAN", "IBAN: IE29 AIBK 9311 5212 3456 78", "[IBAN]"),
            ("PPSN", "PPS 1234567T", "[PPSN]"),
            ("US SSN", "SSN 123-45-6789", "[SSN]"),
            ("Irish mobile", "Call 087 123 4567 today", "[PHONE]"),
            ("international phone", "+353 1 234 5678", "[PHONE]"),
            ("US phone", "(415) 555-0132", "[PHONE]"),
            ("Eircode", "Dublin D02 X285", "[ADDRESS]"),
            ("street address", "12 Grafton Street, Dublin 2", "[ADDRESS]"),
            ("labelled address", "Shipping address: 4 Main St, Galway", "[ADDRESS]"),
            ("apartment", "Apt 4B", "[ADDRESS]"),
            ("Ethereum wallet", "0x52908400098527886E0F7030069857D2E4169EE7", "[WALLET]"),
            ("Bitcoin bech32", "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", "[WALLET]"),
            ("Bitcoin legacy", "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", "[WALLET]"),
            ("Solana wallet", "7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV", "[WALLET]"),
            ("private key hex", "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318", "[KEY]"),
            ("seed phrase", "Recovery phrase: abandon ability able about above absent", "[SECRET]"),
            ("brokerage account", "Brokerage account number: 5RT-28473", "[ID]"),
            ("bank account", "Account number 12345678", "[ID]"),
            ("sort code", "Sort code 93-11-52", "[ID]"),
            ("CVV", "CVV: 123", "[ID]"),
            ("2FA code", "Your verification code is 482913", "[ID]"),
            ("password", "Password: hunter2!", "[SECRET]"),
            ("username label", "Username: aoife_k", "[USERNAME]"),
            ("signed in as", "Signed in as aoifek", "[USERNAME]"),
            ("handle", "Follow @aoife_kelly for more", "[USERNAME]"),
            ("home folder", "/Users/aoife/Documents/budget.numbers", "[USERNAME]"),
            ("date of birth", "Date of birth: 14/03/2004", "[DOB]"),
            ("name label", "Name on card: Aoife Kelly", "[NAME]"),
            ("person name", "Reviewed by Aoife Kelly", "[NAME]"),
            ("JWT", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "[TOKEN]"),
            ("Stripe key", "sk_live_51HqLyjWDarjtT1zdp7dc", "[KEY]"),
            ("IP address", "Server 192.168.1.24", "[IP]"),
        ]
        for (name, input, tag) in cases {
            let out = red(input)
            check(out.contains(tag), "redacts \(name)  →  \(out)")
        }
        let safe = [
            "MacBook Air 13-inch with M4 chip, 16 GB unified memory, 512 GB SSD",
            "Display 2560 x 1664, 500 nits, Wi-Fi 6E, Bluetooth 5.3, macOS 27.2",
            "€1,299.00 or €108.25/mo. for 12 mo. Free delivery by Tue 7 Oct 2026",
            "Battery: up to 18 hours. Weight 1.24 kg. Model A3113. 2 x Thunderbolt 4 ports",
            "Customer reviews 4.6 out of 5 (1,234 ratings). 4-pin connector. Order 2026-10-03",
            "Samsung Galaxy Book4 Pro 14\" AMOLED 2880 x 1800 120Hz Intel Core Ultra 7 155H",
            "Processor 8-core CPU, 10-core GPU, 16-core Neural Engine. USB-C power adapter 70W",
        ]
        for line in safe { check(red(line) == line, "no false hit: \(line.prefix(45))…  →  \(red(line))") }

        // Reveal override: only explicit requests
        for q in ["Don't redact it, what's my card number?", "You can show the redacted email", "unredact this",
                  "It's okay to see my address", "read the redacted account number"] {
            check(Redactor.userAskedToReveal(q), "reveal: \(q)")
        }
        for q in ["Is 16 GB enough for college?", "What does this card do?", "Explain this spec", "Hide the details",
                  "What's my card number?"] {
            check(!Redactor.userAskedToReveal(q), "no reveal: \(q)")
        }

        // Audit 1 fixes (A1, A2, A4-A12); each failed before its fix
        for q in ["How do I show hidden files in Finder?", "Can I see hidden columns in this sheet?", "How do I unhide this row?",
                  "Tell me why this layer is hidden", "How do I stop hiding the Dock?", "How do I include hidden folders in the search?",
                  "How do I unmask this field?"] {
            check(!Redactor.userAskedToReveal(q), "A1 no reveal: \(q)")
        }
        check(Redactor.userAskedToReveal("show the redacted email") && Redactor.userAskedToReveal("please don't redact anything"),
              "A1 explicit redaction requests still reveal")
        check(ChatModel.needsPreview(first: nil, now: ("Claude", true))
              && ChatModel.needsPreview(first: ("Local", true), now: ("OpenAI", true))
              && ChatModel.needsPreview(first: ("DeepSeek", false), now: ("DeepSeek", true))
              && !ChatModel.needsPreview(first: ("Claude", true), now: ("Claude", true)), "A2 new preview when provider or images change")
        for line in ["Apple MacBook Air 13-inch M4, 16GB unified memory, 512GB SSD, Liquid Retina display, 18-hour battery life, €1,299",
                     "MacBook Air 13-inch, Liquid Retina display, 16GB unified memory",
                     "Liquid Retina XDR display, 18-hour battery life"] {
            check(red(line) == line, "A4 product line kept: \(line.prefix(40))…  →  \(red(line))")
        }
        check(red("Reviewed by Aoife Kelly").contains("[NAME]"), "A4 real names still redacted")
        for card in ["4242 4242 4242 4242 12/29 123", "4111 1111 1111 1111 123", "4111-1111-1111-1111 123"] {
            check(red(card).hasPrefix("[CARD]") && !red(card).contains("4242 4242") && !red(card).contains("1111 1111"), "A5 card before expiry/CVC: \(red(card))")
        }
        let pwd = Redactor.redactLines(["Email", "aoife@example.ie", "Password", "•••••••••••", "Sign in"])
        check(pwd[3].hits > 0 && pwd[3].text == "[SECRET]" && pwd[4].hits == 0, "A6 value under a bare Password label")
        for otp in ["Your code is 482913", "482913 is your verification code", "G-482913 is your Google verification code.",
                    "Enter code 482913", "Your WhatsApp code: 123-456"] {
            check(!red(otp).contains("482913") && !red(otp).contains("123-456"), "A7 2FA: \(otp) → \(red(otp))")
        }
        check(red("Use code 4 for the 4-pin connector") == "Use code 4 for the 4-pin connector", "A7 short numbers kept")
        for env in ["OPENAI_API_KEY=abc123def456ghi789jkl012mno", "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                    "secret_key = abcdefghijklmnop1234", "STRIPE_WEBHOOK=whsec_abcdefghijklmnopqrstuvwx"] {
            check(red(env).contains("[SECRET]") || red(env).contains("[KEY]"), "A8 env secret: \(red(env))")
        }
        check(red("Max tokens: 16000") == "Max tokens: 16000", "A8 'tokens:' count kept")
        for line in ["Can easily handle 4K video editing and gaming", "We ship to Ireland and the UK", "Login  Basket  Help"] {
            check(red(line) == line, "A9 copy kept: \(line)  →  \(red(line))")
        }
        check(red("Login: aoife_k").contains("[USERNAME]") && red("Ship to: Aoife Kelly").contains("[NAME]"), "A9 labelled values still redacted")
        let pem = Redactor.redactLines(["-----BEGIN PRIVATE KEY-----", "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj",
                                        "AoGBAMhQ+3+XyKk3pL0mF1JjW8Wqz7G9Y2nA5bE6cD4fH8iJ2kL3mN4oP5qR6sT7", "-----END PRIVATE KEY-----", "done"])
        check(pem[0...3].allSatisfy { $0.hits > 0 && !$0.text.contains("MII") && !$0.text.contains("AoGB") } && pem[4].hits == 0, "A10 PEM body lines")
        check(Config.keyHostMismatch(savedFor: "x.services.ai.azure.com", baseURL: "https://api.deepseek.com") != nil
              && Config.keyHostMismatch(savedFor: "api.deepseek.com", baseURL: "https://api.deepseek.com") == nil
              && Config.keyHostMismatch(savedFor: nil, baseURL: "https://api.deepseek.com") == nil, "A11 key only goes to its saved host")
        check(Config.validBaseURL("https://x.services.ai.azure.com/openai/v1") && Config.validBaseURL("http://localhost:11434/v1")
              && !Config.validBaseURL("sk-abc123def456") && !Config.validBaseURL("api.deepseek.com"), "A12 address must be an http(s) URL")
        check(Config.validVoiceID("EXAVITQu4vr4xnSDxMaL") && !Config.validVoiceID("sk_0123456789abcdef0123456789abcdef0123")
              && !Config.validVoiceID("a b"), "A12 voice ID can't hold a key")

        // send(): redacts by default, sends raw only when revealed
        let rawContent = ContextPacket.Content(selectionImage: img, selectedText: "Card 4242 4242 4242 4242")
        let redContent = ContextPacket.Content(selectionImage: img, selectedText: "Card [CARD]")
        let cardPacket = ContextPacket(appName: "Safari", redacted: redContent, raw: rawContent, redactions: 1)
        func sent(reveal: Bool, question: String) -> String {
            let recorder = RecordingProvider()
            let done = DispatchSemaphore(value: 0)
            MainActor.assumeIsolated {
                let stream = ContextPacket.send(cardPacket, history: [], question: question, reveal: reveal, announce: false,
                                                mode: .explain, provider: recorder) { _ in }
                Task.detached { for try await _ in stream {}; done.signal() }
            }
            _ = done.wait(timeout: .now() + 5)
            return recorder.lastText
        }
        let normal = sent(reveal: false, question: "Email me at a@b.ie")
        check(normal.contains("[CARD]") && normal.contains("[EMAIL]") && !normal.contains("4242"),
              "send(): screen and question redacted by default")
        check(sent(reveal: true, question: "Don't redact").contains("4242 4242 4242 4242"), "send(): raw only when revealed")


        // Phase 2: speech-to-text request (fake key, nothing is sent)
        let wav = Recorder.wav(Data(count: 3200))
        check(wav.count == 3244 && String(data: wav.prefix(4), encoding: .ascii) == "RIFF"
              && abs(Recorder.duration(ofWAV: wav) - 0.1) < 0.001, "WAV header and duration")
        let stt = ElevenLabsSTT(apiKey: "test-key").makeRequest(wav: wav)
        let sttBody = String(decoding: stt.httpBody ?? Data(), as: UTF8.self)
        check(stt.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text" && stt.httpMethod == "POST",
              "STT: endpoint")
        check(stt.value(forHTTPHeaderField: "xi-api-key") == "test-key"
              && stt.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true,
              "STT: key header, multipart")
        check(sttBody.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n") && sttBody.contains("name=\"file\"; filename=\"q.wav\"")
              && sttBody.contains("name=\"tag_audio_events\"\r\n\r\nfalse"), "STT: model, file, no audio events")

        // Phase 2: text-to-speech request
        let tts = ElevenLabsTTS(apiKey: "test-key", voiceID: "voice1").makeRequest(text: "Hello.")
        check(tts.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice1/stream?output_format=pcm_24000",
              "TTS: streaming endpoint, raw PCM")
        check(body(tts)["model_id"] as? String == "eleven_flash_v2_5" && body(tts)["text"] as? String == "Hello."
              && tts.value(forHTTPHeaderField: "xi-api-key") == "test-key", "TTS: flash model, text, key header")

        // Phase 2: engine selection and fallback
        check(Voice.sttChain(elevenLabsKey: "k").map(\.name) == ["ElevenLabs", "on-device"], "STT: ElevenLabs first, Apple fallback")
        check(Voice.sttChain(elevenLabsKey: nil).map(\.name) == ["on-device"], "STT: no key → Apple only")
        check(Voice.tts(muted: false, elevenLabsKey: "k", voiceID: "v") is ElevenLabsTTS, "TTS: ElevenLabs when on")
        check(Voice.tts(muted: true, elevenLabsKey: "k", voiceID: "v") == nil
              && Voice.tts(muted: false, elevenLabsKey: nil, voiceID: "v") == nil, "TTS: off when muted or no key")
        func heard(_ chain: [SpeechToText]) -> String {
            let box = ResultBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                box.value = (try? await Voice.transcribe(wav: wav, with: chain)).map { "\($0.engine): \($0.text)" } ?? "error"
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
            return box.value
        }
        check(heard([FakeSTT(name: "cloud", result: nil), FakeSTT(name: "local", result: "hi")]) == "local: hi",
              "STT: falls back when the first engine fails")
        check(heard([FakeSTT(name: "cloud", result: " "), FakeSTT(name: "local", result: "hi")]) == "local: hi",
              "STT: falls back on an empty transcript")
        check(heard([FakeSTT(name: "cloud", result: "yes"), FakeSTT(name: "local", result: "hi")]) == "cloud: yes",
              "STT: uses the first engine when it works")
        check(heard([FakeSTT(name: "cloud", result: nil)]) == "error", "STT: error when every engine fails")

        // Phase 2: sentence splitting for streamed speech
        let split = Voice.sentences("Yes, 16 GB is enough. It costs €1,299.00 and\nhas 1.5 GB")
        check(split.done == ["Yes, 16 GB is enough.", "It costs €1,299.00 and"] && split.rest == "has 1.5 GB",
              "sentences: splits on end marks and newlines, not decimals")
        check(Voice.splitSpoken("Sa") == .pending && Voice.splitSpoken("Yes, it is.") == .plain, "spoken: waits for the Say: marker, else plain")
        check(Voice.splitSpoken("Say: Yes, 16 GB is") == .summary(say: "Yes, 16 GB is", done: false, shown: ""), "spoken: Say line streams")
        check(Voice.splitSpoken("**Say:** Yes.\n\nIt has **16 GB**.") == .summary(say: "Yes.", done: true, shown: "It has **16 GB**."),
              "spoken: Say line is spoken, the rest is shown")
        check(Voice.speakable("**16 GB** is `enough`") == "16 GB is enough", "speakable: markdown dropped")

        PipSprite.selfTest(check)
        PetGeometry.selfTest(check)
        PetBubbleView.selfTest(check)
        PetView.selfTest(check)
        // Phase 3: timeline (temp database)
        let dbPath = NSTemporaryDirectory() + "glance-selftest-\(getpid()).sqlite"
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + ext) } }
        let now = Date().timeIntervalSince1970
        do {
            let tl = try Timeline(path: dbPath)
            check(tl.version == Timeline.schemaVersion, "timeline: migrated to schema \(Timeline.schemaVersion)")
            let perms = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.posixPermissions] as? Int) ?? 0
            check(perms == 0o600, "timeline: database file is 0600")
            let thumb = MemoryRecorder.thumbnail(page(["Thumb"], width: 1440, height: 900))
            try tl.insert(ts: now - 600, app: "Safari", bundleID: "com.apple.Safari", title: "ThinkPad X1 Carbon",
                          url: "https://www.lenovo.com/ie/en/thinkpad", text: "ThinkPad X1 Carbon\n32GB memory\nBattery up to 15 hours\n€1,899", thumb: thumb)
            try tl.insert(ts: now - 400, app: "Safari", bundleID: "com.apple.Safari", title: "Zenbook 14",
                          url: "https://www.asus.com/ie/zenbook", text: "ASUS Zenbook 14 OLED\n16GB memory\nBattery 75Wh\n€1,099", thumb: thumb)
            try tl.insert(ts: now - 200, app: "Notes", bundleID: "com.apple.Notes", title: "Notes", url: nil,
                          text: "Laptop for college\nBudget: €1,200 max\nNeeds: 16GB RAM, light to carry, good battery for lectures.", thumb: thumb)
            try tl.insert(ts: now - 100, app: "Slack", bundleID: "com.tinyspeck.slackmacgap", title: "general", url: nil,
                          text: "lunch at 1?", thumb: thumb)
            check(try tl.count() == 4 && (try tl.count(matching: "\"battery\"")) == 3, "timeline: FTS5 insert and search")

            // Reopen: migrations don't rerun, rows survive.
            let tl2 = try Timeline(path: dbPath)
            check(try tl2.version == 1 && tl2.count() == 4, "timeline: reopening keeps rows and schema")

            let q = "How is this different from the earlier ones?"
            check(Timeline.terms(from: [q]).isEmpty, "memory terms: a vague question adds no search words")
            let selection = "MacBook Air 13-inch\n16GB unified memory\nUp to 18 hours battery life\n€1,199"
            let terms = Timeline.terms(from: [q, selection])
            let found = try tl.snippets(matching: terms, since: now - 900)
            check(Set(found.map(\.title)) == ["ThinkPad X1 Carbon", "Zenbook 14", "Notes"],
                  "memory: the question + selection finds both laptops and the budget note, not Slack")
            check(found.first { $0.app == "Notes" }?.text.contains("Budget: €1,200") == true
                  && found.first { $0.app == "Notes" }?.text.contains("16GB RAM") == true, "memory: a short note is kept whole (budget included)")
            check(Timeline.matchingLines((1...60).map { "line \($0) filler text" }.joined(separator: "\n") + "\nbattery 18h", terms: ["battery"])
                  == "battery 18h", "memory: a long page keeps only matching lines")
            let vague = try tl.snippets(matching: ["zzz"], since: now - 900, fillRecent: true)
            check(vague.count == 4, "memory: \"the earlier ones\" with no word matches falls back to recent windows")
            check(Timeline.refersToEarlier(q) && !Timeline.refersToEarlier("Is 16 GB enough?"), "memory: earlier-reference detection")
            check((try? tl.snippets(matching: ["a\"b", "c*", "NEAR(", "-x"], since: 0)) != nil, "memory: FTS query is escaped")
            check(try tl.snippets(matching: terms, since: now - 300).count == 1, "memory: only the retention window is searched")

            // A19: the demo gate with the real note and long spec pages. The budget line shares no word with the
            // specs, so it only survives because the short note is sent whole.
            let noteURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../demo/budget-note.txt")
            let note = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
            check(note.contains("Budget: €1,200 max"), "A19: read demo/budget-note.txt")
            let demoPath = dbPath + "-demo"
            defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: demoPath + ext) } }
            let demo = try Timeline(path: demoPath)
            let filler = (1...40).map { "Shop accessories, compare models and find support near you \($0)." }.joined(separator: "\n")
            try demo.insert(ts: now - 500, app: "Safari", bundleID: "com.apple.Safari", title: "ThinkPad X1 Carbon Gen 13 | Lenovo IE",
                            url: "https://www.lenovo.com/ie/en/c/laptops/thinkpad/thinkpadx1/",
                            text: "ThinkPad X1 Carbon Gen 13\n\(filler)\nMemory: up to 32GB LPDDR5x\nBattery: 57Wh, up to 15 hours\nWeight: from 0.99 kg\nFrom €1,849.00", thumb: nil)
            try demo.insert(ts: now - 400, app: "Safari", bundleID: "com.apple.Safari", title: "Zenbook | Laptops | ASUS Ireland",
                            url: "https://www.asus.com/ie/laptops/for-home/zenbook/",
                            text: "ASUS Zenbook 14 OLED\n\(filler)\n16GB LPDDR5X memory\n75Wh battery\n1.2 kg\n€1,099", thumb: nil)
            try demo.insert(ts: now - 300, app: "Notes", bundleID: "com.apple.Notes", title: "Notes", url: nil, text: note, thumb: nil)
            let gateSelection = "Chip\nApple M4 chip\nMemory\n16GB unified memory\nStorage\n256GB SSD\nBattery and Power\nUp to 18 hours Apple TV app movie playback\nWeight 1.24 kg"
            let gate = try demo.snippets(matching: Timeline.terms(from: [q, gateSelection]), since: now - 900,
                                         fillRecent: Timeline.refersToEarlier(q))
            check(gate.count == 3 && gate.contains { $0.app == "Notes" && $0.text.contains("Budget: €1,200 max") },
                  "A19: the gate question sends the note with its budget line, plus both laptops")
            check(gate.contains { $0.title?.hasPrefix("ThinkPad") == true && $0.text.contains("32GB") && !$0.text.contains("support near you 7.") },
                  "A19: long pages still send only their matching lines")

            try tl.trim(olderThan: now - 500)
            check(try tl.count() == 3 && (try tl.count(matching: "\"thinkpad\"")) == 0, "retention: old rows and FTS entries deleted")
            try tl.forget(since: now - 250)
            check(try tl.count() == 1 && (try tl.count(matching: "\"budget\"")) == 0 && (try tl.count(matching: "\"lunch\"")) == 0,
                  "forget: rows and FTS entries since the cut-off deleted")
            try tl.forget(since: 0)
            check(try tl.count() == 0, "forget: empty after forgetting everything")
        } catch {
            check(false, "timeline: \(error.localizedDescription)")
        }

        // Phase 3: exclusions before capture
        func skip(_ id: String?, title: String? = nil, url: String? = nil, priv: Bool? = false, secure: Bool = false) -> String? {
            Exclusions.memorySkipReason(.init(bundleID: id, title: title, url: url, isPrivate: priv, secureInput: secure))
        }
        check(skip("com.1password.1password") == "excluded app", "exclusion: password manager")
        check(skip("com.apple.keychainaccess") == "excluded app", "exclusion: Keychain Access")
        check(skip(Config.bundleID) == "Glance itself", "exclusion: Glance's own windows")
        check(skip("com.apple.Notes", secure: true) == "password field", "exclusion: secure field focused")
        check(skip("com.apple.Safari", url: "https://apple.com", secure: true) == "password field", "exclusion: secure field in a browser")
        check(skip("com.apple.Safari", url: "https://www.apple.com/ie/macbook-air/specs/") == nil, "allowed: normal product page")
        check(skip("com.apple.Notes", title: "Notes", priv: nil) == nil, "allowed: Notes (not a browser)")
        check(skip("com.apple.Safari", url: "https://apple.com", priv: nil) == "private window", "exclusion: browser window we can't read")
        check(skip("com.apple.Safari", title: "Online Banking", url: nil) == "blocked site"
              && skip("com.apple.Safari", title: "Home", url: nil) == "unknown page", "exclusion: browser page without a URL")
        check(skip("com.google.Chrome", url: "https://apple.com", priv: true) == "private window", "exclusion: incognito window")
        check(Exclusions.looksPrivate("Private Browsing") && Exclusions.looksPrivate("New Incognito Tab")
              && !Exclusions.looksPrivate("MacBook Air - Apple (IE)"), "private markers")
        for url in ["https://www.aib.ie/personal", "https://www.paypal.com/myaccount", "https://shop.com/checkout/step2",
                    "https://accounts.google.com/v3/signin", "file:///Users/x/glance/demo/mock-bank.html",
                    "https://www.revolut.com/app", "https://site.ie/login?next=/"] {
            check(skip("com.apple.Safari", url: url) == "blocked site", "URL blocklist: \(url)")
        }
        check(skip("com.apple.Safari", title: "Sign in – Google Accounts", url: "https://example.com") == "blocked site", "URL blocklist: by title")
        check(skip("com.apple.Safari", url: "https://www.asus.com/ie/laptops/for-home/zenbook/") == nil,
              "URL blocklist: no false hit on a laptop page")

        // Phase 3: change detection and thumbnails
        let pageA = page(["MacBook Air", "16 GB unified memory", "18-hour battery"], width: 1440, height: 900)
        let pageB = page(["ThinkPad X1 Carbon", "32 GB memory", "Intel Core Ultra 7", "€1,899"], width: 1440, height: 900)
        let sigA = MemoryRecorder.signature(pageA)
        check(!MemoryRecorder.changed(sigA, MemoryRecorder.signature(pageA)), "change detection: same frame is skipped")
        check(MemoryRecorder.changed(sigA, MemoryRecorder.signature(pageB)), "change detection: different page is stored")
        let scrolled = page(["16 GB unified memory", "18-hour battery", "512 GB SSD"], width: 1440, height: 900)
        check(MemoryRecorder.changed(sigA, MemoryRecorder.signature(scrolled)), "change detection: scrolled text is stored")
        let caret = page(["MacBook Air", "16 GB unified memory", "18-hour battery|"], width: 1440, height: 900)
        check(!MemoryRecorder.changed(sigA, MemoryRecorder.signature(caret)), "change detection: a caret blink is skipped")
        check(MemoryRecorder.changed([], sigA), "change detection: first frame is stored")
        let thumbData = MemoryRecorder.thumbnail(pageA) ?? Data()
        let thumbImg = NSBitmapImageRep(data: thumbData)
        check(thumbImg?.pixelsWide == Config.thumbnailMaxDimension && thumbData.count < 40_000,
              "thumbnail: \(thumbImg?.pixelsWide ?? 0) px wide, \(thumbData.count / 1024) kB (never full frames)")

        // Phase 3: memory snippets are redacted before they reach the packet, and stay redacted on reveal
        let secretSnippet = Timeline.Snippet(ts: now - 120, app: "Safari", title: "Order for Aoife Kelly",
                                             url: "https://shop.ie/orders", text: "Card 4242 4242 4242 4242\nmail aoife.k@example.ie\n16GB memory")
        let memPacket = packet.withMemory([secretSnippet], now: Date(timeIntervalSince1970: now))
        check(memPacket.memory.contains("[CARD]") && memPacket.memory.contains("[EMAIL]") && !memPacket.memory.contains("4242")
              && !memPacket.memory.contains("example.ie") && memPacket.memory.contains("16GB memory"),
              "memory: snippet redacted inside the packet  →  \(memPacket.memory.replacingOccurrences(of: "\n", with: " | "))")
        check(memPacket.memory.contains("[2 min ago]") && memPacket.redactions >= 2, "memory: age and redaction count")
        check(memPacket.firstMessage(content, question: "q", imagesAllowed: false).text.contains("[CARD]"),
              "memory: first message carries the redacted snippets")
        let memSent: String = {
            let recorder = RecordingProvider()
            let done = DispatchSemaphore(value: 0)
            MainActor.assumeIsolated {
                let stream = ContextPacket.send(memPacket, history: [], question: "Don't redact", reveal: true, announce: false,
                                                mode: .explain, provider: recorder) { _ in }
                Task.detached { for try await _ in stream {}; done.signal() }
            }
            _ = done.wait(timeout: .now() + 5)
            return recorder.lastText
        }()
        check(memSent.contains("[CARD]") && !memSent.contains("4242"), "memory: stays redacted even when the user reveals")
        check(ContextPacket(appName: "Safari", redacted: content, raw: content, redactions: 0).memory.isEmpty,
              "memory: nothing from the timeline unless a question adds it")

        // Phase 3: cost of one stored frame (signature + OCR + thumbnail), for the CPU estimate
        let bench = page((1...40).map { "Line \($0): 16 GB unified memory, 512 GB SSD, 18-hour battery, Wi-Fi 6E, €1,299" },
                         width: 1440, height: 900)
        let t0 = Date()
        _ = MemoryRecorder.signature(bench)
        let t1 = Date()
        let benchLines = (try? OCR.lines(in: bench)) ?? []
        let t2 = Date()
        _ = MemoryRecorder.thumbnail(bench)
        let t3 = Date()
        print(String(format: "      frame cost: signature %.1f ms, OCR %.0f ms (%d lines), thumbnail %.1f ms",
                     t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, benchLines.count, t3.timeIntervalSince(t2) * 1000))
        check(benchLines.count >= 30, "OCR reads a 1× (1440×900) frame")

        // Phase 2 hardening: ElevenLabs errors and voice choice
        let paid = VoiceError.elevenLabs(status: 402, body: Data(#"{"detail":{"type":"payment_required","code":"paid_plan_required","message":"Free users cannot use library voices via the API."}}"#.utf8))
        check(paid.isVoiceProblem && paid.localizedDescription.contains("paid_plan_required")
              && paid.localizedDescription.contains("library voices"), "TTS error: 402 library voice is a voice problem, reason shown")
        let credits = VoiceError.elevenLabs(status: 402, body: Data(#"{"detail":{"code":"insufficient_credits","message":"Not enough credits"}}"#.utf8))
        check(!credits.isVoiceProblem, "TTS error: out of credits is not fixed by another voice")
        check(VoiceError.elevenLabs(status: 401, body: Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8))
              .localizedDescription.contains("invalid_api_key") && !VoiceError.elevenLabs(status: 401, body: Data()).isVoiceProblem,
              "TTS error: legacy detail.status shape parsed; bad key is not a voice problem")
        check(VoiceError.elevenLabs(status: 404, body: Data("not json".utf8)).isVoiceProblem, "TTS error: unknown voice (404) is a voice problem")
        func voices(_ list: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: ["voices": list]) }
        let lib: [String: Any] = ["voice_id": "lib", "name": "Lib", "category": "professional"]
        let legacy: [String: Any] = ["voice_id": "old", "name": "Rachel", "category": "premade", "is_legacy": true]
        let mine: [String: Any] = ["voice_id": "mine", "name": "Mine", "category": "generated", "is_owner": true]
        let stock: [String: Any] = ["voice_id": "stock", "name": "Sarah", "category": "premade"]
        check(Voice.usableVoice(fromVoicesJSON: voices([lib, legacy, mine, stock]), excluding: "x")?.id == "stock", "voice pick: stock voice first")
        check(Voice.usableVoice(fromVoicesJSON: voices([lib, legacy, mine]), excluding: "x")?.id == "mine", "voice pick: own voice when no stock voice")
        check(Voice.usableVoice(fromVoicesJSON: voices([lib, legacy]), excluding: "x") == nil
              && Voice.usableVoice(fromVoicesJSON: voices([stock]), excluding: "stock") == nil, "voice pick: never library, legacy or the refused voice")

        check(Voice.splitSpoken("**Say:**\nYes, it is.\n\nMore.") == .summary(say: "Yes, it is.", done: true, shown: "More.")
              && Voice.splitSpoken("_Say:_ Yes.\nMore.") == .summary(say: "Yes.", done: true, shown: "More."), "spoken: marker on its own line or wrapped in markdown")
        check(Voice.speakable("> 8 GB beats C# here") == "8 GB beats C# here", "speakable: # and > kept mid-text")
        check(PanelController.isTap(pressed: 10, released: 10.29) && !PanelController.isTap(pressed: 10, released: 10.31), "hotkey: tap vs hold by event time")

        // Phase 2 hardening: Speaker (fake speech, runs on the main run loop)
        func spoken(_ drive: @MainActor (Speaker, FakeTTS) -> Void) -> [String] {
            MainActor.assumeIsolated {
                let speaker = Speaker(), tts = FakeTTS()
                drive(speaker, tts)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                return tts.spoken
            }
        }
        check(spoken { s, t in s.begin(t); _ = s.answer("Say: No, it isn't.\n\nThe full answer is longer.", final: true) } == ["No, it isn't."],
              "speaker: only the Say line is spoken")
        let long = String(repeating: "word ", count: 70) + "end."
        check(spoken { s, t in s.begin(t); _ = s.answer("No. \(long) Fine.", final: true) } == ["No."],
              "speaker: a sentence that doesn't fit ends speech (no out-of-order summary)")
        check(spoken { s, t in
            t.delay = 0.1
            s.begin(t); _ = s.answer("Say: First answer.\n", final: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02)) // first worker is mid-speech
            s.begin(t); _ = s.answer("Say: Second answer.\n", final: true)
        }.last == "Second answer.", "speaker: a cancelled worker doesn't silence the next answer")

        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

/// A white page with one line of black text per entry.
private func page(_ lines: [String], width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, line) in lines.enumerated() {
        NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 20, y: height - 30 - i * 21))
    }
    NSGraphicsContext.current = nil
    return ctx.makeImage()!
}

private final class ResultBox: @unchecked Sendable { var value = "" }

/// Speech-to-text that returns `result`, or throws when it is nil.
private struct FakeSTT: SpeechToText {
    let name: String
    let result: String?
    func transcribe(wav: Data) async throws -> String {
        guard let result else { throw URLError(.notConnectedToInternet) }
        return result
    }
}

/// Captures what send() would transmit, without any network.
private final class RecordingProvider: AIProvider, @unchecked Sendable {
    var lastText = ""
    var name: String { "Test" }
    var supportsImages: Bool { false }
    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest {
        lastText = messages.map(\.text).joined(separator: "\n")
        throw CancellationError()
    }
    func textDelta(fromEvent payload: String) throws -> String? { nil }
}

/// Records what would be spoken; `delay` simulates a slow stream that honours cancellation.
private final class FakeTTS: TextToSpeech, @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [String] = []
    var delay: Double = 0
    var spoken: [String] { lock.lock(); defer { lock.unlock() }; return _spoken }
    func speak(_ text: String, firstAudio: @escaping @Sendable () -> Void) async throws {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        record(text)
        firstAudio()
    }
    private func record(_ text: String) { lock.lock(); _spoken.append(text); lock.unlock() }
    func stop() {}
}
