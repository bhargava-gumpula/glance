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
    case noMicrophone, noSpeechRecognizer, notAuthorized, nothingHeard
    case allEnginesFailed([String])
    case noUsableVoice
    case elevenLabs(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "Glance can't use the microphone. Check Permissions…"
        case .allEnginesFailed(let errors): errors.joined(separator: " ")
        case .noUsableVoice: "No ElevenLabs voice on this account can be used through the API."
        case .noSpeechRecognizer: "On-device speech recognition isn't available on this Mac."
        case .notAuthorized: "Allow Speech Recognition for Glance in System Settings › Privacy & Security."
        case .nothingHeard: "Didn't catch that. Hold \(Config.hotkeyDescription) and speak."
        case .elevenLabs(let status, let code, let message):
            "ElevenLabs couldn't speak (HTTP \(status)\(code.isEmpty ? "" : ", \(code)")). \(message)"
        }
    }

    /// Builds the error from an ElevenLabs error body: {"detail": {"code"|"status", "message"}} or {"detail": "…"}.
    static func elevenLabs(status: Int, body: Data) -> VoiceError {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["detail"]
        if let d = detail as? [String: Any] {
            let code = (d["code"] as? String) ?? (d["status"] as? String) ?? ""
            return .elevenLabs(status: status, code: code, message: String((d["message"] as? String ?? "").prefix(200)))
        }
        return .elevenLabs(status: status, code: "", message: String((detail as? String ?? "").prefix(200)))
    }

    /// The voice itself is refused (not the key or credits), so another voice may work.
    var isVoiceProblem: Bool {
        guard case .elevenLabs(let status, let code, _) = self else { return false }
        if ["paid_plan_required", "voice_not_found", "voice_access_denied"].contains(code) { return true }
        return (status == 402 && code != "insufficient_credits" && code != "quota_exceeded") || status == 404
    }
}

enum Voice {
    static let elevenLabsAccount = "elevenlabs"

    /// ElevenLabs first when there's a key, then Apple on-device.
    @MainActor
    static func sttChain() -> [SpeechToText] {
        Config.localOnly ? [AppleSTT()] : sttChain(elevenLabsKey: Keychain.get(elevenLabsAccount))
    }

    static func sttChain(elevenLabsKey: String?) -> [SpeechToText] {
        guard let key = elevenLabsKey, !key.isEmpty else { return [AppleSTT()] }
        return [ElevenLabsSTT(apiKey: key), AppleSTT()]
    }

