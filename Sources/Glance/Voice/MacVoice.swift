import AVFoundation

/// On-device speech (AVSpeechSynthesizer) with the best installed English voice. Used when ElevenLabs can't speak.
final class MacTTS: TextToSpeech, @unchecked Sendable {
    static let shared = MacTTS()
    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    private init() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let preferred = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        voice = voices.compactMap { v in
            Self.rank(language: v.language, quality: v.quality.rawValue,
                      novelty: v.voiceTraits.contains(.isNoveltyVoice), preferred: preferred).map { ($0, v) }
        }.max { $0.0 < $1.0 }?.1
        log.notice("voice: Mac voice is \(self.voice?.name ?? "system default", privacy: .public)")
    }

    /// Higher is better: English only, no novelty voices; premium > enhanced > default, then the user's region.
    static func rank(language: String, quality: Int, novelty: Bool, preferred: String) -> Int? {
        guard language.hasPrefix("en"), !novelty else { return nil }
        return quality * 10 + (language == preferred ? 1 : 0)
    }

    func speak(_ text: String, firstAudio: @escaping @Sendable () -> Void) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // The synthesizer queues utterances itself, so returning here keeps sentences in order.
        await MainActor.run { synth.speak(utterance) }
        firstAudio()
    }

    func stop() {
        DispatchQueue.main.async { [synth] in synth.stopSpeaking(at: .immediate) }
    }
}

/// ElevenLabs first; on any failure the sentence is spoken by the Mac voice, so answers are always heard.
/// After a refusal that won't fix itself (no usable voice, bad key, no credits) the rest of the launch uses the Mac voice.
struct FallbackTTS: TextToSpeech {
    let primary: TextToSpeech?
    let fallback: TextToSpeech
    /// Called when the Mac voice takes over, with the reason.
    let onFallback: @Sendable (String) -> Void

    private static let sticky = StickyFlag()

    func speak(_ text: String, firstAudio: @escaping @Sendable () -> Void) async throws {
        if let primary, !Self.sticky.isSet {
            do { return try await primary.speak(text, firstAudio: firstAudio) } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
                log.error("voice: ElevenLabs couldn't speak (\(error.localizedDescription, privacy: .public)); using the Mac voice")
                if !(error is URLError) { Self.sticky.set() } // network errors may pass; retry ElevenLabs next sentence
                onFallback(error.localizedDescription)
            }
        } else if primary == nil {
            onFallback("no ElevenLabs key")
        }
        try await fallback.speak(text, firstAudio: firstAudio)
    }

    func stop() {
        primary?.stop()
        fallback.stop()
    }
}

private final class StickyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
