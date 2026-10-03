import Foundation

/// Any OpenAI-compatible Chat Completions endpoint: DeepSeek, OpenAI, Ollama, LM Studio.
struct OpenAICompatProvider: AIProvider {
    let name: String
    let apiKey: String
    let baseURL: String
    let model: String
    let supportsImages: Bool

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
        let body: [String: Any] = ["model": model, "stream": true, "messages": all]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
