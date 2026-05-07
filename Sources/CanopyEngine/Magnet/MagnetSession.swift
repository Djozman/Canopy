import Foundation

public enum MagnetError: Error {
    case noPeers
    case metadataUnavailable
    case verificationFailed
}

/// Orchestrates metadata download from a magnet link.
/// Collects peers from tracker hints + DHT concurrently, then downloads metadata pieces serially.
public actor MagnetSession {
    private let magnet: MagnetLink
    private let dhtSession: DHTSession?

    public init(magnet: MagnetLink, dhtSession: DHTSession? = nil) {
        self.magnet = magnet
        self.dhtSession = dhtSession
    }

    public func fetchMetadata() async throws -> TorrentFile {
        // Step 1: collect candidates (concurrent tracker + DHT, merged and deduplicated)
        async let trackerPeers = fetchFromTrackers()
        async let dhtPeers = fetchFromDHT()
        let (trackerPeersResult, dhtPeersResult) = await (trackerPeers, dhtPeers)
        var seen = Set<String>()
        let candidates = (trackerPeersResult + dhtPeersResult).filter { seen.insert("\($0.ip):\($0.port)").inserted }
        guard !candidates.isEmpty else { throw MagnetError.noPeers }
        print("[Magnet] Collected \(candidates.count) candidates (tracker: \(trackerPeersResult.count), DHT: \(dhtPeersResult.count))")

        // Step 2: download metadata from candidates (serial, up to 20)
        let downloader = MetadataDownloader(infoHash: magnet.infoHash)
        for peer in candidates.prefix(20) {
            guard !(await downloader.isComplete) else { break }
            await fetchFromPeer(peer, into: downloader)
        }
        guard await downloader.isComplete else {
            throw MagnetError.metadataUnavailable
        }

        // Step 3: verify and parse
        guard let rawInfo = await downloader.assembleAndVerify() else {
            throw MagnetError.verificationFailed
        }
        return try TorrentParser.parse(infoDict: rawInfo)
    }

    // MARK: - Peer Sources

    private func fetchFromTrackers() async -> [Peer] {
        guard !magnet.trackers.isEmpty else { return [] }
        // Create a temporary tracker session for the magnet's info hash
        let session = TrackerSession(
            infoHash: magnet.infoHash,
            peerID: PeerID.current,
            port: 6881,
            announce: nil,
            announceList: [magnet.trackers],
            totalSize: 0
        )
        do {
            let resp = try await session.announce(uploaded: 0, downloaded: 0)
            return resp.peers
        } catch {
            print("[Magnet] Tracker announce failed: \(error)")
            return []
        }
    }

    private func fetchFromDHT() async -> [Peer] {
        guard let dht = dhtSession else { return [] }
        return await dht.getPeers(infoHash: magnet.infoHash)
    }

    // MARK: - Per-peer metadata download

    private func fetchFromPeer(_ peer: Peer, into downloader: MetadataDownloader) async {
        let conn = PeerConnection(peer: peer, infoHash: magnet.infoHash, localPeerID: PeerID.current)
        let stream: AsyncStream<PeerMessage>
        do {
            stream = try await conn.connect()
        } catch {
            return
        }

        // Wait for extension handshake to get remote's ut_metadata ID
        try? await conn.send(.extended(id: 0, data: buildExtensionHandshake()))
        var remoteMetaID: UInt8?

        for await msg in stream {
            switch msg {
            case .extended(0, let data):
                // Extension handshake response
                if let ext = parseExtensionHandshake(from: data) {
                    remoteMetaID = ext.utMetadata
                    guard remoteMetaID != nil else { await conn.disconnect(); return }
                    // Send first request
                    if let piece = await downloader.nextNeededPiece {
                        try? await conn.send(buildMetadataRequest(piece: piece, extensionID: remoteMetaID!))
                    }
                }

            case .extended(let id, let data) where id == remoteMetaID:
                guard let msg = parseMetadataMessage(from: data) else { continue }
                switch msg {
                case .data(let piece, let totalSize, let payload):
                    await downloader.receivePiece(index: piece, totalSize: totalSize, data: payload)
                    if await downloader.isComplete {
                        await conn.disconnect()
                        return
                    }
                    if let next = await downloader.nextNeededPiece, let metaID = remoteMetaID {
                        try? await conn.send(buildMetadataRequest(piece: next, extensionID: metaID))
                    }
                case .reject:
                    // Peer rejected this piece — request next or give up
                    if let next = await downloader.nextNeededPiece, let metaID = remoteMetaID {
                        try? await conn.send(buildMetadataRequest(piece: next, extensionID: metaID))
                    } else {
                        await conn.disconnect()
                        return
                    }
                case .request:
                    break  // we're downloading, not serving
                }

            default:
                break
            }
        }
        await conn.disconnect()
    }
}
