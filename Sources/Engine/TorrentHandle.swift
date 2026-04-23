import Foundation
import Observation
import CryptoKit

@Observable
final class TorrentHandle: Identifiable {
    let id: UUID = .init()
    let meta: Metainfo

    var name: String { meta.name }
    var totalSize: Int64 { meta.totalSize }
    var progress: Double = 0
    var downloadSpeed: Int64 = 0
    var uploadSpeed: Int64 = 0
    var state: TorrentState = .stopped
    var peersCount: Int = 0
    var eta: Int = 0
    var statusMessage: String = ""

    enum TorrentState: String {
        case stopped, connecting, downloading, seeding, checking, error
        var label: String { rawValue.capitalized }
    }

    private var engine: TorrentEngine_?

    init(meta: Metainfo, saveDir: URL) {
        self.meta = meta
        self.engine = TorrentEngine_(meta: meta, saveDir: saveDir, handle: self)
    }

    func start() {
        state = .connecting
        Task { await engine?.start() }
    }

    func stop() {
        state = .stopped
        Task { await engine?.stop() }
    }

    @MainActor
    func update(progress: Double, dlSpeed: Int64, ulSpeed: Int64, peers: Int, state: TorrentState, eta: Int, status: String = "") {
        self.progress = progress
        self.downloadSpeed = dlSpeed
        self.uploadSpeed = ulSpeed
        self.peersCount = peers
        self.statusMessage = status
        self.state = state
        self.eta = eta
    }

    @MainActor
    func setError(_ message: String) {
        self.state = .error
        self.statusMessage = message
    }
}

// MARK: - Internal engine (actor for thread safety)

