// TorrentEngine.swift
// Swift wrapper around the ObjC++ bridge.
// Owns the LibtorrentSession lifecycle, polls for status, handles alerts.

@preconcurrency import ClibtorrentBridge
import Combine
import Foundation

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
    public let isSequentialDownload: Bool

    internal let handle: LTTorrentHandle?

    init(
        id: String, name: String, savePath: String, totalSize: Int64, totalDone: Int64,
        totalUploaded: Int64, downloadRate: Int, uploadRate: Int, progress: Float,
        numSeeds: Int, numPeers: Int, etaSeconds: Int64, state: TorrentState,
        isPaused: Bool, errorMessage: String?, isSequentialDownload: Bool,
        handle: LTTorrentHandle?
    ) {
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
        self.isSequentialDownload = isSequentialDownload
        self.handle = handle
    }

    init(from h: LTTorrentHandle) {
        self.id = h.infoHash
        self.name = h.name
        self.savePath = h.savePath
        self.totalSize = h.totalSize
        self.totalDone = h.totalDone
        self.totalUploaded = h.totalUploaded
        self.downloadRate = Int(h.downloadRate)
        self.uploadRate = Int(h.uploadRate)
        self.progress = h.progress
        self.numSeeds = Int(h.numSeeds)
        self.numPeers = Int(h.numPeers)
        self.etaSeconds = h.etaSeconds
        self.state = TorrentState(rawValue: Int(h.state.rawValue)) ?? .downloading
        self.isPaused = h.paused
        self.errorMessage = h.errorMessage
        self.isSequentialDownload = h.sequentialDownload
        self.handle = h
    }
}

public enum TorrentState: Int {
    case checkingFiles = 0
    case downloadingMetadata = 1
    case downloading = 2
    case finished = 3
    case seeding = 4
    case allocating = 5
    case checkingResumeData = 6

    public var label: String {
        switch self {
        case .checkingFiles: return "Checking"
        case .downloadingMetadata: return "Metadata"
        case .downloading: return "Downloading"
        case .finished: return "Finished"
        case .seeding: return "Seeding"
        case .allocating: return "Allocating"
        case .checkingResumeData: return "Resuming"
        }
    }
}

// MARK: - TorrentEngine

@MainActor
public final class TorrentEngine: ObservableObject {

    @Published public private(set) var torrents: [TorrentStatus] = []
    private var session: LibtorrentSession?
    private nonisolated(unsafe) var pollTimer: Timer?
    private let queue = DispatchQueue(label: "com.qbt.libtorrent", qos: .utility)
    /// IDs of torrents the user has asked to remove but libtorrent hasn't
    /// finished tearing down yet. Polled results are filtered against this so
    /// a still-in-libtorrent handle can't reappear in the UI while removal is
    /// in flight (deleteFiles=true on big torrents takes ~1–2s of unlink calls).
    private var pendingRemovals: Set<String> = []

    /// Callbacks per info-hash for metadata arrival.
    /// One from fetchMetadata, potentially additional from AddTorrentSheet for multi-magnet.
    private var metadataCallbacks: [String: [([PendingFile]) -> Void]] = [:]
    private var metadataErrors: [String: [() -> Void]] = [:]
    private var lastResumeSave = Date.distantPast

    public init() {
        session = LibtorrentSession()
        let resumeDir = Self.resumeDataDirectory()
        session?.resumeDataDir = resumeDir
        // Load previously saved torrents before starting the session
        session?.loadResumeTorrents(fromDir: resumeDir)
        session?.setAlertNotify { [weak self] in
            self?.drainAlerts()
        }
        applyPreferences()
    }

