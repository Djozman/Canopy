// TorrentEngine.swift
// Swift wrapper around the ObjC++ bridge.
// Owns the LibtorrentSession lifecycle, polls for status, handles alerts.

import Foundation
import Combine
@preconcurrency import ClibtorrentBridge

// MARK: - Sendable conformance for ObjC bridge types

extension LTTorrentHandle: @retroactive @unchecked Sendable {}
extension LibtorrentSession: @retroactive @unchecked Sendable {}

// MARK: - Swift mirror of LTTorrentHandle

public struct TorrentStatus: Identifiable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let savePath: String
    public let totalSize: Int64
    public let totalDone: Int64
    public let totalUploaded: Int64
    public let downloadRate: Int
    public let uploadRate: Int
    public let progress: Float
    public let numSeeds: Int
    public let numPeers: Int
    public let etaSeconds: Int64
    public let state: TorrentState
    public let isPaused: Bool
    public let errorMessage: String?

    internal let handle: LTTorrentHandle?

    init(id: String, name: String, savePath: String, totalSize: Int64, totalDone: Int64,
         totalUploaded: Int64, downloadRate: Int, uploadRate: Int, progress: Float,
         numSeeds: Int, numPeers: Int, etaSeconds: Int64, state: TorrentState,
         isPaused: Bool, errorMessage: String?, handle: LTTorrentHandle?) {
        self.id = id
        self.name = name
        self.savePath = savePath
        self.totalSize = totalSize
        self.totalDone = totalDone
        self.totalUploaded = totalUploaded
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.progress = progress
        self.numSeeds = numSeeds
        self.numPeers = numPeers
        self.etaSeconds = etaSeconds
        self.state = state
        self.isPaused = isPaused
        self.errorMessage = errorMessage
        self.handle = handle
    }

    init(from h: LTTorrentHandle) {
        self.id            = h.infoHash
        self.name          = h.name
        self.savePath      = h.savePath
        self.totalSize     = h.totalSize
        self.totalDone     = h.totalDone
        self.totalUploaded = h.totalUploaded
        self.downloadRate  = Int(h.downloadRate)
        self.uploadRate    = Int(h.uploadRate)
        self.progress      = h.progress
        self.numSeeds      = Int(h.numSeeds)
        self.numPeers      = Int(h.numPeers)
        self.etaSeconds    = h.etaSeconds
        self.state         = TorrentState(rawValue: Int(h.state.rawValue)) ?? .downloading
        self.isPaused      = h.paused
        self.errorMessage  = h.errorMessage
        self.handle        = h
    }
}

public enum TorrentState: Int {
    case checkingFiles       = 0
    case downloadingMetadata = 1
    case downloading         = 2
    case finished            = 3
    case seeding             = 4
    case allocating          = 5
    case checkingResumeData  = 6

    public var label: String {
        switch self {
        case .checkingFiles:       return "Checking"
        case .downloadingMetadata: return "Metadata"
        case .downloading:         return "Downloading"
        case .finished:            return "Finished"
        case .seeding:             return "Seeding"
        case .allocating:          return "Allocating"
        case .checkingResumeData:  return "Resuming"
        }
    }
}

// MARK: - TorrentEngine

@MainActor
public final class TorrentEngine: ObservableObject {

    @Published public private(set) var torrents: [TorrentStatus] = []
    @Published public private(set) var sessionError: String?

    private var session: LibtorrentSession?
    private nonisolated(unsafe) var pollTimer: Timer?
    private nonisolated(unsafe) var alertTimer: Timer?
    private let queue = DispatchQueue(label: "com.qbt.libtorrent", qos: .utility)

    // Multiple callbacks per info-hash: one for the PreAdd window, one for the Files tab, etc.
    private var metadataCallbacks: [String: [([PendingFile]) -> Void]] = [:]

    public init() {
        session = LibtorrentSession()
        if session == nil {
            sessionError = "Failed to create libtorrent session."
        }
    }

    deinit {
        pollTimer?.invalidate()
        alertTimer?.invalidate()
    }

