import Foundation
import Network

/// Pure-Swift BitTorrent engine. Manages multiple DownloadCoordinator actors,
/// publishes TorrentStatus snapshots, handles magnet metadata fetching.
@MainActor
public final class CanopyEngine: ObservableObject {
    @Published public var torrents: [TorrentStatus] = []
    @Published public var sessionError: String?

    private var coordinators:  [String: DownloadCoordinator] = [:]   // infoHash hex → coordinator
    private var torrentMetas:  [String: TorrentFile] = [:]           // parsed metadata
    private var torrentSavePaths: [String: String] = [:]             // savePath per torrent
    private var tasks:         [String: Task<Void, Never>] = [:]     // per-torrent download/seed tasks
    private var pausedIDs:     Set<String> = []
    private var pendingRemovals: Set<String> = []
    private var pendingFileDeletions: [String: String] = [:]
    private var metadataCallbacks: [String: [([PendingFile]) -> Void]] = [:]
    private var pendingMagnets: [String: MagnetSession] = [:]
    private var magnetTasks:  [String: Task<Void, Never>] = [:]
    private var dhtSession:   DHTSession?
    private var pollTask: Task<Void, Never>?
    private var lastRates: [String: (downloaded: Int64, uploaded: Int64, timestamp: Date)] = [:]
    private var fileProgressCache: [String: [Int64]] = [:]                       // updated every poll tick
    private var filePrioritiesCache: [String: [Int: FilePriority]] = [:]         // mirrors coordinator state
    public let settings: EngineSettings

    public init(settings: EngineSettings = EngineSettings()) {
        self.settings = settings
    }

