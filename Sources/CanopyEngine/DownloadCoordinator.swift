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
    private var peerLookahead: [String: Int] = [:]  // second piece queued per peer for TCP pipeline
    private var assignedPieces: Set<Int> = []
    private var pieceAssignedAt: [Int: Date] = [:]
    private var completedPieces: Set<Int> = []     // resume: which pieces are done
    private var pieceFrequency: [Int: Int] = [:]   // rarest-first: peer count per piece
    private var peerHashFailures: [String: Int] = [:]  // ban tracking: strike count per peer
    private var bannedPeers: Set<String> = []          // banned peer keys
    private var spawnedPeers: Set<String> = []          // peers with a handlePeer task spawned
    private var peerLastMessageAt: [String: Date] = [:]
    private var peerChokedSince: [String: Date] = [:]
    private var peerLastBlockAt: [String: Date] = [:]
    private var peerConnectedAt: [String: Date] = [:]
    private var peerBlockCount: [String: Int] = [:]
    private var inflightPeers: Set<String> = []
    private var connectBoostRemaining = 30
    private var pieceBlockSources: [Int: [Int: String]] = [:]  // piece → blockBegin → peerKey
    private var fileHandles: [FileHandle?]?
    private var completionContinuation: CheckedContinuation<Void, Error>?
    private var isShutdown = false
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var totalUploaded: Int64 = 0
    private var totalDownloaded: Int64 = 0
    private var listener: NWListener?
    // PEX (BEP 11) state
    private var lastPEXSent: [String: Date] = [:]
    private var pexLastKnown: [String: Set<String>] = [:]

    // Seeding state
    private var uploadRate: [String: [(timestamp: Date, bytes: Int)]] = [:]
    private var interestedPeers: Set<String> = []
    private var unchokedPeers: Set<String> = []
    private var lastChokeRound: Date = .distantPast
    private var dhtSession: DHTSession?
    private var filePriorities: [Int: FilePriority] = [:]
    private let encryption: EngineSettings.EncryptionMode
    private let listenPort: UInt16
    private let maxPeers: Int
    private let uploadLimitKiB: Int
    private let downloadLimitKiB: Int

    public init(torrent: TorrentFile, savePath: String, dhtSession: DHTSession? = nil,
                filePriorities: [Int: FilePriority] = [:],
                encryption: EngineSettings.EncryptionMode = .preferred,
                listenPort: UInt16 = 6881,
                maxPeers: Int = 50,
                uploadLimitKiB: Int = 0,
                downloadLimitKiB: Int = 0) {
        self.torrent = torrent
        self.savePath = savePath
        self.dhtSession = dhtSession
        self.filePriorities = filePriorities
        self.encryption = encryption
        self.listenPort = listenPort
        self.maxPeers = maxPeers
        self.uploadLimitKiB = uploadLimitKiB
        self.downloadLimitKiB = downloadLimitKiB

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

    public func saveResumeData() {
        let path = resumeFilePath()
        guard let data = try? JSONEncoder().encode(completedPieces.sorted()) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Download the entire torrent. Returns when complete.
    /// Call `seed()` afterwards to serve uploads to the swarm.
    public func download() async throws {
        await loadResumeData()
        let skipped = Set(filePriorities.compactMap { $0.value == .dontDownload ? $0.key : nil })
        fileHandles = try diskMapper.openFiles(at: savePath, skippedFiles: skipped)

        let firstResponse = try? await trackerSession.announce()
        let trackerPeerList = firstResponse?.peers ?? []
        print("[Coordinator] Tracker returned \(trackerPeerList.count) peers")

        for peer in trackerPeerList {
            let key = "\(peer.ip):\(peer.port)"
            peers[key] = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
            print("[Coordinator] Connecting to \(key)")
        }

        // DHT peer supplement — always run in background when DHT is available
        if let dht = dhtSession, !torrent.isPrivate {
            Task {
                let dhtPeers = await dht.getPeers(infoHash: torrent.infoHash)
                for peer in dhtPeers {
                    let key = "\(peer.ip):\(peer.port)"
                    guard peers[key] == nil, !bannedPeers.contains(key) else { continue }
                    peers[key] = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
                }
                print("[Coordinator] DHT returned \(dhtPeers.count) peers")
            }
        }

        // If tracker failed and we can't use DHT (no session or private torrent), fail fast
        if peers.isEmpty && (dhtSession == nil || torrent.isPrivate) {
            throw DownloadError.noPeers
        }

        // Suspend until download completes, re-announcing if all peers drop
        try await withCheckedThrowingContinuation { cont in
            completionContinuation = cont
            Task {
                while await !pieceManager.isComplete {
                    // Pause gate — suspend the loop until resume() is called
                    if isPaused {
                        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                            pauseContinuation = c
                        }
                    }
                    if isShutdown { break }

                    let activePeers = peers.count
                    if activePeers < 5 {
                        // Use forceAnnounce to bypass the 30-min interval when we're starved for peers.
                        // forceAnnounce still respects min_interval (usually 60s or unset).
                        print("[Coordinator] 🔄 Low peers (\(activePeers)) — force re-announcing to tracker...")
                        let bytesLeft = max(0, torrent.totalSize - totalDownloaded)
                        if let response = try? await trackerSession.forceAnnounce(uploaded: totalUploaded, downloaded: totalDownloaded, left: bytesLeft) {
                            for peer in response.peers {
                                let key = "\(peer.ip):\(peer.port)"
                                if bannedPeers.contains(key) { continue }
                                peers[key] = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
                            }
                            print("[Coordinator] Re-announce returned \(response.peers.count) peers")
                        }
                        // Also query DHT in parallel
                        if let dht = dhtSession, !torrent.isPrivate {
                            Task {
                                let dhtPeers = await dht.getPeers(infoHash: torrent.infoHash)
                                for peer in dhtPeers {
                                    let key = "\(peer.ip):\(peer.port)"
                                    guard peers[key] == nil, !bannedPeers.contains(key) else { continue }
                                    peers[key] = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
                                }
                                print("[Coordinator] DHT re-query returned \(dhtPeers.count) peers")
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
                        await runChokeAlgorithm()
                    }
                    try? await Task.sleep(for: .seconds(10))
                    // Check for stall — re-queue pieces taking >30s
                    let now = Date()
                    let stale = pieceAssignedAt.filter { now.timeIntervalSince($0.value) > 30 }.map(\.key)
                    var stalePeerKeys: [String] = []
                    for piece in stale {
                        await pieceManager.cancelPending(for: piece)
                        assignedPieces.remove(piece)
                        pieceAssignedAt.removeValue(forKey: piece)
                        pieceBlockSources.removeValue(forKey: piece)
                        if let peerKey = peerPieces.first(where: { $0.value == piece })?.key {
                            peerPieces.removeValue(forKey: peerKey)
                            stalePeerKeys.append(peerKey)
                        }
                        print("[Coordinator] ⏱ Piece \(piece) timed out, re-queuing")
                    }
                    // Re-trigger block requests for peers that lost their stale piece assignment
                    for peerKey in stalePeerKeys {
                        if let conn = peers[peerKey] {
                            await requestBlocks(key: peerKey, conn: conn)
                        }
                    }
                }
                // Download complete — signal caller but keep connections alive for seeding
                try? FileManager.default.removeItem(atPath: resumeFilePath())
                await trackerSession.completed()
                // Announce to DHT that we have this torrent
                if let dht = dhtSession, !torrent.isPrivate {
                    Task { await dht.announcePeer(infoHash: torrent.infoHash, port: 6881) }
                }
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
        // BEP 10: extension handshake BEFORE bitfield (libtorrent order)
        let reserved = await conn.peerReservedBytes
        let supportsFast = reserved.count >= 8 && (reserved[7] & 0x04) != 0
        if !reserved.isEmpty, (reserved[5] & 0x10) != 0 {
            try? await conn.send(.extended(id: 0, data: buildExtensionHandshake(metadataSize: torrent.rawInfoDict.count)))
        }
        // Bitfield (use Fast Extension have_all when peer supports BEP 6)
        if await pieceManager.isComplete && supportsFast {
            try? await conn.send(.haveAll)
        } else {
            let bf = await pieceManager.encodedBitfield()
            if !bf.isEmpty { try? await conn.send(.bitfield(bf)) }
        }
        if await pieceManager.isComplete {
            try? await conn.send(.notInterested)
        } else {
            try? await conn.send(.interested)
        }

        // Send keepalive every 60s to prevent peer timeout (libtorrent: half of peer_timeout=120)
        let keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
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
                await disconnectIfRedundant(key: key)

            case .unchoke:
                print("[Coordinator] ✨ Unchoked by \(key)")
                await requestBlocks(key: key, conn: conn)

            case .piece(let piece, let begin, let data):
                print("[Coordinator] 📦 Piece(\(piece), begin=\(begin), len=\(data.count)) from \(key)")
                await pieceManager.storeBlock(piece: piece, begin: begin, data: data)
                totalDownloaded += Int64(data.count)
                pieceBlockSources[piece, default: [:]][begin] = key
                // Endgame: cancel duplicate block requests from other peers immediately (libtorrent)
                if await pieceManager.progress > 0.95 {
                    for (otherKey, otherConn) in peers where otherKey != key {
                        if peerPieces[otherKey] == piece || peerLookahead[otherKey] == piece {
                            try? await otherConn.send(.cancel(piece: piece, begin: begin, length: data.count))
                        }
                    }
                }
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
                    await disconnectIfRedundant(key: key)
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
                    // Clean up tracking and re-queue the piece immediately
                    assignedPieces.remove(piece)
                    pieceAssignedAt.removeValue(forKey: piece)
                    if let p = peerPieces.removeValue(forKey: key) {
                        await pieceManager.cancelPending(for: p)
                    }
                    await requestBlocks(key: key, conn: conn)

                case .incomplete:
                    break  // not all blocks arrived yet
                }
            case .have(let piece):
                guard piece < torrent.pieces.count else { break }
                peerBitfields[key, default: []].insert(piece)
                pieceFrequency[piece, default: 0] += 1

            // BEP 6 Fast Extension handlers

            case .haveAll:
                let allPieces = Set(0..<torrent.pieces.count)
                let old = peerBitfields[key] ?? []
                for piece in allPieces.subtracting(old) { pieceFrequency[piece, default: 0] += 1 }
                for piece in old.subtracting(allPieces) { pieceFrequency[piece] = max(0, (pieceFrequency[piece] ?? 1) - 1) }
                peerBitfields[key] = allPieces
                if await !conn.isChoked { await requestBlocks(key: key, conn: conn) }

            case .haveNone:
                if let old = peerBitfields.removeValue(forKey: key) {
                    for piece in old { pieceFrequency[piece] = max(0, (pieceFrequency[piece] ?? 1) - 1) }
                }
                peerBitfields[key] = []

            case .suggest(let piece):
                guard piece < torrent.pieces.count else { break }
            case .reject(_, _, _):
                break
            case .allowedFast:
                break

            case .choke:
                if let piece = peerPieces[key] {
                    await pieceManager.cancelPending(for: piece)
                    assignedPieces.remove(piece)
                    peerPieces.removeValue(forKey: key)
                    pieceAssignedAt.removeValue(forKey: piece)
                }

            case .interested:
                interestedPeers.insert(key)
                // Defer unchoke to periodic choke round (libtorrent: on_interested only sets flag)

            case .notInterested:
                interestedPeers.remove(key)

            case .request(let piece, let begin, let length):
                // Only serve if we have the piece and the peer is unchoked
                guard await pieceManager.hasPiece(piece), unchokedPeers.contains(key) else { break }
                if let data = await asyncReadBlockFromDisk(piece: piece, begin: begin, length: length) {
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

            case .extended(let id, let data) where id == localPEXID:
                if let pex = parsePEXMessage(from: data) {
                    for peer in pex.added {
                        let pKey = "\(peer.ip):\(peer.port)"
                        guard !spawnedPeers.contains(pKey), !bannedPeers.contains(pKey) else { continue }
                        guard peerBitfields.count < 50 else { break }
                        let conn = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
                        peers[pKey] = conn
                        spawnedPeers.insert(pKey)
                        Task { await self.handlePeer(key: pKey, conn: conn) }
                        print("[Coordinator] 🔄 PEX discovered \(pKey)")
                    }
                }

            case .extended(localMetadataID, let data):
                // Serve ut_metadata (BEP 9) — respond to magnet metadata requests
                let rawInfo = torrent.rawInfoDict
                guard let msg = parseMetadataMessage(from: data),
                      case .request(let piece) = msg,
                      let remoteMetaID = await conn.peerExtensions?.utMetadata else { break }
                let start = piece * 16384
                guard start < rawInfo.count else {
                    try? await conn.send(buildMetadataReject(piece: piece, extensionID: remoteMetaID))
                    break
                }
                let end = min(start + 16384, rawInfo.count)
                try? await conn.send(buildMetadataData(
                    piece: piece,
                    totalSize: rawInfo.count,
                    data: rawInfo.subdata(in: start..<end),
                    extensionID: remoteMetaID))

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
        lastPEXSent.removeValue(forKey: key)
        pexLastKnown.removeValue(forKey: key)
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
        // libtorrent strict_end_game_mode: only duplicate when every remaining
        // piece has at least one outstanding request
        if await pieceManager.progress > 0.95 {
            let needed = await pieceManager.nextNeededPiece(excluding: skippedPieces())
            guard let needed else { return }
            let unassignedCount = (0..<torrent.pieces.count).filter { i in
                !completedPieces.contains(i) && !skippedPieces().contains(i) && !assignedPieces.contains(i)
            }.count
            guard unassignedCount == 0, let piece = await pieceManager.nextNeededPiece(excluding: skippedPieces().union(assignedPieces)) else {
                // Not all pieces have assignments yet — use rarest-first instead of duplicating
                let peersPieces = peerBitfields[key] ?? []
                if let piece = await rarestPiece(available: peersPieces, excluding: assignedPieces.union(skippedPieces())) {
                    assignedPieces.insert(piece)
                    peerPieces[key] = piece
                    pieceAssignedAt[piece] = Date()
                    let requests = await pieceManager.nextBlockRequests(for: piece)
                    for req in requests {
                        try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
                    }
                }
                return
            }
            // All pieces have assignments — send duplicate requests
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
        guard let piece = await rarestPiece(available: peersPieces, excluding: assignedPieces.union(skippedPieces())) else { return }

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
            return await pieceManager.nextNeededPiece(excluding: excluding.union(skippedPieces()))
        }
        let skipped = skippedPieces()
        // libtorrent initial_picker_threshold: when <4 pieces, pick randomly
        if completedPieces.count < 4 {
            // Prioritize partials first, even during random phase (prioritize_partials)
            let partials = await pieceManager.partialPieces.intersection(available).filter { !excluding.contains($0) && !skipped.contains($0) }
            if let partial = partials.randomElement() { return partial }
            var candidates: [Int] = []
            for p in available {
                if !excluding.contains(p) && !skipped.contains(p) {
                    let hasIt = await pieceManager.hasPiece(p)
                    if !hasIt { candidates.append(p) }
                }
            }
            if let pick = candidates.randomElement() { return pick }
            return await pieceManager.nextNeededPiece(excluding: excluding.union(skippedPieces()))
        }
        // Rarest-first: prioritize partials first, then rarest
        let partials = await pieceManager.partialPieces.intersection(available)
        if let partial = partials.first(where: { !excluding.contains($0) && !skipped.contains($0) }) {
            return partial
        }
        var best: Int?; var bestCount = Int.max
        for piece in available {
            guard !excluding.contains(piece), !skipped.contains(piece) else { continue }
            let hasIt = await pieceManager.hasPiece(piece)
            guard !hasIt else { continue }
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
            let end = cursor + seg.length
            guard end <= data.count, seg.fileIndex < handles.count else { break }
            guard let fh = handles[seg.fileIndex] else { cursor = end; continue }
            let chunk = data.subdata(in: cursor..<end)
            try? fh.seek(toOffset: UInt64(seg.fileOffset))
            try? fh.write(contentsOf: chunk)
            cursor = end
        }
        // fsync after write (libtorrent: flush metadata on piece completion)
        for seg in segments {
            guard seg.fileIndex < handles.count else { continue }
            try? handles[seg.fileIndex]?.synchronize()
        }
    }

    private func readBlockFromDisk(piece: Int, begin: Int, length: Int) -> Data? {
        guard let handles = fileHandles else { return nil }
        let segments = diskMapper.map(piece: piece, blockBegin: begin, blockLength: length)
        var result = Data(capacity: length)
        for seg in segments {
            guard seg.fileIndex < handles.count, let fh = handles[seg.fileIndex] else { return nil }
            do {
                try fh.seek(toOffset: UInt64(seg.fileOffset))
                var remaining = seg.length
                while remaining > 0 {
                    guard let part = try fh.read(upToCount: remaining),
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

    /// Background disk I/O queue (POSIX file descriptors are thread-safe).
    private nonisolated static let diskQueue = DispatchQueue(label: "canopy.disk-write", qos: .utility)

    private func asyncReadBlockFromDisk(piece: Int, begin: Int, length: Int) async -> Data? {
        // Capture handles + mapper before dispatching to avoid actor isolation issues
        let handles = fileHandles
        let mapper = diskMapper
        return await withCheckedContinuation { cont in
            Self.diskQueue.async {
                guard let h = handles else { cont.resume(returning: nil); return }
                let segments = mapper.map(piece: piece, blockBegin: begin, blockLength: length)
                var result = Data(capacity: length)
                for seg in segments {
                    guard seg.fileIndex < h.count, let fh = h[seg.fileIndex] else { cont.resume(returning: nil); return }
                    do {
                        try fh.seek(toOffset: UInt64(seg.fileOffset))
                        var remaining = seg.length
                        while remaining > 0 {
                            guard let part = try fh.read(upToCount: remaining), !part.isEmpty else { cont.resume(returning: nil); return }
                            result.append(part)
                            remaining -= part.count
                        }
                    } catch {
                        cont.resume(returning: nil)
                        return
                    }
                }
                cont.resume(returning: result.isEmpty ? nil : result)
            }
        }
    }

    /// Run the choke algorithm: unchoke top 4 peers by upload rate,
    /// plus one random optimistic unchoke for choked interested peers.
    private func runChokeAlgorithm() async {
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
                try? await peers[key]?.send(.unchoke)
                print("[Coordinator] 🌱 Unchoked \(key)")
            } else if !shouldUnchoke, unchokedPeers.contains(key) {
                try? await peers[key]?.send(.choke)
                print("[Coordinator] 🔒 Choked \(key)")
            }
        }
        unchokedPeers = newUnchoked
        print("[Coordinator] Choke round: \(unchokedPeers.count) unchoked (\(top4.count) top, \(optimistic.count) optimistic)")

        // PEX (BEP 11): broadcast known peers to connected peers (delta-only, 60s interval)
        for key in peers.keys {
            guard Date().timeIntervalSince(lastPEXSent[key] ?? .distantPast) >= 60 else { continue }
            let utPEXID = await peers[key]?.peerExtensions?.utPEX
            guard utPEXID != nil else { continue }
            let current = Set(peers.keys).subtracting([key])
            let last = pexLastKnown[key] ?? []
            let addedKeys = current.subtracting(last)
            let droppedKeys = last.subtracting(current)
            guard !addedKeys.isEmpty || !droppedKeys.isEmpty else { continue }
            let added = addedKeys.compactMap { peers[$0]?.peer }
            let addedSeedFlags: [UInt8] = addedKeys.compactMap { k in
                guard let bf = peerBitfields[k] else { return nil }
                return bf.count == torrent.pieces.count ? 0x02 : 0x01
            }
            let dropped = droppedKeys.compactMap { k -> Peer? in
                let parts = k.split(separator: ":"); guard parts.count == 2 else { return nil }
                return Peer(ip: String(parts[0]), port: UInt16(parts[1]) ?? 0)
            }
            if let msg = buildPEXMessage(added: added, dropped: dropped, addedFlags: addedSeedFlags, utPEXID: utPEXID) {
                try? await peers[key]?.send(msg)
            }
            pexLastKnown[key] = current
            lastPEXSent[key] = Date()
        }
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
            let stream = try await conn.accept(connection: connection, knownInfoHashes: [torrent.infoHash])
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
        // Announce with left=0 so tracker knows we're seeding
        _ = try? await trackerSession.announce(uploaded: totalUploaded, downloaded: totalDownloaded, left: 0)
        print("[Coordinator] 🌱 Entering seeding mode (inbound only)")
        while !isShutdown {
            if Task.isCancelled { break }
            if Date().timeIntervalSince(lastChokeRound) >= 30 {
                lastChokeRound = Date()
                await runChokeAlgorithm()
            }
            // Periodic re-announce — TrackerSession self-throttles via interval, so this is safe to call often
            _ = try? await trackerSession.announce(uploaded: totalUploaded, downloaded: totalDownloaded, left: 0)
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
        if let cont = pauseContinuation {
            pauseContinuation = nil
            cont.resume()
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
                fileHandles?.forEach { try? $0?.close() }
        fileHandles = nil
        if let dht = dhtSession, !torrent.isPrivate {
            await dht.saveRoutingTable()
            await dht.shutdown()
        }
        await trackerSession.stop()
    }

    // MARK: - Status queries (for CanopyEngine polling)

    public func statusSnapshot() -> CoordinatorSnapshot {
        let seederCount = peerBitfields.values.filter { $0.count == torrent.pieces.count }.count
        let state: TorrentState = completedPieces.count == torrent.pieces.count
            ? .seeding
            : (completedPieces.isEmpty ? .downloading : .downloading)
        return CoordinatorSnapshot(
            downloaded: totalDownloaded,
            uploaded: totalUploaded,
            completedPieces: completedPieces.count,
            totalPieces: torrent.pieces.count,
            connectedPeers: peerBitfields.count,
            seederCount: seederCount,
            state: state,
            isPaused: isPaused,
            errorMessage: nil
        )
    }

    public func fileInfos() -> [(index: Int, path: String, size: Int64)] {
        torrent.files.enumerated().map { ($0.offset, $0.element.path, $0.element.size) }
    }

    public func fileProgress() async -> [Int64] {
        // Use PieceManager's per-file progress mapping
        await pieceManager.fileProgress(files: torrent.files, pieceLength: torrent.pieceLength)
    }

    public func setFilePriority(index: Int, priority: FilePriority) {
        filePriorities[index] = priority
    }

    // MARK: - Pause / resume

    public func suspend() {
        isPaused = true
        saveResumeData()
    }

    public func resume() {
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    // MARK: - Recheck / reannounce

    public func recheck() async {
        await pieceManager.reset()
        completedPieces.removeAll()
        try? FileManager.default.removeItem(atPath: resumeFilePath())
                fileHandles?.forEach { try? $0?.close() }
        fileHandles = nil
        totalDownloaded = 0
    }

    public func reannounce() async {
        _ = try? await trackerSession.announce(uploaded: totalUploaded, downloaded: totalDownloaded)
    }

    // MARK: - Piece selection helper

    /// Returns the set of piece indices to skip (mapped entirely to zero-priority files).
    private func skippedPieces() -> Set<Int> {
        guard !filePriorities.isEmpty else { return [] }
        var skipped = Set<Int>()
        for piece in 0..<torrent.pieces.count {
            let pieceFiles = diskMapper.filesForPiece(piece)
            if !pieceFiles.isEmpty && pieceFiles.allSatisfy({ filePriorities[$0] == .dontDownload }) {
                skipped.insert(piece)
            }
        }
        return skipped
    }

    /// Disconnect if both sides are complete — no further utility (libtorrent: close_redundant_connections).
    private func disconnectIfRedundant(key: String) async {
        guard await pieceManager.isComplete else { return }
        let peerPieceSet = peerBitfields[key] ?? []
        guard peerPieceSet.count == torrent.pieces.count else { return }
        Log.coord.info("🔌 Disconnecting redundant connection to \(key) (both sides complete)")
        if let conn = peers.removeValue(forKey: key) { await conn.disconnect() }
        if let bf = peerBitfields.removeValue(forKey: key) {
            for p in bf { pieceFrequency[p] = max(0, (pieceFrequency[p] ?? 1) - 1) }
        }
        if let piece = peerPieces.removeValue(forKey: key) {
            await pieceManager.cancelPending(for: piece)
            assignedPieces.remove(piece)
            pieceAssignedAt.removeValue(forKey: piece)
        }
        if let la = peerLookahead.removeValue(forKey: key) {
            await pieceManager.cancelPending(for: la)
            assignedPieces.remove(la)
        }
        peerLastMessageAt.removeValue(forKey: key)
        peerChokedSince.removeValue(forKey: key)
        peerLastBlockAt.removeValue(forKey: key)
        peerConnectedAt.removeValue(forKey: key)
        peerBlockCount.removeValue(forKey: key)
        uploadRate.removeValue(forKey: key)
        interestedPeers.remove(key)
        unchokedPeers.remove(key)
        spawnedPeers.remove(key)
        inflightPeers.remove(key)
    }
}

public enum DownloadError: Error {
    case noPeers
    case allPeersDisconnected
}
