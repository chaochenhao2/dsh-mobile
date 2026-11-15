import Foundation

// MARK: - Bridge identity

/// Everything `GET /api/info` reports about the Harness this phone is talking to.
struct BridgeInfo: Decodable, Equatable {
    struct Bridge: Decodable, Equatable {
        let version: String
        let port: Int
        let discoveryPort: Int?
        let capabilities: [String]
    }

    struct Harness: Decodable, Equatable {
        let version: String?
        let electron: String?
        let node: String?
    }

    struct Profile: Decodable, Equatable {
        let name: String?
        let directory: String?
    }

    struct Host: Decodable, Equatable {
        let hostname: String
        let platform: String
        let addresses: [String]
        let preferredAddress: String
        let webUrl: String?
        /// Every dialable address with its transport label, when the bridge
        /// reports them. Older bridges omit this and only send `addresses`.
        let candidates: [Candidate]?

        /// Addresses to try, preferring the one the bridge recommends.
        var orderedCandidates: [Candidate] {
            if let candidates, !candidates.isEmpty {
                let preferred = preferredAddress
                return candidates.sorted { left, right in
                    (left.address == preferred ? 0 : 1) < (right.address == preferred ? 0 : 1)
                }
            }
            return addresses.map { Candidate(address: $0, kind: "other", interface: nil, url: nil) }
        }
    }

    /// One address the phone can dial, with the network it belongs to.
    struct Candidate: Decodable, Equatable {
        let address: String
        /// `lan` (same Wi-Fi), `tailnet` (Tailscale-style 100.64/10), or `other`.
        let kind: String
        let interface: String?
        let url: String?

        /// How to describe this route to the person choosing it.
        var label: String {
            switch kind {
            case "lan": return "同一 Wi-Fi"
            case "tailnet": return "Tailscale"
            default: return "其他网络"
            }
        }
    }

    let bridge: Bridge
    let dsh: Harness
    let profile: Profile
    let host: Host
    let protocolName: String

    enum CodingKeys: String, CodingKey {
        case bridge
        case dsh
        case profile
        case host
        case protocolName = "protocol"
    }
}

// MARK: - Sessions

/// One Session row from `GET /api/sessions`.
struct SessionRow: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Double?
    let running: Bool
    let blank: Bool
    let cwd: String?
    let agentAvailable: Bool
    let origin: String?

    /// Relative age, for a list row subtitle.
    var ageText: String {
        guard let updatedAt else { return "—" }
        let date = Date(timeIntervalSince1970: updatedAt / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct SessionList: Decodable {
    let items: [SessionRow]
}

struct SessionCreateResult: Decodable {
    let sessionId: String
}

/// Passive Session state from `GET /api/session/:id`.
struct SessionState: Decodable, Equatable {
    let running: Bool
    let active: Bool
    let pendingInput: [String]

    enum CodingKeys: String, CodingKey {
        case running
        case active
        case pendingInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        running = (try? container.decode(Bool.self, forKey: .running)) ?? false
        active = (try? container.decode(Bool.self, forKey: .active)) ?? false
        pendingInput = (try? container.decode([String].self, forKey: .pendingInput)) ?? []
    }
}

// MARK: - Transcript

/// One rendered line of a Session transcript.
///
/// The bridge folds the wide Harness event vocabulary into these four roles, so
/// the app never has to understand Session events itself.
struct TranscriptNode: Decodable, Identifiable, Equatable {
    enum Role: String, Decodable {
        case user
        case assistant
        case tool
        case notice
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: raw) ?? .unknown
        }
    }

    struct ToolInfo: Decodable, Equatable {
        let name: String
        var arguments: String?
        var status: String?
        var result: String?
        var reason: String?
    }

    let id: String
    let role: Role
    var text: String
    /// The model's reasoning for this step, when the route produced any.
    var reasoning: String?
    var streaming: Bool?
    var tool: ToolInfo?

    /// Decoded explicitly because `var text` and `let id` are mutated by the
    /// operator fold; providing the initializer keeps memberwise construction
    /// available at call sites while leaving `set` open.
    init(
        id: String,
        role: Role,
        text: String,
        reasoning: String? = nil,
        streaming: Bool? = nil,
        tool: ToolInfo? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.streaming = streaming
        self.tool = tool
    }

    var isStreaming: Bool { streaming == true }

    /// Reasoning worth showing: non-empty after trimming.
    var hasReasoning: Bool {
        guard let reasoning else { return false }
        return !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the turn that produced this node was cut short.
    var isNotice: Bool { role == .notice }
}

/// One frame of the Server-Sent Events stream.
///
/// A single flat type keeps the decoder tolerant: the bridge may add operators
/// without the app failing to read the ones it already knows.
struct StreamFrame: Decodable {
    let type: String
    let nodes: [TranscriptNode]?
    let sessionId: String?
    let cursor: Double?

    /// Authoritative run state carried by a `reset` frame.
    let running: Bool?
    let pendingInput: [String]?

    // `op` frames
    let op: String?
    let node: TranscriptNode?
    let id: String?
    /// Which field a `delta` extends: `text` (default) or `reasoning`.
    let field: String?
    let text: String?

    // `status` frames
    let phase: String?
    let turn: Int?
    let reason: String?

    // `error` frames
    let message: String?
}

/// Full Session read from `GET /api/session/:id`.
struct SessionDetail: Decodable {
    let sessionId: String
    let title: String?
    let state: SessionState
    let nodes: [TranscriptNode]
    let cursor: Double?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId
        case title
        case state
        case nodes
        case cursor
        case hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        title = try? container.decode(String.self, forKey: .title)
        state = try container.decode(SessionState.self, forKey: .state)
        nodes = (try? container.decode([TranscriptNode].self, forKey: .nodes)) ?? []
        cursor = try? container.decode(Double.self, forKey: .cursor)
        hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
    }
}

struct PromptAcceptance: Decodable {
    let accepted: Bool
}

// MARK: - Endpoint

/// Where the phone dials the bridge, and with which pairing token.
struct Endpoint: Codable, Equatable {
    var host: String = ""
    var port: Int = 5180
    var token: String = ""

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65_535).contains(port)
    }

    var displayAddress: String { "\(host):\(port)" }

    /// The base URL, or nil when the host cannot form one.
    var baseURL: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let authority = trimmed.contains(":") ? "[\(trimmed)]" : trimmed
        return URL(string: "http://\(authority):\(port)")
    }
}
