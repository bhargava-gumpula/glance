import Foundation

/// Claude via the Messages API (raw HTTP + SSE; there is no official Swift SDK).
struct AnthropicProvider: AIProvider {
    let apiKey: String
    let baseURL: String
    let model: String
    var name: String { "Claude" }
    var supportsImages: Bool { true }

    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest {
        guard let url = URL(string: baseURL + "/v1/messages") else { throw AIError.badURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // On a safety decline, the API re-runs the request on Anthropic's recommended fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": Config.maxOutputTokens,
            "stream": true,
            "system": system,
            "output_config": ["effort": Config.claudeEffort],
            "fallbacks": "default",
            "messages": messages.map { m -> [String: Any] in
                var content: [[String: Any]] = m.images.map {
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                 "data": $0.base64EncodedString()]]
                }
                content.append(["type": "text", "text": m.text])
                return ["role": m.role.rawValue, "content": content]
            },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func textDelta(fromEvent payload: String) throws -> String? {
        guard let event = jsonObject(payload) else { return nil }
        switch event["type"] as? String {
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
        case "message_delta":
            let stop = (event["delta"] as? [String: Any])?["stop_reason"] as? String
            return stop == "refusal" ? "\n\n(Claude declined to answer this one.)" : nil
        case "error":
            let error = event["error"] as? [String: Any]
            throw AIError.api(error?["message"] as? String ?? "Claude returned an error.")
        default:
            return nil
        }
    }
}
