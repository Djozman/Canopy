//  TorrentDownloader.swift
//  Canopy — Native Swift Engine
//
//  Ties the pieces together (BEP 3 end-to-end leech):
//    announce → connect peers → handshake → interested → on unchoke pipeline
//    16 KiB block requests → assemble → SHA-1 verify → write to disk → repeat
//    until every piece is verified.
//
//  TorrentDownloader is an actor: it owns the PieceManager + storage and is the
//  single serialization point. Each PeerSession runs its own socket loop
//  concurrently and only touches shared state through the actor.

import Foundation

enum DownloadError: Error {
    case noTracker
    case noPeers
}

// MARK: - Per-peer driver (runs off the actor; only shared state hops onto it)

final class PeerSession {
    private let peer: Peer
    private let coordinator: TorrentDownloader
    private let infoHash: [UInt8]
    private let myPeerID: [UInt8]
    private let pieceCount: Int
    private let maxPipeline = 16  // outstanding block requests for TCP throughput

    init(
        peer: Peer, coordinator: TorrentDownloader,
        infoHash: [UInt8], myPeerID: [UInt8], pieceCount: Int
    ) {
        self.peer = peer
        self.coordinator = coordinator
        self.infoHash = infoHash
        self.myPeerID = myPeerID
        self.pieceCount = pieceCount
    }

    func run() async {
        let conn = PeerConnection(
            host: peer.ip, port: peer.port,
            infoHash: infoHash, myPeerID: myPeerID)
        await coordinator.register(conn)

        var peerField = Bitfield(pieceCount: pieceCount)
        var inflight: [BlockRequest] = []

        do {
            try await conn.connectAndHandshake()
            try await conn.send(.interested)

            while await !coordinator.isComplete {
                let message = try await conn.receiveMessage()
                switch message {
                case .bitfield(let payload):
                    if let field = Bitfield(payload: payload, pieceCount: pieceCount) {
                        peerField = field
                        await coordinator.addAvailability(field)
                    }
                case .have(let pieceIndex):
                    let idx = Int(pieceIndex)
                    if idx >= 0, idx < pieceCount {
                        peerField.set(idx)
                        await coordinator.addHave(idx)
                    }
                case .piece(let index, let begin, let block):
                    inflight.removeAll { $0.index == index && $0.begin == begin }
                    await coordinator.received(index: Int(index), begin: Int(begin), block: block)
                default:
                    break  // choke/unchoke handled via conn state; we don't serve data yet
                }

                // Keep the pipeline full while the peer is unchoking us.
                if await !conn.peerChoking {
                    while inflight.count < maxPipeline,
                        let req = await coordinator.nextRequest(for: peerField)
                    {
                        try await conn.send(
                            .request(
                                index: req.index,
                                begin: req.begin,
                                length: req.length))
                        inflight.append(req)
                    }
                }
            }
            try? await conn.send(.notInterested)
        } catch {
            await coordinator.requeue(inflight)  // let other peers finish these blocks
        }
        await conn.close()
    }
}

// MARK: - Coordinator

actor TorrentDownloader {
    let metainfo: TorrentMetainfo
    private let storage: TorrentStorage
    private let picker: PieceManager
    private let tracker: HTTPTrackerClient
    private let myPeerID: [UInt8]
    private let port: UInt16

    private var connections: [PeerConnection] = []
    private(set) var downloaded: Int64 = 0

    init(
        metainfo: TorrentMetainfo,
        downloadDirectory: URL,
        myPeerID: Data,
        port: UInt16 = 6881,
        session: URLSession = .shared
    ) throws {
        self.metainfo = metainfo
        self.storage = try TorrentStorage(metainfo: metainfo, downloadDirectory: downloadDirectory)
        self.picker = PieceManager(metainfo: metainfo)
        self.tracker = HTTPTrackerClient(session: session)
        self.myPeerID = [UInt8](myPeerID)
        self.port = port
    }

    var isComplete: Bool { picker.isComplete }
    var progress: Double { Double(picker.completedCount) / Double(max(1, metainfo.pieceCount)) }

    // Shared-state entry points used by PeerSession.
    func register(_ conn: PeerConnection) { connections.append(conn) }
    func addAvailability(_ field: Bitfield) { picker.addAvailability(field) }
    func addHave(_ index: Int) { picker.addHave(index) }
    func nextRequest(for field: Bitfield) -> BlockRequest? { picker.nextRequest(for: field) }
    func requeue(_ requests: [BlockRequest]) { picker.requeue(requests) }

    /// Assemble + verify + persist a block; on the final block of a piece this
    /// hashes it, writes it to disk, and (if that was the last piece) tears down.
    func received(index: Int, begin: Int, block: Data) {
        switch picker.receivedBlock(index: index, begin: begin, block: block) {
        case .pieceComplete(let idx, let data):
            guard picker.verify(index: idx, data: data) else {
                picker.resetPiece(idx)  // bad SHA-1 → re-download from scratch
                return
            }
            do {
                try storage.write(at: Int64(idx) * metainfo.pieceLength, data: data)
            } catch {
                picker.resetPiece(idx)  // disk write failed → retry the piece
                return
            }
            picker.markVerified(idx)
            downloaded += Int64(data.count)
            if picker.isComplete { teardown() }
        case .accepted, .ignored:
            break
        }
    }

    private func teardown() {
        let conns = connections
        connections = []
        for conn in conns { Task { await conn.close() } }  // unblocks idle receive loops
        storage.flush()
    }

    /// Announce, fan out to peers, and download until complete.
    func start(maxPeers: Int = 30) async throws {
        guard let announceURL = metainfo.announce ?? metainfo.announceList.first?.first else {
            throw DownloadError.noTracker
        }

        let response = try await tracker.announce(
            announceURL: announceURL,
            infoHash: metainfo.infoHash,
            peerID: Data(myPeerID),
            port: port,
            left: metainfo.totalLength,
            event: .started)

        let peers = Array(response.peers.prefix(maxPeers))
        guard !peers.isEmpty else { throw DownloadError.noPeers }

        await withTaskGroup(of: Void.self) { group in
            for peer in peers {
                let session = PeerSession(
                    peer: peer,
                    coordinator: self,
                    infoHash: [UInt8](metainfo.infoHash),
                    myPeerID: myPeerID,
                    pieceCount: metainfo.pieceCount)
                group.addTask { await session.run() }
            }
            await group.waitForAll()
        }

        storage.flush()
        storage.close()

        if picker.isComplete {
            _ = try? await tracker.announce(
                announceURL: announceURL,
                infoHash: metainfo.infoHash,
                peerID: Data(myPeerID),
                port: port,
                downloaded: downloaded,
                left: 0,
                event: .completed)
        }
    }
}
