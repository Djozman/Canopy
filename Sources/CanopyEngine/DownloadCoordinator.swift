import Foundation

/// Coordinates downloading a single torrent: tracker announces, peer connections,
/// piece requests, and disk writes. All state lives in the PieceManager actor.
public actor DownloadCoordinator {
    private let torrent: TorrentFile
    private let pieceManager: PieceManager
    private let diskMapper: DiskMapper
    private let trackerSession: TrackerSession
    private let savePath: String

    /// Connected peers, keyed by (ip:port)
    private var peers: [String: PeerConnection] = [:]
    /// Pieces assigned to each peer
    private var peerPieces: [String: Int] = [:]
    /// Active piece sets per peer
    private var assignedPieces: Set<Int> = []
    /// File handles for disk writes
    private var fileHandles: [FileHandle]?

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

    /// Download the entire torrent. Returns when complete.
    public func download() async throws {
        // Open files
        fileHandles = try diskMapper.openFiles(at: savePath)

        // Announce to tracker
        let response = try await trackerSession.announce()
        guard !response.peers.isEmpty else { throw DownloadError.noPeers }

        // Connect to peers and start message loops
        for peer in response.peers.prefix(8) {
            let key = "\(peer.ip):\(peer.port)"
            let conn = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
            peers[key] = conn
        }

        // Process all peer streams concurrently
        await withTaskGroup(of: Void.self) { group in
            for (key, conn) in peers {
                group.addTask { await self.handlePeer(key: key, conn: conn) }
            }
        }
    }

    private func handlePeer(key: String, conn: PeerConnection) async {
        guard let stream = try? await conn.connect() else { return }

        // Send interested
        try? await conn.send(.interested)

        for await msg in stream {
            switch msg {
            case .bitfield(let bf):
                // Record which pieces this peer has
                for (byteIdx, byte) in bf.enumerated() {
                    for bit in 0..<8 {
                        if (byte >> (7 - bit)) & 1 == 1 {
                            await pieceManager.markHave(piece: byteIdx * 8 + bit)
                        }
                    }
                }
                // Start requesting if unchoked
                if await !conn.isChoked {
                    await requestBlocks(key: key, conn: conn)
                }

            case .unchoke:
                await requestBlocks(key: key, conn: conn)

            case .piece(let piece, let begin, let data):
                await pieceManager.storeBlock(piece: piece, begin: begin, data: data)
                if let verified = await pieceManager.tryAssemble(piece: piece) {
                    await writePieceToDisk(piece: piece, data: verified)
                    if await pieceManager.isComplete {
                        // Send completed, stop tracker, cleanup
                        try? await trackerSession.completed()
                        for p in peers.values { p.disconnect() }
                        return
                    }
                    // Request next piece
                    await requestBlocks(key: key, conn: conn)
                }

            case .choke:
                await pieceManager.cancelPending(for: peerPieces[key] ?? -1)
                peerPieces.removeValue(forKey: key)

            default:
                break
            }
        }
    }

    private func requestBlocks(key: String, conn: PeerConnection) async {
        // If this peer already has an assigned piece, continue requesting blocks
        if let piece = peerPieces[key],
           let requests = await pieceManager.nextBlockRequests(for: piece) {
            for req in requests {
                try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
            }
            return
        }

        // Assign a new piece
        guard let piece = await pieceManager.nextNeededPiece(excluding: assignedPieces) else { return }
        assignedPieces.insert(piece)
        peerPieces[key] = piece

        guard let requests = await pieceManager.nextBlockRequests(for: piece) else { return }
        for req in requests {
            try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
        }
    }

    private func writePieceToDisk(piece: Int, data: Data) async {
        guard let handles = fileHandles else { return }
        var dataOffset = 0
        while dataOffset < data.count {
            let blockLen = min(blockSize, data.count - dataOffset)
            let segments = diskMapper.map(piece: piece, blockBegin: dataOffset, blockLength: blockLen)
            var segOffset = 0
            for seg in segments {
                let start = dataOffset + segOffset
                let segData = data.subdata(in: start..<(start + seg.length))
                try? handles[seg.fileIndex].seek(toOffset: UInt64(seg.fileOffset))
                try? handles[seg.fileIndex].write(contentsOf: segData)
                segOffset += seg.length
            }
            dataOffset += blockLen
        }
    }
}

public enum DownloadError: Error {
    case noPeers
}