    /// Tries each engine in order; any failure (offline, timeout, HTTP error) moves to the next.
    static func transcribe(wav: Data, with chain: [SpeechToText]) async throws -> (text: String, engine: String) {
        var errors: [String] = []
        for stt in chain {
            do {
                let text = try await stt.transcribe(wav: wav).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return (text, stt.name) }
                errors.append("\(stt.name): \(VoiceError.nothingHeard.localizedDescription)")
            } catch {
                // Log every engine's failure (never the audio or a transcript) so a fallback is explainable.
                log.error("voice: \(stt.name, privacy: .public) speech-to-text failed (\(error.localizedDescription, privacy: .public))")
                errors.append("\(stt.name): \(error.localizedDescription)")
            }
        }
        throw VoiceError.allEnginesFailed(errors)
    }

    /// Nil when muted. Otherwise ElevenLabs (with a key) backed by the Mac voice, so answers are always spoken.
    @MainActor
    static func tts(muted: Bool, onFallback: @escaping @Sendable (String) -> Void) -> TextToSpeech? {
        tts(muted: muted, elevenLabsKey: Config.localOnly ? nil : Keychain.get(elevenLabsAccount), voiceID: Config.elevenLabsVoiceID,
            fallback: MacTTS.shared, onFallback: onFallback)
    }

    static func tts(muted: Bool, elevenLabsKey: String?, voiceID: String, fallback: TextToSpeech,
                    onFallback: @escaping @Sendable (String) -> Void = { _ in }) -> TextToSpeech? {
        guard !muted else { return nil }
        let primary = elevenLabsKey.flatMap { $0.isEmpty ? nil : ElevenLabsTTS(apiKey: $0, voiceID: voiceID) }
        return FallbackTTS(primary: primary, fallback: fallback, onFallback: onFallback)
    }

    /// From a GET /v2/voices response: a voice the account can use through the API. Prefers stock (premade)
    /// voices, then the account's own generated or cloned ones; never retired (legacy) or Voice Library voices.
    static func usableVoice(fromVoicesJSON data: Data, excluding: String) -> (id: String, name: String)? {
        usableVoices(fromVoicesJSON: data, excluding: excluding).first
    }

    /// All usable voices, best first.
    static func usableVoices(fromVoicesJSON data: Data, excluding: String) -> [(id: String, name: String)] {
        func rank(_ v: [String: Any]) -> Int? {
            guard v["is_legacy"] as? Bool != true, let id = v["voice_id"] as? String, id != excluding else { return nil }
            switch v["category"] as? String {
            case "premade": return 0
            case "generated", "cloned": return v["is_owner"] as? Bool == false ? nil : 1
            default: return nil
            }
        }
        return voiceList(data).compactMap { v in rank(v).map { ($0, v) } }.sorted { $0.0 < $1.0 }
            .map { ($0.1["voice_id"] as? String ?? "", $0.1["name"] as? String ?? "") }
    }

    /// "12 voices: premade 0, professional 9, generated 1, legacy 2" for the log (no names, no keys).
    static func voiceSummary(_ data: Data) -> String {
        let voices = voiceList(data)
        var counts: [String: Int] = [:]
        for v in voices { counts[v["category"] as? String ?? "?", default: 0] += 1 }
        let legacy = voices.filter { $0["is_legacy"] as? Bool == true }.count
        let parts = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" } + ["legacy \(legacy)"]
        return "\(voices.count) voices: " + parts.joined(separator: ", ")
    }

    private static func voiceList(_ data: Data) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["voices"] as? [[String: Any]] ?? []
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
        // Markdown around the marker ("**Say:**", "_Say:_", "> Say:", "# Say:", "`Say:`") is ignored.
        let wrap: Set<Character> = ["*", "_", ">", "#", "`"]
        let t = raw.drop { $0.isWhitespace || wrap.contains($0) }
        if t.count < marker.count { return marker.hasPrefix(t.lowercased()) ? .pending : .plain }
        guard t.prefix(marker.count).lowercased() == marker else { return .plain }
        // The spoken line may also start on the next line ("**Say:**\nYes, …").
        let rest = t.dropFirst(marker.count).drop { $0.isWhitespace || wrap.contains($0) }
        guard let nl = rest.firstIndex(where: \.isNewline) else {
            // Some models (grok-4.6) keep the whole answer on the "Say:" line: the spoken part ends at its 2nd sentence.
            var ends = 0
            var i = rest.startIndex
            while i < rest.endIndex {
                let next = rest.index(after: i)
                if ".!?".contains(rest[i]), next < rest.endIndex, rest[next].isWhitespace {
                    ends += 1
                    if ends == 2 {
                        return .summary(say: String(rest[...i]), done: true, shown: rest[next...].trimmingCharacters(in: .whitespaces))
                    }
                }
                i = next
            }
            return .summary(say: String(rest), done: false, shown: "")
        }
        return .summary(say: String(rest[..<nl]), done: true, shown: rest[nl...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Drops markdown marks so they aren't read aloud.
    static func speakable(_ s: String) -> String {
        s.replacingOccurrences(of: #"[*_`]+"#, with: "", options: .regularExpression)
            // Headings and quotes only at the start, so "C#" and "> 8 GB" are read as written.
            .replacingOccurrences(of: #"^\s*(#+|>)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[-•]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: ElevenLabs

private let elevenLabsSession: Network.Session = {
    let c = Network.Configuration.default
    c.timeoutIntervalForRequest = Config.sttTimeoutSeconds
    // Total deadline as well (the request timeout only limits idle time between packets).
    c.timeoutIntervalForResource = Config.sttTimeoutSeconds * 2
    return Network.session(c)
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
        let (data, resp) = try await Network.data(for: makeRequest(wav: wav), session: elevenLabsSession, delegate: STTTimings(audioBytes: wav.count))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceError.elevenLabs(status: status, body: data.prefix(2048)) }
        struct R: Decodable { let text: String }
        return try JSONDecoder().decode(R.self, from: data).text
    }
}

struct ElevenLabsTTS: TextToSpeech {
    let apiKey: String
    let voiceID: String

    func makeRequest(text: String, voice voiceID: String? = nil) -> URLRequest {
        let id = voiceID ?? self.voiceID
        let voice = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var req = URLRequest(url: URL(string:
            "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream?output_format=pcm_24000")!)
        req.httpMethod = "POST"
        req.timeoutInterval = Config.ttsTimeoutSeconds
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": Config.elevenLabsTTSModel])
        return req
    }

    func speak(_ text: String, firstAudio: @escaping @Sendable () -> Void) async throws {
        let picker = VoicePicker.shared
        if await picker.isExhausted(voiceID) { throw VoiceError.noUsableVoice }
        var voice = await picker.voice(for: voiceID)
        var (bytes, status) = try await open(text, voice: voice)
        if status != 200 {
            let error = await VoiceError.elevenLabs(status: status, body: Self.readBody(bytes))
            // The voice isn't usable with this account (e.g. a library or retired voice on the free plan):
            // try voices the account can use, once per launch, and keep the first that works.
            guard error.isVoiceProblem else { throw error }
            var found = false
            for candidate in await picker.candidates(excluding: voice, apiKey: apiKey) {
                (bytes, status) = try await open(text, voice: candidate)
                if status == 200 { voice = candidate; found = true; break }
                let next = await VoiceError.elevenLabs(status: status, body: Self.readBody(bytes))
                log.notice("voice: candidate \(candidate, privacy: .public) refused (\(next.localizedDescription, privacy: .public))")
                guard next.isVoiceProblem else { throw next }
            }
            guard found else { await picker.markExhausted(voiceID); throw error }
            await picker.remember(voiceID, works: voice)
        }
        let player = PCMPlayer.shared
        let generation = player.generation
        var chunk = Data()
        var first = true
        // 2400 bytes = 50 ms; the first chunk goes out as soon as it arrives.
        for try await b in bytes {
            try Task.checkCancellation()
            chunk.append(b)
            if chunk.count >= 2400 {
                player.enqueue(chunk, generation: generation)
                chunk.removeAll(keepingCapacity: true)
                if first { first = false; firstAudio() }
            }
        }
        if chunk.count >= 2 { player.enqueue(chunk.prefix(chunk.count & ~1), generation: generation); if first { firstAudio() } }
    }

    private func open(_ text: String, voice: String) async throws -> (Network.Bytes, Int) {
        let (bytes, resp) = try await Network.bytes(for: makeRequest(text: text, voice: voice))
        return (bytes, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The first 2 KB of an error response (ElevenLabs puts the reason in `detail`).
    private static func readBody(_ bytes: Network.Bytes) async -> Data {
        var body = Data()
        do { for try await b in bytes { body.append(b); if body.count >= 2048 { break } } } catch {}
        return body
    }

    func stop() { PCMPlayer.shared.stop() }
}

/// Finds an ElevenLabs voice the account can use through the API, when the configured one is refused.
/// Free accounts can't use Voice Library voices via the API, and retired voices like "Rachel" route to library ones.
actor VoicePicker {
    static let shared = VoicePicker()
    /// ElevenLabs stock voices (Sarah, George, Will, Roger, Laura, Jessica), tried when the voice list can't be read.
    static let stockVoiceIDs = ["EXAVITQu4vr4xnSDxMaL", "JBFqnCBsd6RMkjVDRZzb", "bIHbv24MWmeRgasZH58o",
                                "CwhRBWXzGAHq8TQ4Fs17", "FGY2WhTYpPnrIDTdsKH5", "cgSgspJ2msm6clMCkdW9"]
    private var replacements: [String: String] = [:]
    private var exhausted: Set<String> = []

    func voice(for id: String) -> String { replacements[id] ?? id }
    func isExhausted(_ id: String) -> Bool { exhausted.contains(id) }
    func markExhausted(_ id: String) {
        exhausted.insert(id)
        log.error("voice: no ElevenLabs voice usable through the API on this account; using the Mac voice")
    }

    func remember(_ id: String, works voice: String) {
        replacements[id] = voice
        // Remember it; Settings shows the voice in use and can change it.
        UserDefaults.standard.set(voice, forKey: "elevenLabsVoiceID")
        log.notice("voice: switched to ElevenLabs voice \(voice, privacy: .public)")
    }

    /// Voices to try instead of a refused one: the account's usable voices from GET /v2/voices, then stock voices.
    func candidates(excluding refused: String, apiKey: String) async -> [String] {
        var ids: [String] = []
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100")!)
        req.timeoutInterval = Config.ttsTimeoutSeconds
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        do {
            let (data, resp) = try await Network.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // Status and counts only (never the key): explains an empty pick, e.g. 401 missing_permissions (voices_read).
            log.notice("voice: GET /v2/voices HTTP \(status, privacy: .public); \(Voice.voiceSummary(data), privacy: .public)")
            if status == 200 { ids = Voice.usableVoices(fromVoicesJSON: data, excluding: refused).map(\.id) }
        } catch {
            log.error("voice: GET /v2/voices failed (\(error.localizedDescription, privacy: .public))")
        }
        return Self.merge(listed: ids, refused: refused)
    }

    /// The account's usable voices first, then every stock voice not already listed, never the refused one.
    static func merge(listed: [String], refused: String) -> [String] {
        var ids = listed.filter { $0 != refused }
        for id in stockVoiceIDs where id != refused && !ids.contains(id) { ids.append(id) }
        return ids
    }
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
        // Never fall back to Apple's servers: this path is the on-device fallback.
        guard recognizer.supportsOnDeviceRecognition else { throw VoiceError.noSpeechRecognizer }
        req.requiresOnDeviceRecognition = true
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
    /// Called once per answer when speech fails (the answer stays on screen as text).
    var onError: ((Error) -> Void)?

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
        guard tts != nil, !s.isEmpty, budget > 0 else { return }
        // A sentence that doesn't fit ends speech, so the listener never hears a later sentence without the one before.
        guard s.count <= budget || budget == Config.spokenCharLimit else { budget = 0; return }
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
                    // Stopped for a new answer: begin() already reset the state, so leave it alone.
                    if Task.isCancelled { return }
                    // Speech failed: stay silent, the answer is still shown as text.
                    log.error("voice: text-to-speech failed (\(error.localizedDescription, privacy: .public)); text only")
                    self.queue = []
                    self.budget = 0
                    self.onError?(error)
                }
            }
            if !Task.isCancelled { self?.worker = nil }
        }
    }
}

extension Voice {
    /// Opens the TLS connection to ElevenLabs while the user is still talking, so the upload at release doesn't
    /// pay for DNS + TCP + TLS. Sends no key and no audio.
    static func prewarmElevenLabs() {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/")!)
        req.httpMethod = "HEAD"
        Network.fire(req, session: elevenLabsSession)
    }
}

/// Logs where speech-to-text time goes: connection setup, upload, and waiting for ElevenLabs (the model).
private final class STTTimings: NSObject, Network.TaskDelegate, @unchecked Sendable {
    let audioBytes: Int
    init(audioBytes: Int) { self.audioBytes = audioBytes }

    func urlSession(_ session: Network.Session, task: Network.Task, didFinishCollecting metrics: Network.TaskMetrics) {
        guard let m = metrics.transactionMetrics.last else { return }
        func span(_ a: Date?, _ b: Date?) -> Double { guard let a, let b else { return 0 }; return b.timeIntervalSince(a) }
        let connect = span(m.domainLookupStartDate ?? m.connectStartDate, m.connectEndDate)
        let upload = span(m.requestStartDate, m.requestEndDate)
        let server = span(m.requestEndDate, m.responseStartDate)
        let total = metrics.taskInterval.duration
        let reused = m.isReusedConnection
        log.notice("voice: STT \(self.audioBytes / 1000, privacy: .public) kB; connect \(connect, format: .fixed(precision: 2), privacy: .public) s (reused \(reused, privacy: .public)), upload \(upload, format: .fixed(precision: 2), privacy: .public) s, ElevenLabs \(server, format: .fixed(precision: 2), privacy: .public) s, total \(total, format: .fixed(precision: 2), privacy: .public) s")
    }
}
