import Foundation

/// `Glance --selftest`: assert-style checks, non-zero exit on failure.
/// Each phase adds its checks here.
enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }

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

        let packet = ContextPacket(appName: "Safari", selectionImage: img, screenImage: img,
                                   selectedText: "M4 chip", screenText: "M4 chip\nAdd to bag", redactions: 0)
        check(packet.firstMessage(question: "q", imagesAllowed: false).images.isEmpty
              && packet.firstMessage(question: "q", imagesAllowed: false).text.contains("Add to bag"),
              "text-only packet carries screen OCR instead of images")
        check(packet.firstMessage(question: "q", imagesAllowed: true).images.count == 2, "vision packet carries 2 images")

        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
