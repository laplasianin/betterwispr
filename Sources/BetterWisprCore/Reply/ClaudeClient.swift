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

    /// Checks a key with a tiny request. Only the HTTP status matters: thinking shares `max_tokens`, so the model may
    /// never reach its text, and that says nothing about the key.
    public func verify(key: String, model: ClaudeModel) async throws {
        let key = try Self.normalizedKey(key)
        let body = try JSONSerialization.data(withJSONObject: ["model": model.rawValue, "max_tokens": 64,
                                                               "output_config": ["effort": "low"],
                                                               "messages": [["role": "user", "content": "Say hi."]]])
        _ = try await send(body, key: key, requiringText: false)
    }

    /// Opens a connection to the API ahead of a request so the TLS handshake is done by the time the reply is ready.
    /// Sends no key and no data; the 401 it gets back is the point.
    public func warmUp() {
        Task {
            var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpMethod = "GET"
            _ = try? await session.data(for: request)
        }
    }

    // MARK: Streaming

    /// One server-sent event from the streaming Messages API that reply mode cares about.
    public enum StreamEvent: Equatable, Sendable {
        case text(String)
        case stop(String?, outputTokens: Int?)
        case usage(ReplyUsage)
        case error(type: String, message: String)
    }

    /// What `stream` delivers: the whole text so far after each chunk, and the request's token usage once it is known.
    public enum StreamItem: Equatable, Sendable {
        case text(String)
        case usage(ReplyUsage)
    }

    /// Streams the reply as it is written. After the last chunk one more text element carries the cleaned final text
    /// when cleaning changed it, then the usage. Retries once for a transient failure before any text arrived.
    public func stream(to request: ReplyRequest, model: ClaudeModel, effort: ReplyEffort, key: String) -> AsyncThrowingStream<StreamItem, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    guard !request.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReplyError.emptyInstruction }
                    let key = try Self.normalizedKey(key)
                    var body = request.body(model: model, effort: effort)
                    body["stream"] = true
                    let data = try JSONSerialization.data(withJSONObject: body)
                    var received = "", usage = ReplyUsage()
                    do {
                        (received, usage) = try await streamOnce(data, key: key) { received = $0; continuation.yield(.text($0)) }
                    } catch let error as ReplyError where error.isTransient && received.isEmpty {
                        // Once text is on screen a retry could replace it with something else, so only a silent failure is retried.
                        try await Task.sleep(for: retryDelay)
                        try Task.checkCancellation()
                        (received, usage) = try await streamOnce(data, key: key) { received = $0; continuation.yield(.text($0)) }
                    }
                    let final = Self.cleaned(received)
                    guard !final.isEmpty else { throw ReplyError.emptyReply }
                    if final != received { continuation.yield(.text(final)) }
                    continuation.yield(.usage(usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Runs one streaming request, reporting the accumulated text after each chunk and returning it with the usage at the end.
    private func streamOnce(_ body: Data, key: String, onText: (String) -> Void) async throws -> (text: String, usage: ReplyUsage) {
        let request = urlRequest(body, key: key)
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch let error as URLError where error.code == .timedOut { throw ReplyError.timedOut }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw ReplyError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw ReplyError.emptyReply }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            try Self.checkStatus(data, status: http.statusCode)
            throw ReplyError.emptyReply
        }
        var text = "", stop: String?, usage = ReplyUsage()
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data: "), let event = Self.event(fromDataLine: String(line.dropFirst(6))) else { continue }
                switch event {
                case .text(let chunk):
                    text += chunk
                    onText(text)
                case .stop(let reason, let outputTokens):
                    stop = reason
                    if let outputTokens { usage.outputTokens = outputTokens }
                case .usage(let reported): usage = reported
                case .error(let type, let message): throw Self.streamFailure(type: type, message: message)
                }
            }
        } catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where text.isEmpty { throw error.code == .timedOut ? ReplyError.timedOut : ReplyError.network(error.localizedDescription) }
        catch let error as URLError { throw ReplyError.badRequest(error.localizedDescription) }
        switch stop {
        case "refusal": throw ReplyError.refused
        case "max_tokens": throw ReplyError.truncated
        default: return (text, usage)
        }
    }

    /// Maps an in-stream error event to the same errors a failed HTTP status produces.
    private static func streamFailure(type: String, message: String) -> ReplyError {
        switch type {
        case "authentication_error", "permission_error": .invalidKey
        case "rate_limit_error": .rateLimited
        case "overloaded_error": .server(529)
        case "api_error": .server(500)
        default: .badRequest(message)
        }
    }

    /// Decodes the JSON after `data: ` on one SSE line; nil for events reply mode ignores or lines that are not JSON.
    public static func event(fromDataLine line: String) -> StreamEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = object["type"] as? String else { return nil }
        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            return .stop((object["delta"] as? [String: Any])?["stop_reason"] as? String,
                         outputTokens: (object["usage"] as? [String: Any])?["output_tokens"] as? Int)
        case "message_start":
            // The input side of the bill is known before any text; output tokens arrive with message_delta.
            guard let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
            return .usage(ReplyUsage(inputTokens: usage["input_tokens"] as? Int ?? 0, cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                                     cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0, outputTokens: 0))
        case "error":
            let detail = object["error"] as? [String: Any]
            return .error(type: detail?["type"] as? String ?? "error", message: detail?["message"] as? String ?? "Unknown error")
        default:
            return nil
        }
    }

    private func urlRequest(_ body: Data, key: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private func send(_ body: Data, key: String, requiringText: Bool = true) async throws -> String {
        do { return try await once(body, key: key, requiringText: requiringText) }
        catch let error as ReplyError where error.isTransient {
            try await Task.sleep(for: retryDelay)
            try Task.checkCancellation()
            return try await once(body, key: key, requiringText: requiringText)
        }
    }

    private func once(_ body: Data, key: String, requiringText: Bool) async throws -> String {
        let request = urlRequest(body, key: key)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw ReplyError.timedOut }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw ReplyError.network(error.localizedDescription) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ReplyError.emptyReply }
        guard requiringText else {
            try Self.checkStatus(data, status: http.statusCode)
            return ""
        }
        return try Self.parse(data, status: http.statusCode)
    }

    /// Turns a non-2xx status into a `ReplyError`; never trusts the body to be JSON.
    static func checkStatus(_ data: Data, status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw ReplyError.invalidKey
        case 429: throw ReplyError.rateLimited
        case 500...: throw ReplyError.server(status)
        default:
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error.message ?? "HTTP \(status)"
            throw ReplyError.badRequest(message)
        }
    }

    /// Maps an HTTP status and body to the reply text or a `ReplyError`.
    public static func parse(_ data: Data, status: Int) throws -> String {
        try checkStatus(data, status: status)
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
