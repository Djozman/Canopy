import Foundation
import Network

// MARK: - DHT Session

public actor DHTSession {
    public let nodeID: NodeID
    private let routingTable: RoutingTable
    private var listener: NWListener?
    private var currentSecret: Data
    private var previousSecret: Data?
    private var peerCache: [Data: [(peer: Peer, storedAt: Date)]] = [:]
    private var tokenCache: [String: Data] = [:]
    private var rateLimitCounts: [String: (count: Int, windowStart: Date)] = [:]  // per-IP rate limiter
    private var txCounter: UInt16 = 0
    private var rotationTask: Task<Void, Never>?
    private var refreshLoopTask: Task<Void, Never>?

    public init(nodeID: NodeID, routingTable: RoutingTable) {
        self.nodeID = nodeID
        self.routingTable = routingTable
        let secret = DHTSession.generateSecret()
        self.currentSecret = secret
    }

    private static func generateSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &bytes)
        return Data(bytes)
    }

    private func startSecretRotation() {
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))  // libtorrent: 5 minutes
                guard let self = self else { break }
                await self.rotateSecret()
            }
        }
    }

    private func rotateSecret() {
        previousSecret = currentSecret
        currentSecret = Self.generateSecret()
        Log.dht.info("🔐 Secret rotated")
    }

    /// Convert an IP string to its compact binary form (4 bytes for IPv4, 16 for IPv6).
    /// Falls back to nil if parsing fails.
    private static func compactIP(from ip: String) -> Data {
        var addr = sockaddr_in()
        if ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 {
            return Data(bytes: &addr.sin_addr, count: 4)
        }
        var addr6 = sockaddr_in6()
        if ip.withCString({ inet_pton(AF_INET6, $0, &addr6.sin6_addr) }) == 1 {
            return Data(bytes: &addr6.sin6_addr, count: 16)
        }
        return Data()
    }

    private static let writeTokenSize = 4  // libtorrent: 4-byte tokens

    private func generateToken(for ip: String, infoHash: Data) -> Data {
        // BEP 5 §5: first 4 bytes of SHA1(secret + IP compact form + info_hash)
        var input = currentSecret
        input.append(Self.compactIP(from: ip))
        input.append(infoHash)
        let hash = SHA1.hash(input)
        return hash.prefix(Self.writeTokenSize)
    }

    private func validateToken(_ token: Data, for ip: String, infoHash: Data) -> Bool {
        guard token.count == Self.writeTokenSize else { return false }
        if generateToken(for: ip, infoHash: infoHash) == token { return true }
        // Check against previous secret
        if let prev = previousSecret {
            var prevInput = prev
            prevInput.append(Self.compactIP(from: ip))
            prevInput.append(infoHash)
            return SHA1.hash(prevInput).prefix(Self.writeTokenSize) == token
        }
        return false
    }

    // MARK: - Listener

    public func start(port: UInt16) throws {
        let port = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: .udp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            guard let self = self else { connection.cancel(); return }
            Task {
                do {
                    let data = try await connection.receive(minimumIncompleteLength: 1, maximumLength: 4096)
                    var ip: String = "unknown"
                    var port: UInt16 = 0
                    switch connection.endpoint {
                    case .hostPort(let host, let p):
                        ip = "\(host)"
                        port = p.rawValue
                    default: break
                    }
                    await self.handleIncoming(data: data, from: ip, port: port, connection: connection)
                } catch {
                    // connection closed or error — expected
                }
            }
        }
        listener?.start(queue: .global())
        startSecretRotation()
        startRefreshLoop()
        Log.dht.info("👂 Listening on port \(port.rawValue) (node \(self.nodeID.debugDescription))")
    }

    private func startRefreshLoop() {
        refreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard let self = self else { break }
                let buckets = await self.routingTable.allBuckets()
                for bucket in buckets {
                    let target = bucket.randomID()
                    _ = await self.findNode(target: target)
                }
            }
        }
    }

    // MARK: - Incoming Handler

    private func handleIncoming(data: Data, from ip: String, port: UInt16, connection: NWConnection) async {
        // Per-IP rate limiting (libtorrent: dos_blocker, 50 msgs/10s → block)
        let now = Date()
        if var entry = rateLimitCounts[ip] {
            if now.timeIntervalSince(entry.windowStart) > 10 {
                entry = (count: 0, windowStart: now)
            }
            entry.count += 1
            rateLimitCounts[ip] = entry
            if entry.count > 50 {
                return  // drop silently
            }
        } else {
            rateLimitCounts[ip] = (count: 1, windowStart: now)
        }
        guard let msg = parseDHTMessage(data) else { return }

        switch msg {
        case .query(let t, let type, let args):
            guard let senderIDData: Data = {
                guard let p = args.first(where: { $0.0 == "id" }),
                      case .string(let d) = p.1 else { return nil }
                return d
            }(), let senderID = NodeID(bytes: senderIDData) else { return }

            // Update routing table: this node contacted us
            await routingTable.markSeen(nodeID: senderID)
            _ = await routingTable.insert(nodeID: senderID, ip: ip, port: port)
            // Send appropriate response
            var response: Data = buildError(txID: t, code: 203, message: "Protocol error")
            switch type {
            case "ping":
                response = buildResponse(txID: t, ourID: nodeID, args: [])
            case "find_node":
                guard let targetData: Data = {
                    guard let p = args.first(where: { $0.0 == "target" }),
                          case .string(let d) = p.1 else { return nil }
                    return d
                }(), let targetID = NodeID(bytes: targetData) else { break }
                let closest = await routingTable.findClosest(to: targetID, k: 8)
                let nodesData = Data(closest.flatMap { encodeCompactNode(nodeID: $0.nodeID, ip: $0.ip, port: $0.port) })
                response = buildResponse(txID: t, ourID: nodeID, args: [("nodes", .string(nodesData))])
            case "get_peers":
                guard let infoHashData: Data = {
                    guard let p = args.first(where: { $0.0 == "info_hash" }),
                          case .string(let d) = p.1 else { return nil }
                    return d
                }() else { break }
                guard let targetID = NodeID(bytes: infoHashData) else { break }
                let token = generateToken(for: ip, infoHash: infoHashData)
                let closest = await routingTable.findClosest(to: targetID, k: 8)
                let nodesData = Data(closest.flatMap { encodeCompactNode(nodeID: $0.nodeID, ip: $0.ip, port: $0.port) })
                let cached = peerCache[infoHashData]?.filter { Date().timeIntervalSince($0.storedAt) < 1800 } ?? []
                var respArgs: [(String, BencodeValue)] = [("token", .string(token)), ("nodes", .string(nodesData))]
                if !cached.isEmpty {
                    let valuesList = BencodeValue.list(cached.map { .string(encodeCompactPeer($0.peer)) })
                    respArgs.append(("values", valuesList))
                }
                response = buildResponse(txID: t, ourID: nodeID, args: respArgs)
            case "announce_peer":
                guard let infoHashData: Data = {
                    guard let p = args.first(where: { $0.0 == "info_hash" }),
                          case .string(let d) = p.1 else { return nil }
                    return d
                }() else { break }
                let announcedToken: Data? = {
                    guard let p = args.first(where: { $0.0 == "token" }),
                          case .string(let d) = p.1 else { return nil }
                    return d
                }()
                // Validate token — must be present and valid
                guard let announcedToken, validateToken(announcedToken, for: ip, infoHash: infoHashData) else {
                    response = buildError(txID: t, code: 203, message: "Invalid token")
                    break
                }
                // Determine port
                let impliedPort: Bool = {
                    guard let p = args.first(where: { $0.0 == "implied_port" }),
                          case .integer(let v) = p.1 else { return false }
                    return v == 1
                }()
                let announcedPort: UInt16 = {
                    guard let p = args.first(where: { $0.0 == "port" }),
                          case .integer(let v) = p.1 else { return 6881 }
                    return UInt16(exactly: v) ?? 6881
                }()
                let port = impliedPort ? UInt16(connection.endpoint.port?.rawValue ?? announcedPort) : announcedPort
                let peer = Peer(ip: ip, port: port)
                let cache = peerCache[infoHashData, default: []]
                // Cap at 500 peers per info_hash (libtorrent dht_max_peers default)
                guard cache.count < 500 else {
                    response = buildError(txID: t, code: 203, message: "Too many peers")
                    break
                }
                peerCache[infoHashData, default: []].append((peer, Date()))
                // Prune stale entries for this infohash
                peerCache[infoHashData] = peerCache[infoHashData]?.filter {
                    Date().timeIntervalSince($0.storedAt) < 1800
                }
                response = buildResponse(txID: t, ourID: nodeID, args: [])
            default:
                response = buildError(txID: t, code: 204, message: "Unknown method")
            }
            try? await connection.send(content: response)

        case .response(_, _, _):
            break  // responses arrive via sendQuery's own connection, not through listener

        case .error(_, let code, let message):
            Log.dht.warning("⚠️ Error from \(ip): [\(code)] \(message)")
        }
    }

    private func pingRemote(ip: String, port: UInt16) async -> Bool {
        let txID = nextTxID()
        let data = buildPing(txID: txID, ourID: nodeID)
        do {
            _ = try await sendQuery(to: ip, port: port, txID: txID, data: data)
            return true
        } catch {
            return false
        }
    }

    private func makePinger() -> (@Sendable (String, UInt16) async -> Bool) {
        return { [weak self] ip, port in
            guard let self else { return false }
            return await self.pingRemote(ip: ip, port: port)
        }
    }

    // MARK: - Outgoing Queries

    private func nextTxID() -> Data {
        let id = txCounter
        txCounter = txCounter &+ 1
        return makeTransactionID(id)
    }

    /// Send a query to a remote node and wait for response on the same UDP socket.
    /// Same pattern as UDPTracker: send, then receive on the same connection.
    /// `expectedTxID` is validated against the response's `t` field per BEP 5.
    public func sendQuery(to ip: String, port: UInt16, txID: Data, data: Data) async throws -> DHTResponse {
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(integerLiteral: port), using: .udp)
        conn.start(queue: .global())
        defer { conn.cancel() }

        try await conn.send(content: data)
        let raw = try await withTimeout(seconds: 5) {
            try await conn.receive(minimumIncompleteLength: 1, maximumLength: 4096)
        }
        guard let msg = parseDHTMessage(raw) else { throw DHTError.invalidMessage }
        switch msg {
        case .response(let respTxID, let r, let token):
            guard respTxID == txID else { throw DHTError.invalidMessage }
            let resp = extractResponse(from: r)
            return DHTResponse(nodes: resp.nodes, values: resp.values, token: token)
        case .error(_, let code, let message):
            Log.dht.warning("⚠️ Error from \(ip): [\(code)] \(message)")
            throw DHTError.invalidMessage
        default:
            throw DHTError.invalidMessage
        }
    }

    /// Send a response back to a remote node.
    public func sendResponse(data: Data, to ip: String, port: UInt16) async throws {
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(integerLiteral: port), using: .udp)
        conn.start(queue: .global())
        try await conn.send(content: data)
        conn.cancel()
    }

    // MARK: - Iterative Lookup

    /// Find the K closest nodes to a target (iterative lookup).
    public func findNode(target: NodeID) async -> [NodeEntry] {
        var closest = await routingTable.findClosest(to: target, k: 8)
        var queried: Set<NodeID> = []
        let maxRounds = 10

        for _ in 0..<maxRounds {
            let preRoundTop = Set(closest.prefix(8).map(\.nodeID))
            let unqueried = closest.filter { !queried.contains($0.nodeID) }.prefix(3)
            if unqueried.isEmpty { break }

            let results = await withTaskGroup(of: DHTResponse?.self) { group in
                for node in unqueried {
                    queried.insert(node.nodeID)
                    let txID = nextTxID()
                    let data = buildFindNode(txID: txID, ourID: self.nodeID, target: target)
                    group.addTask {
                        do {
                            return try await self.sendQuery(to: node.ip, port: node.port, txID: txID, data: data)
                        } catch {
                            await self.routingTable.markFailed(nodeID: node.nodeID)
                            return nil
                        }
                    }
                }
                var responses: [DHTResponse] = []
                for await r in group { if let r { responses.append(r) } }
                return responses
            }

            // Collect new nodes and responses
            var newClosest = closest
            for resp in results {
                for node in resp.nodes {
                    _ = await routingTable.insert(nodeID: node.nodeID, ip: node.ip, port: node.port, pinger: makePinger())
                    newClosest.append(NodeEntry(
                        nodeIDBytes: node.nodeID.bytes, ip: node.ip, port: node.port,
                        failureCount: 0, lastSeen: Date()
                    ))
                }
            }

            // Sort, deduplicate, and check convergence
            let sorted = newClosest.sorted { a, b in
                a.nodeID.xor(target) < b.nodeID.xor(target)
            }
            var seenIDs = Set<NodeID>()
            closest = sorted.filter { seenIDs.insert($0.nodeID).inserted }

            // Convergence: K-closest unchanged after complete round
            let postRoundTop = Set(closest.prefix(8).map(\.nodeID))
            if postRoundTop == preRoundTop { break }
        }
        return Array(closest.prefix(8))
    }

    /// Get peers for an info hash.
    public func getPeers(infoHash: Data) async -> [Peer] {
        guard let targetID = NodeID(bytes: infoHash) else { return [] }
        let result = await findNode(target: targetID)
        // Try get_peers on the closest nodes
        var seen = Set<String>()
        var peers: [Peer] = []
        for node in result.prefix(8) {
            let txID = nextTxID()
            let data = buildGetPeers(txID: txID, ourID: nodeID, infoHash: infoHash)
            do {
                let resp = try await sendQuery(to: node.ip, port: node.port, txID: txID, data: data)
                if let token = resp.token {
                    tokenCache[node.ip] = token
                }
                for peer in resp.values where seen.insert("\(peer.ip):\(peer.port)").inserted {
                    peers.append(peer)
                }
                // Insert returned nodes into routing table
                for node in resp.nodes {
                    _ = await routingTable.insert(nodeID: node.nodeID, ip: node.ip, port: node.port, pinger: makePinger())
                }
            } catch {
                await routingTable.markFailed(nodeID: node.nodeID)
            }
        }
        return peers
    }

    /// Announce that we have a torrent.
    public func announcePeer(infoHash: Data, port: UInt16) async {
        guard let target = NodeID(bytes: infoHash) else { return }
        let closest = await routingTable.findClosest(to: target, k: 8)
        for node in closest {
            guard let token = tokenCache[node.ip] else { continue }
            let txID = nextTxID()
            let data = buildAnnouncePeer(txID: txID, ourID: nodeID, infoHash: infoHash, port: port, token: token)
            do {
                _ = try await sendQuery(to: node.ip, port: node.port, txID: txID, data: data)
                await routingTable.markSeen(nodeID: node.nodeID)
            } catch {
                await routingTable.markFailed(nodeID: node.nodeID)
            }
        }
    }

    // MARK: - Public RoutingTable wrappers

    public func loadRoutingTable() async { await routingTable.loadFromDisk() }
    public func saveRoutingTable() async { await routingTable.saveToDisk() }

    // MARK: - Shutdown

    public func shutdown() async {
        rotationTask?.cancel()
        rotationTask = nil
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        listener?.cancel()
        listener = nil
        Log.dht.info("🛑 Shutdown complete")
    }
}

// MARK: - Errors

public enum DHTError: Error {
    case timeout
    case invalidMessage
    case bootstrapFailed
}

// MARK: - NWEndpoint port helper

private extension NWEndpoint {
    var port: NWEndpoint.Port? {
        switch self {
        case .hostPort(_, let port): return port
        default: return nil
        }
    }
}
