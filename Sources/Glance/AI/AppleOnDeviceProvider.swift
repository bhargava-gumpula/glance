import Foundation
import FoundationModels

/// Apple's on-device model (FoundationModels, `SystemLanguageModel.default`). Text only: it gets the OCR text
/// and memory text. Never the Private Cloud Compute model: nothing here leaves the Mac.
struct AppleOnDeviceProvider: AIProvider {
    var name: String { "Apple on-device model" }
    var supportsImages: Bool { false }
    /// The on-device model has a small context (about 4k tokens); longer prompts are cut in the middle.
    static let maxPromptChars = 9_000

    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest { throw AIError.api("No HTTP for \(name).") }
    func textDelta(fromEvent payload: String) throws -> String? { nil }

    /// One prompt from the conversation. ponytail: a middle cut drops memory/selection detail first; a summarising
    /// pass would keep more, add it if local answers miss context.
    static func prompt(_ messages: [ChatMessage]) -> String {
        let text = messages.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
        guard text.count > maxPromptChars else { return text }
        let head = 2_000
        return String(text.prefix(head)) + "\n…\n" + String(text.suffix(maxPromptChars - head))
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let why): "\(why)"
        }
    }

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let why = Self.unavailableReason { throw AIError.api("Apple's on-device model isn't available (\(why)).") }
                    let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: Self.prompt(messages)) {
                        try Task.checkCancellation()
                        let full = snapshot.content // cumulative
                        if full.hasPrefix(sent), full.count > sent.count { continuation.yield(String(full.dropFirst(sent.count))) }
                        sent = full
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

/// Local-only mode's AI: the Local provider (Ollama / LM Studio on this Mac); if it can't answer before its
/// first word (not running, model missing, not a localhost address), Apple's on-device model answers instead.
struct LocalOnlyProvider: AIProvider {
    let local: AIProvider
    let fallback: AIProvider
    var name: String { "this Mac (local only)" }
    var supportsImages: Bool { local.supportsImages }

    func makeRequest(system: String, messages: [ChatMessage]) throws -> URLRequest { try local.makeRequest(system: system, messages: messages) }
    func textDelta(fromEvent payload: String) throws -> String? { try local.textDelta(fromEvent: payload) }

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var started = false
                do {
                    for try await d in local.stream(system: system, messages: messages) { started = true; continuation.yield(d) }
                    continuation.finish()
                    return
                } catch {
                    if started || Task.isCancelled { continuation.finish(throwing: error); return }
                    log.notice("local only: \(local.name, privacy: .public) unavailable (\(error.localizedDescription, privacy: .public)); using \(fallback.name, privacy: .public)")
                }
                do {
                    for try await d in fallback.stream(system: system, messages: messages) { continuation.yield(d) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
