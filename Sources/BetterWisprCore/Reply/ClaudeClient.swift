import Foundation

/// Talks to the Anthropic Messages API for reply mode. One request per call, no streaming, no caching, no cookies.
public final class ClaudeClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let keyStore = SpeechAPIKeyStore(service: "com.betterwispr.claude-reply")
    /// A fixed connection record so the single reply key has a stable Keychain account.
    public static let keyConnection: SpeechConnection = {
        var connection = SpeechConnection(id: UUID(uuidString: "5B5D0E7C-2A1F-4C53-9D8E-7F0A1B2C3D4E")!, api: .openAICompatible)
        connection.name = "Claude"
        connection.endpoint = endpoint.absoluteString
        connection.modelID = "claude"
        return connection
    }()

    private let session: URLSession
    private let retryDelay: Duration
    private let timeout: TimeInterval

    public init(configuration: URLSessionConfiguration = .ephemeral, retryDelay: Duration = .seconds(1), timeout: TimeInterval = 30) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration, delegate: SpeechAPIRedirectGuard(), delegateQueue: nil)
        self.retryDelay = retryDelay
        self.timeout = timeout
    }

    deinit { session.invalidateAndCancel() }

    /// Trims the key and refuses keys that could not travel in a header.
    public static func normalizedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReplyError.missingKey }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
              trimmed.count <= 400 else { throw ReplyError.invalidKey }
        return trimmed
    }

    /// Writes the reply; retries once for rate limits, server errors, timeouts and dropped connections.
    public func reply(to request: ReplyRequest, model: ClaudeModel, effort: ReplyEffort, key: String) async throws -> String {
        guard !request.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReplyError.emptyInstruction }
        let key = try Self.normalizedKey(key)
        let body = try JSONSerialization.data(withJSONObject: request.body(model: model, effort: effort))
        return try await send(body, key: key)
    }

    /// Checks a key with the smallest possible request; throws the same errors as `reply`.
    public func verify(key: String, model: ClaudeModel) async throws {
        let key = try Self.normalizedKey(key)
        let body = try JSONSerialization.data(withJSONObject: ["model": model.rawValue, "max_tokens": 8,
                                                               "messages": [["role": "user", "content": "Say hi."]]])
        _ = try await send(body, key: key)
    }

    private func send(_ body: Data, key: String) async throws -> String {
        do { return try await once(body, key: key) }
        catch let error as ReplyError where error.isTransient {
            try await Task.sleep(for: retryDelay)
            try Task.checkCancellation()
            return try await once(body, key: key)
        }
    }

    private func once(_ body: Data, key: String) async throws -> String {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw ReplyError.timedOut }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw ReplyError.network(error.localizedDescription) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ReplyError.emptyReply }
        return try Self.parse(data, status: http.statusCode)
    }

    /// Maps an HTTP status and body to the reply text or a `ReplyError`; never trusts the body to be JSON.
    public static func parse(_ data: Data, status: Int) throws -> String {
        switch status {
        case 200..<300: break
        case 401, 403: throw ReplyError.invalidKey
        case 429: throw ReplyError.rateLimited
        case 500...: throw ReplyError.server(status)
        default:
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error.message ?? "HTTP \(status)"
            throw ReplyError.badRequest(message)
        }
        guard let message = try? JSONDecoder().decode(Response.self, from: data) else { throw ReplyError.emptyReply }
        switch message.stop_reason {
        case "refusal": throw ReplyError.refused
        case "max_tokens": throw ReplyError.truncated
        default: break
        }
        let text = cleaned(message.content.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n"))
        guard !text.isEmpty else { throw ReplyError.emptyReply }
        return text
    }

    /// Strips whitespace, a "Reply:" label and quotation marks that wrap the whole text.
    public static func cleaned(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Reply:", "Answer:", "Ответ:"] where text.hasPrefix(label) {
            text = text.dropFirst(label.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count > 1, let first = text.first, let last = text.last,
           "\"“«".contains(first), "\"”»".contains(last), !text.dropFirst().dropLast().contains(where: { "\"“”«»".contains($0) }) {
            text = text.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
        let stop_reason: String?
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { let type: String; let message: String }
        let error: Detail
    }
}
