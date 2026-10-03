# Phase 2 research: voice

Sources checked 2026-10-03. Anything not confirmed in docs or SDK headers is marked UNVERIFIED. No API keys appear here; read the key from Keychain (`ie.dublinhacx.glance`, account `elevenlabs`).

## 1. ElevenLabs speech-to-text (Scribe)
Docs: https://elevenlabs.io/docs/api-reference/speech-to-text/convert , models: https://elevenlabs.io/docs/overview/models

- `POST https://api.elevenlabs.io/v1/speech-to-text`, header `xi-api-key: <key>`, body `multipart/form-data`.
- Fields: `model_id` (required; `scribe_v2`; `scribe_v1` is deprecated), `file` (audio or video, under 5 GB, at least 100 ms), optional `language_code` (ISO 639-1/3; auto-detected if omitted, so pass `en` to save work), `tag_audio_events` (bool; set false so "(laughter)" does not enter the question), `diarize` (bool; leave off), `timestamps_granularity` (`none`|`word`|`character`; UNVERIFIED that `none` is accepted, omit it), `keyterms` (list, up to 1000; handy for names like "Glance").
- Formats: the docs say "audio/video file" without a list. Send 16 kHz mono 16-bit WAV (works everywhere) or m4a. Exact list is UNVERIFIED.
- Response (single channel): `{"language_code":"en","language_probability":0.98,"text":"...","words":[{"text","start","end","type","speaker_id"}]}`. Use `text`. With `use_multi_channel: true` you get `transcripts: [...]` instead.
- Latency: `scribe_v2` is batch. Short clips (a few seconds) come back quickly, but I found no published number (UNVERIFIED). Keep clips small: 16 kHz mono, trim the tail silence, reuse one `URLSession` so TLS stays warm.
- Streaming alternative: `scribe_v2_realtime` (~150 ms) over a WebSocket. Not needed for hold-to-talk; the whole utterance is known at key-up. The WebSocket protocol was not researched (UNVERIFIED). Revisit only if batch latency is too high.

```swift
import Foundation

func scribe(wav: Data, apiKey: String) async throws -> String {
    let boundary = "glance-\(UUID().uuidString)"
    var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
    req.httpMethod = "POST"
    req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    field("model_id", "scribe_v2")
    field("language_code", "en")
    field("tag_audio_events", "false")
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"q.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(wav)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    req.httpBody = body
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
        throw NSError(domain: "scribe", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
    }
    struct R: Decodable { let text: String }
    return try JSONDecoder().decode(R.self, from: data).text
}
```

## 2. ElevenLabs text-to-speech streaming
Docs: https://elevenlabs.io/docs/api-reference/text-to-speech/stream , https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input , https://elevenlabs.io/docs/developers/best-practices/latency-optimization

**HTTP stream:** `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream?output_format=pcm_24000`, header `xi-api-key`, JSON body `{"text": "...", "model_id": "eleven_flash_v2_5", "voice_settings": {...}}`. The response body is raw audio, streamed.

**Models (low latency first):** `eleven_flash_v2_5` (~75 ms, 32 languages, WebSocket ok), `eleven_flash_v2` (English only), `eleven_v4_turbo` (~100 ms, WebSocket), `eleven_multilingual_v2` (default, higher quality, HTTP only). Default to `eleven_flash_v2_5`. Table: https://elevenlabs.io/docs/overview/models

**Output formats** (query `output_format`): `mp3_22050_32`, `mp3_44100_128`, `pcm_8000` ... `pcm_48000`, plus opus, mu-law and a-law. Pick **`pcm_24000`** (or `pcm_22050`): raw 16-bit little-endian mono, so it needs no decoder. Higher tier plans gate `pcm_44100+` and `mp3_44100_192`. Whether `pcm_24000` is open to the free tier is UNVERIFIED; fall back to `pcm_22050`.

**Latency tips (from the docs):** Flash model; stream; use WebSocket when text arrives incrementally and set `auto_mode` (UNVERIFIED where it is passed; docs say it manages generation triggers); default/synthetic/instant-clone voices are fastest, professional clones slower; `api.us.elevenlabs.io` for the US region; `optimize_streaming_latency` is deprecated, do not use it.

