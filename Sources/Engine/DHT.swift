import Foundation
import Network
import CryptoKit
import os

// BEP 5 — Kademlia-based DHT for peer discovery without trackers.
actor DHT {
    static let shared = DHT()

    private let nodeId: Data
    private var routingTable: [DHTNodeInfo] = []
    private var tokenSecrets: [String: Data] = [:]    // ip -> token received from that node
    private var pendingTx: [String: CheckedContinuation<DHTResponse, Error>] = [:]
    // Maps 2-byte tx id -> info_hash so responses are routed to the right torrent
    private var pendingGetPeers: [Data: Data] = [:]
    private var connection: NWConnection?
    private var isRunning = false
    private var lastRoutingSave: Date = .distantPast

    private static let k = 8
    private static let alpha = 3
    private static let maxNodes = 500
    private static let port: UInt16 = 6881
    private static let bootstrapNodes: [(String, UInt16)] = [
        ("router.bittorrent.com",  6881),
        ("router.utorrent.com",    6881),
        ("dht.transmissionbt.com", 6881),
        ("router.bitcomet.com",    6881),
        ("dht.aelitis.com",        6881),
        ("dht.libtorrent.org",     6881),
        ("dht.example.com",      6881),
    ]

    var onPeersFound: ((_ infoHash: Data, _ peers: [(String, UInt16)]) -> Void)?

    init() {
        if let saved = UserDefaults.standard.data(forKey: "dht.nodeId"), saved.count == 20 {
            nodeId = saved
        } else {
            var id = Data(count: 20)
            _ = id.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!) }
            UserDefaults.standard.set(id, forKey: "dht.nodeId")
            nodeId = id
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        loadRoutingTable()
        await bindSocket()
        await bootstrap()
    }

    func stop() {
        isRunning = false
        saveRoutingTable(force: true)
        connection?.cancel()
        connection = nil
    }

    // MARK: - Bootstrap

    private func bindSocket() async {
        startListener()
    }

    private func startListener() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) else { return }

        listener.newConnectionHandler = { [weak self] newConn in
            guard let self else { return }
            newConn.stateUpdateHandler = { state in
                if case .ready = state {
                    Task { [self] in await self.receiveFrom(newConn) }
                }
            }
            newConn.start(queue: .global())
        }
        listener.start(queue: .global())
    }

    private func receiveFrom(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self, let data, error == nil else { return }
            let ep = conn.endpoint
            if case .hostPort(let h, let p) = ep {
                Task {
                    await self.handlePacket(data, from: "\(h)", port: p.rawValue)
                    await self.receiveFrom(conn)
                }
            }
        }
    }

    private func bootstrap() async {
        for (host, port) in Self.bootstrapNodes {
            guard let addr = await resolve(host: host) else { continue }
            let node = DHTNodeInfo(id: Data(repeating: 0, count: 20), ip: addr, port: port)
            await sendPing(to: node)
        }
    }

    private func resolve(host: String) async -> String? {
        await withCheckedContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let conn = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(host), port: 6881),
                using: .udp
            )
            @Sendable func resumeOnce(returning value: String?) {
                let alreadyResumed = resumed.withLock { isResumed in
                    if isResumed { return true }
                    isResumed = true; return false
                }
                if !alreadyResumed { cont.resume(returning: value); conn.cancel() }
            }
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    if case .hostPort(let h, _) = conn.currentPath?.remoteEndpoint {
                        resumeOnce(returning: "\(h)")
                    } else { resumeOnce(returning: nil) }
                } else if case .failed = state { resumeOnce(returning: nil) }
            }
            conn.start(queue: .global())
            Task { try? await Task.sleep(for: .seconds(3)); resumeOnce(returning: nil) }
        }
    }

    // MARK: - Public API

    func findPeers(infoHash: Data) async {
        let closest = closestNodes(to: infoHash, k: Self.k)
        let targets = closest.isEmpty ? routingTable.prefix(Self.alpha).map { $0 } : Array(closest.prefix(Self.alpha))
        for node in targets {
            await sendGetPeers(to: node, infoHash: infoHash)
        }
    }

    func announcePeer(infoHash: Data, port: UInt16) async {
        for node in closestNodes(to: infoHash, k: Self.k) {
            if let token = tokenSecrets[node.ip] {
                await sendAnnouncePeer(to: node, infoHash: infoHash, port: port, token: token)
            }
        }
    }

    // MARK: - Message sending

    private func sendPing(to node: DHTNodeInfo) async {
        let tx = randomTx()
        let msg = BValue.dict([
            ("t", .bytes(tx)),
            ("y", .bytes(Data("q".utf8))),
            ("q", .bytes(Data("ping".utf8))),
            ("a", .dict([("id", .bytes(nodeId))]))
        ])
        send(Bencode.encode(msg), to: node)
    }

    private func sendFindNode(to node: DHTNodeInfo, target: Data) async {
        let tx = randomTx()
        let msg = BValue.dict([
            ("t", .bytes(tx)),
            ("y", .bytes(Data("q".utf8))),
            ("q", .bytes(Data("find_node".utf8))),
            ("a", .dict([
                ("id",     .bytes(nodeId)),
                ("target", .bytes(target))
            ]))
        ])
        send(Bencode.encode(msg), to: node)
    }

    private func sendGetPeers(to node: DHTNodeInfo, infoHash: Data) async {
        let tx = randomTx()
        // Track which info_hash this tx corresponds to so we can route the response
        pendingGetPeers[tx] = infoHash
        // Prune old entries to avoid unbounded growth
        if pendingGetPeers.count > 500 { pendingGetPeers.removeAll() }
        let msg = BValue.dict([
            ("t", .bytes(tx)),
            ("y", .bytes(Data("q".utf8))),
            ("q", .bytes(Data("get_peers".utf8))),
            ("a", .dict([
                ("id",        .bytes(nodeId)),
                ("info_hash", .bytes(infoHash))
            ]))
        ])
        send(Bencode.encode(msg), to: node)
    }

    private func sendAnnouncePeer(to node: DHTNodeInfo, infoHash: Data, port: UInt16, token: Data) async {
        let tx = randomTx()
        let msg = BValue.dict([
            ("t", .bytes(tx)),
            ("y", .bytes(Data("q".utf8))),
            ("q", .bytes(Data("announce_peer".utf8))),
            ("a", .dict([
                ("id",           .bytes(nodeId)),
                ("implied_port", .int(1)),
                ("info_hash",    .bytes(infoHash)),
                ("port",         .int(Int(port))),
                ("token",        .bytes(token))
            ]))
        ])
        send(Bencode.encode(msg), to: node)
    }

    private func respondPing(tx: Data, to node: DHTNodeInfo) {
        let msg = BValue.dict([
            ("t", .bytes(tx)),
            ("y", .bytes(Data("r".utf8))),
            ("r", .dict([("id", .bytes(nodeId))]))
        ])
        send(Bencode.encode(msg), to: node)
    }

    private func respondGetPeers(tx: Data, to node: DHTNodeInfo, peers: [DHTNodeInfo]) {
        let token = makeToken(for: node.ip)
        let nodesData = peers.prefix(Self.k).reduce(Data()) { acc, n in
            var d = acc
            d.append(n.id)
            guard let parts = n.ip.split(separator: ".").compactMap({ UInt8($0) }) as? [UInt8],
                  parts.count == 4 else { return d }
            d.append(contentsOf: parts)
            d.appendUInt16(n.port)
            return d
        }
        let msg = BValue.dict([
            ("t", .bytes(tx)),
            ("y", .bytes(Data("r".utf8))),
            ("r", .dict([
                ("id",    .bytes(nodeId)),
                ("token", .bytes(token)),
                ("nodes", .bytes(nodesData))
            ]))
        ])
        send(Bencode.encode(msg), to: node)
    }

    // MARK: - Receive

    private func handlePacket(_ data: Data, from ip: String, port: UInt16) async {
        guard let msg = try? Bencode.decode(data) else { return }
        let type = msg["y"]?.string ?? ""
        let tx   = msg["t"]?.data ?? Data()
        let sender = DHTNodeInfo(
            id: msg["a"]?["id"]?.data ?? msg["r"]?["id"]?.data ?? Data(repeating: 0, count: 20),
            ip: ip, port: port)

        addNode(sender)

        switch type {
        case "q": await handleQuery(msg: msg, tx: tx, from: sender)
        case "r": await handleResponse(msg: msg, tx: tx, from: sender)
        default: break
        }
    }

    private func handleQuery(msg: BValue, tx: Data, from node: DHTNodeInfo) async {
        let q = msg["q"]?.string ?? ""
        switch q {
        case "ping":
            respondPing(tx: tx, to: node)
        case "find_node":
            let target = msg["a"]?["target"]?.data ?? Data()
            respondGetPeers(tx: tx, to: node, peers: closestNodes(to: target, k: Self.k))
        case "get_peers":
            let infoHash = msg["a"]?["info_hash"]?.data ?? Data()
            respondGetPeers(tx: tx, to: node, peers: closestNodes(to: infoHash, k: Self.k))
        case "announce_peer":
            respondPing(tx: tx, to: node)
        default: break
        }
    }

    private func handleResponse(msg: BValue, tx: Data, from node: DHTNodeInfo) async {
        guard let r = msg["r"] else { return }

        // Store token for future announce_peer calls
        if let token = r["token"]?.data {
            tokenSecrets[node.ip] = token
        }

        // Look up which info_hash this response is for (only set for get_peers queries)
        let infoHash = pendingGetPeers[tx]

        // Compact peer list (values) — only present when node has peers for that info_hash
        if let values = r["values"]?.list, let hash = infoHash {
            var peers: [(String, UInt16)] = []
            for v in values {
                guard let d = v.data else { continue }
                if d.count == 6 {
                    let ip = "\(d[0]).\(d[1]).\(d[2]).\(d[3])"
                    let port = UInt16(d[4]) << 8 | UInt16(d[5])
                    peers.append((ip, port))
                } else if d.count == 18 {
                    var addr = [UInt8](repeating: 0, count: 16)
                    for j in 0..<16 { addr[j] = d[j] }
                    let ip = IPv6ToString(addr)
                    let port = UInt16(d[16]) << 8 | UInt16(d[17])
                    peers.append((ip, port))
                }
            }
            if !peers.isEmpty {
                // Route peers only to the torrent that requested them — not all torrents
                DHTBus.shared.dispatch(infoHash: hash, peers: peers)
            }
        }

        // Compact node list — add to routing table, and continue iterative lookup
        var newNodes: [DHTNodeInfo] = []
        if let nodes = r["nodes"]?.data {
            var i = 0
            while i + 26 <= nodes.count {
                let id   = Data(nodes[i..<(i+20)])
                let ip   = "\(nodes[i+20]).\(nodes[i+21]).\(nodes[i+22]).\(nodes[i+23])"
                let port = UInt16(nodes[i+24]) << 8 | UInt16(nodes[i+25])
                let n = DHTNodeInfo(id: id, ip: ip, port: port)
                addNode(n); newNodes.append(n)
                i += 26
            }
        }
        if let nodes6 = r["nodes6"]?.data {
            var i = 0
            while i + 38 <= nodes6.count {
                let id = Data(nodes6[i..<(i+20)])
                var addr = [UInt8](repeating: 0, count: 16)
                for j in 0..<16 { addr[j] = nodes6[i+20+j] }
                let ip = IPv6ToString(addr)
                let port = UInt16(nodes6[i+36]) << 8 | UInt16(nodes6[i+37])
                let n = DHTNodeInfo(id: id, ip: ip, port: port)
                addNode(n); newNodes.append(n)
                i += 38
            }
        }

        // Iterative get_peers: when we receive closer nodes but no peers yet,
        // continue the lookup towards those nodes.
        if let hash = infoHash, !newNodes.isEmpty {
            let closest = closestNodes(to: hash, k: 3)
            for n in closest.prefix(Self.alpha) {
                await sendGetPeers(to: n, infoHash: hash)
            }
        }
    }

    // MARK: - Routing table

    private func addNode(_ node: DHTNodeInfo) {
        guard node.id.count == 20, !node.ip.isEmpty, node.port > 0 else { return }
        if routingTable.contains(where: { $0.id == node.id }) { return }
        routingTable.append(node)
        if routingTable.count > Self.maxNodes { routingTable.removeFirst() }
        // Throttled persistence: save at most once per 60s
        let now = Date.now
        if now.timeIntervalSince(lastRoutingSave) > 60 {
            lastRoutingSave = now
            saveRoutingTable()
        }
    }

    private func closestNodes(to target: Data, k: Int) -> [DHTNodeInfo] {
        routingTable
            .sorted { xorDist($0.id, target).lexicographicallyPrecedes(xorDist($1.id, target)) }
            .prefix(k)
            .map { $0 }
    }

    // MARK: - Routing table persistence

    private func saveRoutingTable(force: Bool = false) {
        let nodes = routingTable.prefix(200).map { n -> [String: Any] in
            ["id": n.id.hexString, "ip": n.ip, "port": Int(n.port)]
        }
        if let json = try? JSONSerialization.data(withJSONObject: nodes) {
            UserDefaults.standard.set(json, forKey: "dht.routingTable")
        }
    }

    private func loadRoutingTable() {
        guard let json = UserDefaults.standard.data(forKey: "dht.routingTable"),
              let array = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]]
        else { return }
        for node in array {
            guard let idHex = node["id"] as? String,
                  let id   = Data(hex: idHex), id.count == 20,
                  let ip   = node["ip"]   as? String,
                  let port = node["port"] as? Int
            else { continue }
            routingTable.append(DHTNodeInfo(id: id, ip: ip, port: UInt16(port)))
        }
        print("[DHT] Loaded \(routingTable.count) nodes from cache")
    }

    // MARK: - Send helper

    private func send(_ data: Data, to node: DHTNodeInfo) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(node.ip),
            port: NWEndpoint.Port(rawValue: node.port)!
        )
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.start(queue: .global())
        conn.send(content: data, completion: .idempotent)
    }

    private func randomTx() -> Data {
        Data((0..<2).map { _ in UInt8.random(in: 0...255) })
    }

    private func makeToken(for ip: String) -> Data {
        var secret = Data(ip.utf8)
        secret.append(contentsOf: nodeId.prefix(4))
        return Data(Insecure.SHA1.hash(data: secret).prefix(8))
    }

    private func xorDist(_ a: Data, _ b: Data) -> Data {
        let len = min(a.count, b.count)
        return Data((0..<len).map { a[$0] ^ b[$0] })
    }

    private func IPv6ToString(_ addr: [UInt8]) -> String {
        var str = ""
        for i in stride(from: 0, to: 16, by: 2) {
            let val = UInt16(addr[i]) << 8 | UInt16(addr[i+1])
            str += String(format: "%x", val)
            if i < 14 { str += ":" }
        }
        return str
    }
}

struct DHTNodeInfo {
    let id: Data
    let ip: String
    let port: UInt16
}

struct DHTResponse {
    var peers: [(String, UInt16)]
    var nodes: [DHTNodeInfo]
}

// Lightweight event bus: DHT peers reach the right TorrentHandle by info-hash.
final class DHTBus {
    static let shared = DHTBus()
    private var listeners: [(Data, ([(String, UInt16)]) -> Void)] = []

    func register(infoHash: Data, handler: @escaping ([(String, UInt16)]) -> Void) {
        listeners.removeAll { $0.0 == infoHash }
        listeners.append((infoHash, handler))
    }
    func unregister(infoHash: Data) {
        listeners.removeAll { $0.0 == infoHash }
    }
    /// Dispatch peers only to the torrent with the matching info-hash.
    func dispatch(infoHash: Data, peers: [(String, UInt16)]) {
        for (hash, handler) in listeners where hash == infoHash { handler(peers) }
    }
}

