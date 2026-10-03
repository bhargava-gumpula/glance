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
    /// ElevenLabs voice for spoken answers. Settings override.
    static var elevenLabsVoiceID: String { value("elevenLabsVoiceID", default: defaultElevenLabsVoiceID) }
    /// "Sarah", a stock voice. If the account can't use it through the API, `VoicePicker` switches to one it can.
    static let defaultElevenLabsVoiceID = "EXAVITQu4vr4xnSDxMaL"
    static let ttsTimeoutSeconds: Double = 10
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

extension Config {
    /// Audit A11: an API key is only sent to the host it was saved for. Returns the problem, or nil when fine.
    /// `savedFor` is nil for keys saved before this check existed; those adopt the current host.
    static func keyHostMismatch(savedFor: String?, baseURL: String) -> String? {
        guard let savedFor, let host = URL(string: baseURL)?.host, host != savedFor else { return nil }
        return "This API key was saved for \(savedFor), but the address now points to \(host). Re-enter the key in Settings to use it there."
    }

    /// Audit A12: the Address field must be an http(s) URL with a host (a pasted key is neither).
    static func validBaseURL(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && !(url.host ?? "").isEmpty
    }

    /// ElevenLabs voice IDs are short and alphanumeric; a key pasted there would be sent in the URL path.
    static func validVoiceID(_ s: String) -> Bool {
        !s.hasPrefix("sk_") && (1...32).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
