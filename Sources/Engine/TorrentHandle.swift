import Foundation
import Observation
import CryptoKit
import Network
import UserNotifications

@Observable
final class TorrentHandle: Identifiable {
    let id: UUID = .init()
    let dateAdded: Date = .init()
    var meta: Metainfo              // updated when magnet resolves
    var fileSelections: [Bool]      // one entry per meta.files; true = download this file
    var saveDirectory: URL

    var name: String { meta.name }
    var totalSize: Int64 { meta.totalSize }
    /// Set true when a magnet's metadata arrives and the user still needs to pick which
    /// files to keep. Cleared by `fileSelectionCompleted()`.
    var needsFileSelection: Bool = false
    var selectedSize: Int64 {
        let sel = fileSelections
        guard !sel.isEmpty, sel.count == meta.files.count else { return meta.totalSize }
        var total: Int64 = 0
        for (idx, file) in meta.files.enumerated() where idx < sel.count && sel[idx] {
            total += file.length
        }
        return total
    }
    /// Progress against `selectedSize` rather than `totalSize`. With a 3GB selection of a
    /// 70GB torrent, this hits 1.0 when the user's chosen 3GB is done — matches the
    /// progress bar to what the user actually asked for.
    var progress: Double = 0
    var downloadSpeed: Int64 = 0
    var bytesReceived: Int64 = 0    // bytes of selected content received and verified
    /// Per-file download fractions, [0, 1] each. Indexed parallel to `meta.files`.
    /// Deselected files always read 0.
    var fileProgresses: [Double] = []
    var uploadSpeed: Int64 = 0
    var state: TorrentState = .stopped
    var peersCount: Int = 0
    var seedsCount: Int = 0
    var eta: Int = 0
    var statusMessage: String = ""
    var pieces: [Bool] = []           // completed pieces
    var piecesPending: [Bool] = []    // pieces being downloaded
    var metadataPiecesCount: Int = 0
    var metadataTotalPieces: Int = 0
    var handshakedPeersCount: Int = 0
    var peerInfos: [PeerInfo] = []

    struct PeerInfo: Identifiable {
        var id: String { "\(transport):\(host):\(port)" }
        let host: String
        let port: UInt16
        let transport: String   // "TCP" or "uTP"
        let state: String
        let dlSpeed: Int64
        let ulSpeed: Int64
        let piecesHeld: Int
        let totalPieces: Int
        let peerChoking: Bool
        let amChoking: Bool
        let hasExtension: Bool
        var flags: String {
            var f: [String] = []
            if !peerChoking { f.append("D") }  // we can download (peer not choking us)
            if !amChoking   { f.append("U") }  // we are uploading (we're not choking peer)
            if hasExtension { f.append("e") }  // BEP 10 ext
            return f.isEmpty ? "—" : f.joined(separator: " ")
        }
    }

    enum TorrentState: String {
        case stopped, connecting, downloading, seeding, checking, error, metadata
    }

