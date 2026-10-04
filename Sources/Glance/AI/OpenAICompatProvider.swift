import Foundation

/// Any OpenAI-compatible Chat Completions endpoint: DeepSeek, OpenAI, Ollama, LM Studio.
struct OpenAICompatProvider: AIProvider {
    let name: String
    let apiKey: String
    let baseURL: String
    let model: String
    let supportsImages: Bool
    /// Sent as `reasoning_effort` so reasoning models start answering sooner. Nil once the deployment rejected it.
    var reasoningEffort: String? = nil

    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest {
        guard let url = URL(string: baseURL + "/chat/completions") else { throw AIError.badURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if url.host?.hasSuffix(".azure.com") == true { request.setValue(apiKey, forHTTPHeaderField: "api-key") }
        }

        var all: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            if supportsImages && !m.images.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": m.text]]
                parts += m.images.map {
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
                }
                all.append(["role": m.role.rawValue, "content": parts])
            } else {
                all.append(["role": m.role.rawValue, "content": m.text])
            }
        }
        var body: [String: Any] = ["model": model, "stream": true, "messages": all]
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Streams with `reasoning_effort`; if the deployment rejects the parameter (before any text), it is
    /// remembered for this address and model and the request is sent again without it.
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        guard reasoningEffort != nil else { return sseStream(self, system: system, messages: messages) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var started = false
                do {
                    for try await d in sseStream(self, system: system, messages: messages) { started = true; continuation.yield(d) }
                    continuation.finish()
                    return
                } catch AIError.http(let status, let body) where !started && ReasoningEffort.rejected(status: status, body: body) {
                    ReasoningEffort.markUnsupported(baseURL: baseURL, model: model)
                    log.notice("ai: \(name, privacy: .public) rejected reasoning_effort (HTTP \(status, privacy: .public)); sending without it from now on")
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                var plain = self
                plain.reasoningEffort = nil
                do {
                    for try await d in sseStream(plain, system: system, messages: messages) { continuation.yield(d) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func textDelta(fromEvent payload: String) throws -> String? {
        guard let event = jsonObject(payload) else { return nil }
        if let error = event["error"] as? [String: Any] {
            throw AIError.api(error["message"] as? String ?? "\(name) returned an error.")
        }
        let choice = (event["choices"] as? [[String: Any]])?.first
        return (choice?["delta"] as? [String: Any])?["content"] as? String
    }
}

/// Which OpenAI-compatible deployments refuse `reasoning_effort`, remembered across launches per address + model.
enum ReasoningEffort {
    /// Accepted by OpenAI reasoning models, xAI mini models and Azure's OpenAI-compatible endpoint.
    static let lowest = "low"

    private static func key(_ baseURL: String, _ model: String) -> String { "reasoningUnsupported.\(baseURL)|\(model)" }
    static func unsupported(baseURL: String, model: String) -> Bool { UserDefaults.standard.bool(forKey: key(baseURL, model)) }
    static func markUnsupported(baseURL: String, model: String) { UserDefaults.standard.set(true, forKey: key(baseURL, model)) }
    static func forget(baseURL: String, model: String) { UserDefaults.standard.removeObject(forKey: key(baseURL, model)) }

    /// A 4xx that names the parameter: the deployment doesn't take it.
    static func rejected(status: Int, body: String) -> Bool {
        (400..<500).contains(status) && status != 401 && status != 403 && status != 429 && body.lowercased().contains("reasoning")
    }
}
