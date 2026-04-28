import Foundation
import Network

// BEP 14 — Local Service Discovery.
// Multicasts on 239.192.152.143:6771 and listens for the same. Discovered LAN peers go
// straight to TorrentEngine.connectToPeers — LAN peers can saturate gigabit links.
actor LocalPeerDiscovery {
    static let shared = LocalPeerDiscovery()

    private let groupAddr = "239.192.152.143"
    private let groupPort: UInt16 = 6771
    private let cookie: String = String(format: "%08x", UInt32.random(in: .min ... .max))

    private var listeners: [Data: (String, UInt16) -> Void] = [:]
    private var ourPort: UInt16 = 6881

    private var connectionGroup: NWConnectionGroup?
    private var announceTask: Task<Void, Never>?

    func register(infoHash: Data, onPeer: @escaping (String, UInt16) -> Void) {
        listeners[infoHash] = onPeer
    }

    func unregister(infoHash: Data) {
        listeners.removeValue(forKey: infoHash)
    }

    func start(localPort: UInt16 = 6881) async {
        ourPort = localPort
        guard connectionGroup == nil else { return }

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let mcEndpoint: NWEndpoint = .hostPort(
                host: NWEndpoint.Host(groupAddr),
                port: NWEndpoint.Port(rawValue: groupPort)!)
            let mcGroup = try NWMulticastGroup(for: [mcEndpoint])
            let cg = NWConnectionGroup(with: mcGroup, using: params)

            cg.setReceiveHandler(maximumMessageSize: 4096, rejectOversizedMessages: true) {
                [weak self] message, content, _ in
                guard let self, let data = content else { return }
                let remote = message.remoteEndpoint
                Task { await self.handleAnnouncement(data, from: remote) }
            }
            cg.stateUpdateHandler = { state in
                if case .failed(let err) = state { print("[LPD] group failed: \(err)") }
            }
            cg.start(queue: .global())
            self.connectionGroup = cg
            print("[LPD] Joined multicast \(groupAddr):\(groupPort)")
        } catch {
            print("[LPD] Failed to join multicast group: \(error)")
            return
        }

        announceTask = Task { [weak self] in
            // First broadcast after 2 s, then every 5 minutes (BEP 14)
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self?.broadcast()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func broadcast() async {
        let hashes = Array(listeners.keys)
        guard !hashes.isEmpty, let cg = connectionGroup else { return }
        let hashesHex = hashes.map { $0.map { String(format: "%02X", $0) }.joined() }

        var msg = "BT-SEARCH * HTTP/1.1\r\n"
        msg += "Host: \(groupAddr):\(groupPort)\r\n"
        msg += "Port: \(ourPort)\r\n"
        for h in hashesHex { msg += "Infohash: \(h)\r\n" }
        msg += "cookie: \(cookie)\r\n\r\n\r\n"

        guard let data = msg.data(using: .utf8) else { return }
        cg.send(content: data) { error in
            if let error = error { print("[LPD] send failed: \(error)") }
        }
    }

    private func handleAnnouncement(_ data: Data, from remote: NWEndpoint?) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        if text.contains("cookie: \(cookie)") { return }    // ignore our own

        // Extract source IP
        var sourceIP: String?
        if case let .hostPort(host, _) = remote {
            switch host {
            case .ipv4(let a): sourceIP = "\(a)"
            case .ipv6(let a): sourceIP = "\(a)"
            case .name(let n, _): sourceIP = n
            @unknown default: break
            }
        }
        guard let ip = sourceIP else { return }

        var port: UInt16 = 0
        var hashes: [Data] = []

        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("port:") {
                let s = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                port = UInt16(s) ?? 0
            } else if lower.hasPrefix("infohash:") {
                let s = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
                if let h = Data(hex: String(s)) { hashes.append(h) }
            }
        }
        guard port > 0 else { return }

        for hash in hashes {
            if let listener = listeners[hash] {
                print("[LPD] Discovered peer \(ip):\(port) for \(hash.prefix(4).map { String(format: "%02x", $0) }.joined())")
                listener(ip, port)
            }
        }
    }

    func stop() {
        announceTask?.cancel(); announceTask = nil
        connectionGroup?.cancel(); connectionGroup = nil
    }
}
