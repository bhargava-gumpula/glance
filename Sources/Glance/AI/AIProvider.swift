import Foundation

struct ChatMessage: Sendable {
    enum Role: String, Sendable { case user, assistant }
    var role: Role
    var text: String
    /// JPEG images. Dropped by providers that can't see images.
    var images: [Data] = []
}

enum AIError: LocalizedError {
    case missingKey(String)
    case badURL(String)
    case http(Int, String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let name): "Add your \(name) API key in Glance Settings."
        case .badURL(let url): "The provider address \"\(url)\" isn't a valid URL."
        case .http(let status, let body): "The provider returned HTTP \(status). \(body.prefix(300))"
        case .api(let message): message
        }
    }
}

/// A chat model that streams text. Only `ContextPacket.send()` calls `stream`.
protocol AIProvider: Sendable {
    var name: String { get }
    var supportsImages: Bool { get }
    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest
    /// Parses one server-sent-event `data:` payload into a text delta, if it carries one.
    func textDelta(fromEvent payload: String) throws -> String?
    /// HTTP + SSE by default; on-device providers stream their own way.
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

extension AIProvider {
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        sseStream(self, system: system, messages: messages)
    }
}

/// HTTP + server-sent events, with per-request timings in the log (sizes and times only, never content):
/// request size, time to HTTP headers, first reasoning event, first text, and how spread out the text events
/// were (one burst at the end means the server or a proxy buffered the stream).
func sseStream(_ provider: AIProvider, system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            let start = Date()
            func since(_ d: Date?) -> Double { d.map { $0.timeIntervalSince(start) } ?? -1 }
            var headers: Date?, firstReasoning: Date?, firstText: Date?, lastText: Date?
            var reasoningEvents = 0, textEvents = 0
            var size = 0
            let images = messages.reduce(0) { $0 + $1.images.count }
            defer {
                log.notice("ai: \(provider.name, privacy: .public) request \(size / 1000, privacy: .public) kB, \(images, privacy: .public) image(s); headers \(since(headers), format: .fixed(precision: 2), privacy: .public) s, first reasoning \(since(firstReasoning), format: .fixed(precision: 2), privacy: .public) s (\(reasoningEvents, privacy: .public) events), first text \(since(firstText), format: .fixed(precision: 2), privacy: .public) s, \(textEvents, privacy: .public) text events over \(firstText.map { (lastText ?? $0).timeIntervalSince($0) } ?? 0, format: .fixed(precision: 2), privacy: .public) s, total \(Date().timeIntervalSince(start), format: .fixed(precision: 2), privacy: .public) s")
            }
            do {
                let request = try provider.makeRequest(system: system, messages: messages)
                size = request.httpBody?.count ?? 0
                let (bytes, response) = try await Network.bytes(for: request)
                headers = Date()
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    var body = ""
                    for try await line in bytes.lines { body += line; if body.count > 1000 { break } }
                    throw AIError.http(status, body)
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    if let delta = try provider.textDelta(fromEvent: payload), !delta.isEmpty {
                        if firstText == nil { firstText = Date() }
                        lastText = Date()
                        textEvents += 1
                        continuation.yield(delta)
                    } else if payload.contains("\"reasoning") || payload.contains("thinking") {
                        if firstReasoning == nil { firstReasoning = Date() }
                        reasoningEvents += 1
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

enum Providers {
    /// The provider chosen in Settings, with its key from the Keychain.
    @MainActor
    static func current() throws -> AIProvider {
        // Phase 4: local only uses the Local provider, backed by Apple's on-device model. The Network gate
        // refuses anything that isn't this Mac, so a non-localhost Local address falls through to Apple too.
        if Config.localOnly {
            return LocalOnlyProvider(local: make(id: "local", key: Keychain.get("local") ?? ""), fallback: AppleOnDeviceProvider())
        }
        let id = Config.provider
        let preset = Config.preset(id)
        let key = Keychain.get(id) ?? ""
        if preset.needsKey && key.isEmpty { throw AIError.missingKey(preset.name) }
        if !key.isEmpty {
            // Audit A11: a key only goes to the host it was saved for.
            let hostKey = "keyHost.\(id)"
            let saved = UserDefaults.standard.string(forKey: hostKey)
            if let problem = Config.keyHostMismatch(savedFor: saved, baseURL: Config.baseURL(for: id)) { throw AIError.api(problem) }
            if saved == nil, let host = URL(string: Config.baseURL(for: id))?.host { UserDefaults.standard.set(host, forKey: hostKey) }
        }
        return make(id: id, key: key)
    }

    static func make(id: String, key: String) -> AIProvider {
        let preset = Config.preset(id)
        switch preset.kind {
        case .anthropic:
            return AnthropicProvider(apiKey: key, baseURL: Config.baseURL(for: id), model: Config.model(for: id))
        case .openAICompat:
            let base = Config.baseURL(for: id), model = Config.model(for: id)
            return OpenAICompatProvider(name: preset.name, apiKey: key, baseURL: base, model: model,
                                        supportsImages: Config.supportsImages(for: id),
                                        reasoningEffort: ReasoningEffort.unsupported(baseURL: base, model: model) ? nil : ReasoningEffort.lowest)
        }
    }
}

func jsonObject(_ payload: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
}