actor TorrentEngine_: PeerDelegate {
    private let meta: Metainfo
    private let store: PieceStore
    private let tracker = TrackerClient()
    private var peers: [PeerConnection] = []
    private var isRunning = false

    // Peer discovery
    private var pexKnown: Set<String> = []      // "ip:port" — for PEX deduplication only
    private var pexAdded: [(String, UInt16)] = []
    private var pexDropped: [(String, UInt16)] = []

    // Retry queue: peers we should reconnect to after a backoff
    private struct RetryEntry {
        let ip: String; let port: UInt16; var retryAt: Date; var attempts: Int
    }
    private var retryQueue: [RetryEntry] = []
    private var peerAttempts: [String: Int] = [:]
    private var blacklist: Set<String> = []

    private var choker = Choker()

    // Speed tracking — only update display speed every 1s to avoid jitter
    private var bytesDownloaded: Int64 = 0
    private var bytesUploaded: Int64 = 0
    private var lastSpeedSample: Date = .now
    private var speedDlAccum: Int64 = 0
    private var speedUlAccum: Int64 = 0
    private var displayDlSpeed: Int64 = 0
    private var displayUlSpeed: Int64 = 0

    // BEP 9 Metadata
    private var metadataPieces: [Int: Data] = [:]
    private var metadataSize: Int = 0

    private let peerId: Data
    private weak var handle: TorrentHandle?

    static let maxPeers = 80
    static let port: UInt16 = 6881
    static let pipeline = 25
    static let endgameThreshold = 20

    // Per-peer in-flight tracking: peer identity -> set of "piece:offset" keys.
    // When a peer disconnects we only remove ITS keys, leaving other peers' requests intact.
    private var peerInFlight: [ObjectIdentifier: Set<String>] = [:]
    private var globalInFlight: Set<String> = []   // union of all peerInFlight sets

    private var trackerStatus = ""
    private var trackerInterval = 1800  // seconds; updated from tracker response

    init(meta: Metainfo, saveDir: URL, handle: TorrentHandle) {
        self.meta = meta
        self.handle = handle
        self.peerId = Self.makePeerId()
        self.store = (try? PieceStore(meta: meta, saveDir: saveDir)) ?? { fatalError("PieceStore init failed") }()
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        await announceAndConnect(event: "started")
        await refreshRarityOrder()   // prime cache before first block arrives

        DHTBus.shared.register(infoHash: meta.infoHash) { [weak self] peers in
            Task { await self?.connectToPeers(peers.map { TrackerPeer(ip: $0.0, port: $0.1) }) }
        }
        Task { await DHT.shared.findPeers(infoHash: meta.infoHash) }

        startStatsLoop()
    }

    func stop() async {
        isRunning = false
        DHTBus.shared.unregister(infoHash: meta.infoHash)
        for peer in peers { await peer.disconnect() }
        peers = []
        await store.closeAll()
    }

    // MARK: - Tracker

    private func announceAndConnect(event: String? = nil) async {
        let left = meta.totalSize - (await store.downloaded)
        let trackerURLs = meta.announceList.flatMap { $0 }
        print("[Canopy] Announcing to \(trackerURLs.count) trackers")

        // Fire every tracker independently — connect to peers as each one responds,
        // don't block waiting for slow/dead trackers.
        for urlString in trackerURLs {
            guard let url = URL(string: urlString) else { continue }
            Task {
                let resp: TrackerResponse?
                if url.scheme == "udp" {
                    let client = UDPTrackerClient(url: url)
                    let peers = try? await client.announce(
                        infoHash: self.meta.infoHash, peerId: self.peerId,
                        port: Self.port, event: event ?? ""
                    )
                    print("[Canopy] UDP \(urlString): \(peers?.count ?? 0) peers")
                    resp = peers.map { TrackerResponse(interval: 1800, peers: $0) }
                } else if url.scheme == "http" || url.scheme == "https" {
                    do {
                        resp = try await self.tracker.announce(
                            trackerURL: urlString, infoHash: self.meta.infoHash,
                            peerId: self.peerId, port: Self.port,
                            uploaded: self.bytesUploaded, downloaded: self.bytesDownloaded,
                            left: left, event: event
                        )
                        print("[Canopy] HTTP \(urlString): \(resp?.peers.count ?? 0) peers")
                    } catch {
                        print("[Canopy] HTTP \(urlString) failed: \(error)")
                        resp = nil
                    }
                } else {
                    return  // wss:// etc. not supported
                }

                guard let r = resp, !r.peers.isEmpty else { return }
                let interval = max(60, r.interval)
                await self.connectToPeers(r.peers)
                await self.updateTrackerStatus(added: r.peers.count)
                // Schedule re-announce on this tracker's interval
                try? await Task.sleep(for: .seconds(interval))
                if await self.isRunning { await self.announceAndConnect() }
            }
        }
    }

    private func updateTrackerStatus(added: Int) {
        trackerStatus = "Tracker: \(added) peers found"
    }

    private func connectToPeers(_ newPeers: [TrackerPeer]) async {
        let needed = Self.maxPeers - peers.count
        guard needed > 0 else { return }
        // Only deduplicate against currently active/connecting peers (not all-time seen)
        let connectedKeys = Set(peers.map { "\($0.host):\($0.port)" })
        // Also exclude those already queued for retry (they'll reconnect on schedule)
        let queuedKeys = Set(retryQueue.map { "\($0.ip):\($0.port)" })
        var added = 0
        let totalPieces = meta.pieces.count

        for peer in newPeers {
            guard added < needed else { break }
            let key = "\(peer.ip):\(peer.port)"
            guard !connectedKeys.contains(key),
                  !queuedKeys.contains(key),
                  !blacklist.contains(key) else { continue }
            print("[Canopy] Connecting to \(key)")
            let conn = PeerConnection(
                host: peer.ip, port: peer.port,
                infoHash: meta.infoHash, peerId: peerId,
                totalPieces: totalPieces
            )
            await conn.setDelegate(self)
            peers.append(conn)
            await conn.connect()
            added += 1
        }
        print("[Canopy] connectToPeers: attempted \(added), pool now \(peers.count)")
    }

    private func processRetryQueue() async {
        let now = Date.now
        var due: [RetryEntry] = []
        retryQueue = retryQueue.filter {
            if $0.retryAt <= now { due.append($0); return false }
            return true
        }
        guard !due.isEmpty else { return }

        let needed = Self.maxPeers - peers.count
        guard needed > 0 else {
            // Put them back — pool is full
            retryQueue.append(contentsOf: due)
            return
        }

        let connectedKeys = Set(peers.map { "\($0.host):\($0.port)" })
        let totalPieces = meta.pieces.count
        var added = 0

        for entry in due {
            let key = "\(entry.ip):\(entry.port)"
            guard !blacklist.contains(key), !connectedKeys.contains(key), added < needed else {
                if added >= needed { retryQueue.append(entry) }
                continue
            }
            let conn = PeerConnection(
                host: entry.ip, port: entry.port,
                infoHash: meta.infoHash, peerId: peerId,
                totalPieces: totalPieces
            )
            await conn.setDelegate(self)
            peers.append(conn)
            await conn.connect()
            added += 1
        }
    }

    // MARK: - PEX

    private func broadcastPEX() async {
        guard !pexAdded.isEmpty || !pexDropped.isEmpty else { return }
        for peer in peers {
            await peer.sendPEX(added: pexAdded, dropped: pexDropped)
        }
        pexAdded = []
        pexDropped = []
    }

    // MARK: - Piece scheduling

    // Cached rarity order, refreshed in the 1s stats loop to avoid O(N²) per block
    private var cachedRarityOrder: [Int] = []

    private func refreshRarityOrder() async {
        let missing = await store.missingPieces()
        guard !missing.isEmpty else { cachedRarityOrder = []; return }
        if missing.count <= Self.endgameThreshold { cachedRarityOrder = missing; return }
        var counts = [Int: Int]()
        for p in peers {
            let bf = await p.bitfield
            for idx in missing where idx < bf.count && bf[idx] {
                counts[idx, default: 0] += 1
            }
        }
        cachedRarityOrder = missing.sorted { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
    }

    private func scheduleRequests(for peer: PeerConnection) async {
        guard await !peer.peerChoking else { return }

        let pid = ObjectIdentifier(peer)
        let slotsLeft = Self.pipeline - (peerInFlight[pid]?.count ?? 0)
        guard slotsLeft > 0 else { return }

        let orderedPieces = cachedRarityOrder
        guard !orderedPieces.isEmpty else { return }

        let isEndgame = orderedPieces.count <= Self.endgameThreshold
        let peerBitfield = await peer.bitfield
        guard !peerBitfield.isEmpty else { return }

        // Single actor hop to PieceStore — replaces O(pieces) individual calls
        let blocks = await store.blocksToRequest(
            orderedPieces: orderedPieces,
            peerBitfield: peerBitfield,
            excluding: globalInFlight,
            endgame: isEndgame,
            maxBlocks: slotsLeft
        )
        guard !blocks.isEmpty else { return }

        var myInFlight = peerInFlight[pid] ?? []
        for b in blocks {
            let key = "\(b.piece):\(b.offset)"
            myInFlight.insert(key)
            globalInFlight.insert(key)
        }
        peerInFlight[pid] = myInFlight

        // Single actor hop to PeerConnection — sends all requests in one TCP write
        await peer.requestBlocks(blocks)
    }

    // MARK: - PeerDelegate

    func peerDidDisconnect(_ peer: PeerConnection) async {
        let key = "\(peer.host):\(peer.port)"
        print("[Canopy] Peer disconnected: \(key), pool now \(peers.count - 1)")
        peers.removeAll { $0 === peer }
        // Only remove THIS peer's in-flight keys — other peers' requests stay tracked
        let pid = ObjectIdentifier(peer)
        if let keys = peerInFlight.removeValue(forKey: pid) {
            globalInFlight.subtract(keys)
        }
        pexDropped.append((peer.host, peer.port))

        guard !blacklist.contains(key) else { return }

        // Track cumulative attempts across all sessions to drive backoff
        let attempts = (peerAttempts[key] ?? 0) + 1
        peerAttempts[key] = attempts

        if attempts > 6 {
            blacklist.insert(key)
            peerAttempts.removeValue(forKey: key)
            return
        }
        // Exponential backoff: 5s, 10s, 20s, 40s, 80s, 160s
        let delay = pow(2.0, Double(attempts - 1)) * 5.0
        // Remove any stale entry for this peer before adding the new one
        retryQueue.removeAll { "\($0.ip):\($0.port)" == key }
        retryQueue.append(RetryEntry(
            ip: peer.host, port: peer.port,
            retryAt: Date.now.addingTimeInterval(delay),
            attempts: attempts
        ))
    }

    func peerUnchokedUs(_ peer: PeerConnection) async {
        await scheduleRequests(for: peer)
    }

    func peerSentBitfield(_ peer: PeerConnection) async {
        await scheduleRequests(for: peer)
    }

    func peerSentHave(_ peer: PeerConnection) async {
        await scheduleRequests(for: peer)
    }

    func peerSentBlock(_ peer: PeerConnection, piece: Int, offset: Int, data: Data) async {
        let key = "\(piece):\(offset)"
        let pid = ObjectIdentifier(peer)
        globalInFlight.remove(key)
        peerInFlight[pid]?.remove(key)

        speedDlAccum += Int64(data.count)
        bytesDownloaded += Int64(data.count)

        do {
            try await store.receiveBlock(piece: piece, offset: offset, data: data)
            if await store.hasPiece(piece) {
                let missing = await store.missingPieces()
                let isEndgame = missing.count <= Self.endgameThreshold
                // Clear all in-flight keys for this completed piece
                let prefix = "\(piece):"
                for (k, var keys) in peerInFlight {
                    keys = keys.filter { !$0.hasPrefix(prefix) }
                    peerInFlight[k] = keys
                }
                globalInFlight = globalInFlight.filter { !$0.hasPrefix(prefix) }
                for p in peers {
                    await p.sendHave(piece: piece)
                    if isEndgame {
                        let pieceBlocks = await store.allBlocksForPiece(piece: piece)
                        for block in pieceBlocks {
                            await p.sendCancel(piece: piece, offset: block.offset, length: block.length)
                        }
                    }
                }
            }
        } catch {
            print("Error receiving block: \(error)")
        }
        await scheduleRequests(for: peer)
    }

    func peerSentPEX(_ peer: PeerConnection, peers: [(String, UInt16)]) async {
        var toConnect: [TrackerPeer] = []
        for p in peers {
            let key = "\(p.0):\(p.1)"
            if !pexKnown.contains(key) && !blacklist.contains(key) {
                pexKnown.insert(key)
                pexAdded.append(p)
                toConnect.append(TrackerPeer(ip: p.0, port: p.1))
            }
        }
        if !toConnect.isEmpty {
            await connectToPeers(toConnect)
        }
    }

    func peerSentMetadata(_ peer: PeerConnection, piece: Int, totalSize: Int, data: Data) async {
        guard metadataSize == 0 || metadataSize == totalSize else { return }
        metadataSize = totalSize
        metadataPieces[piece] = data

        let expectedPieces = (totalSize + 16383) / 16384
        guard metadataPieces.count == expectedPieces else { return }

        var fullMetadata = Data()
        for i in 0..<expectedPieces {
            guard let p = metadataPieces[i] else { return }
            fullMetadata.append(p)
        }
        let hash = Data(Insecure.SHA1.hash(data: fullMetadata))
        if hash == meta.infoHash {
            print("BEP9 metadata verified for \(meta.infoHash.hexString)")
        }
    }

    func peerRequestedMetadata(_ peer: PeerConnection, piece: Int) async {
        // No-op: we only serve metadata if we started from a .torrent file,
        // which would require storing the raw info bytes at init time.
    }

    func peerRequestedBlock(_ peer: PeerConnection, piece: Int, offset: Int, length: Int) async {
        if let data = try? await store.readBlock(piece: piece, offset: offset, length: length) {
            await peer.sendPiece(index: piece, begin: offset, block: data)
            bytesUploaded += Int64(data.count)
            speedUlAccum += Int64(data.count)
        }
    }

    func peerConnected(_ peer: PeerConnection, supportsExtensions: Bool) async {
        print("[Canopy] Peer connected: \(peer.host):\(peer.port) ext=\(supportsExtensions)")
        let bits = await store.getBitfield()
        await peer.sendBitfield(bits)
        // Reset attempt counter on successful connection
        let key = "\(peer.host):\(peer.port)"
        peerAttempts.removeValue(forKey: key)
        if !pexKnown.contains(key) {
            pexKnown.insert(key)
            pexAdded.append((peer.host, peer.port))
        }
    }

    // MARK: - Stats

    private func startStatsLoop() {
        Task {
            while isRunning {
                try? await Task.sleep(for: .seconds(1))
                await refreshRarityOrder()
                for peer in peers {
                    await peer.updateStats()
                    await scheduleRequests(for: peer)
                }
                await choker.update(peers: peers)
                await broadcastPEX()
                await processRetryQueue()
                await pushStats()
            }
        }
    }

    private func pushStats() async {
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastSpeedSample)

        // Only recompute speed every second to avoid noisy instantaneous readings
        if elapsed >= 1 {
            displayDlSpeed = Int64(Double(speedDlAccum) / elapsed)
            displayUlSpeed = Int64(Double(speedUlAccum) / elapsed)
            speedDlAccum = 0
            speedUlAccum = 0
            lastSpeedSample = now
        }

        let progress = await store.progress
        let done = await store.completedPieces
        let newState: TorrentHandle.TorrentState
        if progress >= 1 {
            newState = .seeding
        } else if !peers.isEmpty {
            newState = .downloading
        } else if retryQueue.isEmpty {
            newState = .connecting
        } else {
            newState = .connecting  // retrying peers
        }
        let left = meta.totalSize - Int64(done) * Int64(meta.pieceLength)
        let eta = displayDlSpeed > 0 ? Int(left / max(displayDlSpeed, 1)) : 0
        let retryInfo = retryQueue.isEmpty ? "" : " (\(retryQueue.count) retrying)"
        let status = peers.isEmpty
            ? trackerStatus + retryInfo
            : "\(peers.count) peer\(peers.count == 1 ? "" : "s") connected"

        await handle?.update(
            progress: progress, dlSpeed: displayDlSpeed, ulSpeed: displayUlSpeed,
            peers: peers.count, state: newState, eta: eta, status: status
        )
    }

    // MARK: - Helpers

    private static func makePeerId() -> Data {
        var id = Data("-CN0001-".utf8)
        while id.count < 20 { id.append(UInt8.random(in: 0...255)) }
        return id
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// Swift actor isolation helpers
private extension PeerConnection {
    func setDelegate(_ d: PeerDelegate) async {
        await self.setDelegateInternal(d)
    }
    func setDelegateInternal(_ d: PeerDelegate) {
        self.delegate = d
    }
}