**WebSocket input streaming** (feed LLM tokens as they arrive):
- `wss://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream-input?model_id=eleven_flash_v2_5&output_format=pcm_24000&inactivity_timeout=60`
- Auth: `xi-api-key` header on the handshake. `URLSessionWebSocketTask` can set it on the `URLRequest`. (Header auth on the handshake is standard in the SDKs; the docs page I fetched only showed the first-message form. The first message also accepts `xi_api_key` in the JSON for browsers. UNVERIFIED for the macOS header route, test it.)
- Messages, all JSON text frames:
  1. First: `{"text":" ","voice_settings":{"stability":0.5,"similarity_boost":0.8},"generation_config":{"chunk_length_schedule":[50,90,120,150]}}` (the single space is required).
  2. Then per LLM chunk: `{"text":"Hello there. "}` (end each chunk with a space; the service buffers until a size threshold). `{"text":"...","flush":true}` forces generation of buffered text; use it at the end of a sentence and at the end of the answer.
  3. Close: `{"text":""}`.
- Server frames: `{"audio":"<base64>","isFinal":null,...}` (optional `alignment`/`normalizedAlignment` with `sync_alignment=true`) and finally `{"isFinal":true}`. Decode base64 to PCM and schedule it.
- Tradeoff: WebSocket buffers text, so it adds latency when the full text is already known. For Glance: stream LLM deltas into the WebSocket, flush on sentence ends. Simpler fallback: split on sentence boundaries and POST each sentence to the HTTP stream endpoint, playing the results in order.

**Playback on macOS while it streams.** Simplest workable: `AVAudioEngine` + `AVAudioPlayerNode`, convert each PCM chunk to an `AVAudioPCMBuffer` and `scheduleBuffer`. No file, no decoder, begins as soon as the first buffer is queued.

```swift
import AVFoundation

final class PCMPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    init() throws {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)   // mixer converts to the output device rate
        try engine.start()
        node.play()
    }
    func enqueue(_ pcm: Data) {                       // raw 16-bit LE mono @ 24 kHz
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        pcm.withUnsafeBytes { src in
            buf.int16ChannelData![0].update(from: src.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        node.scheduleBuffer(buf, completionHandler: nil)
    }
    func stop() { node.stop(); engine.stop() }       // call for "Stop"/mute
}
```
Note: `connect(..., format: int16)` into the mixer should work (the mixer converts). If it throws, make the format `.pcmFormatFloat32` non-interleaved and convert samples to Float (divide by 32768). UNVERIFIED on this SDK, test early. Keep HTTP chunks even in byte count (a split mid-sample corrupts audio): carry a leftover odd byte to the next chunk.

HTTP stream into the player:
```swift
func speak(_ text: String, voice: String, apiKey: String, player: PCMPlayer) async throws {
    var req = URLRequest(url: URL(string:
        "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream?output_format=pcm_24000")!)
    req.httpMethod = "POST"
    req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_flash_v2_5"])
    let (bytes, _) = try await URLSession.shared.bytes(for: req)
    var chunk = Data(); chunk.reserveCapacity(4800)
    for try await b in bytes {                       // byte-wise is fine at 48 kB/s
        chunk.append(b)
        if chunk.count >= 4800 { player.enqueue(chunk); chunk.removeAll(keepingCapacity: true) }   // 100 ms
    }
    if chunk.count >= 2 { player.enqueue(chunk.prefix(chunk.count & ~1)) }
}
```
WebSocket send/receive skeleton:
```swift
let ws = URLSession.shared.webSocketTask(with: {
    var r = URLRequest(url: URL(string: "wss://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream-input?model_id=eleven_flash_v2_5&output_format=pcm_24000")!)
    r.setValue(apiKey, forHTTPHeaderField: "xi-api-key"); return r }())
ws.resume()
try await ws.send(.string(#"{"text":" ","voice_settings":{"stability":0.5,"similarity_boost":0.8}}"#))
// per LLM delta:  try await ws.send(.string(String(data: try JSONSerialization.data(withJSONObject: ["text": delta + " "]), encoding: .utf8)!))
// end:            try await ws.send(.string(#"{"text":""}"#))
while true {
    guard case .string(let s) = try await ws.receive(),
          let o = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
    if let a = o["audio"] as? String, let d = Data(base64Encoded: a) { player.enqueue(d) }
    if o["isFinal"] as? Bool == true { break }
}
```

## 3. Hold-to-talk mic capture (AVAudioEngine)
`HotKey` already reports press and release. On press: start the engine; on release: stop and hand over a WAV.
- Needs `NSMicrophoneUsageDescription` in Info.plist (the app already requests Microphone) and the permission granted.
- Tap the input node in its native format (a tap cannot change the sample rate), convert with `AVAudioConverter` to 16 kHz mono Int16, append to a buffer, then add a 44-byte WAV header.
- `inputNode.installTap` callback runs on an audio thread; guard shared buffers with a lock.

