import Foundation
import Network

/// Coordinates downloading and seeding a single torrent: tracker announces,
/// peer connections, piece requests, disk I/O, and upload/choke algorithm.
public actor DownloadCoordinator {
    private let torrent: TorrentFile
    private let pieceManager: PieceManager
    private let diskMapper: DiskMapper
    private let trackerSession: TrackerSession
    private let savePath: String

    private var peerBitfields: [String: Set<Int>] = [:]
    private var peers: [String: PeerConnection] = [:]
    private var peerPieces: [String: Int] = [:]
    private var assignedPieces: Set<Int> = []
    private var pieceAssignedAt: [Int: Date] = [:]
    private var completedPieces: Set<Int> = []     // resume: which pieces are done
    private var pieceFrequency: [Int: Int] = [:]   // rarest-first: peer count per piece
    private var peerHashFailures: [String: Int] = [:]  // ban tracking: strike count per peer
    private var bannedPeers: Set<String> = []          // banned peer keys
    private var spawnedPeers: Set<String> = []          // peers with a handlePeer task spawned
    private var pieceBlockSources: [Int: [Int: String]] = [:]  // piece → blockBegin → peerKey
    private var fileHandles: [FileHandle]?
    private var completionContinuation: CheckedContinuation<Void, Error>?
    private var isShutdown = false
    private var totalUploaded: Int64 = 0
    private var totalDownloaded: Int64 = 0
    private var listener: NWListener?

    // Seeding state
    private var uploadRate: [String: [(timestamp: Date, bytes: Int)]] = [:]
    private var interestedPeers: Set<String> = []
    private var unchokedPeers: Set<String> = []
    private var lastChokeRound: Date = .distantPast

    public init(torrent: TorrentFile, savePath: String) {
        self.torrent = torrent
        self.savePath = savePath

        self.pieceManager = PieceManager(
            pieceCount: torrent.pieces.count,
            pieceLength: torrent.pieceLength,
            totalSize: torrent.totalSize,
            expectedHashes: torrent.pieces
        )

        self.diskMapper = DiskMapper(
            files: torrent.files,
            pieceLength: torrent.pieceLength
        )

        self.trackerSession = TrackerSession(
            infoHash: torrent.infoHash,
            peerID: PeerID.current,
            port: 6881,
            announce: torrent.announce,
            announceList: torrent.announceList,
            totalSize: torrent.totalSize
        )
    }

    private func resumeFilePath() -> String {
        "\(savePath)/.canopy_resume"
    }

    private func loadResumeData() async {
        let path = resumeFilePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let indices = try? JSONDecoder().decode([Int].self, from: data) else { return }
        for piece in indices {
            await pieceManager.markHave(piece: piece)
            completedPieces.insert(piece)
        }
    }

    private func saveResumeData() {
        let path = resumeFilePath()
        guard let data = try? JSONEncoder().encode(completedPieces.sorted()) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Download the entire torrent. Returns when complete.
    /// Call `seed()` afterwards to serve uploads to the swarm.
    public func download() async throws {
        await loadResumeData()
        fileHandles = try diskMapper.openFiles(at: savePath)

        let response = try await trackerSession.announce()
        print("[Coordinator] Tracker returned \(response.peers.count) peers, interval=\(response.interval)")
        guard !response.peers.isEmpty else { throw DownloadError.noPeers }

        for peer in response.peers { // try all returned peers
            let key = "\(peer.ip):\(peer.port)"
            let conn = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
            peers[key] = conn
            print("[Coordinator] Connecting to \(key)")
        }

        // Suspend until download completes, re-announcing if all peers drop
        try await withCheckedThrowingContinuation { cont in
            completionContinuation = cont
            Task {
                while await !pieceManager.isComplete {
                    if await peers.isEmpty {
                        print("[Coordinator] 🔄 All peers dropped — re-announcing...")
                        if let response = try? await trackerSession.announce(uploaded: totalUploaded, downloaded: totalDownloaded) {
                            for peer in response.peers {
                                let key = "\(peer.ip):\(peer.port)"
                                if bannedPeers.contains(key) { continue }
                                let conn = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
                                peers[key] = conn
                            }
                        }
                    }
                    // Spawn tasks for any peers not yet connected, cap at 50 total active
                    let maxPeers = 50
                    let alreadyActive = peerBitfields.count
                    var spawned = 0
                    for (key, conn) in peers {
                        if alreadyActive + spawned >= maxPeers { break }
                        if bannedPeers.contains(key) { continue }
                        if !spawnedPeers.contains(key) {
                            spawnedPeers.insert(key)
                            Task { await self.handlePeer(key: key, conn: conn) }
                            spawned += 1
                        }
                    }
                    // Choke algorithm runs every 30s (during download, keeps peers open for upload too)
                    if Date().timeIntervalSince(lastChokeRound) >= 30 {
                        lastChokeRound = Date()
                        runChokeAlgorithm()
                    }
                    try? await Task.sleep(for: .seconds(10))
                    // Check for stall — re-queue pieces taking >30s
                    let now = Date()
                    let stale = pieceAssignedAt.filter { now.timeIntervalSince($0.value) > 30 }.map(\.key)
                    for piece in stale {
                        await pieceManager.cancelPending(for: piece)
                        assignedPieces.remove(piece)
                        pieceAssignedAt.removeValue(forKey: piece)
                        pieceBlockSources.removeValue(forKey: piece)
                        if let peerKey = peerPieces.first(where: { $0.value == piece })?.key {
                            peerPieces.removeValue(forKey: peerKey)
                        }
                        print("[Coordinator] ⏱ Piece \(piece) timed out, re-queuing")
                    }
                }
                // Download complete — signal caller but keep connections alive for seeding
                try? FileManager.default.removeItem(atPath: resumeFilePath())
                await trackerSession.completed()
                // We're done downloading — tell peers we're no longer interested
                for p in peers.values { try? await p.send(.notInterested) }
                if let c = completionContinuation {
                    completionContinuation = nil
                    c.resume()
                }
            }
        }
    }

    private func handlePeer(key: String, conn: PeerConnection, inboundStream: AsyncStream<PeerMessage>? = nil) async {
        let stream: AsyncStream<PeerMessage>
        if let s = inboundStream {
            stream = s
            print("[Coordinator] 🔗 Handling inbound \(key)")
        } else {
            do {
                stream = try await conn.connect()
            } catch {
                print("[Coordinator] ⚠️ Failed to connect to \(key): \(error)")
                peers.removeValue(forKey: key)
                return
            }
            print("[Coordinator] ✅ Connected to \(key)")
        }
        // Send our bitfield first (BEP 3: must be first message after handshake if we have pieces)
        let bf = await pieceManager.encodedBitfield()
        if !bf.isEmpty { try? await conn.send(.bitfield(bf)) }
        if await pieceManager.isComplete {
            try? await conn.send(.notInterested)
        } else {
            try? await conn.send(.interested)
        }
        // BEP 10: send extension handshake if peer supports it
        let reserved = await conn.peerReservedBytes
        assert(reserved.isEmpty || reserved.count == 8, "Malformed reserved bytes: \(reserved.count)")
        if reserved.isEmpty {
            print("[Coordinator] ⚠️ Reserved bytes not yet set for \(key) — skipping extension handshake")
        } else if (reserved[5] & 0x10) != 0 {
            try? await conn.send(.extended(id: 0, data: buildExtensionHandshake()))
        } else {
            print("[Coordinator] ℹ️ No extension protocol from \(key)")
        }

        // Send keepalive every 90s to prevent peer timeout
        let keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                if Task.isCancelled { break }
                try? await conn.send(.keepAlive)
            }
        }
        defer { keepaliveTask.cancel() }

        for await msg in stream {
            switch msg {

            case .bitfield(let bf):
                var peerSet = Set<Int>()
                for (byteIdx, byte) in bf.enumerated() {
                    for bit in 0..<8 {
                        if (byte >> (7 - bit)) & 1 == 1 {
                            let pieceIdx = byteIdx * 8 + bit
                            guard pieceIdx < torrent.pieces.count else { continue }
                            peerSet.insert(pieceIdx)
                            pieceFrequency[pieceIdx, default: 0] += 1
                        }
                    }
                }
                peerBitfields[key] = peerSet
                if await !conn.isChoked {
                    await requestBlocks(key: key, conn: conn)
                }

            case .unchoke:
                print("[Coordinator] ✨ Unchoked by \(key)")
                await requestBlocks(key: key, conn: conn)

            case .piece(let piece, let begin, let data):
                print("[Coordinator] 📦 Piece(\(piece), begin=\(begin), len=\(data.count)) from \(key)")
                await pieceManager.storeBlock(piece: piece, begin: begin, data: data)
                totalDownloaded += Int64(data.count)
                pieceBlockSources[piece, default: [:]][begin] = key
                if let currentPiece = peerPieces[key], currentPiece == piece {
                    await requestBlocks(key: key, conn: conn)
                }
                let result = await pieceManager.tryAssemble(piece: piece)
                switch result {
                case .verified(let data):
                    pieceBlockSources.removeValue(forKey: piece)
                    assignedPieces.remove(piece)
                    let otherPeers = peerPieces.filter { $0.value == piece && $0.key != key }
                    for (k, _) in otherPeers {
                        peerPieces.removeValue(forKey: k)
                        let pieceSize = (piece == torrent.pieces.count - 1)
                            ? Int(torrent.totalSize - (Int64(piece) * torrent.pieceLength))
                            : Int(torrent.pieceLength)
                        var offset = 0
                        while offset < pieceSize {
                            try? await peers[k]?.send(.cancel(piece: piece, begin: offset, length: min(blockSize, pieceSize - offset)))
                            offset += blockSize
                        }
                    }
                    peerPieces.removeValue(forKey: key)
                    pieceAssignedAt.removeValue(forKey: piece)
                    await writePieceToDisk(piece: piece, data: data)
                    completedPieces.insert(piece)
                    saveResumeData()
                    for (k, c) in peers where k != key { try? await c.send(.have(piece: piece)) }
                    await requestBlocks(key: key, conn: conn)

                case .hashMismatch:
                    if let sources = pieceBlockSources.removeValue(forKey: piece) {
                        let contributors = Set(sources.values)
                        for peerKey in contributors {
                            peerHashFailures[peerKey, default: 0] += 1
                            let strikes = peerHashFailures[peerKey]!
                            print("[Coordinator] ⚠️ Hash failure from \(peerKey) — strike \(strikes)/3")
                            if strikes >= 3 {
                                print("[Coordinator] 🚫 Banning \(peerKey) for repeated hash failures")
                                bannedPeers.insert(peerKey)
                                if let p = peers.removeValue(forKey: peerKey) {
                                    await p.disconnect()
                                }
                                if let bf = peerBitfields.removeValue(forKey: peerKey) {
                                    for p in bf { pieceFrequency[p, default: 1] -= 1 }
                                }
                                if let assignedPiece = peerPieces.removeValue(forKey: peerKey) {
                                    await pieceManager.cancelPending(for: assignedPiece)
                                    assignedPieces.remove(assignedPiece)
                                    pieceAssignedAt.removeValue(forKey: assignedPiece)
                                }
                            }
                        }
                    }

                case .incomplete:
                    break  // not all blocks arrived yet
                }
            case .have(let piece):
                guard piece < torrent.pieces.count else { break }
                peerBitfields[key, default: []].insert(piece)
                pieceFrequency[piece, default: 0] += 1

            case .choke:
                if let piece = peerPieces[key] {
                    await pieceManager.cancelPending(for: piece)
                    assignedPieces.remove(piece)
                    peerPieces.removeValue(forKey: key)
                    pieceAssignedAt.removeValue(forKey: piece)
                }

            case .interested:
                interestedPeers.insert(key)
                // Immediately try to unchoke an interested peer if we have slots
                if unchokedPeers.count < 4 && !unchokedPeers.contains(key) {
                    unchokedPeers.insert(key)
                    try? await conn.send(.unchoke)
                }

            case .notInterested:
                interestedPeers.remove(key)

            case .request(let piece, let begin, let length):
                // Only serve if we have the piece and the peer is unchoked
                guard await pieceManager.hasPiece(piece), unchokedPeers.contains(key) else { break }
                if let data = readBlockFromDisk(piece: piece, begin: begin, length: length) {
                    try? await conn.send(.piece(piece: piece, begin: begin, data: data))
                    let now = Date()
                    uploadRate[key, default: []].append((now, data.count))
                    totalUploaded += Int64(data.count)
                    // Prune entries older than 20s
                    uploadRate[key] = uploadRate[key]?.filter { now.timeIntervalSince($0.timestamp) <= 20 }
                }

            case .extended(0, let data):
                // Extension handshake response
                if let ext = parseExtensionHandshake(from: data) {
                    await conn.setExtensions(ext)
                    print("[Coordinator] 🔌 Extensions from \(key): ut_pex=\(ext.utPEX != nil) ut_metadata=\(ext.utMetadata != nil) metadata_size=\(ext.metadataSize ?? 0)")
                }

            case .extended(let id, _):
                print("[Coordinator] Unhandled extended msg id=\(id) from \(key)")

            default:
                break
            }
        }
        // Peer disconnected — clean up and check if we're out of peers
        print("[Coordinator] ⛔ Disconnected from \(key)")
        peers.removeValue(forKey: key)
        if let bf = peerBitfields.removeValue(forKey: key) {
            for piece in bf {
                pieceFrequency[piece] = max(0, (pieceFrequency[piece] ?? 1) - 1)
            }
        }
        if let piece = peerPieces[key] {
            await pieceManager.cancelPending(for: piece)
            assignedPieces.remove(piece)
            peerPieces.removeValue(forKey: key)
        }
        uploadRate.removeValue(forKey: key)
        interestedPeers.remove(key)
        unchokedPeers.remove(key)
        spawnedPeers.remove(key)
    }

    private func requestBlocks(key: String, conn: PeerConnection) async {
        if let piece = peerPieces[key] {
            let requests = await pieceManager.nextBlockRequests(for: piece)
            for req in requests {
                try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
            }
            return
        }

        // Endgame: >95% done — request remaining pieces from ALL peers
        if await pieceManager.progress > 0.95 {
            guard let piece = await pieceManager.nextNeededPiece(excluding: []) else { return }
            peerPieces[key] = piece
            pieceAssignedAt[piece] = Date()
            let requests = await pieceManager.nextBlockRequests(for: piece)
            for req in requests {
                try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
            }
            return
        }

        // Rarest-first: pick the piece this peer has that fewest OTHER peers also have
        let peersPieces = peerBitfields[key] ?? []
        guard let piece = await rarestPiece(available: peersPieces, excluding: assignedPieces) else { return }

        assignedPieces.insert(piece)
        peerPieces[key] = piece
        pieceAssignedAt[piece] = Date()

        let requests = await pieceManager.nextBlockRequests(for: piece)
        for req in requests {
            try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
        }
    }

    private func rarestPiece(available: Set<Int>, excluding: Set<Int>) async -> Int? {
        guard !available.isEmpty else {
            return await pieceManager.nextNeededPiece(excluding: excluding)
        }
        var best: Int?; var bestCount = Int.max
        for piece in available {
            guard !excluding.contains(piece), !(await pieceManager.hasPiece(piece)) else { continue }
            let freq = pieceFrequency[piece] ?? 0
            if freq < bestCount { bestCount = freq; best = piece }
        }
        return best
    }

    private func writePieceToDisk(piece: Int, data: Data) async {
        guard let handles = fileHandles else { return }
        let segments = diskMapper.map(piece: piece, blockBegin: 0, blockLength: data.count)
        var cursor = 0
        for seg in segments {
            let chunk = data.subdata(in: cursor..<(cursor + seg.length))
            try? handles[seg.fileIndex].seek(toOffset: UInt64(seg.fileOffset))
            try? handles[seg.fileIndex].write(contentsOf: chunk)
            cursor += seg.length
        }
    }

    private func readBlockFromDisk(piece: Int, begin: Int, length: Int) -> Data? {
        guard let handles = fileHandles else { return nil }
        let segments = diskMapper.map(piece: piece, blockBegin: begin, blockLength: length)
        var result = Data(capacity: length)
        for seg in segments {
            guard seg.fileIndex < handles.count else { return nil }
            do {
                try handles[seg.fileIndex].seek(toOffset: UInt64(seg.fileOffset))
                var remaining = seg.length
                while remaining > 0 {
                    guard let part = try handles[seg.fileIndex].read(upToCount: remaining),
                          !part.isEmpty else { return nil }
                    result.append(part)
                    remaining -= part.count
                }
            } catch {
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Run the choke algorithm: unchoke top 4 peers by upload rate,
    /// plus one random optimistic unchoke for choked interested peers.
    private func runChokeAlgorithm() {
        let now = Date()
        // Calculate upload rates (bytes/sec) over last 20s window
        // Seed with zero for all interested peers so new peers aren't invisible
        var rateMap: [String: Double] = [:]
        for key in interestedPeers { rateMap[key] = 0.0 }
        for (key, history) in uploadRate {
            let recent = history.filter { now.timeIntervalSince($0.timestamp) <= 20 }
            let totalBytes = recent.reduce(0) { $0 + $1.bytes }
            let elapsed = recent.isEmpty ? 20.0 : max(now.timeIntervalSince(recent[0].timestamp), 1)
            rateMap[key] = Double(totalBytes) / elapsed
        }
        var rates = rateMap.map { (key: $0.key, rate: $0.value) }
        rates.sort { $0.rate > $1.rate }

        // Top 4 by upload rate (tit-for-tat)
        let top4 = Set(rates.prefix(4).map(\.key))

        // Optimistic unchoke: one random choked interested peer
        let choked = Set(peers.keys).subtracting(unchokedPeers)
        let eligible = choked.intersection(interestedPeers)
        let optimistic = eligible.randomElement().map { Set([$0]) } ?? []

        let newUnchoked = top4.union(optimistic)

        // Apply changes — unchoke or choke each peer
        for key in peers.keys {
            let shouldUnchoke = newUnchoked.contains(key)
            if shouldUnchoke, !unchokedPeers.contains(key) {
                Task { try? await peers[key]?.send(.unchoke) }
                print("[Coordinator] 🌱 Unchoked \(key)")
            } else if !shouldUnchoke, unchokedPeers.contains(key) {
                Task { try? await peers[key]?.send(.choke) }
                print("[Coordinator] 🔒 Choked \(key)")
            }
        }
        unchokedPeers = newUnchoked
        print("[Coordinator] Choke round: \(unchokedPeers.count) unchoked (\(top4.count) top, \(optimistic.count) optimistic)")
    }

    /// Start listening for inbound peer connections on the announced port.
    public func startListener() throws {
        let port = NWEndpoint.Port(rawValue: 6881)!
        listener = try NWListener(using: .tcp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            guard let self = self else { connection.cancel(); return }
            Task { await self.acceptInbound(connection: connection) }
        }
        listener?.start(queue: .global())
        print("[Coordinator] 👂 Listening on port 6881")
    }

    private func acceptInbound(connection: NWConnection) async {
        let peerIP: String
        let peerPort: UInt16
        switch connection.endpoint {
        case .hostPort(let host, let port):
            peerIP = "\(host)"
            peerPort = port.rawValue
        default:
            connection.cancel()
            return
        }
        let key = "\(peerIP):\(peerPort)"
        let conn = PeerConnection(peer: Peer(ip: peerIP, port: peerPort), infoHash: torrent.infoHash, localPeerID: PeerID.current)
        do {
            let stream = try await conn.accept(connection: connection)
            if peerBitfields.count >= 50 { await conn.disconnect(); return }
            print("[Coordinator] 🔗 Inbound connection from \(key)")
            peers[key] = conn
            Task { await self.handlePeer(key: key, conn: conn, inboundStream: stream) }
        } catch {
            print("[Coordinator] ⚠️ Inbound handshake failed from \(key): \(error)")
            connection.cancel()
        }
    }
    /// Call shutdown() to stop.
    public func seed() async {
        guard fileHandles != nil else { return }
        // Announce once so tracker knows we're seeding
        try? await trackerSession.announce(uploaded: totalUploaded, downloaded: totalDownloaded, left: 0)
        print("[Coordinator] 🌱 Entering seeding mode (inbound only)")
        while !isShutdown {
            if Task.isCancelled { break }
            if Date().timeIntervalSince(lastChokeRound) >= 30 {
                lastChokeRound = Date()
                runChokeAlgorithm()
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Shut down seeding: close all connections and file handles.
    public func shutdown() async {
        print("[Coordinator] 🛑 Shutting down")
        isShutdown = true
        if let cont = completionContinuation {
            completionContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        listener?.cancel()
        listener = nil
        for p in peers.values { await p.disconnect() }
        peers.removeAll()
        peerBitfields.removeAll()
        peerPieces.removeAll()
        assignedPieces.removeAll()
        pieceAssignedAt.removeAll()
        pieceFrequency.removeAll()
        peerHashFailures.removeAll()
        pieceBlockSources.removeAll()
        uploadRate.removeAll()
        interestedPeers.removeAll()
        unchokedPeers.removeAll()
        fileHandles?.forEach { try? $0.close() }
        fileHandles = nil
        await trackerSession.stop()
    }
}

public enum DownloadError: Error {
    case noPeers
    case allPeersDisconnected
}