    public func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Save resume data synchronously so it completes before process exit
        let s = session
        queue.sync {
            s?.saveResumeDataAllAndWait()
        }
    }

    public func startPolling(interval: TimeInterval = 2.0) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Pre-add parsing

    public func parse(torrentPath: String) -> PendingTorrent? {
        guard let session, let entries = session.parseFileList(torrentPath) else { return nil }
        let files = entries.map { e in
            PendingFile(id: Int(e.index), path: e.path, size: e.size)
        }
        let total = files.reduce(0) { $0 + $1.size }
        let name = URL(fileURLWithPath: torrentPath).deletingPathExtension().lastPathComponent
        return PendingTorrent(
            source: .file(path: torrentPath),
            name: name, totalSize: total,
            savePath: defaultSavePath, files: files)
    }

    public func confirm(_ pending: PendingTorrent) {
        let priorities = pending.files.map { NSNumber(value: $0.priority.rawValue) }
        let savePath = (pending.savePath as NSString).expandingTildeInPath
        let session = self.session
        let source = pending.source
        let fileCount = pending.files.count
        let name = pending.name
        NSLog("[Canopy] confirm(\(name)): savePath=\(savePath), fileCount=\(fileCount)")
        queue.async {
            switch source {
            case .file(let path):
                let result = session?.addTorrentFile(
                    path, savePath: savePath,
                    priorities: priorities.isEmpty ? nil : priorities)
                NSLog(
                    "[Canopy] confirm: addTorrentFile(\(path)) -> \(result == nil ? "FAILED (nil)" : "ok handle=\(result!.infoHash)")"
                )
            case .magnet(let uri):
                let result = session?.addMagnetURI(uri, savePath: savePath)
                NSLog(
                    "[Canopy] confirm: addMagnetURI -> \(result == nil ? "FAILED (nil)" : "ok handle=\(result!.infoHash)")"
                )
            }
        }
    }

    public var defaultSavePath: String {
        let fallback = NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true)
            .first ?? NSHomeDirectory() + "/Downloads"
        let stored = UserDefaults.standard.string(forKey: "downloadDir") ?? fallback
        return (stored as NSString).expandingTildeInPath
    }

    public func applyPreferences() {
        let defaults = UserDefaults.standard
        let settings: [String: NSNumber] = [
            "downloadRate": NSNumber(value: max(0, defaults.integer(forKey: "downloadLimit")) * 1024),
            "uploadRate": NSNumber(value: max(0, defaults.integer(forKey: "uploadLimit")) * 1024),
            "activeDownloads": NSNumber(value: max(1, defaults.object(forKey: "maxActiveDown") == nil ? 3 : defaults.integer(forKey: "maxActiveDown"))),
            "activeSeeds": NSNumber(value: max(1, defaults.object(forKey: "maxActiveSeed") == nil ? 5 : defaults.integer(forKey: "maxActiveSeed"))),
            "activeLimit": NSNumber(value: max(2, defaults.object(forKey: "maxActiveDown") == nil ? 8 : defaults.integer(forKey: "maxActiveDown") + defaults.integer(forKey: "maxActiveSeed"))),
            "enableDHT": NSNumber(value: defaults.object(forKey: "enableDHT") == nil ? true : defaults.bool(forKey: "enableDHT")),
            "enableLSD": NSNumber(value: defaults.object(forKey: "enableLSD") == nil ? true : defaults.bool(forKey: "enableLSD")),
            "enableUPnP": NSNumber(value: defaults.object(forKey: "enableUPnP") == nil ? true : defaults.bool(forKey: "enableUPnP")),
            "enableNatPMP": NSNumber(value: defaults.object(forKey: "enableNatPMP") == nil ? true : defaults.bool(forKey: "enableNatPMP")),
            "anonymousMode": NSNumber(value: defaults.bool(forKey: "anonymousMode")),
            "listenPort": NSNumber(value: defaults.object(forKey: "listenPort") == nil ? 6881 : defaults.integer(forKey: "listenPort")),
        ]
        let currentSession = session
        queue.async { currentSession?.applySettingsDictionary(settings) }
    }

    private static func resumeDataDirectory() -> String {
        let appSupport =
            NSSearchPathForDirectoriesInDomains(
                .applicationSupportDirectory, .userDomainMask, true
            ).first ?? NSHomeDirectory() + "/Library/Application Support"
        let dir = appSupport + "/Canopy/Resume"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Magnet metadata fetch

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
        let hash = h.infoHash
        metadataCallbacks[hash, default: []].append { files in
            Task { @MainActor in onFiles(files) }
        }
        metadataErrors[hash, default: []].append {
            Task { @MainActor in onError() }
        }
        Task { @MainActor [weak self, weak h] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, let h, self.metadataCallbacks[hash] != nil else { return }
            let failures = self.metadataErrors.removeValue(forKey: hash) ?? []
            self.metadataCallbacks.removeValue(forKey: hash)
            self.cancelMagnet(handle: h)
            failures.forEach { $0() }
        }
        return h
    }

    public func commitMagnet(handle: LTTorrentHandle, savePath: String, files: [PendingFile]) {
        let priorities = files.map { NSNumber(value: $0.priority.rawValue) }
        let expanded = (savePath as NSString).expandingTildeInPath
        let session = self.session
        queue.async {
            session?.commitMagnet(
                handle, savePath: expanded, priorities: priorities.isEmpty ? nil : priorities)
        }
    }

    public func cancelMagnet(handle: LTTorrentHandle) {
        metadataCallbacks.removeValue(forKey: handle.infoHash)
        metadataErrors.removeValue(forKey: handle.infoHash)
        let session = self.session
        queue.async {
            session?.cancelMagnet(handle)
        }
    }

    // Called from drainAlerts when metadata_received_alert fires
    private func handleMetadataReceived(infoHash: String, handle: LTTorrentHandle) {
        guard let callbacks = metadataCallbacks.removeValue(forKey: infoHash) else { return }
        metadataErrors.removeValue(forKey: infoHash)
        let count = Int(handle.fileCount)
        var files: [PendingFile] = []
        for i in 0..<count {
            var outSize: Int64 = 0
            var outPriority: Int32 = 0
            guard let path = handle.filePath(at: Int32(i), size: &outSize, priority: &outPriority)
            else { continue }
            files.append(PendingFile(id: i, path: path, size: outSize))
        }
        for cb in callbacks { cb(files) }
    }

    public func pause(_ torrent: TorrentStatus) {
        guard let h = torrent.handle else {
            NSLog("[Canopy] pause: no handle for \(torrent.name)")
            return
        }
        NSLog("[Canopy] pause(\(torrent.name))")
        queue.async { h.pause() }
    }
    public func resume(_ torrent: TorrentStatus) {
        guard let h = torrent.handle else {
            NSLog("[Canopy] resume: no handle for \(torrent.name)")
            return
        }
        NSLog("[Canopy] resume(\(torrent.name))")
        queue.async { h.resume() }
    }
    public func remove(_ torrent: TorrentStatus, deleteFiles: Bool = false) {
        guard let h = torrent.handle else {
            NSLog("[Canopy] remove: no handle for \(torrent.name)")
            return
        }
        let flag = deleteFiles
        NSLog("[Canopy] remove(\(torrent.name), deleteFiles=\(flag))")
        let id = torrent.id
        pendingRemovals.insert(id)
        torrents.removeAll { $0.id == id }
        let session = self.session
        queue.async {
            NSLog("[Canopy] removeTorrent calling ObjC with deleteFiles=\(flag)")
            session?.removeTorrent(h, deleteFiles: flag)
        }
        // Delete the resume file so it doesn't resurrect on next launch
        let resumePath = Self.resumeDataDirectory() + "/" + id + ".resume"
        try? FileManager.default.removeItem(atPath: resumePath)
    }
    public func recheck(_ torrent: TorrentStatus) {
        guard let h = torrent.handle else {
            NSLog("[Canopy] recheck: no handle for \(torrent.name)")
            return
        }
        NSLog("[Canopy] recheck(\(torrent.name))")
        queue.async { h.recheck() }
    }
    public func reannounce(_ torrent: TorrentStatus) {
        guard let h = torrent.handle else {
            NSLog("[Canopy] reannounce: no handle for \(torrent.name)")
            return
        }
        NSLog("[Canopy] reannounce(\(torrent.name))")
        queue.async { h.reannounce() }
    }
    public func setSequentialDownload(_ torrent: TorrentStatus, enabled: Bool) {
        guard let h = torrent.handle else {
            NSLog("[Canopy] setSequentialDownload: no handle for \(torrent.name)")
            return
        }
        NSLog("[Canopy] setSequentialDownload(\(torrent.name), enabled=\(enabled))")
        queue.async { h.sequentialDownload = enabled }
    }
    public func pauseSession() {
        let s = session
        queue.async { s?.pause() }
    }
    public func resumeSession() {
        let s = session
        queue.async { s?.resume() }
    }

    private func poll() {
        let session = self.session
        let shouldSave = Date().timeIntervalSince(lastResumeSave) >= 60
        if shouldSave { lastResumeSave = Date() }
        queue.async { [weak self] in
            guard let self, let session else { return }
            if shouldSave { session.saveResumeDataAll() }
            let handles = session.allTorrents()
            let results = handles.map { TorrentStatus(from: $0) }
            DispatchQueue.main.async {
                self.torrents = results.filter { !self.pendingRemovals.contains($0.id) }
            }
        }
    }

    private func drainAlerts() {
        let session = self.session
        queue.async { [weak self] in
            guard let self, let session else { return }
            session.popAlerts { type, h, msg, _ in
                if type == LTAlertType.metadataReceived, let h {
                    let hash = h.infoHash
                    DispatchQueue.main.async {
                        self.handleMetadataReceived(infoHash: hash, handle: h)
                    }
                } else if type == LTAlertType.torrentError, let h {
                    let hash = h.infoHash
                    DispatchQueue.main.async {
                        guard self.metadataCallbacks.removeValue(forKey: hash) != nil else { return }
                        let failures = self.metadataErrors.removeValue(forKey: hash) ?? []
                        failures.forEach { $0() }
                        self.cancelMagnet(handle: h)
                    }
                }
                if type == LTAlertType.torrentRemoved, !msg.isEmpty {
                    DispatchQueue.main.async {
                        self.torrents.removeAll { $0.id == msg }
                        self.pendingRemovals.remove(msg)
                    }
                }
            }
        }
    }
}
