import Foundation

/// One computer this phone knows about.
///
/// A device is durable: the address and token are kept so the app can reach the
/// computer without a connect step, and the identity lets a known computer be
/// recognized again if DHCP moves it.
struct Device: Codable, Identifiable, Equatable, Sendable {
    /// Stable identity reported by the computer.
    var id: String
    var name: String
    var host: String
    var port: Int
    var token: String
    /// The computer's own platform label, for the device list.
    var platform: String
    /// When pairing completed.
    var pairedAt: Date
    /// Last time this device answered, for ordering and the online label.
    var lastSeen: Date?
    /// Whether the last probe succeeded.
    var isOnline: Bool

    var endpoint: Endpoint {
        Endpoint(host: host, port: port, token: token)
    }

    var displayAddress: String { "\(host):\(port)" }

    /// A short platform label for the row subtitle.
    var platformLabel: String {
        switch platform {
        case "win32": return "Windows"
        case "darwin": return "macOS"
        case "linux": return "Linux"
        case "ios": return "iPhone"
        case "android": return "Android"
        default: return platform.isEmpty ? "未知" : platform
        }
    }

    /// A relative last-seen label.
    var seenText: String {
        guard let lastSeen else { return "尚未连接" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastSeen, relativeTo: Date())
    }

    /// Return a copy marked online or offline.
    /// @param online - whether the probe succeeded.
    /// @returns the updated device.
    func marking(online: Bool) -> Device {
        var next = self
        next.isOnline = online
        if online { next.lastSeen = Date() }
        return next
    }
}

/// A Session merged from one device, carrying the device it came from.
struct DeviceSession: Identifiable, Equatable {
    /// Globally unique across devices: two computers can both have a Session
    /// with the same id only if they were forked from a shared history, so the
    /// device id is part of the key.
    var id: String { "\(deviceId)/\(row.id)" }
    let deviceId: String
    let deviceName: String
    /// Transport for this device, carried so opening a row needs no lookup.
    let endpoint: Endpoint
    let row: SessionRow
}

/// What a paired computer reports about itself.
struct DeviceSelf: Decodable, Equatable {
    let deviceId: String
    let name: String
    let platform: String
}

/// Payload of `GET /api/devices`.
struct DeviceListPayload: Decodable {
    let self: DeviceSelf
    let devices: [PairedDeviceRecord]
}

/// One device the computer remembers.
struct PairedDeviceRecord: Decodable, Equatable {
    let deviceId: String
    let name: String
    let platform: String?
    let address: String?
}
