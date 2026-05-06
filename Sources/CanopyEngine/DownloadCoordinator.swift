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

    /// Download the entire torrent. Blocks until complete or error.
    public func download() async throws {
        fileHandles = try diskMapper.openFiles(at: savePath)
        defer {
            fileHandles?.forEach { try? $0.close() }
            fileHandles = nil
        }

        let response = try await trackerSession.announce()
        guard !response.peers.isEmpty else { throw DownloadError.noPeers }

        for peer in response.peers.prefix(8) {
            let key = "\(peer.ip):\(peer.port)"
            let conn = PeerConnection(peer: peer, infoHash: torrent.infoHash, localPeerID: PeerID.current)
            peers[key] = conn
        }

        // Suspend until download completes
        try await withCheckedThrowingContinuation { cont in
            completionContinuation = cont
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for (key, conn) in peers {
                        group.addTask { await self.handlePeer(key: key, conn: conn) }
                    }
                }
                // Don't resume here — only resume on completion or error
            }
        }
    }

    private func handlePeer(key: String, conn: PeerConnection) async {
        guard let stream = try? await conn.connect() else { return }
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
                            peerSet.insert(byteIdx * 8 + bit)
                        }
                    }
                }
                peerBitfields[key] = peerSet
                if await !conn.isChoked {
                    await requestBlocks(key: key, conn: conn)
                }

            case .unchoke:
                await requestBlocks(key: key, conn: conn)

            case .piece(let piece, let begin, let data):
                await pieceManager.storeBlock(piece: piece, begin: begin, data: data)
                if let currentPiece = peerPieces[key], currentPiece == piece {
                    await requestBlocks(key: key, conn: conn)
                }
                if let verified = await pieceManager.tryAssemble(piece: piece) {
                    assignedPieces.remove(piece)
                    peerPieces.removeValue(forKey: key)
                    await writePieceToDisk(piece: piece, data: verified)
                    // Announce new piece to all OTHER connected peers
                    for (k, c) in peers where k != key { try? await c.send(.have(piece: piece)) }
                    if await pieceManager.isComplete {
                        try? await trackerSession.completed()
                        for p in peers.values { await p.disconnect() }
                        if let cont = completionContinuation {
                            completionContinuation = nil
                            cont.resume()
                        }
                        return
                    }
                    await requestBlocks(key: key, conn: conn)
                }

            case .choke:
                if let piece = peerPieces[key] {
                    await pieceManager.cancelPending(for: piece)
                    assignedPieces.remove(piece)
                    peerPieces.removeValue(forKey: key)
                }

            default:
                break
            }
        }
        // Peer disconnected — clean up and check if we're out of peers
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

        let peersPieces = peerBitfields[key] ?? []
        guard let piece = await pieceManager.nextNeededPiece(excluding: assignedPieces, availableIn: peersPieces) else {
            return
        }

        assignedPieces.insert(piece)
        peerPieces[key] = piece

        let requests = await pieceManager.nextBlockRequests(for: piece)
        for req in requests {
            try? await conn.send(.request(piece: req.piece, begin: req.begin, length: req.length))
        }
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
