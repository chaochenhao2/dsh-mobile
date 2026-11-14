import Foundation
import Darwin

/// One bridge that announced itself on the local network.
struct DiscoveredBridge: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let addresses: [String]
    let port: Int
    let harnessVersion: String?
    let token: String?

    /// The endpoint to dial, carrying the token only when the bridge broadcasts it.
    var endpoint: Endpoint {
        Endpoint(host: host, port: port, token: token ?? "")
    }
}

/// Listens for the bridge's UDP beacon.
///
/// The plugin broadcasts every three seconds on port 5181, so a phone on the same
/// network can offer the computer without anyone typing an address. Receiving
/// broadcast datagrams needs no special entitlement; iOS asks for local network
/// permission the first time.
final class UDPDiscovery {
    /// Beacon payload, as the plugin serializes it.
    private struct Beacon: Decodable {
        let service: String?
        let name: String
        let host: String
        let addresses: [String]?
        let port: Int
        let dsh: String?
        let token: String?
    }

    private let queue = DispatchQueue(label: "com.dshmobile.discovery")
    private var socketFD: Int32 = -1
    private var isRunning = false
    private var generation = 0
    private var handler: ((DiscoveredBridge) -> Void)?

    deinit {
        stop()
    }

    /// Start listening. Calling this again restarts the listener.
    /// @param port - the beacon port the plugin broadcasts to.
    /// @param onBeacon - invoked on the main queue for every decoded beacon.
    func start(port: UInt16 = 5181, onBeacon: @escaping (DiscoveredBridge) -> Void) {
        stop()
        handler = onBeacon
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound: Int32? = withUnsafePointer(to: &address) { pointer in
            let describe: (UnsafePointer<sockaddr>) -> Int32 = { raw in
                let socketAddress = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr.self)
                return bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, describe)
        }
        guard bound == 0 else {
            close(fd)
            return
        }

        socketFD = fd
        isRunning = true
        generation += 1
        let current = generation
        queue.async { [weak self] in
            self?.receiveLoop(fd: fd, generation: current)
        }
    }

    /// Stop listening and close the socket.
    func stop() {
        isRunning = false
        generation += 1
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    /// Read datagrams until the listener is stopped, decoding each beacon.
    /// @param fd - the bound socket.
    /// @param generation - the listener generation this loop serves.
    private func receiveLoop(fd: Int32, generation: Int) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while isRunning && generation == self.generation {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received: Int = withUnsafeMutablePointer(to: &address) { pointer in
                let describe: (UnsafeMutablePointer<sockaddr>) -> Int = { raw in
                    let socketAddress = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: sockaddr.self)
                    return buffer.withUnsafeMutableBytes { bytes in
                        let base = bytes.baseAddress
                        return recvfrom(fd, base, bytes.count, 0, socketAddress, &length)
                    }
                }
                return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, describe)
            }
            guard received > 0 else {
                if !isRunning || generation != self.generation { break }
                // A receive timeout is how the loop notices a stop request.
                continue
            }
            let data = Data(buffer[0..<received])
            guard let beacon = try? JSONDecoder().decode(Beacon.self, from: data),
                  beacon.service == "dsh-mobile-bridge" else { continue }
            let discovered = DiscoveredBridge(
                id: "\(beacon.host):\(beacon.port)",
                name: beacon.name,
                host: beacon.host,
                addresses: beacon.addresses ?? [beacon.host],
                port: beacon.port,
                harnessVersion: beacon.dsh,
                token: beacon.token
            )
            DispatchQueue.main.async { [weak self] in
                self?.handler?(discovered)
            }
        }
    }
}
