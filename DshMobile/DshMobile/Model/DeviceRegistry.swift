import Foundation

/// Owns the paired devices, their online state, and the merged Session list.
///
/// This replaces the single-connection model. Every device is probed in
/// parallel, each contributes its own Sessions, and a failure on one never
/// hides the others — a phone that reaches two computers should show both.
@MainActor
final class DeviceRegistry: ObservableObject {
    /// Every paired device, most recently seen first.
    @Published private(set) var devices: [Device] = []
    /// Sessions from every online device, merged.
    @Published private(set) var sessions: [DeviceSession] = []
    /// True while a probe round is running.
    @Published private(set) var isProbing = false
    /// Last error per device, so a row can explain why it is offline.
    @Published private(set) var errors: [String: String] = [:]

    private static let storageKey = "com.dshmobile.devices"

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([Device].self, from: data) else {
            return
        }
        devices = saved
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - Membership

    /// Whether a device with this identity is already known.
    /// @param id - the device identity.
    /// @returns the existing device, if any.
    func device(id: String) -> Device? {
        devices.first { $0.id == id }
    }

    /// Add or replace a device, keeping the list ordered by recency.
    /// @param device - the device to remember.
    func upsert(_ device: Device) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        sortDevices()
        persist()
    }

    /// Forget one device and drop its Sessions.
    /// @param id - the device identity to remove.
    func remove(id: String) {
        devices.removeAll { $0.id == id }
        sessions.removeAll { $0.deviceId == id }
        errors[id] = nil
        persist()
    }

    /// Whether any device other than this phone is reachable.
    var hasOnlineDevice: Bool {
        devices.contains { $0.isOnline }
    }

    /// Every device that answered the last probe.
    var onlineDevices: [Device] {
        devices.filter { $0.isOnline }
    }

    private func sortDevices() {
        devices.sort { left, right in
            // Online first, then most recently seen; a paired device that has
            // never answered still sorts predictably at the end.
            if left.isOnline != right.isOnline { return left.isOnline }
            return (left.lastSeen ?? .distantPast) > (right.lastSeen ?? .distantPast)
        }
    }

    // MARK: - Probing

    /// Probe every device in parallel and rebuild the merged Session list.
    ///
    /// Probing concurrently is what makes a multi-device list usable: doing it
    /// in sequence would cost a full timeout per offline device before the phone
    /// showed anything at all.
    func refreshAll() async {
        guard !devices.isEmpty else {
            sessions = []
            return
        }
        isProbing = true
        defer { isProbing = false }
        let snapshot = devices
        // One task per device, then gather. Results are applied on the main
        // actor so the published lists never mutate from several contexts.
        let results = await withTaskGroup(of: ProbeResult.self) { group in
            for device in snapshot {
                group.addTask { await Self.probe(device) }
            }
            var collected: [ProbeResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        var merged: [DeviceSession] = []
        var nextDevices: [Device] = []
        var nextErrors: [String: String] = [:]
        for result in results {
            switch result {
            case let .online(device, rows):
                nextDevices.append(device.marking(online: true))
                for row in rows {
                    merged.append(DeviceSession(
                        deviceId: device.id,
                        deviceName: device.name,
                        endpoint: device.endpoint,
                        row: row
                    ))
                }
            case let .offline(device, reason):
                nextDevices.append(device.marking(online: false))
                nextErrors[device.id] = reason
            }
        }
        // Preserve any device added while the probe was in flight.
        for device in devices where !nextDevices.contains(where: { $0.id == device.id }) {
            nextDevices.append(device)
        }
        devices = nextDevices
        errors = nextErrors
        sortDevices()
        merged.sort { ($0.row.updatedAt ?? 0) > ($1.row.updatedAt ?? 0) }
        sessions = merged
        persist()
    }

    /// One probe outcome.
    enum ProbeResult {
        case online(Device, [SessionRow])
        case offline(Device, String)
    }

    /// Probe one device and read its Sessions.
    /// @param device - the device to reach.
    /// @returns its outcome.
    private static func probe(_ device: Device) async -> ProbeResult {
        var api = BridgeAPI(endpoint: device.endpoint)
        api.onRetry = nil
        do {
            // `info` is cheap and proves both reachability and token validity,
            // so a device is only asked for Sessions once it answered.
            _ = try await api.info()
            let rows = try await api.sessionRows()
            return .online(device, rows)
        } catch {
            if RetryPolicy.isCancellation(error) {
                return .offline(device, "已取消")
            }
            return .offline(device, Self.reason(error))
        }
    }

    /// Turn a failure into a short explanation for the device row.
    /// @param error - the failure.
    /// @returns a human label.
    private static func reason(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            if case let .http(status, _) = bridge {
                if status == 401 { return "令牌无效，需要重新配对" }
                return "服务返回 \(status)"
            }
            return bridge.errorDescription ?? "无法连接"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost: return "找不到设备"
            case .timedOut: return "连接超时"
            case .networkConnectionLost: return "网络中断"
            case .notConnectedToInternet: return "手机未联网"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Pairing

    /// Pair with a computer at an address and remember it on both sides.
    ///
    /// The computer is asked to record this phone as well, so the pairing is
    /// symmetric and shows up in its own device list.
    /// @param host - address typed by the person, or discovered.
    /// @param port - bridge port.
    /// @param token - the bearer token the computer printed.
    /// @param displayName - this phone's name, shown on the computer.
    /// @returns the paired device, or throws with the reason.
    func pair(host: String, port: Int, token: String, displayName: String) async throws -> Device {
        let endpoint = Endpoint(host: host, port: port, token: token)
        guard endpoint.isValid else {
            throw DeviceError.invalidAddress
        }
        var api = BridgeAPI(endpoint: endpoint)
        api.onRetry = nil
        let info = try await api.info()
        guard let identity = info.device else {
            throw DeviceError.notAPairedBridge
        }
        // Ask the computer to remember this phone. A failure here is not fatal:
        // the phone can still use the device, it just will not be listed there.
        try? await api.registerDevice(
            deviceId: Self.phoneId(),
            name: displayName,
            platform: "ios",
            address: nil
        )
        let device = Device(
            id: identity.deviceId,
            name: identity.name,
            host: host,
            port: port,
            token: token,
            platform: identity.platform,
            pairedAt: Date(),
            lastSeen: Date(),
            isOnline: true
        )
        upsert(device)
        return device
    }

    /// This phone's own identity, generated once and reused.
    /// @returns a stable id for this installation.
    private static func phoneId() -> String {
        let key = "com.dshmobile.deviceId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// The name this phone reports to computers.
    /// @returns a display name.
    static var phoneName: String {
        let key = "com.dshmobile.deviceName"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        return "iPhone"
    }

    /// Pairing is the only way to add a device, so failures get their own type.
    enum DeviceError: LocalizedError {
        case invalidAddress
        case notAPairedBridge

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "地址或令牌不完整。"
            case .notAPairedBridge: return "这台电脑没有报告设备身份，可能不是本插件的服务。"
            }
        }
    }
}
