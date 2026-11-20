import Foundation

/// One Session's live transcript.
///
/// The store applies the bridge's operators (`reset`, `add`, `update`,
/// `remove`, `delta`, `status`) to an ordered node list, so rendering stays a
/// pure function of `nodes`. The Server-Sent-Events task owns the connection for
/// as long as the screen is on screen.
@MainActor
final class ChatStore: ObservableObject {
    let sessionID: String
    let title: String

    @Published private(set) var nodes: [TranscriptNode] = []
    @Published private(set) var isRunning = false
    @Published private(set) var pendingInput: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = true
    @Published private(set) var tick = 0
    @Published var showNotices = false
    /// How many times the in-flight request has been retried, for the status line.
    @Published private(set) var retryCount = 0
    @Published private(set) var isRetrying = false
    /// Why the last retry happened, shown while reconnecting.
    @Published private(set) var lastRetryReason: String?

    /// The model this Session will run its next prompt on.
    @Published private(set) var model: SessionModel?
    /// The full catalog, loaded lazily the first time the picker opens.
    @Published private(set) var catalog: ModelCatalog?
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isSwitchingModel = false

    // Mutable so the retry reporter can be installed after construction.
    private var api: BridgeAPI
    private var streamTask: Task<Void, Never>?
    private var startedAt: Date?

    init(sessionID: String, title: String, api: BridgeAPI) {
        self.sessionID = sessionID
        self.title = title
        self.api = api
    }

    /// Attach the transport's retry reporter to this store.
    ///
    /// Called once before the first request. The API value is copied into the
    /// store at initialization, so the reporter is installed on that same copy
    /// by rebuilding it here with a callback that targets this instance.
    func attachRetryReporter() {
        api.onRetry = { [weak self] attempt, error in
            Task { @MainActor in
                self?.noteRetry(attempt: attempt, error: error)
            }
        }
    }

    /// Record a retry observed by the transport.
    /// @param attempt - how many attempts have failed so far.
    /// @param error - the failure that triggered the retry.
    func noteRetry(attempt: Int, error: Error) {
        retryCount = attempt
        isRetrying = attempt > 0
        lastRetryReason = Self.describe(error)
    }

    /// Record that the in-flight request finally succeeded or gave up.
    private func clearRetryState() {
        if isRetrying || retryCount > 0 {
            retryCount = 0
            isRetrying = false
            lastRetryReason = nil
        }
    }

    deinit {
        streamTask?.cancel()
    }

    /// Nodes that should be drawn, honouring the notice toggle.
    var visibleNodes: [TranscriptNode] {
        showNotices ? nodes : nodes.filter { !$0.isNotice }
    }

    /// How long the current turn has been running, for the status line.
    var runningDescription: String {
        guard isRunning else { return pendingInput.isEmpty ? "空闲" : "等待确认" }
        guard let startedAt else { return "运行中" }
        let seconds = Int(Date().timeIntervalSince(startedAt).rounded())
        return "运行中 · \(seconds)s"
    }

    // MARK: - Lifecycle

    /// Read the transcript, then follow it live.
    func start() async {
        await load()
        follow()
    }

    /// Stop following. The Session keeps running on the computer.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Read the whole Session once.
    func load() async {
        isLoading = nodes.isEmpty
        do {
            let detail = try await api.detail(sessionID: sessionID)
            nodes = detail.nodes
            isRunning = detail.state.running
            pendingInput = detail.state.pendingInput
            model = detail.model
            if detail.state.running { startedAt = startedAt ?? Date() }
            lastError = nil
            clearRetryState()
        } catch {
            lastError = Self.describe(error)
        }
        isLoading = false
        tick += 1
    }

    // MARK: - Model