```swift
import AVFoundation

final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func start() throws {
        pcm.removeAll()
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw NSError(domain: "rec", code: 1) }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [self] buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * outFmt.sampleRate / inFmt.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            let n = Int(out.frameLength) * 2
            lock.lock(); pcm.append(Data(bytes: out.int16ChannelData![0], count: n)); lock.unlock()
        }
        try engine.start()
    }

    func stop() -> Data {                              // WAV bytes, ready for scribe()
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        lock.lock(); let body = pcm; lock.unlock()
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var h = Data("RIFF".utf8); h += le(UInt32(36 + body.count)); h += Data("WAVEfmt ".utf8)
        h += le(UInt32(16)); h += le(UInt16(1)); h += le(UInt16(1)); h += le(UInt32(16000))
        h += le(UInt32(32000)); h += le(UInt16(2)); h += le(UInt16(16)); h += Data("data".utf8); h += le(UInt32(body.count))
        return h + body
    }
}
```
Tips: ignore presses under ~300 ms (accidental); add ~150 ms tail before `stop()` so the last word is not clipped; call `engine.prepare()` at launch to cut start-up. Encoding to m4a is possible with `AVAudioFile` settings (`kAudioFormatMPEG4AAC`) but WAV is simpler and 16 kHz mono is only 32 kB/s.

## 4. Apple on-device fallback
Header: `$(xcrun --show-sdk-path)/System/Library/Frameworks/Speech.framework/Headers/SFSpeechRecognizer.h` and `SFSpeechRecognitionRequest.h`.

**Option A: `SFSpeechRecognizer` (classic, safest).**
- `SFSpeechRecognizer.supportsOnDeviceRecognition` (checked in the header) must be true; then set `request.requiresOnDeviceRecognition = true`. The request only honors it when the recognizer supports it.
- Needs `NSSpeechRecognitionUsageDescription` and `SFSpeechRecognizer.requestAuthorization`. This is a separate permission from Microphone (UNVERIFIED if it blocks the unsigned or self-signed build; test).
- Feed `SFSpeechAudioBufferRecognitionRequest.append(_:)` from the same engine tap (native format is fine here), or `SFSpeechURLRecognitionRequest` with the WAV.

```swift
import Speech
func appleTranscribe(wavURL: URL) async throws -> String {
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), r.supportsOnDeviceRecognition
    else { throw NSError(domain: "stt", code: 1) }
    let req = SFSpeechURLRecognitionRequest(url: wavURL)
    req.requiresOnDeviceRecognition = true
    req.shouldReportPartialResults = false
    return try await withCheckedThrowingContinuation { c in
        var done = false
        r.recognitionTask(with: req) { res, err in
            guard !done else { return }
            if let res, res.isFinal { done = true; c.resume(returning: res.bestTranscription.formattedString) }
            else if let err { done = true; c.resume(throwing: err) }
        }
    }
}
```

**Option B: `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+; present in SDK 27).** Swift-only, in `Speech.swiftmodule/arm64e-apple-macos.swiftinterface` (not in the ObjC headers). Confirmed symbols: `actor SpeechAnalyzer(modules:options:)`, `analyzeSequence(_:)`, `finalizeAndFinishThroughEndOfInput()`, `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, `AnalyzerInput(buffer:)`, `SpeechTranscriber(locale:preset:)` with presets `transcription`, `progressiveTranscription`, `AssetInventory.status(forModules:)`, `AssetInventory.assetInstallationRequest(supporting:)` (model download on first use), `SpeechTranscriber.installedLocales`, `DictationTranscriber`. Results are an `AsyncSequence` whose elements have `isFinal`; the result text is `r.text` (`AttributedString`).

```swift
import Speech
import AVFoundation
func analyzerTranscribe(buffers: [AVAudioPCMBuffer]) async throws -> String {
    let t = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
    let a = SpeechAnalyzer(modules: [t])
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    async let text: String = { var s = ""; for try await r in t.results where r.isFinal { s += String(r.text.characters) }; return s }()
    try await a.start(inputSequence: stream)
    for b in buffers { cont.yield(AnalyzerInput(buffer: b)) }
    cont.finish()
    try await a.finalizeAndFinishThroughEndOfInput()
    return try await text
}
```
This snippet type-checks against SDK 27 with `swiftc -typecheck` (runtime behaviour untested). Input buffers must be in `bestAvailableAudioFormat`. Recommendation: build Option A first (smallest, known API); try B only if A reports no on-device support.

Network fallback logic: try Scribe with a 4 s timeout; on `URLError` (offline, timeout) use the Apple path.

## 5. SwiftUI macros
None of this needs SwiftUI. AVFoundation, Speech and URLSession are plain frameworks; all snippets use classes and closures. Only the UI that shows state (mute toggle, mic level) must stay AppKit or `ObservableObject`, as the app already does.
