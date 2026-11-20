import Foundation

/// A failure the phone can explain to the person holding it.
enum BridgeError: LocalizedError {
    case missingEndpoint
    case invalidURL
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "还没有连接到电脑。"
        case .invalidURL:
            return "地址无效，请检查主机名与端口。"
        case let .http(status, body):
            if status == 401 { return "配对令牌不正确。" }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "服务器返回 HTTP \(status)。" : "HTTP \(status)：\(trimmed)"
        case let .transport(message):
            return "网络错误：\(message)"
        case let .decoding(message):
            return "无法解析响应：\(message)"
        }
    }
}

/// The bridge's JSON and Server-Sent-Events API.
///
/// Every call authenticates with the pairing token; the bridge is the only
/// component that knows how to reach the Harness, so this type stays a thin
/// transport.
struct BridgeAPI {
    let endpoint: Endpoint

    /// Reports each retry to the caller so the UI can show "reconnecting".
    var onRetry: (@Sendable (Int, Error) -> Void)?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 3_600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// The streaming session keeps the request alive while the Harness is quiet.
    private static let streamingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 3_600
        configuration.timeoutIntervalForResource = 86_400
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(endpoint: Endpoint, onRetry: (@Sendable (Int, Error) -> Void)? = nil) {
        self.endpoint = endpoint
        self.onRetry = onRetry
    }

    // MARK: - Requests

    private func makeRequest(_ method: String, _ path: String, body: Data?) throws -> URLRequest {
        guard let base = endpoint.baseURL else { throw BridgeError.invalidURL }
        guard let url = URL(string: path, relativeTo: base) else { throw BridgeError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.token.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Perform one request, retrying transient failures.
    ///
    /// Idempotent reads and writes are safe to repeat. A prompt carries the
    /// caller's request id so the Session deduplicates a repeat rather than
    /// enqueueing the message twice.
    /// @param method - HTTP method.
    /// @param path - absolute path with query.
    /// @param body - optional JSON body.
    /// @param session - the URL session carrying the request.
    /// @param retryable - whether a transient failure may be retried.
    /// @returns the decoded response.
    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: Any]?,
        session: URLSession,
        retryable: Bool = true
    ) async throws -> T {
        let payload: Data?
        if let body {
            payload = try? JSONSerialization.data(withJSONObject: body)
        } else {
            payload = method == "POST" ? Data("{}".utf8) : nil
        }
        let request = try makeRequest(method, path, body: payload)
        let attempts = retryable ? RetryPolicy.maxAttempts : 1
        let notify = onRetry
        return try await Retry.run(maxAttempts: attempts, onRetry: { attempt, error, _ in
            notify?(attempt, error)
        }, operation: {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw BridgeError.transport("没有收到 HTTP 响应")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw BridgeError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
                }
                do {
                    let decoder = JSONDecoder()
                    return try decoder.decode(T.self, from: data)
                } catch {
                    throw BridgeError.decoding(error.localizedDescription)
                }
            } catch let error as BridgeError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BridgeError.transport(error.localizedDescription)
            }
        })
    }

    // MARK: - Endpoints

    func info() async throws -> BridgeInfo {
        try await send("GET", "/api/info", body: nil, session: Self.session)
    }

    func sessions() async throws -> [SessionRow] {
        let list: SessionList = try await send("GET", "/api/sessions", body: nil, session: Self.session)
        return list.items
    }

    func createSession() async throws -> String {
        let result: SessionCreateResult = try await send("POST", "/api/sessions", body: [:], session: Self.session)
        return result.sessionId
    }

    func detail(sessionID: String) async throws -> SessionDetail {
        try await send("GET", "/api/session/\(escaped(sessionID))", body: nil, session: Self.session)
    }

    /// Submit a prompt to one Session.
    ///
    /// `requestID` identifies this submission across retries: the bridge passes
    /// it through and the Session deduplicates on it, so a retried send is not
    /// enqueued twice.
    /// @param sessionID - Session receiving the prompt.
    /// @param text - what the person typed.
    /// @param requestID - stable identity for this submission.
    func prompt(sessionID: String, text: String, requestID: String) async throws {
        let _: PromptAcceptance = try await send(
            "POST",
            "/api/session/\(escaped(sessionID))/prompt",
            body: [
                "text": text,
                "clientTimeZone": TimeZone.current.identifier,
                "requestId": requestID,
            ],
            session: Self.session
        )
    }

    func cancel(sessionID: String) async throws {
        let _: PromptAcceptance = try await send(
            "POST",
            "/api/session/\(escaped(sessionID))/cancel",
            body: [:],
            session: Self.session
        )
    }

    /// The routable model catalog with provider names and effort choices.
    func models() async throws -> ModelCatalog {
        try await send("GET", "/api/models", body: nil, session: Self.session)
    }

    /// Switch one Session to another model.
    ///
    /// The Harness records the choice on the Session and saves it as the new
    /// default, so the next prompt runs on it.
    /// @param sessionID - Session whose model changes.
    /// @param provider - provider id.
    /// @param model - model id.
    /// @param reasoningEffort - effort id, or nil to leave it to the adapter.
    /// @returns the selection the Host installed.
    func selectModel(
        sessionID: String,
        provider: String,
        model: String,
        reasoningEffort: String?
    ) async throws -> ModelSwitchResult {
        var body: [String: Any] = ["provider": provider, "model": model]
        if let reasoningEffort, !reasoningEffort.isEmpty {
            body["reasoningEffort"] = reasoningEffort
        }
        return try await send(
            "POST",
            "/api/session/\(escaped(sessionID))/model",
            body: body,
            session: Self.session
        )
    }

    /// Follow one Session, yielding every operator the bridge emits.
    ///
    /// The stream ends normally on cancellation and reports transport or HTTP
    /// failures through the stream's termination error.
    /// @param sessionID - Session to follow.
    /// @returns every decoded frame, in order.
    func follow(sessionID: String) -> AsyncThrowingStream<StreamFrame, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        "GET",
                        "/api/session/\(escaped(sessionID))/stream?activate=1",
                        body: nil
                    )
                    let (bytes, response) = try await Self.streamingSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw BridgeError.transport("没有收到 HTTP 响应")
                    }
                    guard http.statusCode == 200 else {
                        throw BridgeError.http(status: http.statusCode, body: "")
                    }
                    let decoder = JSONDecoder()
                    // `URLSession.AsyncBytes.lines` is a throwing AsyncSequence on
                    // every supported deployment target, so the loop needs `try`.
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let frame = try? decoder.decode(StreamFrame.self, from: data) {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
