import AVFoundation

/// Hold-to-talk mic capture: native-format tap → 16 kHz mono Int16 → WAV.
final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private var running = false
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func start() throws {
        if running { _ = stop() } // only one tap per bus: a second installTap raises an exception Swift can't catch
        // Without permission the engine "records" silence instead of failing, so check first.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceError.noMicrophone }
        lock.lock(); pcm.removeAll(); lock.unlock()
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        let outFmt = Self.format
        guard inFmt.sampleRate > 0, let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw VoiceError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [self] buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * outFmt.sampleRate / inFmt.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            nonisolated(unsafe) var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            let data = Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)
            lock.lock(); pcm.append(data); lock.unlock()
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        running = true
    }

    /// Stops and returns the recording as a WAV file (empty if nothing was recorded).
    func stop() -> Data {
        guard running else { return Data() }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let body = pcm; pcm.removeAll(); lock.unlock()
        return Self.wav(body)
    }

    static func wav(_ body: Data) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var h = Data("RIFF".utf8); h += le(UInt32(36 + body.count)); h += Data("WAVEfmt ".utf8)
        h += le(UInt32(16)); h += le(UInt16(1)); h += le(UInt16(1)); h += le(UInt32(16000))
        h += le(UInt32(32000)); h += le(UInt16(2)); h += le(UInt16(16)); h += Data("data".utf8); h += le(UInt32(body.count))
        return h + body
    }

    /// Seconds of audio in a WAV from `wav(_:)`.
    static func duration(ofWAV wav: Data) -> Double { Double(max(0, wav.count - 44)) / 32000 }
}

/// Plays raw 16-bit LE mono PCM as it streams in.
final class PCMPlayer: @unchecked Sendable {
    static let shared = PCMPlayer()
    static let sampleRate = 24000.0
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: PCMPlayer.sampleRate, channels: 1)!
    private let lock = NSLock()
    private var _generation = 0

    private init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // macOS stops the engine when the output device changes (e.g. headphones); restart on the next buffer.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [self] _ in
            lock.lock(); defer { lock.unlock() }
            node.stop()
        }
    }

    /// Bumped by `stop()`. Audio from a stream that started before the last stop is dropped.
    var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }

    func enqueue(_ pcm: Data, generation: Int) {
        let frames = pcm.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard generation == _generation else { return }
        if !engine.isRunning {
            // play() on a stopped engine raises an exception Swift can't catch, so never call it after a failed start.
            do { try engine.start() } catch {
                log.error("voice: audio output failed (\(error.localizedDescription, privacy: .public))")
                return
            }
        }
        if !node.isPlaying { node.play() }
        node.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Drops everything queued (mute, Stop, or a new question).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        _generation += 1
        node.stop()
    }
}
