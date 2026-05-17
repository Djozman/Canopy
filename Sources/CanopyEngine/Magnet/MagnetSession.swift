import Foundation

public enum MagnetError: Error {
    case noPeers
    case metadataUnavailable
    case verificationFailed
}

public typealias MagnetProgress = @Sendable (String) -> Void

/// Orchestrates metadata download from a magnet link.
/// Collects peers from tracker hints + DHT concurrently, then downloads metadata pieces in parallel.
public actor MagnetSession {
    private let magnet: MagnetLink
    private let dhtSession: DHTSession?
    private var progress: MagnetProgress?

    public init(magnet: MagnetLink, dhtSession: DHTSession? = nil) {
        self.magnet = magnet
        self.dhtSession = dhtSession
    }

    public func setProgress(_ cb: @escaping MagnetProgress) {
        self.progress = cb
    }

    private func report(_ msg: String) {
        Log.engine.info("\(msg)")
        progress?(msg)
    }

    public func fetchMetadata() async throws -> TorrentFile {
        // Hard ceiling on the entire fetch — better to fail fast than spin forever.
        return try await withTimeout(seconds: 45) {
            try await self.fetchMetadataInner()
        }
    }

    private func fetchMetadataInner() async throws -> TorrentFile {
        report("Searching for peers…")
        async let trackerPeers = fetchFromTrackers()
        async let dhtPeers = fetchFromDHT()
        let (trackerPeersResult, dhtPeersResult) = await (trackerPeers, dhtPeers)
        var seen = Set<String>()
        let candidates = (trackerPeersResult + dhtPeersResult).filter { seen.insert("\($0.ip):\($0.port)").inserted }
        guard !candidates.isEmpty else {
            report("No peers found (trackers + DHT both empty)")
            throw MagnetError.noPeers
        }
        report("Found \(candidates.count) peers (tracker: \(trackerPeersResult.count), DHT: \(dhtPeersResult.count)) — fetching metadata…")

        // Step 2: download metadata — try up to 50 peers concurrently, each with a 12s timeout
        let downloader = MetadataDownloader(infoHash: magnet.infoHash)
        let attempted = Counter()
        let succeeded = Counter()
        let bep10Skipped = Counter()
        await withTaskGroup(of: Void.self) { group in
            for peer in candidates.prefix(50) {
                group.addTask {
                    guard !(await downloader.isComplete) else { return }
                    await attempted.inc()
                    do {
                        try await withTimeout(seconds: 12) {
                            let ok = await self.fetchFromPeer(peer, into: downloader)
                            if ok == .gotData { await succeeded.inc() }
                            else if ok == .noBEP10 { await bep10Skipped.inc() }
                        }
                    } catch {
                        // expected for unresponsive peers — just move on
                    }
                }
            }
        }
        let a = await attempted.value
        let s = await succeeded.value
        let b = await bep10Skipped.value
        report("Attempted \(a) peers, \(s) served data, \(b) skipped (no BEP 10)")
        guard await downloader.isComplete else {
            report("All \(candidates.count) peers exhausted — metadata not received")
            throw MagnetError.metadataUnavailable
        }
        report("Metadata received — verifying…")

        // Step 3: verify and parse
        guard let rawInfo = await downloader.assembleAndVerify() else {
            throw MagnetError.verificationFailed
        }
        var tf = try TorrentParser.parse(infoDict: rawInfo)
        // Inject tracker URLs from the magnet link — TorrentParser.parse(infoDict:) can't know them
        if !magnet.trackers.isEmpty {
            tf = TorrentFile(
                announce: magnet.trackers.first,
                announceList: [magnet.trackers],
                name: tf.name, pieceLength: tf.pieceLength, pieces: tf.pieces,
                files: tf.files, infoHash: tf.infoHash, totalSize: tf.totalSize,
                isPrivate: tf.isPrivate, rawInfoDict: tf.rawInfoDict
            )
        }
        return tf
    }

    // MARK: - Peer Sources

    private func fetchFromTrackers() async -> [Peer] {
        guard !magnet.trackers.isEmpty else { return [] }
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
            Log.engine.warning("Tracker announce failed: \(error)")
            return []
        }
    }

    private func fetchFromDHT() async -> [Peer] {
        guard let dht = dhtSession else { return [] }
        return await dht.getPeers(infoHash: magnet.infoHash)
    }

    // MARK: - Per-peer metadata download

    enum FetchOutcome { case gotData, noBEP10, failed }

    private func fetchFromPeer(_ peer: Peer, into downloader: MetadataDownloader) async -> FetchOutcome {
        let conn = PeerConnection(peer: peer, infoHash: magnet.infoHash, localPeerID: PeerID.current)
        let stream: AsyncStream<PeerMessage>
        do {
            stream = try await conn.connect()
        } catch {
            return .failed
        }

        // BEP 10 support check — bit 20 (byte 5, mask 0x10) of reserved bytes.
        // Peers without it will never serve metadata, no point holding the connection.
        let reserved = await conn.peerReservedBytes
        guard reserved.count >= 8, (reserved[5] & 0x10) != 0 else {
            await conn.disconnect()
            return .noBEP10
        }

        try? await conn.send(.extended(id: 0, data: buildExtensionHandshake()))
        var remoteMetaID: UInt8?
        var receivedAnyData = false

        for await msg in stream {
            switch msg {
            case .extended(0, let data):
                if let ext = parseExtensionHandshake(from: data) {
                    remoteMetaID = ext.utMetadata
                    guard let metaID = remoteMetaID else { await conn.disconnect(); return .failed }
                    // Always request piece 0 first — nextNeededPiece returns nil until
                    // totalSize is known, which only arrives with the first data response.
                    let piece = await downloader.nextNeededPiece ?? 0
                    try? await conn.send(buildMetadataRequest(piece: piece, extensionID: metaID))
                }

            case .extended(let id, let data) where id == remoteMetaID:
                guard let msg = parseMetadataMessage(from: data) else { continue }
                switch msg {
                case .data(let piece, let totalSize, let payload):
                    receivedAnyData = true
                    await downloader.receivePiece(index: piece, totalSize: totalSize, data: payload)
                    if await downloader.isComplete {
                        await conn.disconnect()
                        return .gotData
                    }
                    if let next = await downloader.nextNeededPiece, let metaID = remoteMetaID {
                        try? await conn.send(buildMetadataRequest(piece: next, extensionID: metaID))
                    }
                case .reject:
                    if let next = await downloader.nextNeededPiece, let metaID = remoteMetaID {
                        try? await conn.send(buildMetadataRequest(piece: next, extensionID: metaID))
                    } else {
                        await conn.disconnect()
                        return receivedAnyData ? .gotData : .failed
                    }
                case .request:
                    break
                }

            default:
                break
            }
        }
        await conn.disconnect()
        return receivedAnyData ? .gotData : .failed
    }
}

private actor Counter {
    private(set) var value: Int = 0
    func inc() { value += 1 }
}