    /// Load the catalog if it is not already cached.
    func loadCatalogIfNeeded() async {
        guard catalog == nil, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalog = try await api.models()
            clearRetryState()
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Switch this Session to another model and effort.
    ///
    /// The bridge reports the selection it actually installed, which can differ
    /// from the request when the adapter resolves a default effort, so the
    /// returned value is what the UI shows.
    /// @param provider - provider id.
    /// @param model - model id.
    /// @param reasoningEffort - effort id, or nil when the model has none.
    /// @returns whether the switch succeeded.
    @discardableResult
    func switchModel(provider: String, model: String, reasoningEffort: String?) async -> Bool {
        guard !isSwitchingModel else { return false }
        isSwitchingModel = true
        defer { isSwitchingModel = false }
        do {
            let result = try await api.selectModel(
                sessionID: sessionID,
                provider: provider,
                model: model,
                reasoningEffort: reasoningEffort
            )
            self.model = result.current ?? result.selected
            lastError = nil
            clearRetryState()
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    /// Open the live stream, reopening it after a transient disconnect.
    ///
    /// A phone loses Wi-Fi constantly — a held door, a lift, the screen locking.
    /// The stream is a long-lived connection, so the recovery belongs here: the
    /// loop reconnects with backoff and only reports an error once the attempts
    /// are exhausted. The reopening snapshot rebuilds the transcript, so no
    /// operator replay is needed.
    private func follow() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    for try await frame in self.frames() {
                        if Task.isCancelled { break }
                        // Any frame proves the connection is healthy again.
                        if attempt > 0 {
                            attempt = 0
                            self.clearRetryState()
                        }
                        self.apply(frame)
                    }
                    // The server closed an open stream; treat it like a drop.
                    if Task.isCancelled { break }
                    throw BridgeError.transport("连接已断开")
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    guard RetryPolicy.isTransient(error) else {
                        self.lastError = Self.describe(error)
                        break
                    }
                    attempt += 1
                    guard attempt < RetryPolicy.maxAttempts else {
                        self.isRetrying = false
                        self.lastError = Self.describe(error)
                        break
                    }
                    let wait = RetryPolicy.delay(afterAttempt: attempt - 1)
                    self.retryCount = attempt
                    self.isRetrying = true
                    self.lastRetryReason = Self.describe(error)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
        }
    }

    private func frames() -> AsyncThrowingStream<StreamFrame, Error> {
        api.follow(sessionID: sessionID)
    }

    // MARK: - Operators

    private func apply(_ frame: StreamFrame) {
        switch frame.type {
        case "reset":
            nodes = frame.nodes ?? []
            // The bridge sends the Session API's own state here. A snapshot is
            // history: a turn that finished before this connection opened left
            // no `turn/end` for us to observe, so assuming "running" would be
            // wrong for most Sessions most of the time.
            isRunning = frame.running ?? false
            pendingInput = frame.pendingInput ?? []
            startedAt = isRunning ? Date() : nil
            lastError = nil
        case "op":
            applyOperator(frame)
            return
        case "status":
            isRunning = (frame.phase == "running")
            if let pending = frame.pendingInput { pendingInput = pending }
            startedAt = isRunning ? (startedAt ?? Date()) : nil
        case "error":
            lastError = frame.message
        default:
            break
        }
        tick += 1
    }

    private func applyOperator(_ frame: StreamFrame) {
        switch frame.op {
        case "add", "update":
            guard let node = frame.node else { break }
            if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                nodes[index] = node
            } else {
                nodes.append(node)
            }
        case "remove":
            guard let id = frame.id else { break }
            nodes.removeAll { $0.id == id }
        case "delta":
            guard let id = frame.id, let text = frame.text else { break }
            let isReasoning = frame.field == "reasoning"
            if let index = nodes.firstIndex(where: { $0.id == id }) {
                if isReasoning {
                    nodes[index].reasoning = (nodes[index].reasoning ?? "") + text
                } else {
                    nodes[index].text += text
                }
                nodes[index].streaming = true
            } else {
                var node = TranscriptNode(
                    id: id,
                    role: .assistant,
                    text: isReasoning ? "" : text,
                    reasoning: isReasoning ? text : nil,
                    streaming: true
                )
                node.streaming = true
                nodes.append(node)
            }
        default:
            break
        }
        tick += 1
    }

    // MARK: - Commands

    /// Submit a prompt to this Session.
    /// @param text - what the person typed.
    /// @returns whether the prompt was accepted.
    @discardableResult
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            // One identity per submission: a retried send is deduplicated by the
            // Session, so a dropped response cannot enqueue the message twice.
            let requestID = UUID().uuidString
            try await api.prompt(sessionID: sessionID, text: trimmed, requestID: requestID)
            isRunning = true
            startedAt = Date()
            lastError = nil
            return true
        } catch {
            isRetrying = false
            lastError = Self.describe(error)
            return false
        }
    }

    /// Stop the active turn without dropping queued input.
    func cancel() async {
        do {
            try await api.cancel(sessionID: sessionID)
            isRunning = false
            startedAt = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "请求失败。"
        }
        return error.localizedDescription
    }
}
