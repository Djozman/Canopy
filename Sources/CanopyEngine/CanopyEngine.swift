import Foundation
import SwiftTorrent
import Combine

public struct EngineSettings: Sendable {
    public enum EncryptionMode: Sendable { case disabled, preferred, required }
    public var encryption: EncryptionMode = .preferred
    public var maxPeers: Int = 50
    public var listenPort: UInt16 = 6881
    public var uploadLimitKiB: Int = 0
    public var downloadLimitKiB: Int = 0

    public init() {}
}

@MainActor
public final class CanopyEngine: ObservableObject {
    @Published public var torrents: [TorrentStatus] = []
    @Published public var sessionError: String?
    public let settings: EngineSettings

    private var session: Session?
    private var handles: [String: TorrentHandle] = [:]
    private var savePaths: [String: String] = [:]
    private var fileMetas: [String: FileMeta] = [:]
    private var pollingTask: Task<Void, Never>?
    private var magnetTasks: [String: Task<Void, Never>] = [:]
    private var isShutdown = false

    private struct FileMeta {
        var files: [TorrentInfo.FileEntry] = []
        var priorities: [Int: FilePriority] = [:]
    }

    public init(settings: EngineSettings = EngineSettings()) {
        self.settings = settings
    }

    private func ensureSession() -> Session {
        if let s = session { return s }
        let s = Session(settings: SessionSettings(
            listenPort: settings.listenPort,
            maxConnections: 200,
            maxConnectionsPerTorrent: settings.maxPeers,
            downloadRateLimit: settings.downloadLimitKiB * 1024,
            uploadRateLimit: settings.uploadLimitKiB * 1024,
            dhtEnabled: true,
            dhtPort: Int(settings.listenPort) + 1,
            userAgent: "Canopy/2.0",
            savePath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads").path
        ))
        session = s
        return s
    }

    // MARK: - Lifecycle

    public func shutdown() {
        isShutdown = true
        pollingTask?.cancel()
        pollingTask = nil
        for (_, task) in magnetTasks { task.cancel() }
        magnetTasks.removeAll()
        Task {
            try? await session?.shutdown()
        }
    }

    public func startPolling(interval: TimeInterval = 2.0) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func poll() async {
        guard let session, !isShutdown else { return }
        let statuses = await session.allStatus()
        let mapped = statuses.map { self.mapStatus($0) }
        self.torrents = mapped
    }

    // MARK: - Adding torrents

    public func addTorrentFile(at path: String, saveTo saveDir: String,
                                priorities: [Int: FilePriority] = [:]) {
        let session = ensureSession()
        Task { [weak self] in
            do {
                let params = try AddTorrentParams.fromFile(path, savePath: saveDir)
                let handle = try await session.addTorrent(params)
                let hex = await handle.infoHash.description
                self?.register(handle: handle, hex: hex, savePath: saveDir,
                               priorities: priorities, files: params.torrentInfo?.files ?? [])
            } catch {
                self?.sessionError = error.localizedDescription
            }
        }
    }

    public func addMagnetLink(_ uri: String, saveTo saveDir: String,
                               priorities: [Int: FilePriority] = [:]) {
        let session = ensureSession()
        Task { [weak self] in
            do {
                let params = try AddTorrentParams.fromMagnet(uri, savePath: saveDir)
                let handle = try await session.addTorrent(params)
                let hex = await handle.infoHash.description
                self?.register(handle: handle, hex: hex, savePath: saveDir,
                               priorities: priorities, files: [])
            } catch {
                self?.sessionError = error.localizedDescription
            }
        }
    }

    private func register(handle: TorrentHandle, hex: String, savePath: String,
                          priorities: [Int: FilePriority], files: [TorrentInfo.FileEntry]) {
        handles[hex] = handle
        savePaths[hex] = savePath
        fileMetas[hex] = FileMeta(files: files, priorities: priorities)
    }

    // MARK: - Pre-add

