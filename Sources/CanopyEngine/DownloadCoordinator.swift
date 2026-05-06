import Foundation

/// Coordinates downloading a single torrent: tracker announces, peer connections,
/// piece requests, and disk writes.
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
    private var fileHandles: [FileHandle]?
    private var completionContinuation: CheckedContinuation<Void, Error>?

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
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Download the entire torrent. Blocks until complete or error.
    public func download() async throws {
        await loadResumeData()
        fileHandles = try diskMapper.openFiles(at: savePath)
        defer {
            fileHandles?.forEach { try? $0.close() }
            fileHandles = nil
        }

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
                        if let response = try? await trackerSession.announce(uploaded: 0, downloaded: 0) {
                            for peer in response.peers {
                                let key = "\(peer.ip):\(peer.port)"
                                let conn = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
                                peers[key] = conn
                            }
                        }
                    }
                    // Spawn tasks for any peers not yet connected
                    for (key, conn) in peers {
                        if peerBitfields[key] == nil && peerPieces[key] == nil {
                            Task { await self.handlePeer(key: key, conn: conn) }
                        }
                    }
                    try? await Task.sleep(for: .seconds(10))
                    // Check for stall — re-queue pieces taking >30s
                    let now = Date()
                    let stale = pieceAssignedAt.filter { now.timeIntervalSince($0.value) > 30 }.map(\.key)
                    for piece in stale {
                        await pieceManager.cancelPending(for: piece)
                        assignedPieces.remove(piece)
                        pieceAssignedAt.removeValue(forKey: piece)
                        print("[Coordinator] ⏱ Piece \(piece) timed out, re-queuing")
                    }
                }
            }
        }
    }

    private func handlePeer(key: String, conn: PeerConnection) async {
        let stream: AsyncStream<PeerMessage>
        do {
            stream = try await conn.connect()
        } catch {
            print("[Coordinator] ⚠️ Failed to connect to \(key): \(error)")
            return
        }
        print("[Coordinator] ✅ Connected to \(key)")
        try? await conn.send(.interested)

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
                if let currentPiece = peerPieces[key], currentPiece == piece {
                    await requestBlocks(key: key, conn: conn)
                }
                if let verified = await pieceManager.tryAssemble(piece: piece) {
                    assignedPieces.remove(piece)
                    peerPieces.removeValue(forKey: key)
                    pieceAssignedAt.removeValue(forKey: piece)
                    await writePieceToDisk(piece: piece, data: verified)
                    completedPieces.insert(piece)
                    saveResumeData()
                    // Announce new piece to all OTHER connected peers
                    for (k, c) in peers where k != key { try? await c.send(.have(piece: piece)) }
                    if await pieceManager.isComplete {
                        if let cont = completionContinuation {
                            completionContinuation = nil
                            cont.resume()
                        }
                        try? await trackerSession.completed()
                        for p in peers.values { await p.disconnect() }
                        return
                    }
                    await requestBlocks(key: key, conn: conn)
                }

            case .choke:
                if let piece = peerPieces[key] {
                    await pieceManager.cancelPending(for: piece)
                    assignedPieces.remove(piece)
                    peerPieces.removeValue(forKey: key)
                    pieceAssignedAt.removeValue(forKey: piece)
                }

            default:
                break
            }
        }
        // Peer disconnected — clean up and check if we're out of peers
        print("[Coordinator] ⛔ Disconnected from \(key)")
        peers.removeValue(forKey: key)
        peerBitfields.removeValue(forKey: key)
        if let piece = peerPieces[key] {
            await pieceManager.cancelPending(for: piece)
            assignedPieces.remove(piece)
            peerPieces.removeValue(forKey: key)
        }
        if peers.isEmpty, let cont = completionContinuation {
            completionContinuation = nil
            cont.resume(throwing: DownloadError.allPeersDisconnected)
        }
    }

    private func requestBlocks(key: String, conn: PeerConnection) async {
        if let piece = peerPieces[key] {
            let requests = await pieceManager.nextBlockRequests(for: piece)
            for req in requests {
                try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
            }
            return
        }

        // Endgame: >95% done — request from ALL peers simultaneously
        if await pieceManager.progress > 0.95 {
            guard let piece = await pieceManager.nextNeededPiece(excluding: []) else { return }
            assignedPieces.insert(piece)
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
}

public enum DownloadError: Error {
    case noPeers
    case allPeersDisconnected
}
