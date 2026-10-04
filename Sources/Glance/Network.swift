import Foundation

/// Phase 4: the one gate every request goes through. While local-only mode is on, it refuses every host
/// except this Mac (localhost, 127.0.0.1, ::1). The selftest fails if any other file opens a connection itself.
enum Network {
    typealias Session = URLSession
    typealias Bytes = URLSession.AsyncBytes
    typealias Task = URLSessionTask
    typealias TaskDelegate = URLSessionTaskDelegate
    typealias TaskMetrics = URLSessionTaskMetrics
    typealias Configuration = URLSessionConfiguration

    enum Blocked: LocalizedError {
        case localOnly(String)
        var errorDescription: String? {
            switch self {
            case .localOnly(let host): "Local only is on, so Glance didn't contact \(host)."
            }
        }
    }

    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func allowed(_ url: URL, localOnly: Bool) -> Bool {
        guard localOnly else { return true }
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return localHosts.contains(host)
    }

    private static func gate(_ request: URLRequest) throws {
        guard let url = request.url, allowed(url, localOnly: Config.localOnly) else {
            log.notice("network: blocked \(request.url?.host ?? "?", privacy: .public) (local only)")
            throw Blocked.localOnly(request.url?.host ?? "that address")
        }
    }

    static func session(_ configuration: URLSessionConfiguration) -> URLSession { URLSession(configuration: configuration) }

    static func data(for request: URLRequest, session: URLSession = .shared,
                     delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        try gate(request)
        return try await session.data(for: request, delegate: delegate)
    }

    static func bytes(for request: URLRequest, session: URLSession = .shared) async throws -> (Bytes, URLResponse) {
        try gate(request)
        return try await session.bytes(for: request)
    }

    /// Fire-and-forget (connection pre-warm). Silently skipped when blocked.
    static func fire(_ request: URLRequest, session: URLSession = .shared) {
        guard (try? gate(request)) != nil else { return }
        session.dataTask(with: request).resume()
    }
}