    public func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        for (_, task) in magnetTasks { task.cancel() }
        magnetTasks.removeAll()
        for (_, task) in tasks { task.cancel() }
        for (_, c) in coordinators {
            Task { await c.shutdown() }
        }
        coordinators.removeAll()
        Task { await dhtSession?.shutdown() }
        dhtSession = nil
    }

    // MARK: - Polling

    public func startPolling(interval: TimeInterval = 2.0) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func poll() async {
        var snapshots: [TorrentStatus] = []
        let now = Date()
        for (id, c) in coordinators where !pendingRemovals.contains(id) {
            guard let meta = torrentMetas[id] else { continue }
            let snap = await c.statusSnapshot()
            fileProgressCache[id] = await c.fileProgress()
            let prev = lastRates[id]
            let elapsed = prev.map { max(now.timeIntervalSince($0.timestamp), 0.1) } ?? 2.0
            let dlDelta = prev.map { snap.downloaded - $0.downloaded } ?? 0
            let ulDelta = prev.map { snap.uploaded - $0.uploaded } ?? 0
            let downloadRate = max(0, Int(Double(dlDelta) / elapsed))
            let uploadRate   = max(0, Int(Double(ulDelta) / elapsed))
            lastRates[id] = (snap.downloaded, snap.uploaded, now)
            let eta: Int64 = downloadRate > 0
                ? Int64((meta.totalSize - snap.downloaded) / Int64(downloadRate))
                : -1
            let isPaused = pausedIDs.contains(id)
            snapshots.append(TorrentStatus(
                id: id, name: meta.name, savePath: torrentSavePaths[id] ?? "",
                totalSize: meta.totalSize, totalDone: snap.downloaded,
                totalUploaded: snap.uploaded, downloadRate: downloadRate,
                uploadRate: uploadRate, progress: snap.totalPieces > 0
                    ? Float(snap.completedPieces) / Float(snap.totalPieces) : 0,
                numSeeds: snap.seederCount, numPeers: snap.connectedPeers,
                etaSeconds: eta, state: snap.state, isPaused: isPaused,
                errorMessage: snap.errorMessage
            ))
        }
        self.torrents = snapshots
    }

    // MARK: - Adding torrents

    public func addTorrentFile(at path: String, saveTo saveDir: String,
                               priorities: [Int: FilePriority] = [:]) {
        let expanded = (saveDir as NSString).expandingTildeInPath
        do {
            let torrent = try TorrentParser.parse(path: path)
            let id = torrent.infoHash.hex
            guard coordinators[id] == nil else { return }
            startTorrent(torrent: torrent, id: id, savePath: expanded, filePriorities: priorities)
        } catch {
            NSLog("[CanopyEngine] Failed to parse torrent: \(error)")
        }
    }

    public func addMagnetLink(_ uri: String, saveTo saveDir: String,
                               priorities: [Int: FilePriority] = [:]) {
        let expanded = (saveDir as NSString).expandingTildeInPath
        guard let magnet = MagnetLink.parse(uri) else {
            NSLog("[CanopyEngine] Failed to parse magnet URI")
            return
        }
        let id = magnet.infoHash.hex
        guard coordinators[id] == nil else { return }
        let session = MagnetSession(magnet: magnet, dhtSession: dhtSession)
        pendingMagnets[id] = session
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let torrentFile = try await session.fetchMetadata()
                await MainActor.run {
                    self.pendingMagnets.removeValue(forKey: id)
                    self.startTorrent(torrent: torrentFile, id: id, savePath: expanded, filePriorities: priorities)
                    if let cbs = self.metadataCallbacks.removeValue(forKey: id) {
                        let files = torrentFile.files.enumerated().map {
                            PendingFile(id: $0.offset, path: $0.element.path, size: $0.element.size)
                        }
                        for cb in cbs { cb(files) }
                    }
                }
            } catch {
                await MainActor.run {
                    self.pendingMagnets.removeValue(forKey: id)
                    self.metadataCallbacks.removeValue(forKey: id)
                }
            }
        }
        magnetTasks[id] = task
    }

    private func startTorrent(torrent: TorrentFile, id: String, savePath: String,
                               filePriorities: [Int: FilePriority] = [:]) {
        ensureDHT()
        // Read bandwidth limits from UserDefaults (synced with SettingsView AppStorage).
        // Use configured settings values unless they're 0 (unlimited), in which case
        // check UserDefaults for user-set values. SettingsView writes to the keys
        // "downloadLimit" and "uploadLimit" via AppStorage.
        let dlDefault = UserDefaults.standard.integer(forKey: "downloadLimit")
        let ulDefault = UserDefaults.standard.integer(forKey: "uploadLimit")
        let effectiveDL = settings.downloadLimitKiB > 0 ? settings.downloadLimitKiB : max(0, dlDefault)
        let effectiveUL = settings.uploadLimitKiB > 0 ? settings.uploadLimitKiB : max(0, ulDefault)
        let coordinator = DownloadCoordinator(torrent: torrent, savePath: savePath,
                                                dhtSession: dhtSession, filePriorities: filePriorities,
                                                encryption: settings.encryption,
                                                listenPort: settings.listenPort,
                                                maxPeers: settings.maxPeers,
                                                uploadLimitKiB: effectiveUL,
                                                downloadLimitKiB: effectiveDL)
        coordinators[id] = coordinator
        torrentMetas[id] = torrent
        torrentSavePaths[id] = savePath
        if !filePriorities.isEmpty { filePrioritiesCache[id] = filePriorities }
        let coordinatorRef = coordinator
        let task = Task {
            do {
                try await coordinatorRef.startListener()
            } catch {
                Log.coord.error("Failed to start listener on port \(self.settings.listenPort): \(error)")
            }
            do {
                try await coordinatorRef.download()
                await MainActor.run {
                    NotificationCenter.default.post(name: .torrentFinished, object: nil)
                }
                await coordinatorRef.seed()
            } catch is CancellationError {
                // Normal shutdown — task was cancelled by remove() or app exit
            } catch {
                NSLog("[CanopyEngine] Torrent \(torrent.name) failed: \(error)")
            }
        }
        tasks[id] = task
    }

    // MARK: - Parse / pre-add

    public func parse(torrentPath: String) -> PendingTorrent? {
        guard let tf = try? TorrentParser.parse(path: torrentPath) else { return nil }
        let files = tf.files.enumerated().map {
            PendingFile(id: $0.offset, path: $0.element.path, size: $0.element.size)
        }
        let name = URL(fileURLWithPath: torrentPath).deletingPathExtension().lastPathComponent
        return PendingTorrent(source: .file(path: torrentPath),
                              name: name.isEmpty ? tf.name : name,
                              totalSize: tf.totalSize,
                              savePath: defaultSavePath,
                              files: files)
    }

    public func pendingMagnet(uri: String) -> PendingTorrent {
        var name = "Fetching metadata\u{2026}"
        if let comps = URLComponents(string: uri),
           let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value {
            name = dn
        }
        return PendingTorrent(source: .magnet(uri: uri),
                              name: name, totalSize: 0,
                              savePath: defaultSavePath, files: [])
    }

    public func confirm(_ pending: PendingTorrent) {
        let savePath = (pending.savePath as NSString).expandingTildeInPath
        let priorities = Dictionary(uniqueKeysWithValues: pending.files.map { ($0.id, $0.priority) })
        switch pending.source {
        case .file(let path):
            addTorrentFile(at: path, saveTo: savePath, priorities: priorities)
        case .magnet(let uri):
            addMagnetLink(uri, saveTo: savePath, priorities: priorities)
        }
    }

    private var defaultSavePath: String {
        NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true)
            .first ?? NSHomeDirectory() + "/Downloads"
    }

    // MARK: - Magnet metadata fetch

    /// Pre-compute the handle (infohash hex) for a magnet URI without starting a fetch.
    /// Returns nil if the URI is not a valid magnet link.
    public func magnetHandle(for uri: String) -> String? {
        MagnetLink.parse(uri)?.infoHash.hex
    }

    public func fetchMetadata(
        uri: String,
        onFiles: @MainActor @escaping ([PendingFile]) -> Void,
        onError: @MainActor @escaping () -> Void,
        onProgress: (@MainActor @Sendable (String) -> Void)? = nil
    ) -> String? {
        guard let magnet = MagnetLink.parse(uri) else {
            onError()
            return nil
        }
        let id = magnet.infoHash.hex
        metadataCallbacks[id, default: []].append { files in
            onFiles(files)
        }
        ensureDHT()
        let session = MagnetSession(magnet: magnet, dhtSession: dhtSession)
        pendingMagnets[id] = session
        if let onProgress {
            Task {
                await session.setProgress { msg in
                    Task { @MainActor in onProgress(msg) }
                }
            }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let torrentFile = try await session.fetchMetadata()
                await MainActor.run {
                    self.torrentMetas[id] = torrentFile
                    self.pendingMagnets.removeValue(forKey: id)
                    if let cbs = self.metadataCallbacks.removeValue(forKey: id) {
                        let files = torrentFile.files.enumerated().map {
                            PendingFile(id: $0.offset, path: $0.element.path, size: $0.element.size)
                        }
                        for cb in cbs { cb(files) }
                    }
                }
            } catch {
                NSLog("[CanopyEngine] Magnet metadata fetch failed: \(error)")
                await MainActor.run {
                    self.pendingMagnets.removeValue(forKey: id)
                    self.metadataCallbacks.removeValue(forKey: id)
                    onError()
                    NotificationCenter.default.post(
                        name: Notification.Name("MagnetMetadataFailed"),
                        object: nil,
                        userInfo: ["handle": id, "error": "\(error)"]
                    )
                }
            }
        }
        magnetTasks[id] = task
        return id
    }

    public func onMetadataReady(
        for infoHash: String,
        callback: @MainActor @escaping ([PendingFile]) -> Void
    ) {
        metadataCallbacks[infoHash, default: []].append { files in
            callback(files)
        }
    }

    public func commitMagnet(handle: String, savePath: String, files: [PendingFile]) {
        let expanded = (savePath as NSString).expandingTildeInPath
        magnetTasks[handle]?.cancel()
        magnetTasks.removeValue(forKey: handle)
        guard let torrentFile = torrentMetas.removeValue(forKey: handle) else {
            NSLog("[CanopyEngine] commitMagnet: no metadata for \(handle)")
            return
        }
        let priorities = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.priority) })
        startTorrent(torrent: torrentFile, id: handle, savePath: expanded, filePriorities: priorities)
    }

    public func cancelMagnet(handle: String) {
        magnetTasks[handle]?.cancel()
        magnetTasks.removeValue(forKey: handle)
        pendingMagnets.removeValue(forKey: handle)
        metadataCallbacks.removeValue(forKey: handle)
        torrentMetas.removeValue(forKey: handle)
    }

    // MARK: - Torrent control

    public func pause(_ torrent: TorrentStatus) {
        pausedIDs.insert(torrent.id)
        guard let c = coordinators[torrent.id] else { return }
        Task { await c.suspend() }
    }

    public func resume(_ torrent: TorrentStatus) {
        pausedIDs.remove(torrent.id)
        guard let c = coordinators[torrent.id] else { return }
        Task { await c.resume() }
    }

    public func remove(_ torrent: TorrentStatus, deleteFiles: Bool = false) {
        let id = torrent.id
        let savePath = torrentSavePaths[id] ?? torrent.savePath
        let meta = torrentMetas[id]
        pendingRemovals.insert(id)
        torrents.removeAll { $0.id == id }
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        if let c = coordinators.removeValue(forKey: id) {
            Task { await c.shutdown() }
        }
        torrentMetas.removeValue(forKey: id)
        torrentSavePaths.removeValue(forKey: id)
        fileProgressCache.removeValue(forKey: id)
        filePrioritiesCache.removeValue(forKey: id)
        pausedIDs.remove(id)
        lastRates.removeValue(forKey: id)
        pendingRemovals.remove(id)
        if deleteFiles {
            let fm = FileManager.default
            let root = savePath.hasSuffix("/") ? savePath : savePath + "/"
            if let meta {
                for entry in meta.files {
                    let filePath = root + entry.path
                    try? fm.removeItem(at: URL(fileURLWithPath: filePath))
                }
            }
            let dirPath = root + torrent.name
            try? fm.removeItem(at: URL(fileURLWithPath: dirPath))
            try? fm.removeItem(at: URL(fileURLWithPath: root + ".canopy_resume"))
        }
    }

    public func recheck(_ torrent: TorrentStatus) {
        let id = torrent.id
        tasks[id]?.cancel()
        guard let c = coordinators[id] else { return }
        let task = Task {
            await c.recheck()
            do {
                try await c.download()
                await MainActor.run {
                    NotificationCenter.default.post(name: .torrentFinished, object: nil)
                }
                await c.seed()
            } catch {}
        }
        tasks[id] = task
    }

    public func reannounce(_ torrent: TorrentStatus) {
        guard let c = coordinators[torrent.id] else { return }
        Task { await c.reannounce() }
    }

    public func pauseSession() {
        for (id, c) in coordinators {
            pausedIDs.insert(id)
            Task { await c.suspend() }
        }
    }

    public func resumeSession() {
        pausedIDs.removeAll()
        for (_, c) in coordinators {
            Task { await c.resume() }
        }
    }

    public func saveResumeData() {
        for (_, c) in coordinators {
            Task { await c.saveResumeData() }
        }
    }

    // MARK: - File tree data source

    public func fileCount(for torrentID: String) -> Int {
        torrentMetas[torrentID]?.files.count ?? 0
    }

    public func fileInfos(at index: Int, for torrentID: String) -> (path: String, size: Int64, priority: Int)? {
        guard let meta = torrentMetas[torrentID],
              index < meta.files.count else { return nil }
        let f = meta.files[index]
        let prio = filePrioritiesCache[torrentID]?[index]?.rawValue ?? FilePriority.normal.rawValue
        return (f.path, f.size, prio)
    }

    public func fileProgress(for torrentID: String) -> [Int64] {
        fileProgressCache[torrentID] ?? []
    }

    public func setFilePriority(_ priority: FilePriority, at index: Int, for torrentID: String) {
        filePrioritiesCache[torrentID, default: [:]][index] = priority
        guard let c = coordinators[torrentID] else { return }
        Task { await c.setFilePriority(index: index, priority: priority) }
    }

    // MARK: - Private helpers

    private func ensureDHT() {
        guard dhtSession == nil else { return }
        let nodeID = NodeID.loadOrCreate()
        let routingTable = RoutingTable(ourID: nodeID)
        let dht = DHTSession(nodeID: nodeID, routingTable: routingTable)
        dhtSession = dht
        Task {
            try? await dht.start(port: 6882)
            _ = await DHTBootstrap.bootstrap(session: dht)
        }
    }

}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
