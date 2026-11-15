import Foundation

/// App-wide state: which computer this phone is paired with, and its Session list.
///
/// The store owns the endpoint so every screen shares one connection; a Session
/// transcript lives in its own `ChatStore` and is discarded when the screen
/// closes.
@MainActor
final class AppStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var info: BridgeInfo?
    @Published private(set) var sessions: [SessionRow] = []
    @Published private(set) var isLoadingSessions = false
    @Published var lastError: String?
    @Published var endpoint: Endpoint

    private static let storageKey = "com.dshmobile.endpoint"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Endpoint.self, from: data) {
            endpoint = saved
        } else {
            endpoint = Endpoint()
        }
    }

    /// Whether the phone is talking to a Harness right now.
    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// The transport for the current endpoint, when it is complete.
    var api: BridgeAPI? {
        endpoint.isValid ? BridgeAPI(endpoint: endpoint) : nil
    }

    /// A one-line description of the connected computer.
    var hostSummary: String {
        guard let info else { return endpoint.displayAddress }
        let version = info.dsh.version.map { "Harness \($0)" } ?? "Harness"
        return "\(info.host.hostname) · \(version)"
    }

    // MARK: - Connection

    /// Pair with the configured endpoint and load its Session list.
    ///
    /// When the configured address fails and the bridge is reachable some other
    /// way, the store retries the remaining candidates — the usual case is a
    /// phone that left the home Wi-Fi but can still reach the computer over
    /// Tailscale.
    func connect() async {
        guard let api else {
            lastError = "请填写主机地址与配对令牌。"
            phase = .failed("endpoint-incomplete")
            return
        }
        phase = .connecting
        lastError = nil
        do {
            info = try await api.info()
            sessions = try await api.sessions()
            phase = .connected
            persist()
            return
        } catch {
            lastError = Self.describe(error)
        }
        // The first address failed; walk the alternatives the bridge reported.
        if let alternatives = await alternateEndpoints(excluding: endpoint.host) {
            for candidate in alternatives {
                do {
                    let probe = BridgeAPI(endpoint: candidate)
                    info = try await probe.info()
                    sessions = try await probe.sessions()
                    endpoint = candidate
                    phase = .connected
                    lastError = nil
                    persist()
                    return
                } catch {
                    lastError = Self.describe(error)
                }
            }
        }
        info = nil
        phase = .idle
    }

    /// Re-run connection using a specific address the person chose.
    /// @param host - the address to dial, keeping the current port and token.
    func reconnect(host: String) async {
        var next = endpoint
        next.host = host
        endpoint = next
        await connect()
    }

    /// Ask the reachable bridge for its other addresses.
    ///
    /// Discovery is best-effort: a bridge that cannot be reached cannot answer,
    /// so a failure here simply means "no alternatives to try".
    /// @param excluding - the host already attempted.
    /// @returns endpoints to try next, or nil when none are known.
    private func alternateEndpoints(excluding: Set<String>) async -> [Endpoint]? {
        let probe = BridgeAPI(endpoint: endpoint)
        guard let reachable = try? await probe.info() else { return nil }
        let hosts = reachable.host.orderedCandidates
            .map(\.address)
            .filter { !excluding.contains($0) }
        guard !hosts.isEmpty else { return nil }
        return hosts.map { host in
            var next = endpoint
            next.host = host
            return next
        }
    }

    /// Re-read the Session list without dropping the connection.
    func refreshSessions() async {
        guard let api, isConnected else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            sessions = try await api.sessions()
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Create a blank Session and return its identity.
    /// @returns the new Session id, or nil when creation failed.
    func createSession() async -> String? {
        guard let api else { return nil }
        do {
            let sessionID = try await api.createSession()
            await refreshSessions()
            return sessionID
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    /// Forget the pairing and return to the connect screen.
    func disconnect() {
        phase = .idle
        info = nil
        sessions = []
        lastError = nil
    }

    /// Replace the endpoint and pair with it.
    /// @param next - the address and token to use from now on.
    func adopt(_ next: Endpoint) async {
        endpoint = next
        await connect()
    }

    // MARK: - Helpers

    private func persist() {
        guard let data = try? JSONEncoder().encode(endpoint) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func describe(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "连接失败。"
        }
        return error.localizedDescription
    }
}
