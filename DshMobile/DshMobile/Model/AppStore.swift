import Foundation

/// App-wide state: the paired devices and the Session list merged from them.
///
/// There is no connect step any more. The phone remembers every computer it has
/// paired with, probes them in parallel, and shows their Sessions together. A
/// transcript still lives in its own `ChatStore` and is discarded on close.
@MainActor
final class AppStore: ObservableObject {
    /// Every paired device, ordered online-first.
    @Published private(set) var registry = DeviceRegistry()
    /// Sessions merged across every reachable device.
    @Published private(set) var sessions: [DeviceSession] = []
    /// Current search text, mirrored so an in-flight result can detect that a
    /// newer query superseded it.
    @Published var searchQuery: String = ""
    @Published private(set) var hits: [SessionHit] = []
    /// Whether those results covered message bodies; false means title-only,
    /// because the deployment disabled the transcript index.
    @Published private(set) var searchIsTranscript = false
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingSessions = false
    @Published var lastError: String?

    /// A retry in flight, for the status banner.
    @Published private(set) var isRetrying = false
    @Published private(set) var retryCount = 0

    /// The device used for actions that are not per-Session, such as the file
    /// browser before a Session is chosen. The first reachable one wins.
    var primaryDevice: Device? {
        registry.devices.first { $0.isOnline }
    }

    /// The transport for the primary device, when one is reachable.
    ///
    /// Retry reporting is attached here so requests made through it feed the
    /// status banner.
    var api: BridgeAPI? {
        guard let device = primaryDevice else { return nil }
        var client = BridgeAPI(endpoint: device.endpoint)
        client.onRetry = { [weak self] attempt, _ in
            Task { @MainActor in
                self?.isRetrying = true
                self?.retryCount = attempt
            }
        }
        return client
    }

    /// Whether at least one computer answered the last probe.
    var hasAnyOnlineDevice: Bool {
        registry.hasOnlineDevice
    }

    /// Whether the phone knows any computer at all.
    var hasPairedDevice: Bool {
        !registry.devices.isEmpty
    }

    /// A one-line summary of the device situation.
    var statusSummary: String {
        let online = registry.onlineDevices.count
        let total = registry.devices.count
        if total == 0 { return "尚未配对设备" }
        if online == 0 { return "\(total) 台设备全部离线" }
        if online == total { return "\(total) 台设备在线" }
        return "\(online)/\(total) 台设备在线"
    }

    // MARK: - Devices

    /// Probe every device and refresh the merged list.
    func refreshSessions() async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        await registry.refreshAll()
        sessions = registry.sessions
        if registry.hasOnlineDevice {
            lastError = nil
            isRetrying = false
            retryCount = 0
        }
    }

    /// Pair with a computer and immediately fold its Sessions into the list.
    /// @param host - address to dial.
    /// @param port - bridge port.
    /// @param token - bearer token.
    /// @returns the paired device, or throws with the reason.
    @discardableResult
    func pair(host: String, port: Int, token: String) async throws -> Device {
        let device = try await registry.pair(
            host: host,
            port: port,
            token: token,
            displayName: DeviceRegistry.phoneName
        )
        await refreshSessions()
        return device
    }

    /// Forget a device and drop its Sessions.
    /// @param id - the device identity to remove.
    func forget(id: String) {
        registry.remove(id: id)
        sessions = registry.sessions
    }

    /// The last probe failure recorded for a device.
    /// @param id - the device identity.
    /// @returns the reason, when the device is offline because of a failure.
    func error(for id: String) -> String? {
        registry.errors[id]
    }

    // MARK: - Sessions

    /// Locate one Session across devices.
    /// @param sessionID - the Session identity inside its device.
    /// @param deviceID - the device it belongs to, when known.
    /// @returns the merged row.
    func mergedSession(_ sessionID: String, deviceID: String?) -> DeviceSession? {
        sessions.first { entry in
            entry.row.id == sessionID && (deviceID == nil || entry.deviceId == deviceID)
        }
    }

    /// Search every reachable device's transcript.
    ///
    /// Each device searches with its own transport, so one disabled index does
    /// not hide matches on the others.
    /// @param query - the text to look for.
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            hits = []
            searchIsTranscript = false
            isSearching = false
            return
        }
        isSearching = true
        defer { isSearching = false }
        let online = registry.onlineDevices
        let results = await withTaskGroup(of: SearchChunk.self) { group in
            for device in online {
                group.addTask {
                    var client = BridgeAPI(endpoint: device.endpoint)
                    client.onRetry = nil
                    do {
                        let payload = try await client.search(query: trimmed)
                        return SearchChunk(device: device, payload: payload, failure: nil)
                    } catch {
                        return SearchChunk(device: device, payload: nil, failure: error.localizedDescription)
                    }
                }
            }
            var collected: [SearchChunk] = []
            for await chunk in group { collected.append(chunk) }
            return collected
        }
        // A newer query may have started while these were in flight.
        guard trimmed == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        var merged: [SessionHit] = []
        var transcript = false
        for chunk in results {
            guard let payload = chunk.payload else { continue }
            if payload.isTranscriptSearch { transcript = true }
            for hit in payload.items {
                merged.append(hit.attributed(to: chunk.device))
            }
        }
        hits = merged
        searchIsTranscript = transcript
        lastError = nil
    }

    /// One device's search outcome.
    struct SearchChunk {
        let device: Device
        let payload: SearchPayload?
        let failure: String?
    }

    /// Rename a Session on its own device.
    /// @param sessionID - Session to rename.
    /// @param deviceID - the device hosting it.
    /// @param title - the new title.
    /// @returns whether the rename was accepted.
    @discardableResult
    func rename(sessionID: String, deviceID: String, title: String) async -> Bool {
        guard let device = registry.device(id: deviceID) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var client = BridgeAPI(endpoint: device.endpoint)
        client.onRetry = nil
        do {
            try await client.rename(sessionID: sessionID, title: trimmed)
            // Patch the merged row in place so the list does not reorder under
            // the person while they are looking at it.
            if let index = sessions.firstIndex(where: { $0.row.id == sessionID && $0.deviceId == deviceID }) {
                sessions[index] = DeviceSession(
                    deviceId: deviceID,
                    deviceName: device.name,
                    endpoint: sessions[index].endpoint,
                    row: sessions[index].row.withTitle(trimmed)
                )
            }
            return true
        } catch {
            if RetryPolicy.isCancellation(error) { return false }
            lastError = Self.describe(error)
            return false
        }
    }

    /// Create a Session on one device.
    /// @param device - where to create it.
    /// @param workspaceID - existing workspace, when chosen.
    /// @param cwd - directory typed by hand.
    /// @param agentPreset - agent mode id.
    /// @returns the new Session identity.
    func createSession(
        on device: Device,
        workspaceID: String?,
        cwd: String?,
        agentPreset: String?
    ) async throws -> String {
        var client = BridgeAPI(endpoint: device.endpoint)
        client.onRetry = nil
        let created = try await client.createSession(
            workspaceID: workspaceID,
            cwd: cwd,
            agentPreset: agentPreset
        )
        await refreshSessions()
        return created
    }

    private static func describe(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "请求失败。"
        }
        return error.localizedDescription
    }
}

extension SessionHit {
    /// Attach the device this hit came from, so a merged list can label it.
    /// @param device - the source device.
    /// @returns the hit with its origin.
    func attributed(to device: Device) -> SessionHit {
        SessionHit(
            id: "\(device.id)/\(id)",
            title: title,
            running: running,
            snippet: snippet,
            deviceId: device.id,
            deviceName: device.name
        )
    }
}
