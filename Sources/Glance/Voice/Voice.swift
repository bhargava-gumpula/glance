import Foundation
import Speech

/// Voice audio goes to ElevenLabs (or stays on the Mac). Screen content never goes through here:
/// only `ContextPacket.send()` sends that.
protocol SpeechToText: Sendable {
    var name: String { get }
    func transcribe(wav: Data) async throws -> String
}

protocol TextToSpeech: Sendable {
    /// Speaks one sentence. Returns once its audio is queued; `firstAudio` fires when the first sound is queued.
    func speak(_ text: String, firstAudio: @escaping @Sendable () -> Void) async throws
    func stop()
}

enum VoiceError: LocalizedError {
    case noMicrophone, http(Int), noSpeechRecognizer, notAuthorized, nothingHeard

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "Glance can't use the microphone. Check Permissions…"
        case .http(let status): "ElevenLabs returned HTTP \(status)."
        case .noSpeechRecognizer: "On-device speech recognition isn't available on this Mac."
        case .notAuthorized: "Allow Speech Recognition for Glance in System Settings › Privacy & Security."
        case .nothingHeard: "Didn't catch that. Hold \(Config.hotkeyDescription) and speak."
        }
    }
}

enum Voice {
    static let elevenLabsAccount = "elevenlabs"

    /// ElevenLabs first when there's a key, then Apple on-device.
    @MainActor
    static func sttChain() -> [SpeechToText] {
        sttChain(elevenLabsKey: Keychain.get(elevenLabsAccount))
    }

    static func sttChain(elevenLabsKey: String?) -> [SpeechToText] {
        guard let key = elevenLabsKey, !key.isEmpty else { return [AppleSTT()] }
        return [ElevenLabsSTT(apiKey: key), AppleSTT()]
    }