    public func startPolling(interval: TimeInterval = 0.5) {
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        alertTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.drainAlerts()
        }
    }

    public func addTorrentFile(at path: String, saveTo saveDir: String) {
        let expanded = (saveDir as NSString).expandingTildeInPath
        let session = self.session
        queue.async {
            _ = session?.addTorrentFile(path, savePath: expanded)
        }
    }

    public func addMagnetLink(_ uri: String, saveTo saveDir: String) {
        let expanded = (saveDir as NSString).expandingTildeInPath
        let session = self.session
        queue.async {
            _ = session?.addMagnetURI(uri, savePath: expanded)
        }
    }

    // MARK: - Pre-add parsing

    public func parse(torrentPath: String) -> PendingTorrent? {
        guard let session, let entries = session.parseFileList(torrentPath) else { return nil }
        let files = entries.map { e in
            PendingFile(id: Int(e.index), path: e.path, size: e.size)
        }
        let total = files.reduce(0) { $0 + $1.size }
        let name = URL(fileURLWithPath: torrentPath).deletingPathExtension().lastPathComponent
        return PendingTorrent(source: .file(path: torrentPath),
                              name: name, totalSize: total,
                              savePath: defaultSavePath, files: files)
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
        let priorities = pending.files.map { NSNumber(value: $0.priority.rawValue) }
        let savePath = (pending.savePath as NSString).expandingTildeInPath
        let session = self.session
        queue.async {
            switch pending.source {
            case .file(let path):
                _ = session?.addTorrentFile(path, savePath: savePath,
                                            priorities: priorities.isEmpty ? nil : priorities)
            case .magnet(let uri):
                _ = session?.addMagnetURI(uri, savePath: savePath)
            }
        }
    }

    private var defaultSavePath: String {
        NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true)
            .first ?? NSHomeDirectory() + "/Downloads"
    }

    // MARK: - Magnet metadata fetch

    /// Add magnet in paused/metadata-only mode. Returns handle immediately.
    /// Register callbacks via `onMetadataReady(for:callback:)` before metadata arrives.
    public func fetchMetadata(
        uri: String,
        onFiles: @MainActor @escaping ([PendingFile]) -> Void,
        onError: @MainActor @escaping () -> Void
    ) -> LTTorrentHandle? {
        let session = self.session
        var handle: LTTorrentHandle?
        queue.sync {
            handle = session?.addMagnet(forMetadata: uri)
        }
        guard let h = handle else {
            DispatchQueue.main.async { onError() }
            return nil
        }
        // Register the caller's callback
        let hash = h.infoHash
        metadataCallbacks[hash, default: []].append { files in
            DispatchQueue.main.async { onFiles(files) }
        }
        return h
    }

    /// Register an additional callback to be fired when metadata arrives for a given handle.
    /// Safe to call multiple times — each callback is appended and all fire once.
    public func onMetadataReady(
        for handle: LTTorrentHandle,
        callback: @escaping ([PendingFile]) -> Void
    ) {
        let hash = handle.infoHash
        metadataCallbacks[hash, default: []].append { files in
            DispatchQueue.main.async { callback(files) }
        }
    }

    public func commitMagnet(handle: LTTorrentHandle, savePath: String, files: [PendingFile]) {
        let priorities = files.map { NSNumber(value: $0.priority.rawValue) }
        let expanded = (savePath as NSString).expandingTildeInPath
        let session = self.session
        queue.async {
            session?.commitMagnet(handle, savePath: expanded, priorities: priorities.isEmpty ? nil : priorities)
        }
    }

    public func cancelMagnet(handle: LTTorrentHandle) {
        metadataCallbacks.removeValue(forKey: handle.infoHash)
        let session = self.session
        queue.async {
            session?.cancelMagnet(handle)
        }
    }

    // Called from drainAlerts when metadata_received_alert fires
    private func handleMetadataReceived(infoHash: String, handle: LTTorrentHandle) {
        guard let callbacks = metadataCallbacks.removeValue(forKey: infoHash) else { return }
        let count = Int(handle.fileCount)
        var files: [PendingFile] = []
        for i in 0..<count {
            var outSize: Int64 = 0
            var outPriority: Int32 = 0
            guard let path = handle.filePath(at: Int32(i), size: &outSize, priority: &outPriority)
            else { continue }
            files.append(PendingFile(id: i, path: path, size: outSize))
        }
        // Fire every registered callback with the same file list
        for cb in callbacks { cb(files) }
    }

    public func pause(_ torrent: TorrentStatus) {
        if let h = torrent.handle { queue.async { h.pause() } }
    }
    public func resume(_ torrent: TorrentStatus) {
        if let h = torrent.handle { queue.async { h.resume() } }
    }
    public func remove(_ torrent: TorrentStatus, deleteFiles: Bool = false) {
        let session = self.session
        if let h = torrent.handle {
            queue.async { session?.removeTorrent(h, deleteFiles: deleteFiles) }
        }
    }
    public func recheck(_ torrent: TorrentStatus) {
        if let h = torrent.handle { queue.async { h.recheck() } }
    }
    public func reannounce(_ torrent: TorrentStatus) {
        if let h = torrent.handle { queue.async { h.reannounce() } }
    }
    public func pauseSession()  { let s = session; queue.async { s?.pause() } }
    public func resumeSession() { let s = session; queue.async { s?.resume() } }
    public func saveResumeData() { let s = session; queue.async { s?.saveResumeDataAll() } }

    private func poll() {
        let session = self.session
        queue.async { [weak self] in
            guard let self, let session else { return }
            let handles = session.allTorrents()
            let results = handles.map { TorrentStatus(from: $0) }
            DispatchQueue.main.async { self.torrents = results }
        }
    }

    private func drainAlerts() {
        let session = self.session
        queue.async { [weak self] in
            guard let self, let session else { return }
            session.popAlerts { type, h, msg, _ in
                if type == LTAlertType.torrentFinished {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .torrentFinished, object: nil)
                    }
                }
                if type == LTAlertType.metadataReceived, let h {
                    let hash = h.infoHash
                    DispatchQueue.main.async {
                        self.handleMetadataReceived(infoHash: hash, handle: h)
                    }
                }
                if type == LTAlertType.torrentRemoved, !msg.isEmpty {
                    DispatchQueue.main.async {
                        self.torrents.removeAll { $0.id == msg }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    public static let torrentFinished = Notification.Name("TorrentFinished")
}
