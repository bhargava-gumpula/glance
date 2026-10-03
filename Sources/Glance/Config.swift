import Foundation
import os

/// Every tunable default lives here. Settings overrides are stored in UserDefaults under the same key.
/// See DECISIONS.md for which open decision each value belongs to.
enum Config {
    static let bundleID = "ie.dublinhacx.glance"

    /// Global hotkey: Option + Space (Carbon key code 49 = space).
    static let hotkeyKeyCode: UInt32 = 49
    static let hotkeyDescription = "⌥Space"

    static var captureIntervalSeconds: Double { value("captureIntervalSeconds", default: 3) }
    static var retentionMinutes: Int { value("retentionMinutes", default: 15) }
    static var provider: String { value("provider", default: "claude") }
    static var ttsEnabled: Bool { value("ttsEnabled", default: true) }

    // MARK: Voice (Phase 2)

    /// Holding the hotkey longer than this means talk; a shorter tap toggles the panel.
    static let holdToTalkSeconds = 0.3
    /// ElevenLabs voice for spoken answers (default: the premade "Rachel"). Settings override.
    static var elevenLabsVoiceID: String { value("elevenLabsVoiceID", default: "21m00Tcm4TlvDq8ikWAM") }
    static let elevenLabsSTTModel = "scribe_v2"
    static let elevenLabsTTSModel = "eleven_flash_v2_5"
    /// After this, speech-to-text falls back to Apple on-device.
    static let sttTimeoutSeconds: Double = 6
    /// Spoken answers are short: the first sentence, plus more while they fit this many characters.
    static let spokenCharLimit = 280

    /// Apps that are never captured (bundle IDs).
    static var excludedApps: [String] {
        value("excludedApps", default: [
            "com.apple.keychainaccess",
            "com.apple.systempreferences",
            "com.apple.Passwords",
            "com.1password.1password",
            "com.bitwarden.desktop",
        ])
    }

    // MARK: Memory (Phase 3)

    /// "Forget" in the menu deletes this many minutes back.
    static let forgetMinutes = 15
    /// Longest side of the stored thumbnail. Full frames are never stored.
    static let thumbnailMaxDimension = 320
    /// A frame counts as changed when more than this share of cells in a 128×72 grey copy changed by more than
    /// 6 grey levels. A blinking caret touches 1–2 cells (0.02 %); scrolling or a new page touches hundreds.
    static let frameChangeFraction = 0.003
    /// At most this many earlier windows, and characters per window, go into a question.
    static let memorySnippetLimit = 6
    static let memorySnippetChars = 700
    /// Browsers: private-window and URL checks apply to these.
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    /// Pages whose URL or window title contains any of these are never stored.
    static var blockedURLKeywords: [String] {
        value("blockedURLKeywords", default: [
            "bank", "aib.ie", "boi.com", "ptsb.ie", "revolut.com", "n26.com", "monzo.com", "creditunion",
            "paypal.", "stripe.com", "klarna.", "checkout", "payment", "/pay/", "billing", "wallet",
            "login", "log-in", "signin", "sign-in", "sign in", "log in", "signup", "password", "2fa", "mfa",
            "accounts.google.com", "appleid.apple.com", "account.apple.com", "login.microsoftonline.com",
            "revenue.ie", "mygovid", "welfare.ie",
        ])
    }
    /// Window or toolbar text that marks a private window.
    static let privateWindowMarkers = ["private browsing", "incognito", "inprivate", "private window"]

    // MARK: AI providers

    struct ProviderPreset: Sendable {
        enum Kind: Sendable { case anthropic, openAICompat }
        let id: String
        let name: String
        let kind: Kind
        let baseURL: String
        let model: String
        let supportsImages: Bool
        let needsKey: Bool
    }

    static let providerPresets: [ProviderPreset] = [
        .init(id: "claude", name: "Claude", kind: .anthropic,
              baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", supportsImages: true, needsKey: true),
        // deepseek-chat is text-only, so it gets the OCR text of the screen instead of images.
        .init(id: "deepseek", name: "DeepSeek", kind: .openAICompat,
              baseURL: "https://api.deepseek.com", model: "deepseek-chat", supportsImages: false, needsKey: true),
        .init(id: "openai", name: "OpenAI", kind: .openAICompat,
              baseURL: "https://api.openai.com/v1", model: "gpt-5", supportsImages: true, needsKey: true),
        // Ollama's OpenAI-compatible endpoint. LM Studio: http://localhost:1234/v1
        .init(id: "local", name: "Local (Ollama / LM Studio)", kind: .openAICompat,
              baseURL: "http://localhost:11434/v1", model: "qwen2.5vl", supportsImages: true, needsKey: false),
    ]

    static func preset(_ id: String) -> ProviderPreset {
        providerPresets.first { $0.id == id } ?? providerPresets[0]
    }
    static func model(for id: String) -> String { value("model.\(id)", default: preset(id).model) }
    static func baseURL(for id: String) -> String { normalizedBaseURL(value("baseURL.\(id)", default: preset(id).baseURL)) }

    /// Accepts a pasted full endpoint: keeps the first line, drops a trailing slash and endpoint path.
    static func normalizedBaseURL(_ raw: String) -> String {
        var url = raw.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        for suffix in ["/", "/chat/completions", "/v1/messages", "/"] where url.hasSuffix(suffix) {
            url.removeLast(suffix.count)
        }
        return url
    }
    static func supportsImages(for id: String) -> Bool { value("supportsImages.\(id)", default: preset(id).supportsImages) }

    /// Claude effort. "low" keeps the panel snappy; raise for harder questions.
    static var claudeEffort: String { value("claudeEffort", default: "low") }
    static let maxOutputTokens = 16000
    /// Longest side of images sent to a provider, in pixels.
    static let maxImageDimension = 1568

    private static func value<T>(_ key: String, default fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }
}

/// Timing and fallback notes, readable with `log stream --predicate 'subsystem == "ie.dublinhacx.glance"'`.
/// Never log keys, transcripts or screen text here.
let log = Logger(subsystem: Config.bundleID, category: "glance")