    /// Tries each engine in order; any failure (offline, timeout, HTTP error) moves to the next.
    static func transcribe(wav: Data, with chain: [SpeechToText]) async throws -> (text: String, engine: String) {
        var lastError: Error = VoiceError.nothingHeard
        for stt in chain {
            do {
                let text = try await stt.transcribe(wav: wav).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return (text, stt.name) }
                lastError = VoiceError.nothingHeard
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// ElevenLabs when speaking is on and there's a key; otherwise answers stay text-only.
    @MainActor
    static func tts(muted: Bool) -> TextToSpeech? {
        tts(muted: muted, elevenLabsKey: Keychain.get(elevenLabsAccount), voiceID: Config.elevenLabsVoiceID)
    }

    static func tts(muted: Bool, elevenLabsKey: String?, voiceID: String) -> TextToSpeech? {
        guard !muted, let key = elevenLabsKey, !key.isEmpty else { return nil }
        return ElevenLabsTTS(apiKey: key, voiceID: voiceID)
    }

    /// Splits off complete sentences (end mark followed by whitespace, or a newline); returns them and the rest.
    static func sentences(_ text: String) -> (done: [String], rest: String) {
        var done: [String] = []
        var current = ""
        var prev: Character?
        for ch in text {
            if ch.isNewline || (ch.isWhitespace && [".", "!", "?", ":"].contains(prev)) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { done.append(s) }
                current = ""
            } else {
                current.append(ch)
            }
            prev = ch
        }
        return (done, current)
    }

    enum SpokenSplit: Equatable {
        /// Too short to tell whether it opens with "Say:".
        case pending
        /// No "Say:" line: the answer itself is spoken and shown.
        case plain
        /// `say` is spoken; `shown` (the rest) is displayed. `done` once the "Say:" line has ended.
        case summary(say: String, done: Bool, shown: String)
    }

    /// Splits an answer that opens with "Say: <short spoken version>" on its own line from the full answer.
    static func splitSpoken(_ raw: String) -> SpokenSplit {
        let marker = "say:"
        let t = raw.drop { $0.isWhitespace || $0 == "*" }
        if t.count < marker.count { return marker.hasPrefix(t.lowercased()) ? .pending : .plain }
        guard t.prefix(marker.count).lowercased() == marker else { return .plain }
        let rest = t.dropFirst(marker.count).drop { $0 == " " || $0 == "*" }
        guard let nl = rest.firstIndex(where: \.isNewline) else { return .summary(say: String(rest), done: false, shown: "") }
        return .summary(say: String(rest[..<nl]), done: true, shown: rest[nl...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Drops markdown marks so they aren't read aloud.
    static func speakable(_ s: String) -> String {
        s.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[-•]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: ElevenLabs

private let elevenLabsSession: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = Config.sttTimeoutSeconds
    return URLSession(configuration: c)
}()

struct ElevenLabsSTT: SpeechToText {
    let apiKey: String
    var name: String { "ElevenLabs" }

    func makeRequest(wav: Data) -> URLRequest {
        let boundary = "glance-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = Config.sttTimeoutSeconds
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", Config.elevenLabsSTTModel)
        field("language_code", "en")
        field("tag_audio_events", "false")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"q.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        return req
    }

    func transcribe(wav: Data) async throws -> String {
        let (data, resp) = try await elevenLabsSession.data(for: makeRequest(wav: wav))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceError.http(status) }
        struct R: Decodable { let text: String }
        return try JSONDecoder().decode(R.self, from: data).text
    }
}

struct ElevenLabsTTS: TextToSpeech {
    let apiKey: String
    let voiceID: String

    func makeRequest(text: String) -> URLRequest {
        let voice = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceID
        var req = URLRequest(url: URL(string:
            "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream?output_format=pcm_24000")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": Config.elevenLabsTTSModel])
        return req
    }

    func speak(_ text: String, firstAudio: @escaping @Sendable () -> Void) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(for: makeRequest(text: text))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceError.http(status) }
        let player = PCMPlayer.shared
        var chunk = Data()
        var first = true
        // 2400 bytes = 50 ms; the first chunk goes out as soon as it arrives.
        for try await b in bytes {
            try Task.checkCancellation()
            chunk.append(b)
            if chunk.count >= 2400 {
                player.enqueue(chunk)
                chunk.removeAll(keepingCapacity: true)
                if first { first = false; firstAudio() }
            }
        }
        if chunk.count >= 2 { player.enqueue(chunk.prefix(chunk.count & ~1)); if first { firstAudio() } }
    }

    func stop() { PCMPlayer.shared.stop() }
}

// MARK: Apple on-device

struct AppleSTT: SpeechToText {
    var name: String { "on-device" }

    func transcribe(wav: Data) async throws -> String {
        let status = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw VoiceError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable
        else { throw VoiceError.noSpeechRecognizer }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.shouldReportPartialResults = false

        let once = Once()
        return try await withCheckedThrowingContinuation { c in
            recognizer.recognitionTask(with: req) { res, err in
                if let res, res.isFinal {
                    if once.first() { c.resume(returning: res.bestTranscription.formattedString) }
                } else if let err {
                    if once.first() { c.resume(throwing: err) }
                }
            }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

// MARK: Speaker

/// Reads a short version of a streamed answer aloud, sentence by sentence, starting with the first full sentence.
@MainActor
final class Speaker {
    private var tts: TextToSpeech?
    private var pending = ""
    private var queue: [String] = []
    private var budget = 0
    private var worker: Task<Void, Never>?
    private var onFirstAudio: (@Sendable () -> Void)?

    func begin(_ tts: TextToSpeech?, onFirstAudio: (@Sendable () -> Void)? = nil) {
        stop()
        self.tts = tts
        self.onFirstAudio = onFirstAudio
        budget = Config.spokenCharLimit
        fed = 0
        finished = false
    }

    private var fed = 0
    private var finished = false

    /// Takes the whole answer so far; speaks its "Say:" line (or, without one, the start of the answer)
    /// and returns the text to show on screen.
    func answer(_ raw: String, final: Bool = false) -> String {
        var shown = raw
        var speak = raw
        var done = final
        switch Voice.splitSpoken(raw) {
        case .pending where !final:
            return ""
        case .summary(let say, let sayDone, let rest):
            speak = say
            done = sayDone || final
            shown = final && rest.isEmpty ? say : rest
        default:
            break
        }
        if !finished {
            if speak.count > fed { feed(String(speak.dropFirst(fed))); fed = speak.count }
            if done { finish(); finished = true }
        }
        return shown
    }

    func feed(_ delta: String) {
        guard tts != nil else { return }
        pending += delta
        let (done, rest) = Voice.sentences(pending)
        pending = rest
        done.forEach(enqueue)
    }

    func finish() {
        enqueue(pending)
        pending = ""
    }

    func stop() {
        worker?.cancel()
        worker = nil
        queue = []
        pending = ""
        tts?.stop()
        tts = nil
    }

    private func enqueue(_ sentence: String) {
        let s = Voice.speakable(sentence)
        // Always the first sentence; later ones only while they fit the short-answer budget.
        guard tts != nil, !s.isEmpty, budget > 0, s.count <= budget || budget == Config.spokenCharLimit else { return }
        budget -= s.count
        queue.append(s)
        if worker == nil { work() }
    }

    private func work() {
        guard let tts else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let s = self.queue.removeFirst()
                let fire = self.onFirstAudio
                self.onFirstAudio = nil
                do {
                    try await tts.speak(s) { fire?() }
                } catch {
                    // Speech failed: stay silent, the answer is still shown as text.
                    if !Task.isCancelled { log.error("voice: text-to-speech failed (\(error.localizedDescription, privacy: .public)); text only") }
                    self.queue = []
                    self.budget = 0
                }
            }
            if !Task.isCancelled { self?.worker = nil }
        }
    }
}
