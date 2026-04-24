import Foundation
import Observation
import CryptoKit
import Network

@Observable
final class TorrentHandle: Identifiable {
    let id: UUID = .init()
    var meta: Metainfo              // updated when magnet resolves
    var fileSelections: [Bool]      // one entry per meta.files; true = download this file
    var saveDirectory: URL

    var name: String { meta.name }
    var totalSize: Int64 { meta.totalSize }
    var progress: Double = 0
    var downloadSpeed: Int64 = 0
    var uploadSpeed: Int64 = 0
    var state: TorrentState = .stopped
    var peersCount: Int = 0
    var seedsCount: Int = 0
    var eta: Int = 0
    var statusMessage: String = ""

    enum TorrentState: String {
        case stopped, connecting, downloading, seeding, checking, error, metadata
        var label: String {
            self == .metadata ? "Fetching Metadata…" : rawValue.capitalized
        }
    }

    private var engine: TorrentEngine_?

    init(meta: Metainfo, saveDir: URL, fileSelections: [Bool]? = nil,
         persistCallback: ((Data, Metainfo) -> Void)? = nil) {
        self.meta = meta
        self.saveDirectory = saveDir
        self.fileSelections = fileSelections ?? Array(repeating: true, count: meta.files.count)
        let skipped = Set(meta.files.indices.filter { !(self.fileSelections[$0]) })
        self.engine = TorrentEngine_(meta: meta, saveDir: saveDir, skippedFiles: skipped,
                                     handle: self, persistCallback: persistCallback)
    }

    func start() {
        state = meta.pieces.isEmpty ? .metadata : .connecting
        Task { await engine?.start() }
    }

    func stop() {
        state = .stopped
        Task { await engine?.stop() }
    }

    func stopAndWait() async {
        state = .stopped
        await engine?.stop()
    }

    func acceptInbound(_ connection: NWConnection, remoteSupportsExt: Bool) {
        Task { await engine?.acceptInbound(connection, remoteSupportsExt: remoteSupportsExt) }
    }

    // Called by TorrentEngine_ when a magnet link resolves to full metadata.
    @MainActor
    func onMagnetResolved(newMeta: Metainfo) {
        meta = newMeta
        fileSelections = Array(repeating: true, count: newMeta.files.count)
        state = .connecting
    }

