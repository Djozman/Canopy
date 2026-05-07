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
    private nonisolated(unsafe) var pollTimer: Timer?
    private var lastRates: [String: (downloaded: Int64, timestamp: Date)] = [:]  // for rate calculation

    public init() {}

    public func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.poll() }
        }
    }

    private func poll() async {
        var snapshots: [TorrentStatus] = []
        let now = Date()
        for (id, c) in coordinators where !pendingRemovals.contains(id) {
            guard let meta = torrentMetas[id] else { continue }
            let snap = await c.statusSnapshot()
            let prev = lastRates[id]
            let elapsed = prev.map { max(now.timeIntervalSince($0.timestamp), 0.1) } ?? 2.0
            let dlDelta = prev.map { snap.downloaded - $0.downloaded } ?? 0
            let downloadRate = max(0, Int(Double(dlDelta) / elapsed))
            lastRates[id] = (snap.downloaded, now)
            let eta: Int64 = downloadRate > 0
                ? Int64((meta.totalSize - snap.downloaded) / Int64(downloadRate))
                : -1
            let isPaused = pausedIDs.contains(id)
            snapshots.append(TorrentStatus(
                id: id, name: meta.name, savePath: torrentSavePaths[id] ?? "",
                totalSize: meta.totalSize, totalDone: snap.downloaded,
                totalUploaded: snap.uploaded, downloadRate: downloadRate,
                uploadRate: 0, progress: snap.totalPieces > 0
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
        let coordinator = DownloadCoordinator(torrent: torrent, savePath: savePath,
                                              dhtSession: dhtSession, filePriorities: filePriorities)
        coordinators[id] = coordinator
        torrentMetas[id] = torrent
        torrentSavePaths[id] = savePath
        let coordinatorRef = coordinator
        let task = Task { [weak self] in
            do {
                try await coordinatorRef.startListener()
                try await coordinatorRef.download()
                await MainActor.run {
                    NotificationCenter.default.post(name: .torrentFinished, object: nil)
                }
                await coordinatorRef.seed()
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
                              name: name ?? tf.name,
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

    public func fetchMetadata(
        uri: String,
        onFiles: @MainActor @escaping ([PendingFile]) -> Void,
        onError: @MainActor @escaping () -> Void
    ) -> String? {
        guard let magnet = MagnetLink.parse(uri) else {
            DispatchQueue.main.async { onError() }
            return nil
        }
        let id = magnet.infoHash.hex
        metadataCallbacks[id, default: []].append { files in
            DispatchQueue.main.async { onFiles(files) }
        }
        ensureDHT()
        let session = MagnetSession(magnet: magnet, dhtSession: dhtSession)
        pendingMagnets[id] = session
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
                await MainActor.run {
                    self.pendingMagnets.removeValue(forKey: id)
                    self.metadataCallbacks.removeValue(forKey: id)
                    DispatchQueue.main.async { onError() }
                }
            }
        }
        magnetTasks[id] = task
        return id
    }

    public func onMetadataReady(
        for infoHash: String,
        callback: @escaping ([PendingFile]) -> Void
    ) {
        metadataCallbacks[infoHash, default: []].append { files in
            DispatchQueue.main.async { callback(files) }
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
        pendingRemovals.insert(id)
        torrents.removeAll { $0.id == id }
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        if let c = coordinators.removeValue(forKey: id) {
            Task { await c.shutdown() }
        }
        torrentMetas.removeValue(forKey: id)
        torrentSavePaths.removeValue(forKey: id)
        pausedIDs.remove(id)
        lastRates.removeValue(forKey: id)
        if deleteFiles, let path = torrentSavePaths[id] ?? Optional(torrent.savePath) {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func recheck(_ torrent: TorrentStatus) {
        guard let c = coordinators[torrent.id] else { return }
        Task {
            await c.recheck()
            // Restart download after recheck
            do {
                try await c.download()
                await MainActor.run {
                    NotificationCenter.default.post(name: .torrentFinished, object: nil)
                }
                await c.seed()
            } catch {}
        }
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
            Task { await c.statusSnapshot() }  // triggers resume-data write during download loop
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
        var prio = 4 // normal
        if let task = tasks[torrentID] { } // mark usage
        // Read priority from coordinator via a synchronous-ish bridge
        // For now, default to normal; the DownloadCoordinator stores it post-start
        return (f.path, f.size, prio)
    }

    public func fileProgress(for torrentID: String) -> [Int64] {
        guard let c = coordinators[torrentID] else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [Int64] = []
        Task {
            result = await c.fileProgress()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    public func setFilePriority(_ priority: FilePriority, at index: Int, for torrentID: String) {
        guard let c = coordinators[torrentID] else { return }
        Task { await c.setFilePriority(index: index, priority: priority) }
    }

    // MARK: - Private helpers

    private func ensureDHT() {
        guard dhtSession == nil else { return }
        let nodeID = NodeID.random()
        let routingTable = RoutingTable(ourID: nodeID)
        dhtSession = DHTSession(nodeID: nodeID, routingTable: routingTable)
        Task {
            await dhtSession?.loadRoutingTable()
            try? await dhtSession?.start(port: 6882)
        }
    }

}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