    public func parse(torrentPath: String) -> PendingTorrent? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: torrentPath))
            let info = try TorrentInfo.parse(from: data)
            let files = info.files.enumerated().map { i, f in
                PendingFile(id: i, path: f.path, size: f.length)
            }
            return PendingTorrent(source: .file(path: torrentPath), name: info.name,
                                  totalSize: info.totalSize, savePath: "", files: files)
        } catch {
            sessionError = error.localizedDescription
            return nil
        }
    }

    public func pendingMagnet(uri: String) -> PendingTorrent {
        guard let magnet = MagnetLink(uri: uri) else {
            return PendingTorrent(source: .magnet(uri: uri), name: "Unknown",
                                  totalSize: 0, savePath: "", files: [])
        }
        return PendingTorrent(source: .magnet(uri: uri),
                              name: magnet.displayName ?? "Fetching metadata\u{2026}",
                              totalSize: 0, savePath: "", files: [])
    }

    public func confirm(_ pending: PendingTorrent) {
        switch pending.source {
        case .file(let path):
            addTorrentFile(at: path, saveTo: pending.savePath,
                           priorities: filePriorityMap(from: pending.files))
        case .magnet(let uri):
            addMagnetLink(uri, saveTo: pending.savePath,
                          priorities: filePriorityMap(from: pending.files))
        }
    }

    private func filePriorityMap(from files: [PendingFile]) -> [Int: FilePriority] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.priority) })
    }

    // MARK: - Magnet metadata

    public func magnetHandle(for uri: String) -> String? {
        MagnetLink(uri: uri)?.infoHash.description
    }

    public func fetchMetadata(uri: String,
                              onFiles: @escaping ([PendingFile]) -> Void,
                              onError: @escaping () -> Void,
                              onProgress: ((String) -> Void)? = nil) -> String? {
        guard let hash = magnetHandle(for: uri) else { return nil }
        let session = ensureSession()

        magnetTasks[hash]?.cancel()
        magnetTasks[hash] = Task { [weak self] in
            do {
                guard let magnet = MagnetLink(uri: uri) else {
                    await MainActor.run { self?.magnetTasks.removeValue(forKey: hash); onError() }
                    return
                }
                let params = AddTorrentParams(magnetLink: magnet, paused: true)
                let handle = try await session.addTorrent(params)
                onProgress?("Connecting to peers\u{2026}")

                try await Task.sleep(for: .seconds(2))
                onProgress?("Downloading metadata\u{2026}")

                let info = try await handle.waitForMetadata(timeout: 30)
                let files = info.files.enumerated().map { i, f in
                    PendingFile(id: i, path: f.path, size: f.length)
                }
                await MainActor.run {
                    self?.register(handle: handle, hex: hash, savePath: "",
                                   priorities: [:], files: info.files)
                    onFiles(files)
                }
            } catch {
                await MainActor.run {
                    self?.handles.removeValue(forKey: hash)
                    self?.magnetTasks.removeValue(forKey: hash)
                    onError()
                }
            }
        }
        return hash
    }

    public func onMetadataReady(for infoHash: String,
                                 callback: @escaping ([PendingFile]) -> Void) {}

    public func commitMagnet(handle: String, savePath: String,
                              files: [PendingFile]) {
        guard let torrentHandle = handles[handle] else { return }
        savePaths[handle] = savePath
        let prios = filePriorityMap(from: files)
        let existingFiles = fileMetas[handle]?.files ?? []
        fileMetas[handle] = FileMeta(files: existingFiles, priorities: prios)
        Task {
            try? await torrentHandle.resume()
        }
        magnetTasks.removeValue(forKey: handle)
    }

    public func cancelMagnet(handle: String) {
        magnetTasks[handle]?.cancel()
        magnetTasks.removeValue(forKey: handle)
        if let h = handles.removeValue(forKey: handle) {
            Task {
                let hash = await h.infoHash
                await session?.removeTorrent(hash)
            }
        }
    }

    // MARK: - Torrent control

    public func pause(_ torrent: TorrentStatus) {
        guard let handle = handles[torrent.id] else { return }
        Task { await handle.pause() }
    }

    public func resume(_ torrent: TorrentStatus) {
        guard let handle = handles[torrent.id] else { return }
        Task { try? await handle.resume() }
    }

    public func remove(_ torrent: TorrentStatus, deleteFiles: Bool = false) {
        guard let handle = handles.removeValue(forKey: torrent.id) else { return }
        savePaths.removeValue(forKey: torrent.id)
        fileMetas.removeValue(forKey: torrent.id)
        magnetTasks[torrent.id]?.cancel()
        magnetTasks.removeValue(forKey: torrent.id)
        Task {
            let hash = await handle.infoHash
            await session?.removeTorrent(hash, deleteFiles: deleteFiles)
        }
    }

    public func recheck(_ torrent: TorrentStatus) {}

    public func reannounce(_ torrent: TorrentStatus) {}

    public func pauseSession() {
        Task { await session?.pauseAll() }
    }

    public func resumeSession() {
        Task { try? await session?.resumeAll() }
    }

    public func saveResumeData() {
        Task { [weak self] in
            for (hex, handle) in self?.handles ?? [:] {
                if let data = await handle.generateResumeData() {
                    let path = (self?.savePaths[hex] ?? "") + "/.canopy_resume"
                    try? data.encode().write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    // MARK: - File tree

    public func fileCount(for torrentID: String) -> Int {
        fileMetas[torrentID]?.files.count ?? 0
    }

    public func fileInfos(at index: Int, for torrentID: String) -> (path: String, size: Int64, priority: Int)? {
        guard let meta = fileMetas[torrentID], index < meta.files.count else { return nil }
        let f = meta.files[index]
        let prio = meta.priorities[index]?.rawValue ?? FilePriority.normal.rawValue
        return (f.path, f.length, prio)
    }

    public func fileProgress(for torrentID: String) -> [Int64] {
        guard let meta = fileMetas[torrentID] else { return [] }
        return meta.files.map { _ in 0 }
    }

    public func setFilePriority(_ priority: FilePriority, at index: Int,
                                 for torrentID: String) {
        fileMetas[torrentID]?.priorities[index] = priority
    }

    // MARK: - Status mapping

    private func mapStatus(_ st: SwiftTorrent.TorrentStatus) -> TorrentStatus {
        let hex = st.infoHash.description
        let savePath = savePaths[hex] ?? ""
        let canState = mapState(st.state)

        let progress = Float(st.progress)
        let downloadRate = Int(st.downloadRate)
        let uploadRate = Int(st.uploadRate)
        let eta = computeETA(bytesLeft: st.totalSize - st.totalDownloaded, rate: downloadRate)
        let isPaused = st.state == .paused || st.state == .stopped

        return TorrentStatus(
            id: hex,
            name: st.name,
            savePath: savePath,
            totalSize: st.totalSize,
            totalDone: st.totalDownloaded,
            totalUploaded: st.totalUploaded,
            downloadRate: downloadRate,
            uploadRate: uploadRate,
            progress: progress,
            numSeeds: st.numSeeds,
            numPeers: st.numPeers,
            etaSeconds: eta,
            state: canState,
            isPaused: isPaused,
            errorMessage: st.state == .error ? "Error" : nil
        )
    }

    private func mapState(_ state: SwiftTorrent.TorrentState) -> TorrentState {
        switch state {
        case .checkingFiles:       return .checkingFiles
        case .downloadingMetadata: return .downloadingMetadata
        case .downloading:         return .downloading
        case .seeding:             return .seeding
        case .paused, .stopped:    return .downloading
        case .error:               return .downloading
        }
    }

    private func computeETA(bytesLeft: Int64, rate: Int) -> Int64 {
        guard rate > 0, bytesLeft > 0 else { return -1 }
        return bytesLeft / Int64(rate)
    }
}
