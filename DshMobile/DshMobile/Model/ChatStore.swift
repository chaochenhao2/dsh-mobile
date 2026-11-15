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

    private let api: BridgeAPI
    private var streamTask: Task<Void, Never>?
    private var startedAt: Date?

    init(sessionID: String, title: String, api: BridgeAPI) {
        self.sessionID = sessionID
        self.title = title
        self.api = api
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
            if detail.state.running { startedAt = startedAt ?? Date() }
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        isLoading = false
        tick += 1
    }

    private func follow() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await frame in self.frames() {
                    if Task.isCancelled { break }
                    self.apply(frame)
                }
            } catch {
                if !Task.isCancelled {
                    self.lastError = Self.describe(error)
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
            try await api.prompt(sessionID: sessionID, text: trimmed)
            isRunning = true
            startedAt = Date()
            lastError = nil
            return true
        } catch {
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
