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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, messages: messages)
                    let (bytes, response) = try await Network.bytes(for: request)
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
                        if let delta = try textDelta(fromEvent: payload) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
            return OpenAICompatProvider(name: preset.name, apiKey: key, baseURL: Config.baseURL(for: id),
                                        model: Config.model(for: id), supportsImages: Config.supportsImages(for: id))
        }
    }
}

func jsonObject(_ payload: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
}