    var stateLabel: String {
        switch state {
        case .metadata:
            if metadataTotalPieces > 0 {
                return "Metadata (\(metadataPiecesCount)/\(metadataTotalPieces) pieces)"
            } else {
                return "Metadata (\(peersCount) peers)"
            }
        default: return state.rawValue.capitalized
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
        await engine?.closeAll()
    }

    func closeFileHandles() async {
        await engine?.closeAll()
    }

    func updateFileSelection(at index: Int, selected: Bool) {
        guard index < fileSelections.count else { return }
        fileSelections[index] = selected
        needsFileSelection = false
        let skipped = Set(meta.files.indices.filter { !fileSelections[$0] })
        Task { await engine?.updateSkippedFiles(skipped) }
    }

    /// Called by the file-selection UI when the user clicks "Start Download". Releases
    /// the engine's gate so piece data starts flowing.
    func fileSelectionCompleted() {
        needsFileSelection = false
        let skipped = Set(meta.files.indices.filter { !fileSelections[$0] })
        Task { [weak engine] in
            await engine?.updateSkippedFiles(skipped)
            await engine?.releaseFileSelectionGate()
        }
    }

    /// Override the save dir before the PieceStore exists (i.e. between magnet metadata
    /// resolution and the user clicking Start). After PieceStore creation this is a no-op.
    func setSaveDirectory(_ url: URL) {
        saveDirectory = url
        Task { [weak engine] in await engine?.setSaveDir(url) }
    }

    func acceptInbound(_ connection: NWConnection, remoteSupportsExt: Bool) {
        Task { await engine?.acceptInbound(connection, remoteSupportsExt: remoteSupportsExt) }
    }

    func acceptInboundUTP(_ peer: UTPConnection, remoteSupportsExt: Bool) {
        Task { await engine?.acceptInboundUTP(peer, remoteSupportsExt: remoteSupportsExt) }
    }

    /// Routed by `TorrentEngine.handleInboundMSE` after a successful MSE responder
    /// handshake matched our SKEY.
    func acceptInboundMSE(connection: NWConnection,
                          cipher: MSECipher?,
                          decryptedLeftover: Data,
                          remoteSupportsExt: Bool) async {
        await engine?.acceptInboundMSE(connection: connection,
                                       cipher: cipher,
                                       decryptedLeftover: decryptedLeftover,
                                       remoteSupportsExt: remoteSupportsExt)
    }

    // Called by TorrentEngine_ when a magnet link resolves to full metadata.
    @MainActor
    func onMagnetResolved(newMeta: Metainfo) {
        meta = newMeta
        fileSelections = Array(repeating: true, count: newMeta.files.count)
        needsFileSelection = newMeta.files.count > 1
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
    private var saveDir: URL
    private var isMagnetMode: Bool
    private var rawMetadata: Data?       // raw info-dict bytes once fetched, for serving peers
    private var skippedFiles: Set<Int>

    private let tracker = TrackerClient()
    private var peers: [any AnyPeer] = []
    private var isRunning = false
    /// Set true after a magnet's metadata arrives but before the user confirms which
    /// files to keep. Gates `scheduleRequests` so we don't write piece data to disk
    /// before the user has finalized their selection.
    private var awaitingFileSelection = false

    // Peer discovery
    private var pexKnown: Set<String> = []
    private var pexAdded: [(String, UInt16)] = []
    private var pexDropped: [(String, UInt16)] = []

    // Retry queue
    private struct RetryEntry { let ip: String; let port: UInt16; var retryAt: Date; var attempts: Int }
    private var retryQueue: [RetryEntry] = []
    private var peerAttempts: [String: Int] = [:]
    private var blacklist: Set<String> = []
    /// Hosts whose MSE handshake failed — next dial uses plaintext to skip retry.
    private var mseDisabledHosts: Set<String> = []

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

    static let maxPeers = 500
    static let port: UInt16 = 6881
    static let pipeline = 500
    /// Per-peer in-flight cap. Prevents a single slow peer from monopolising the global
    /// pipeline budget — fast peers always get slots even if a stalled peer hasn't been
    /// cleared yet.
    static let peerPipeline = 100
    // Enter endgame at 50 pieces remaining (was 20). In endgame the same block is
    // requested from multiple peers; whoever delivers first wins, the rest get CANCEL.
    // Earlier entry = fewer trailing-tail stalls on the last 1–2% of a torrent.
    static let endgameThreshold = 50

    private var peerInFlight: [ObjectIdentifier: Set<UInt64>] = [:]
    private var globalInFlight: Set<UInt64> = []
    private var trackerTasks: [Task<Void, Never>] = []
    private var rarityDirty = true
    private var trackerStatus = ""
    private var didSendCompleted = false

    /// Incremental rarity counter — pieceCounts[i] = number of connected peers that
    /// have piece i. Updated on HAVE / bitfield events instead of recomputing from
    /// scratch every tick, eliminating the O(peers × pieces) refresh loop.
    private var pieceCounts: [Int] = []

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
            self.pieceCounts = Array(repeating: 0, count: meta.pieces.count)
        }
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        if !isMagnetMode {
            // If we have a saved bitfield, verify pieces on disk before downloading more.
            // This catches corrupted or partially-written blocks from a previous run.
            let savedPieces = await store?.completedPieces ?? 0
            if savedPieces > 0 {
                let h = handle
                await MainActor.run { h?.state = .checking }
                await store?.fullVerification()
                let h2 = handle
                await MainActor.run { h2?.state = .connecting }
            }
            await refreshRarityOrder()
        }

        await announceAndConnect(event: "started")

        if !meta.isPrivate {
            DHTBus.shared.register(infoHash: meta.infoHash) { [weak self] peers in
                Task { await self?.connectToPeers(peers.map { TrackerPeer(ip: $0.0, port: $0.1) }) }
            }
            // Local Peer Discovery (BEP 14). Multicast on the LAN — peers on the same
            // network can saturate gigabit, way above any internet seed.
            let infoHash = meta.infoHash
            Task {
                await LocalPeerDiscovery.shared.register(infoHash: infoHash) { [weak self] ip, port in
                    Task { await self?.connectToPeers([TrackerPeer(ip: ip, port: port)]) }
                }
            }
            Task {
                await DHT.shared.findPeers(infoHash: meta.infoHash)
                if isMagnetMode {
                    await DHT.shared.announcePeer(infoHash: meta.infoHash, port: 6881)
                }
            }
        }
        startStatsLoop()
    }