    @MainActor
    func update(progress: Double, dlSpeed: Int64, ulSpeed: Int64, peers: Int, seeds: Int,
                state: TorrentState, eta: Int, status: String = "") {
        self.progress = progress
        self.downloadSpeed = dlSpeed
        self.uploadSpeed = ulSpeed
        self.peersCount = peers
        self.seedsCount = seeds
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
    private var meta: Metainfo
    private var store: PieceStore?       // nil while in magnet mode
    private let saveDir: URL
    private var isMagnetMode: Bool
    private var rawMetadata: Data?       // raw info-dict bytes once fetched, for serving peers
    private var skippedFiles: Set<Int>

    private let tracker = TrackerClient()
    private var peers: [any AnyPeer] = []
    private var isRunning = false
    private var useUTPNext = false

    // Peer discovery
    private var pexKnown: Set<String> = []
    private var pexAdded: [(String, UInt16)] = []
    private var pexDropped: [(String, UInt16)] = []

    // Retry queue
    private struct RetryEntry { let ip: String; let port: UInt16; var retryAt: Date; var attempts: Int }
    private var retryQueue: [RetryEntry] = []
    private var peerAttempts: [String: Int] = [:]
    private var blacklist: Set<String> = []

    private var choker = Choker()

    // Speed accumulators
    private var bytesDownloaded: Int64 = 0
    private var bytesUploaded: Int64 = 0
    private var lastSpeedSample: Date = .now
    private var speedDlAccum: Int64 = 0
    private var speedUlAccum: Int64 = 0
    private var displayDlSpeed: Int64 = 0
    private var displayUlSpeed: Int64 = 0

    // BEP 9 — metadata assembly
    private var metadataPieces: [Int: Data] = [:]
    private var metadataTotalSize: Int = 0

    // Called when magnet resolves — lets TorrentEngine persist the .torrent
    var persistCallback: ((Data, Metainfo) -> Void)?

    let peerId: Data
    private weak var handle: TorrentHandle?

    static let maxPeers = 200
    static let port: UInt16 = 6881
    static let pipeline = 200
    static let endgameThreshold = 20

    private var peerInFlight: [ObjectIdentifier: Set<UInt64>] = [:]
    private var globalInFlight: Set<UInt64> = []
    private var trackerTasks: [Task<Void, Never>] = []
    private var rarityDirty = true
    private var trackerStatus = ""

    init(meta: Metainfo, saveDir: URL, skippedFiles: Set<Int>, handle: TorrentHandle,
         persistCallback: ((Data, Metainfo) -> Void)? = nil) {
        self.meta = meta
        self.saveDir = saveDir
        self.skippedFiles = skippedFiles
        self.handle = handle
        self.peerId = Self.makePeerId()
        self.isMagnetMode = meta.pieces.isEmpty
        self.persistCallback = persistCallback

        if !meta.pieces.isEmpty {
            self.store = try? PieceStore(meta: meta, saveDir: saveDir, skippedFiles: skippedFiles)
        }
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        if !isMagnetMode {
            await refreshRarityOrder()
        }

        await announceAndConnect(event: "started")

        DHTBus.shared.register(infoHash: meta.infoHash) { [weak self] peers in
            Task { await self?.connectToPeers(peers.map { TrackerPeer(ip: $0.0, port: $0.1) }) }
        }
        Task { await DHT.shared.findPeers(infoHash: meta.infoHash) }
        startStatsLoop()
    }

    func stop() async {
        isRunning = false
        trackerTasks.forEach { $0.cancel() }
        trackerTasks = []
        DHTBus.shared.unregister(infoHash: meta.infoHash)
        for peer in peers { await peer.disconnect() }
        peers = []
        await store?.closeAll()
    }

    func acceptInbound(_ connection: NWConnection, remoteSupportsExt: Bool) async {
        let peer = PeerConnection(incomingConnection: connection, infoHash: meta.infoHash,
                                  peerId: peerId, totalPieces: meta.pieces.count)
        guard peers.count < Self.maxPeers else { await peer.disconnect(); return }
        peers.append(peer)
        await peer.setDelegateInternal(self)
        await peer.acceptInbound(remoteSupportsExt: remoteSupportsExt)
    }

    // MARK: - Magnet resolution

    private func magnetResolved(newMeta: Metainfo, rawInfo: Data) async {
        isMagnetMode = false
        meta = newMeta
        rawMetadata = rawInfo
        metadataPieces.removeAll()

        store = try? PieceStore(meta: newMeta, saveDir: saveDir, skippedFiles: skippedFiles)

        // Notify handle (UI update) and outer engine (persistence)
        await handle?.onMagnetResolved(newMeta: newMeta)
        persistCallback?(rawInfo, newMeta)

        // Start real download
        await announceAndConnect(event: "started")
        await refreshRarityOrder()

        // Tell already-connected peers our (empty) bitfield
        if let bits = await store?.getBitfield() {
            for peer in peers {
                await peer.sendBitfield(bits)
                await scheduleRequests(for: peer)
            }
        }
    }

    // MARK: - Tracker

    private func announceAndConnect(event: String? = nil) async {
        let downloaded = await store?.downloaded ?? 0
        let left = isMagnetMode ? meta.totalSize : max(0, meta.totalSize - downloaded)
        let trackerURLs = meta.announceList.flatMap { $0 }
        print("[Canopy] Announcing to \(trackerURLs.count) trackers")

        for urlString in trackerURLs {
            guard let url = URL(string: urlString) else { continue }
            let t = Task { [weak self] in
                guard let self else { return }
                let resp: TrackerResponse?
                if url.scheme == "udp" {
                    let client = UDPTrackerClient(url: url)
                    let peers = try? await client.announce(
                        infoHash: meta.infoHash, peerId: peerId,
                        port: Self.port, event: event ?? "",
                        downloaded: bytesDownloaded, left: left, uploaded: bytesUploaded)
                    print("[Canopy] UDP \(urlString): \(peers?.count ?? 0) peers")
                    resp = peers.map { TrackerResponse(interval: 1800, peers: $0) }
                } else if url.scheme == "http" || url.scheme == "https" {
                    do {
                        resp = try await tracker.announce(
                            trackerURL: urlString, infoHash: meta.infoHash,
                            peerId: peerId, port: Self.port,
                            uploaded: bytesUploaded, downloaded: bytesDownloaded,
                            left: left, event: event)
                        print("[Canopy] HTTP \(urlString): \(resp?.peers.count ?? 0) peers")
                    } catch { print("[Canopy] HTTP \(urlString) failed: \(error)"); resp = nil }
                } else { return }

                guard let r = resp, !r.peers.isEmpty else { return }
                let interval = max(60, r.interval)
                await self.connectToPeers(r.peers)
                await self.updateTrackerStatus(added: r.peers.count)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, await self.isRunning else { return }
                await self.announceAndConnect()
            }
            trackerTasks.append(t)
        }
    }

    private func updateTrackerStatus(added: Int) { trackerStatus = "Tracker: \(added) peers found" }

    private func makeConnection(host: String, port: UInt16, totalPieces: Int) -> any AnyPeer {
        useUTPNext.toggle()
        if useUTPNext {
            return UTPConnection(host: host, port: port,
                                 infoHash: meta.infoHash, peerId: peerId, totalPieces: totalPieces)
        } else {
            return PeerConnection(host: host, port: port,
                                  infoHash: meta.infoHash, peerId: peerId, totalPieces: totalPieces)
        }
    }

    private func connectToPeers(_ newPeers: [TrackerPeer]) async {
        let needed = Self.maxPeers - peers.count
        guard needed > 0 else { return }
        let connectedKeys = Set(peers.map { "\($0.host):\($0.port)" })
        let queuedKeys = Set(retryQueue.map { "\($0.ip):\($0.port)" })
        var added = 0
        let totalPieces = meta.pieces.count

        for peer in newPeers {
            guard added < needed else { break }
            let key = "\(peer.ip):\(peer.port)"
            guard !connectedKeys.contains(key), !queuedKeys.contains(key),
                  !blacklist.contains(key) else { continue }
            let conn = makeConnection(host: peer.ip, port: peer.port, totalPieces: totalPieces)
            await conn.setDelegateInternal(self)
            peers.append(conn)
            await conn.connect()
            added += 1
        }
    }

    private func processRetryQueue() async {
        let now = Date.now
        var due: [RetryEntry] = []
        retryQueue = retryQueue.filter { if $0.retryAt <= now { due.append($0); return false }; return true }
        guard !due.isEmpty else { return }
        let needed = Self.maxPeers - peers.count
        guard needed > 0 else { retryQueue.append(contentsOf: due); return }
        let connectedKeys = Set(peers.map { "\($0.host):\($0.port)" })
        let totalPieces = meta.pieces.count
        var added = 0
        for entry in due {
            let key = "\(entry.ip):\(entry.port)"
            guard !blacklist.contains(key), !connectedKeys.contains(key), added < needed else {
                if added >= needed { retryQueue.append(entry) }; continue
            }
            let conn = makeConnection(host: entry.ip, port: entry.port, totalPieces: totalPieces)
            await conn.setDelegateInternal(self)
            peers.append(conn); await conn.connect(); added += 1
        }
    }

    // MARK: - PEX

    private func broadcastPEX() async {
        guard !pexAdded.isEmpty || !pexDropped.isEmpty else { return }
        for peer in peers { await peer.sendPEX(added: pexAdded, dropped: pexDropped) }
        pexAdded = []; pexDropped = []
    }

    // MARK: - Piece scheduling

    private var cachedRarityOrder: [Int] = []

    private func refreshRarityOrder() async {
        let missing = await store?.wantedPieces() ?? []
        guard !missing.isEmpty else { cachedRarityOrder = []; return }
        if missing.count <= Self.endgameThreshold { cachedRarityOrder = missing; return }
        var counts = [Int: Int]()
        for p in peers {
            let bf = await p.bitfield
            for idx in missing where idx < bf.count && bf[idx] { counts[idx, default: 0] += 1 }
        }
        cachedRarityOrder = missing.sorted { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
    }

    private func scheduleRequests(for peer: any AnyPeer) async {
        guard !isMagnetMode, let store else { return }
        if rarityDirty { await refreshRarityOrder(); rarityDirty = false }
        guard await !peer.peerChoking else { return }
        let pid = ObjectIdentifier(peer)
        let slotsLeft = Self.pipeline - (peerInFlight[pid]?.count ?? 0)
        guard slotsLeft > 0, !cachedRarityOrder.isEmpty else { return }
        let isEndgame = cachedRarityOrder.count <= Self.endgameThreshold
        let peerBitfield = await peer.bitfield
        guard !peerBitfield.isEmpty else { return }
        let blocks = await store.blocksToRequest(
            orderedPieces: cachedRarityOrder, peerBitfield: peerBitfield,
            excluding: globalInFlight, endgame: isEndgame, maxBlocks: slotsLeft)
        guard !blocks.isEmpty else { return }
        var myInFlight = peerInFlight[pid] ?? []
        for b in blocks {
            let key = PieceStore.inFlightKey(piece: b.piece, blockIndex: b.offset / PieceStore.blockSize)
            myInFlight.insert(key); globalInFlight.insert(key)
        }
        peerInFlight[pid] = myInFlight
        await peer.requestBlocks(blocks)
    }

    // MARK: - PeerDelegate

    private func clearInFlight(for peer: any AnyPeer) {
        let pid = ObjectIdentifier(peer)
        if let inFlight = peerInFlight[pid] { for k in inFlight { globalInFlight.remove(k) } }
        peerInFlight.removeValue(forKey: ObjectIdentifier(peer))
    }

    func peerDidDisconnect(_ peer: any AnyPeer) async {
        let key = "\(peer.host):\(peer.port)"
        let pid = ObjectIdentifier(peer)
        peers.removeAll { ObjectIdentifier($0) == pid }
        clearInFlight(for: peer)
        pexDropped.append((peer.host, peer.port))
        guard !blacklist.contains(key) else { return }
        let attempts = (peerAttempts[key] ?? 0) + 1
        peerAttempts[key] = attempts
        if attempts > 6 { blacklist.insert(key); peerAttempts.removeValue(forKey: key); return }
        let delay = pow(2.0, Double(attempts - 1)) * 5.0
        retryQueue.removeAll { "\($0.ip):\($0.port)" == key }
        retryQueue.append(RetryEntry(ip: peer.host, port: peer.port,
                                     retryAt: Date.now.addingTimeInterval(delay), attempts: attempts))
    }

    func peerChokedUs(_ peer: any AnyPeer) async { clearInFlight(for: peer) }

    func peerUnchokedUs(_ peer: any AnyPeer) async { await scheduleRequests(for: peer) }

    func peerSentBitfield(_ peer: any AnyPeer) async {
        rarityDirty = true
        let isPeerSeed = await peer.bitfield.allSatisfy { $0 }
        let amISeed = await (store?.progress ?? 0) >= 1.0
        if isPeerSeed && amISeed { await peer.disconnect(); return }
        await scheduleRequests(for: peer)
    }

    func peerSentHave(_ peer: any AnyPeer) async { rarityDirty = true; await scheduleRequests(for: peer) }

    func peerSentBlock(_ peer: any AnyPeer, piece: Int, offset: Int, data: Data) async {
        guard let store else { return }
        let key = PieceStore.inFlightKey(piece: piece, blockIndex: offset / PieceStore.blockSize)
        let pid = ObjectIdentifier(peer)
        globalInFlight.remove(key); peerInFlight[pid]?.remove(key)
        speedDlAccum += Int64(data.count); bytesDownloaded += Int64(data.count)

        do {
            try await store.receiveBlock(piece: piece, offset: offset, data: data)
            if await store.hasPiece(piece) {
                rarityDirty = true
                let missing = await store.missingPieces()
                let isEndgame = missing.count <= Self.endgameThreshold
                let pieceHigh = UInt64(piece)
                for (k, var keys) in peerInFlight { keys = keys.filter { $0 >> 32 != pieceHigh }; peerInFlight[k] = keys }
                globalInFlight = globalInFlight.filter { $0 >> 32 != pieceHigh }
                for p in peers {
                    await p.sendHave(piece: piece)
                    if isEndgame {
                        let pieceBlocks = await store.allBlocksForPiece(piece: piece)
                        for block in pieceBlocks { await p.sendCancel(piece: piece, offset: block.offset, length: block.length) }
                    }
                }
            }
        } catch { print("Error receiving block: \(error)") }
        await scheduleRequests(for: peer)
    }

    func peerSentPEX(_ peer: any AnyPeer, peers newPeers: [(String, UInt16)]) async {
        var toConnect: [TrackerPeer] = []
        for p in newPeers {
            let key = "\(p.0):\(p.1)"
            if !pexKnown.contains(key) && !blacklist.contains(key) {
                pexKnown.insert(key); pexAdded.append(p)
                toConnect.append(TrackerPeer(ip: p.0, port: p.1))
            }
        }
        if !toConnect.isEmpty { await connectToPeers(toConnect) }
    }

    // BEP 9 — peer advertised metadata_size in their extension handshake
    func peerSentExtHandshake(_ peer: any AnyPeer, metadataSize: Int) async {
        guard isMagnetMode else { return }
        if metadataTotalSize == 0 { metadataTotalSize = metadataSize }
        await peer.requestMetadataPiece(0)
    }

    // BEP 9 — we received a metadata piece
    func peerSentMetadata(_ peer: any AnyPeer, piece: Int, totalSize: Int, data: Data) async {
        guard isMagnetMode else { return }
        guard metadataTotalSize == 0 || metadataTotalSize == totalSize else { return }
        metadataTotalSize = totalSize
        metadataPieces[piece] = data

        let expectedPieces = (totalSize + 16383) / 16384
        let nextPiece = (0..<expectedPieces).first { metadataPieces[$0] == nil }
        if let next = nextPiece { await peer.requestMetadataPiece(next); return }

        // All pieces received — assemble and verify SHA1
        var fullMetadata = Data()
        for i in 0..<expectedPieces { guard let p = metadataPieces[i] else { return }; fullMetadata.append(p) }
        guard Data(Insecure.SHA1.hash(data: fullMetadata)) == meta.infoHash else {
            print("[Canopy] BEP9: metadata hash mismatch, discarding")
            metadataPieces.removeAll(); return
        }
        do {
            let newMeta = try Metainfo.fromInfoDict(fullMetadata, infoHash: meta.infoHash, trackers: meta.announceList)
            await magnetResolved(newMeta: newMeta, rawInfo: fullMetadata)
        } catch { print("[Canopy] BEP9: failed to parse metadata: \(error)") }
    }

    // BEP 9 — peer requested a metadata piece from us
    func peerRequestedMetadata(_ peer: any AnyPeer, piece: Int) async {
        guard let raw = rawMetadata else { return }
        let offset = piece * 16384
        guard offset < raw.count else { return }
        let end = min(offset + 16384, raw.count)
        await peer.sendMetadataPiece(piece, totalSize: raw.count, data: Data(raw[offset..<end]))
    }

    func peerConnected(_ peer: any AnyPeer, supportsExtensions: Bool) async {
        print("[Canopy] Peer connected: \(peer.host):\(peer.port) ext=\(supportsExtensions)")
        let bits = await store?.getBitfield() ?? []
        if !bits.isEmpty { await peer.sendBitfield(bits) }
        let key = "\(peer.host):\(peer.port)"
        peerAttempts.removeValue(forKey: key)
        if !pexKnown.contains(key) { pexKnown.insert(key); pexAdded.append((peer.host, peer.port)) }
    }

    func peerRequestedBlock(_ peer: any AnyPeer, piece: Int, offset: Int, length: Int) async {
        let store = self.store
        Task { [weak self] in
            guard let data = try? await store?.readBlock(piece: piece, offset: offset, length: length) else { return }
            await peer.sendPiece(index: piece, begin: offset, block: data)
            await self?.recordUpload(bytes: Int64(data.count))
        }
    }

    private func recordUpload(bytes: Int64) { bytesUploaded += bytes; speedUlAccum += bytes }

    // MARK: - Stats loop

    private func startStatsLoop() {
        Task {
            while isRunning {
                try? await Task.sleep(for: .seconds(1))
                let now = Date.now
                for peer in peers {
                    if now.timeIntervalSince(await peer.lastMessageReceivedTime) > 120 {
                        await peer.disconnect(); continue
                    }
                    if now.timeIntervalSince(await peer.lastBlockReceivedTime) > 15 {
                        let pid = ObjectIdentifier(peer)
                        if !(peerInFlight[pid]?.isEmpty ?? true) { clearInFlight(for: peer) }
                    }
                    await peer.sendKeepAliveIfNeeded()
                    await peer.updateStats()
                    await scheduleRequests(for: peer)
                }
                let isSeeding = await (store?.progress ?? 0) >= 1.0
                await choker.update(peers: peers, isSeeding: isSeeding)
                await broadcastPEX()
                await processRetryQueue()
                await pushStats()
            }
        }
    }

    private func pushStats() async {
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastSpeedSample)
        if elapsed >= 1 {
            displayDlSpeed = Int64(Double(speedDlAccum) / elapsed)
            displayUlSpeed = Int64(Double(speedUlAccum) / elapsed)
            speedDlAccum = 0; speedUlAccum = 0; lastSpeedSample = now
        }

        let progress = await store?.progress ?? 0
        let done = await store?.completedPieces ?? 0
        let newState: TorrentHandle.TorrentState
        if isMagnetMode        { newState = .metadata }
        else if progress >= 1  { newState = .seeding }
        else if !peers.isEmpty { newState = .downloading }
        else                   { newState = .connecting }

        let left = meta.totalSize - Int64(done) * Int64(meta.pieceLength)
        let eta = displayDlSpeed > 0 ? Int(left / max(displayDlSpeed, 1)) : 0
        let retryInfo = retryQueue.isEmpty ? "" : " (\(retryQueue.count) retrying)"

        var seedCount = 0
        for p in peers { let bf = await p.bitfield; if !bf.isEmpty && bf.allSatisfy({ $0 }) { seedCount += 1 } }
        let pCount = peers.count - seedCount
        let status: String
        if isMagnetMode        { status = "Connecting to peers to fetch metadata…" }
        else if peers.isEmpty  { status = trackerStatus + retryInfo }
        else                   { status = "\(seedCount) seed\(seedCount == 1 ? "" : "s"), \(pCount) peer\(pCount == 1 ? "" : "s") connected" }

        await handle?.update(progress: progress, dlSpeed: displayDlSpeed, ulSpeed: displayUlSpeed,
                             peers: pCount, seeds: seedCount, state: newState, eta: eta, status: status)
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
