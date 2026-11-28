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
/// Reply to a rename request; only the committed title matters to the app.
private struct RenameResult: Decodable {
    let title: String?
}

/// Reply to an approval answer; only the acknowledgement matters.
private struct ApprovalAnswerReceipt: Decodable {
    let ok: Bool?
    let id: String?
}

/// One uploaded file a prompt refers to.
///
/// Only the path crosses the wire; the bridge decides whether to inline an image
/// or name a file for the model's own tools.
struct PromptAttachment: Equatable {
    let path: String
    /// `image`, `video`, or `file`.
    let kind: String
    let name: String
}

/// One file the bridge accepted into the Session's upload folder.
struct UploadedFile: Decodable, Equatable {
    let name: String
    /// Absolute path on the computer, which the prompt refers to.
    let path: String
    let bytes: Int
    let mediaType: String
    /// `image`, `video`, or `file`.
    let kind: String
}

/// Payload of `GET /api/session/:id/uploads`.
struct StoredUploads: Decodable, Equatable {
    let directory: String
    let files: [UploadedFile]
}

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

    /// Archive downloads can take longer than a JSON call on a large folder,
    /// so they get their own budget instead of the 15-second interactive one.
    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Uploads carry whole files, so they need a generous budget of their own.
    private static let uploadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
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
        // Send credentials only when there are some: a `Bearer ` header with an
        // empty value is a malformed credential, and the default deployment
        // wants no header at all.
        let token = endpoint.token.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
                // A withdrawn request is not a network failure: surface it as
                // cancellation so callers never render "canceled" as an error.
                if RetryPolicy.isCancellation(error) { throw CancellationError() }
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

    /// Create a Session anchored to a workspace, a typed path, or neither.
    /// @param workspaceID - existing workspace to attach, when chosen.
    /// @param cwd - directory typed by hand, when no workspace is chosen.
    /// @param agentPreset - agent mode id, or nil for the Harness default.
    /// @returns the new Session identity.
    func createSession(workspaceID: String?, cwd: String?, agentPreset: String?) async throws -> String {
        var body: [String: Any] = [:]
        if let workspaceID, !workspaceID.isEmpty { body["workspaceId"] = workspaceID }
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let agentPreset, !agentPreset.isEmpty { body["agentPreset"] = agentPreset }
        let result: SessionCreateResult = try await send("POST", "/api/sessions", body: body, session: Self.session)
        return result.sessionId
    }

    /// Read every durable workspace plus the process default directory.
    func workspaces() async throws -> WorkspacesPayload {
        try await send("GET", "/api/workspaces", body: nil, session: Self.session)
    }

    /// Read the selectable agent modes.
    func modes() async throws -> ModesPayload {
        try await send("GET", "/api/modes", body: nil, session: Self.session)
    }

    /// Read the process-level permission catalog.
    func permissions() async throws -> PermissionsPayload {
        try await send("GET", "/api/permissions", body: nil, session: Self.session)
    }

    /// Switch one Session's permission preset.
    ///
    /// This changes only this Session's sandbox and approval knobs; the default
    /// for future Sessions is untouched.
    /// @param sessionID - Session whose permission changes.
    /// @param value - preset value from the catalog.
    /// @returns the resulting state.
    func setPermission(sessionID: String, value: String) async throws -> PermissionsPayload {
        try await send(
            "POST",
            "/api/session/\(escaped(sessionID))/permission",
            body: ["value": value],
            session: Self.session
        )
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
    /// @param attachments - files already uploaded into this Session's folder.
    func prompt(
        sessionID: String,
        text: String,
        requestID: String,
        attachments: [PromptAttachment] = []
    ) async throws {
        var body: [String: Any] = [
            "text": text,
            "clientTimeZone": TimeZone.current.identifier,
            "requestId": requestID,
        ]
        if !attachments.isEmpty {
            body["attachments"] = attachments.map { attachment in
                ["path": attachment.path, "kind": attachment.kind, "name": attachment.name]
            }
        }
        let _: PromptAcceptance = try await send(
            "POST",
            "/api/session/\(escaped(sessionID))/prompt",
            body: body,
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

    /// Search every Session's transcript for a literal query.
    /// @param query - the text to look for.
    /// @returns matching Sessions with their excerpts.
    func search(query: String) async throws -> SearchPayload {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await send("GET", "/api/search?q=\(encoded)", body: nil, session: Self.session)
    }

    /// Rename one Session.
    ///
    /// The Harness commits the new title as a durable event, so it survives a
    /// restart and shows up on the computer too.
    /// @param sessionID - Session to rename.
    /// @param title - the new title.
    func rename(sessionID: String, title: String) async throws {
        let _: RenameResult = try await send(
            "POST",
            "/api/session/\(escaped(sessionID))/rename",
            body: ["title": title],
            session: Self.session
        )
    }

    /// Read the Session rows without wrapping them in the list payload.
    ///
    /// The merged multi-device list wants just the rows, and the probing path
    /// has no use for the envelope.
    /// @returns every Session on this device.
    func sessionRows() async throws -> [SessionRow] {
        let payload: SessionList = try await send("GET", "/api/sessions", body: nil, session: Self.session)
        return payload.items
    }

    /// Tell this computer about the phone that just paired with it.
    ///
    /// Pairing is symmetric: without this the phone would appear in its own list
    /// but not on the computer's.
    /// @param deviceId - the phone's identity.
    /// @param name - the phone's display name.
    /// @param platform - the phone's platform label.
    /// @param address - the phone's address, when it has one to offer.
    func registerDevice(deviceId: String, name: String, platform: String, address: String?) async throws {
        var body: [String: Any] = ["deviceId": deviceId, "name": name, "platform": platform]
        if let address, !address.isEmpty { body["address"] = address }
        let _: DeviceListPayload = try await send("POST", "/api/devices", body: body, session: Self.session)
    }

    /// Read this computer's own identity and its paired devices.
    func deviceList() async throws -> DeviceListPayload {
        try await send("GET", "/api/devices", body: nil, session: Self.session)
    }

    /// Ask this computer to forget a paired device.
    /// @param deviceId - the device identity to remove.
    func forgetDevice(deviceId: String) async throws {
        let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
        let _: DeviceListPayload = try await send(
            "POST",
            "/api/devices/\(encoded)/forget",
            body: [:],
            session: Self.session
        )
    }

    /// Upload one file into the Session's workspace folder.
    ///
    /// The body is the raw file rather than base64 in JSON: encoding a video
    /// would inflate it by a third and force the whole thing through memory on
    /// both ends for no benefit.
    /// @param sessionID - Session that will receive the attachment.
    /// @param file - the bytes, name, and media type.
    /// @returns the stored file's description, including its absolute path.
    func upload(sessionID: String, file: PickedFile) async throws -> UploadedFile {
        var components = URLComponents()
        components.path = "/api/session/\(sessionID)/upload"
        components.queryItems = [
            URLQueryItem(name: "name", value: file.name),
            URLQueryItem(name: "mediaType", value: file.mediaType),
        ]
        let path = components.string ?? "/api/session/\(sessionID)/upload"
        var request = try makeRequest("POST", path, body: nil)
        request.setValue(file.mediaType, forHTTPHeaderField: "Content-Type")
        // The default request timeout is far too short for a large video on a
        // weak link; uploads get their own budget.
        return try await Retry.run(maxAttempts: RetryPolicy.maxAttempts) {
            do {
                let (data, response) = try await Self.uploadSession.upload(for: request, from: file.data)
                guard let http = response as? HTTPURLResponse else {
                    throw BridgeError.transport("没有收到 HTTP 响应")
                }
                guard (200..<300).contains(http.statusCode) else {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    throw BridgeError.http(status: http.statusCode, body: text)
                }
                do {
                    return try JSONDecoder().decode(UploadedFile.self, from: data)
                } catch {
                    throw BridgeError.decoding(error.localizedDescription)
                }
            } catch let error as BridgeError {
                throw error
            } catch {
                if RetryPolicy.isCancellation(error) { throw CancellationError() }
                throw BridgeError.transport(error.localizedDescription)
            }
        }
    }

    /// List the files already uploaded for a Session.
    /// @param sessionID - Session whose upload folder is read.
    /// @returns the stored files.
    func uploads(sessionID: String) async throws -> StoredUploads {
        try await send("GET", "/api/session/\(escaped(sessionID))/uploads", body: nil, session: Self.session)
    }

    /// Read the approval prompts waiting for a decision.
    func approvals() async throws -> ApprovalsPayload {
        try await send("GET", "/api/approvals", body: nil, session: Self.session)
    }

    /// Answer one approval prompt.
    ///
    /// The bridge returns 409 when the prompt already expired or was cancelled,
    /// which the caller should treat as "nothing to do" rather than an error.
    /// @param id - the prompt to settle.
    /// @param allow - whether to grant it once.
    func answerApproval(id: String, allow: Bool) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let _: ApprovalAnswerReceipt = try await send(
            "POST",
            "/api/approvals/\(encoded)/answer",
            body: ["allow": allow],
            session: Self.session
        )
    }

    /// List one directory level inside a Session's workspace.
    ///
    /// `path` is optional; omitting it lists the Session's own root, which is
    /// what the file browser opens on.
    /// @param sessionID - Session whose files are browsed.
    /// @param path - absolute or workspace-relative directory, or nil for the root.
    /// @returns the listing, including the parent for a `..` row.
    func listFiles(sessionID: String, path: String?) async throws -> FileListing {
        var requestPath = "/api/session/\(escaped(sessionID))/files"
        if let path, !path.isEmpty {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
            requestPath += "?path=\(encoded)"
        }
        return try await send("GET", requestPath, body: nil, session: Self.session)
    }

    /// Download the selected paths.
    ///
    /// The bridge sends a single file as itself and several as a ZIP, so what
    /// comes back may be any size. `download(for:)` writes the body to a
    /// temporary file instead of a `Data` buffer, which is what keeps a
    /// multi-gigabyte download from exhausting the phone's memory.
    /// @param sessionID - Session whose files are read.
    /// @param paths - absolute paths chosen on the phone.
    /// @returns the temporary file URL and the suggested file name.
    func download(sessionID: String, paths: [String]) async throws -> (temporaryURL: URL, fileName: String) {
        let body = try JSONSerialization.data(withJSONObject: ["paths": paths])
        let request = try makeRequest(
            "POST",
            "/api/session/\(escaped(sessionID))/files/archive",
            body: body
        )
        return try await Retry.run(maxAttempts: RetryPolicy.maxAttempts) {
            do {
                let (url, response) = try await Self.downloadSession.download(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw BridgeError.transport("没有收到 HTTP 响应")
                }
                guard (200..<300).contains(http.statusCode) else {
                    // An error body is small, so reading it here is safe.
                    let data = (try? Data(contentsOf: url)) ?? Data()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    try? FileManager.default.removeItem(at: url)
                    throw BridgeError.http(status: http.statusCode, body: text)
                }
                return (url, Self.suggestedName(from: http))
            } catch let error as BridgeError {
                throw error
            } catch {
                if RetryPolicy.isCancellation(error) { throw CancellationError() }
                throw BridgeError.transport(error.localizedDescription)
            }
        }
    }

    /// Read the suggested file name from the response headers.
    ///
    /// The bridge sends an RFC 5987 `filename*` with percent-encoding, which is
    /// what keeps a non-ASCII name intact across the wire.
    /// @param response - the HTTP response.
    /// @returns the decoded name, falling back to a generic one.
    private static func suggestedName(from response: HTTPURLResponse) -> String {
        let raw = response.value(forHTTPHeaderField: "content-disposition") ?? ""
        if let range = raw.range(of: "filename*=UTF-8''") {
            let encoded = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        return "dsh-file"
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