    func updateSkippedFiles(_ skipped: Set<Int>) async {
        self.skippedFiles = skipped
        await store?.updateSkippedFiles(skipped)
    }

    /// Updates the save dir. Only effective before the PieceStore is created (i.e. during
    /// the magnet-resolved-but-not-yet-confirmed window).
    func setSaveDir(_ url: URL) async {
        guard store == nil else { return }
        saveDir = url
    }

    /// Called after the user finalizes file selection in the magnet flow. Builds the
    /// PieceStore with the chosen `skippedFiles` and starts piece downloads.
    func releaseFileSelectionGate() async {
        guard awaitingFileSelection else { return }
        awaitingFileSelection = false
        if store == nil {
            store = try? PieceStore(meta: meta, saveDir: saveDir, skippedFiles: skippedFiles)
        }
        await announceAndConnect(event: "started")
        await refreshRarityOrder()
        if let bits = await store?.getBitfield() {
            for peer in peers {
                await peer.sendBitfield(bits)
                await scheduleRequests(for: peer)
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        trackerTasks.forEach { $0.cancel() }
        trackerTasks = []

        // Fire-and-forget "stopped" announce so trackers know we're leaving
        if !isMagnetMode {
            await sendOneShot(event: "stopped")
        }

        DHTBus.shared.unregister(infoHash: meta.infoHash)
        let ih = meta.infoHash
        Task { await LocalPeerDiscovery.shared.unregister(infoHash: ih) }
        for peer in peers { await peer.disconnect() }
        peers = []
    }

    func closeAll() async {
        await store?.closeAll()
    }

    /// Fire a single one-shot tracker announce (no repeat, no error handling beyond print).
    private func sendOneShot(event: String) async {
        let infoHash = meta.infoHash
        let peerId   = self.peerId
        let dl       = bytesDownloaded
        let ul       = bytesUploaded
        let left: Int64 = event == "completed" ? 0 : max(0, meta.totalSize - (await store?.downloaded ?? 0))
        let urls     = meta.announceList.flatMap { $0 }
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            if url.scheme == "udp" {
                let client = UDPTrackerClient(url: url)
                _ = try? await client.announce(infoHash: infoHash, peerId: peerId,
                    port: Self.port, event: event, downloaded: dl, left: left, uploaded: ul)
            } else if url.scheme == "http" || url.scheme == "https" {
                _ = try? await tracker.announce(trackerURL: urlString, infoHash: infoHash,
                    peerId: peerId, port: Self.port, uploaded: ul, downloaded: dl,
                    left: left, event: event)
            }
        }
    }

    func acceptInbound(_ connection: NWConnection, remoteSupportsExt: Bool) async {
        let peer = PeerConnection(incomingConnection: connection, infoHash: meta.infoHash,
                                  peerId: peerId, totalPieces: meta.pieces.count, isPrivate: meta.isPrivate)
        guard peers.count < Self.maxPeers else { await peer.disconnect(); return }
        peers.append(peer)
        await peer.setDelegateInternal(self)
        await peer.acceptInbound(remoteSupportsExt: remoteSupportsExt)
    }

    func acceptInboundUTP(_ peer: UTPConnection, remoteSupportsExt: Bool) async {
        await peer.bindInbound(infoHash: meta.infoHash, peerId: peerId, totalPieces: meta.pieces.count, isPrivate: meta.isPrivate)
        guard peers.count < Self.maxPeers else { peer.disconnect(); return }
        peers.append(peer)
        peer.setDelegateInternal(self)
        await peer.acceptInbound(remoteSupportsExt: remoteSupportsExt)
    }

    func acceptInboundMSE(connection: NWConnection,
                          cipher: MSECipher?,
                          decryptedLeftover: Data,
                          remoteSupportsExt: Bool) async {
        let peer = PeerConnection(incomingConnection: connection, infoHash: meta.infoHash,
                                  peerId: peerId, totalPieces: meta.pieces.count, isPrivate: meta.isPrivate)
        guard peers.count < Self.maxPeers else { await peer.disconnect(); return }
        peers.append(peer)
        await peer.setDelegateInternal(self)
        await peer.acceptInboundMSE(cipher: cipher,
                                    decryptedLeftover: decryptedLeftover,
                                    remoteSupportsExt: remoteSupportsExt)
    }

    // MARK: - Magnet resolution

    private func magnetResolved(newMeta: Metainfo, rawInfo: Data) async {
        isMagnetMode = false
        meta = newMeta
        rawMetadata = rawInfo
        metadataPieces.removeAll()
        pieceCounts = Array(repeating: 0, count: newMeta.pieces.count)

        // Defer creating the PieceStore (which lays files on disk) until the user picks
        // which files to keep. Single-file torrents have nothing to choose, so they
        // start downloading immediately.
        if newMeta.files.count > 1 {
            awaitingFileSelection = true
        } else {
            store = try? PieceStore(meta: newMeta, saveDir: saveDir, skippedFiles: skippedFiles)
        }

        // Notify handle (UI update) and outer engine (persistence)
        await handle?.onMagnetResolved(newMeta: newMeta)
        persistCallback?(rawInfo, newMeta)

        // Start real download — only if we don't need to wait for the user.
        guard !awaitingFileSelection else { return }
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
        var trackerURLs = meta.announceList.flatMap { $0 }
        guard !trackerURLs.isEmpty else { return }

        // BEP 48 — on the very first announce, scrape HTTP trackers in parallel and
        // sort by swarm size so the busiest tracker is contacted first → first peers
        // arrive faster. Bound the scrape phase to 3 s so a slow tracker can't delay us.
        if event == "started", trackerURLs.count > 1 {
            let httpURLs = trackerURLs.filter { $0.hasPrefix("http") }
            if httpURLs.count > 1 {
                let infoHash = meta.infoHash
                let scrapes = await withTaskGroup(of: (String, Int).self) { group in
                    for url in httpURLs {
                        group.addTask { [weak self] in
                            guard let self else { return (url, 0) }
                            let scrape = try? await withThrowingTaskGroup(of: TrackerScrape?.self) { g in
                                g.addTask { try await self.tracker.scrape(trackerURL: url, infoHash: infoHash) }
                                g.addTask { try await Task.sleep(for: .seconds(3)); return nil }
                                let result = try await g.next() ?? nil
                                g.cancelAll()
                                return result
                            }
                            return (url, (scrape ?? nil)?.quality ?? 0)
                        }
                    }
                    var results: [(String, Int)] = []
                    for await r in group { results.append(r) }
                    return results
                }
                let scoreMap = Dictionary(uniqueKeysWithValues: scrapes)
                trackerURLs.sort { (scoreMap[$0] ?? 0) > (scoreMap[$1] ?? 0) }
            }
        }

        // Capture immutable values so the Task closure doesn't need actor hops for them
        let capturedInfoHash = meta.infoHash
        let capturedPeerId   = peerId

        for urlString in trackerURLs {
            guard let url = URL(string: urlString) else { continue }
            let t = Task { [weak self] in
                guard let self else { return }
                var firstEvent: String? = event   // only sent on the first iteration
                var backoff: Double = 30          // retry delay on tracker failure

                while !Task.isCancelled {
                    guard await self.isRunning else { return }

                    // Snapshot mutable state via actor hops before the async announce call
                    let dl           = await self.bytesDownloaded
                    let ul           = await self.bytesUploaded
                    let done         = await self.store?.downloaded ?? 0
                    let isMagnet     = await self.isMagnetMode
                    let metaSize     = await self.meta.totalSize
                    let left: Int64  = isMagnet ? metaSize : max(0, metaSize - done)

                    let resp: TrackerResponse?
                    if url.scheme == "udp" {
                        let client = UDPTrackerClient(url: url)
                        let peers = try? await client.announce(
                            infoHash: capturedInfoHash, peerId: capturedPeerId,
                            port: Self.port, event: firstEvent ?? "",
                            downloaded: dl, left: left, uploaded: ul)
                        print("[Canopy] UDP \(urlString): \(peers?.count ?? 0) peers")
                        resp = peers.map { TrackerResponse(interval: 1800, peers: $0) }
                    } else if url.scheme == "http" || url.scheme == "https" {
                        resp = try? await self.tracker.announce(
                            trackerURL: urlString, infoHash: capturedInfoHash,
                            peerId: capturedPeerId, port: Self.port,
                            uploaded: ul, downloaded: dl, left: left, event: firstEvent)
                        print("[Canopy] HTTP \(urlString): \(resp?.peers.count ?? 0) peers")
                    } else { return }

                    firstEvent = nil  // subsequent iterations carry no event

                    if let r = resp {
                        backoff = 30  // reset on success
                        if !r.peers.isEmpty {
                            await self.connectToPeers(r.peers)
                            await self.updateTrackerStatus(added: r.peers.count)
                        }
                        let interval = Double(max(60, r.interval))
                        try? await Task.sleep(for: .seconds(interval))
                    } else {
                        print("[Canopy] Tracker \(urlString) failed, retry in \(Int(backoff))s")
                        try? await Task.sleep(for: .seconds(backoff))
                        backoff = min(backoff * 2, 3_600)  // cap at 1 hour
                    }
                }
            }
            trackerTasks.append(t)
        }
    }

    private func updateTrackerStatus(added: Int) { trackerStatus = "Tracker: \(added) peers found" }

    /// Mix of outbound transports: 50% TCP / 50% uTP. uTP uses LEDBAT congestion control
    /// which fills idle bandwidth more aggressively without triggering TCP backoff on fast
    /// connections. Peers behind TCP-blocking firewalls are also reachable via uTP.
    private var transportTick: Int = 0

    private func makeConnection(host: String, port: UInt16, totalPieces: Int) -> any AnyPeer {
        transportTick &+= 1
        if (transportTick % 2) == 0 {
            return UTPConnection(host: host, port: port,
                                 infoHash: meta.infoHash, peerId: peerId,
                                 totalPieces: totalPieces, isPrivate: meta.isPrivate)
        }
        return PeerConnection(host: host, port: port,
                              infoHash: meta.infoHash, peerId: peerId,
                              totalPieces: totalPieces, isPrivate: meta.isPrivate)
    }

    private func connectToPeers(_ newPeers: [TrackerPeer]) async {
        let needed = Self.maxPeers - peers.count
        guard needed > 0 else { return }
        let connectedKeys = Set(peers.map { "\($0.host):\($0.port)" })
        let queuedKeys = Set(retryQueue.map { "\($0.ip):\($0.port)" })
        var added = 0
        let totalPieces = meta.pieces.count
        var fresh: [any AnyPeer] = []

        for peer in newPeers {
            guard added < needed else { break }
            let key = "\(peer.ip):\(peer.port)"
            guard !connectedKeys.contains(key), !queuedKeys.contains(key),
                  !blacklist.contains(key) else { continue }
            let conn = makeConnection(host: peer.ip, port: peer.port, totalPieces: totalPieces)
            await conn.setDelegateInternal(self)
            if mseDisabledHosts.contains(key), let tcp = conn as? PeerConnection {
                await tcp.setMSEMode(.disabled)
            }
            peers.append(conn)
            fresh.append(conn)
            added += 1
        }
        // Kick all dials off in parallel — the actor doesn't block on connect(), so
        // connections race in the network stack instead of serializing one at a time.
        for conn in fresh { Task { await conn.connect() } }
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
        var fresh: [any AnyPeer] = []
        for entry in due {
            let key = "\(entry.ip):\(entry.port)"
            guard !blacklist.contains(key), !connectedKeys.contains(key), added < needed else {
                if added >= needed { retryQueue.append(entry) }; continue
            }
            let conn = makeConnection(host: entry.ip, port: entry.port, totalPieces: totalPieces)
            await conn.setDelegateInternal(self)
            if mseDisabledHosts.contains(key), let tcp = conn as? PeerConnection {
                await tcp.setMSEMode(.disabled)
            }
            peers.append(conn)
            fresh.append(conn)
            added += 1
        }
        // Parallel retry dials.
        for conn in fresh { Task { await conn.connect() } }
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
        // Use the incrementally-maintained pieceCounts array — no actor hops, no
        // O(peers × pieces) loop. Counts are kept current by peerSentBitfield /
        // peerSentHave / peerDidDisconnect.
        cachedRarityOrder = missing.sorted {
            let a = $0 < pieceCounts.count ? pieceCounts[$0] : 0
            let b = $1 < pieceCounts.count ? pieceCounts[$1] : 0
            return a < b
        }
    }

    private func scheduleRequests(for peer: any AnyPeer) async {
        // While `awaitingFileSelection` is true (magnet metadata just arrived, user
        // hasn't picked files yet), don't request piece data — keeps disk untouched
        // until the user finalizes which files to keep.
        guard !isMagnetMode, let store, !awaitingFileSelection else { return }
        if rarityDirty { await refreshRarityOrder(); rarityDirty = false }
        guard await !peer.isClosed, await !peer.peerChoking else { return }
        let pid = ObjectIdentifier(peer)
        let perPeerUsed = peerInFlight[pid]?.count ?? 0
        // Enforce both a per-peer cap (peerPipeline) and the global cap (pipeline) so
        // one slow/stalled peer cannot monopolise the entire in-flight budget.
        let slotsLeft = min(
            Self.peerPipeline - perPeerUsed,
            Self.pipeline - globalInFlight.count
        )
        guard slotsLeft > 0, !cachedRarityOrder.isEmpty else { return }
        let isEndgame = cachedRarityOrder.count <= Self.endgameThreshold
        let peerBitfield = await peer.bitfield
        guard !peerBitfield.isEmpty else { return }

        if isEndgame {
            // True endgame: flood every unchoked peer with every missing block so the
            // last pieces finish as fast as possible. The first delivery wins; the rest
            // receive CANCEL messages in peerSentBlock.
            for p in peers {
                guard await !p.isClosed, await !p.peerChoking else { continue }
                let epid = ObjectIdentifier(p)
                let epUsed = peerInFlight[epid]?.count ?? 0
                let epSlots = min(Self.peerPipeline - epUsed, Self.pipeline - globalInFlight.count)
                guard epSlots > 0 else { continue }
                let epBitfield = await p.bitfield
                guard !epBitfield.isEmpty else { continue }
                let blocks = await store.blocksToRequest(
                    orderedPieces: cachedRarityOrder, peerBitfield: epBitfield,
                    excluding: [], endgame: true, maxBlocks: epSlots)
                guard !blocks.isEmpty else { continue }
                var myInFlight = peerInFlight[epid] ?? []
                for b in blocks {
                    let key = PieceStore.inFlightKey(piece: b.piece, blockIndex: b.offset / PieceStore.blockSize)
                    myInFlight.insert(key); globalInFlight.insert(key)
                }
                peerInFlight[epid] = myInFlight
                await p.requestBlocks(blocks)
            }
            return
        }

        let blocks = await store.blocksToRequest(
            orderedPieces: cachedRarityOrder, peerBitfield: peerBitfield,
            excluding: globalInFlight, endgame: false, maxBlocks: slotsLeft)
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

    /// PeerConnection signals here when an MSE handshake fails. Marks the host
    /// "plaintext-only" for subsequent retries.
    func peerMSEHandshakeFailed(host: String, port: UInt16) async {
        let key = "\(host):\(port)"
        mseDisabledHosts.insert(key)
        if mseDisabledHosts.count > 5_000 { mseDisabledHosts.removeFirst() }
    }

    func peerDidDisconnect(_ peer: any AnyPeer) async {
        let key = "\(peer.host):\(peer.port)"
        let pid = ObjectIdentifier(peer)
        // Decrement pieceCounts for every piece this peer held
        let bf = await peer.bitfield
        for (i, has) in bf.enumerated() where has && i < pieceCounts.count {
            pieceCounts[i] = max(0, pieceCounts[i] - 1)
        }
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

    func peerChokedUs(_ peer: any AnyPeer) async {
        clearInFlight(for: peer)
        // Immediately offer those slots to other unchoked peers rather than
        // waiting up to 1 second for the next stats-loop tick.
        let pid = ObjectIdentifier(peer)
        for p in peers where ObjectIdentifier(p) != pid {
            if await !p.peerChoking { await scheduleRequests(for: p) }
        }
    }

    func peerUnchokedUs(_ peer: any AnyPeer) async { await scheduleRequests(for: peer) }

    func peerSentBitfield(_ peer: any AnyPeer) async {
        rarityDirty = true
        let bf = await peer.bitfield
        // Populate incremental rarity counters from the full bitfield
        if pieceCounts.isEmpty && !bf.isEmpty { pieceCounts = Array(repeating: 0, count: bf.count) }
        for (i, has) in bf.enumerated() where has && i < pieceCounts.count { pieceCounts[i] += 1 }
        let isPeerSeed = bf.allSatisfy { $0 }
        let amISeed = await (store?.progress ?? 0) >= 1.0
        if isPeerSeed && amISeed {
            clearInFlight(for: peer)
            await peer.disconnect()
            return
        }
        await scheduleRequests(for: peer)
    }

    func peerSentHave(_ peer: any AnyPeer) async {
        rarityDirty = true
        // Bump the count for the newly announced piece
        let bf = await peer.bitfield
        if let idx = bf.lastIndex(of: true), idx < pieceCounts.count { pieceCounts[idx] += 1 }
        await scheduleRequests(for: peer)
    }

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
                // Decrement rarity counter — piece is now complete, no longer wanted
                if piece < pieceCounts.count { pieceCounts[piece] = 0 }
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
        guard !meta.isPrivate else { return }
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
        let pieceSize = min(16384, totalSize - (piece * 16384))
        guard data.count >= pieceSize else {
            print("[Canopy] BEP9: received truncated piece \(piece) (\(data.count) < \(pieceSize))")
            return
        }
        metadataPieces[piece] = data.prefix(pieceSize)
        print("[Canopy] BEP9: received piece \(piece)/\( (totalSize + 16383) / 16384 ) from \(peer.host)")

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

    private func requestMetadataPieces() async {
        guard isMagnetMode else { return }
        let expected = metadataTotalSize > 0 ? (metadataTotalSize + 16383) / 16384 : 1
        var candidates: [any AnyPeer] = []
        for p in peers { if await p.extMetadata != nil { candidates.append(p) } }
        guard !candidates.isEmpty else { return }

        for i in 0..<expected where metadataPieces[i] == nil {
            // Request each missing piece from up to 3 different peers in parallel
            for j in 0..<min(3, candidates.count) {
                let peer = candidates[(i + j) % candidates.count]
                await peer.requestMetadataPiece(i)
            }
        }
    }

    func peerRejectedMetadata(_ peer: any AnyPeer, piece: Int) async {
        print("[Canopy] BEP9: peer \(peer.host) rejected metadata request for piece \(piece)")
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
        if bits.contains(true) { await peer.sendBitfield(bits) }
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

    private var lastDHTQuery: Date = .distantPast

    private func startStatsLoop() {
        Task {
            while isRunning {
                try? await Task.sleep(for: .seconds(1))
                let now = Date.now

                // Pass 1: housekeeping + track which peers had stale in-flight cleared.
                // Do NOT schedule requests here — ordering matters (see Pass 2).
                var stalledPids = Set<ObjectIdentifier>()
                var toRemove: [ObjectIdentifier] = []
                for peer in peers {
                    let pid = ObjectIdentifier(peer)
                    let idle = now.timeIntervalSince(await peer.lastMessageReceivedTime)
                    // Prune peers that never completed handshake within 5 s, or went silent for 2 min.
                    // Free their in-flight slots immediately so other peers can claim them.
                    let handshaked = await peer.lastHandshakeReceivedTime != .distantPast
                    if (!handshaked && idle > 5) || idle > 120 {
                        clearInFlight(for: peer)
                        toRemove.append(pid)
                        await peer.disconnect()
                        continue
                    }
                    // If a peer has stopped delivering blocks for 0.5 s, free their in-flight
                    // slots so other peers can claim them immediately. Mark as stalled so we
                    // schedule them last in Pass 2.
                    if now.timeIntervalSince(await peer.lastBlockReceivedTime) > 0.5 {
                        if !(peerInFlight[pid]?.isEmpty ?? true) {
                            clearInFlight(for: peer)
                            stalledPids.insert(pid)
                        }
                    }
                    await peer.sendKeepAliveIfNeeded()
                    await peer.updateStats()
                }
                // Remove force-disconnected peers from the active list immediately so Pass 2
                // doesn't try to re-fill globalInFlight through them.
                if !toRemove.isEmpty {
                    peers.removeAll { toRemove.contains(ObjectIdentifier($0)) }
                }

                // Pass 2: schedule active peers first so they claim the freed slots, then
                // stalled peers pick up whatever remains. This prevents a stalled peer from
                // immediately re-filling globalInFlight and blocking faster peers.
                for peer in peers where !stalledPids.contains(ObjectIdentifier(peer)) {
                    await scheduleRequests(for: peer)
                }
                for peer in peers where stalledPids.contains(ObjectIdentifier(peer)) {
                    await scheduleRequests(for: peer)
                }

                if isMagnetMode {
                    await requestMetadataPieces()
                }

                // Periodic DHT — adaptive interval: query every 8 s when starved for peers
                // (< 10 connected), otherwise every 30 s. Runs for all non-private torrents
                // while we still need more peers, not just in magnet mode.
                if !meta.isPrivate && (isMagnetMode || peers.count < 30) {
                    let dhtInterval: TimeInterval = peers.count < 10 ? 8 : 30
                    if now.timeIntervalSince(lastDHTQuery) >= dhtInterval {
                        lastDHTQuery = now
                        Task { await DHT.shared.findPeers(infoHash: meta.infoHash) }
                        Task { await DHT.shared.announcePeer(infoHash: meta.infoHash, port: 6881) }
                    }
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

        let dlSpeed = displayDlSpeed
        let ulSpeed = displayUlSpeed
        // Effective progress against *selected* size, not total. With 3GB selected of a
        // 70GB torrent, the bar fills to 100% when those 3GB are done — matches the
        // user's mental model and the speed counter.
        let selSize        = await store?.selectedSize ?? meta.totalSize
        let downloadedSel  = await store?.downloadedSelected ?? 0
        let progressValue: Double = selSize > 0
            ? min(1.0, Double(downloadedSel) / Double(selSize))
            : (await store?.progress ?? 0)
        let done = await store?.completedPieces ?? 0
        // Per-file progress — deselected files always read 0 (they're never written).
        var fileProgresses: [Double] = Array(repeating: 0, count: meta.files.count)
        if let s = store {
            for i in meta.files.indices {
                fileProgresses[i] = await s.fileProgress(i)
            }
        }

        // Batch all per-peer reads into a single snapshot struct per peer to minimise
        // actor hops — one hop per peer instead of 7+.
        struct PeerSnap {
            var bitfield: [Bool]
            var pState: String
            var dl: Int64
            var ul: Int64
            var choking: Bool
            var amChoke: Bool
            var hasExt: Bool
            var handshaked: Bool
        }
        var snapshots: [TorrentHandle.PeerInfo] = []
        var seedCount = 0
        var hCountVal = 0
        for p in peers {
            let bf      = await p.bitfield
            let pState  = await p.state
            let dl      = await p.downloadSpeed
            let ul      = await p.uploadSpeed
            let choking = await p.peerChoking
            let amChoke = await p.amChoking
            let hasExt  = await p.extMetadata != nil
            let hs      = await p.lastHandshakeReceivedTime != .distantPast
            if hs { hCountVal += 1 }
            let isSeed = !bf.isEmpty && bf.allSatisfy { $0 }
            if isSeed { seedCount += 1 }
            snapshots.append(TorrentHandle.PeerInfo(
                host: p.host, port: p.port,
                transport: p.transportName,
                state: pState.rawValue,
                dlSpeed: dl, ulSpeed: ul,
                piecesHeld: bf.filter { $0 }.count,
                totalPieces: bf.count,
                peerChoking: choking, amChoking: amChoke,
                hasExtension: hasExt
            ))
        }
        let pCount = peers.count - seedCount

        let newState: TorrentHandle.TorrentState
        if isMagnetMode            { newState = .metadata }
        else if progressValue >= 1 { newState = .seeding }
        else if !peers.isEmpty     { newState = .downloading }
        else                       { newState = .connecting }

        // Detect download completion — send "completed" announce and notify user once
        if newState == .seeding && !didSendCompleted {
            didSendCompleted = true
            Task { [weak self] in await self?.sendOneShot(event: "completed") }
            let torrentName = meta.name
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                content.title = "Download Complete"
                content.body  = torrentName
                content.sound = .default
                let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await center.add(req)
            }
        }

        let left = max(0, meta.totalSize - Int64(done) * Int64(meta.pieceLength))
        let eta = dlSpeed > 0 ? Int(left / max(dlSpeed, 1)) : 0
        let retryInfo = retryQueue.isEmpty ? "" : " (\(retryQueue.count) retrying)"

        let status: String
        if isMagnetMode {
            let mCount = metadataPieces.count
            let mTotal = metadataTotalSize > 0 ? (metadataTotalSize + 16383) / 16384 : 0
            if mTotal > 0 {
                status = "Fetching metadata... (\(mCount)/\(mTotal) pieces)"
            } else {
                status = "Searching for metadata... (\(peers.count) connected, \(hCountVal) handshaked)"
            }
        }
        else if peers.isEmpty  { status = trackerStatus + retryInfo }
        else                   { status = "\(seedCount) seed\(seedCount == 1 ? "" : "s"), \(pCount) peer\(pCount == 1 ? "" : "s") connected" }

        let pMap = await store?.bitfieldCopy ?? []
        // In-flight piece bitmap (one bit per piece that has at least one block requested
        // but not yet received). Used by the piece-map view to color partially-loaded
        // pieces differently from unstarted ones.
        var inFlightPieces = Array(repeating: false, count: pMap.count)
        for (_, blocks) in peerInFlight {
            for key in blocks {
                let p = Int(key >> 32)
                if p < inFlightPieces.count { inFlightPieces[p] = true }
            }
        }

        let finalSeedCount = seedCount
        let finalPCount = pCount
        let finalStatus = status
        let finalEta = eta
        let mCount = metadataPieces.count
        let mTotal = metadataTotalSize > 0 ? (metadataTotalSize + 16383) / 16384 : 0
        let h = self.handle
        let finalBytesReceived = min(downloadedSel, selSize)
        let finalSelectedSize  = selSize
        let finalFileProgresses = fileProgresses
        let finalHCount = hCountVal
        let finalSnapshots = snapshots
        let finalInFlightPieces = inFlightPieces

        await MainActor.run { [weak h] in
            guard let handle = h else { return }
            handle.progress = progressValue
            handle.downloadSpeed = dlSpeed
            handle.bytesReceived = finalBytesReceived
            handle.fileProgresses = finalFileProgresses
            handle.uploadSpeed = ulSpeed
            _ = finalSelectedSize  // (already exposed via TorrentHandle.selectedSize getter)
            handle.peersCount = finalPCount
            handle.seedsCount = finalSeedCount
            handle.statusMessage = finalStatus
            handle.pieces = pMap
            handle.piecesPending = finalInFlightPieces
            handle.state = newState
            handle.eta = finalEta
            handle.metadataPiecesCount = mCount
            handle.metadataTotalPieces = mTotal
            handle.handshakedPeersCount = finalHCount
            handle.peerInfos = finalSnapshots
        }
    }

    // MARK: - Helpers

    private static func makePeerId() -> Data {
        var id = Data("-qB4500-".utf8)
        while id.count < 20 { id.append(UInt8.random(in: 0...255)) }
        return id
    }
}
