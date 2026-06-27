import Foundation
import Combine
import LibtorrentKit

/// Owns the libtorrent session and republishes its state to SwiftUI.
@MainActor
final class EngineSession: ObservableObject {
    struct Stats: Equatable {
        var downloadRate: Int64 = 0
        var uploadRate: Int64 = 0
        var totalDownload: Int64 = 0
        var totalUpload: Int64 = 0
        var dhtNodes: Int = 0
        var isListening = false
    }

    @Published private(set) var torrents: [Torrent] = []
    @Published private(set) var stats = Stats()
    @Published var settings: AppSettings

    private let session: LTSession
    private var timer: Timer?
    private var tick = 0

    init(settings: AppSettings) {
        self.settings = settings
        let fm = FileManager.default
        let configDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Canopy", isDirectory: true)
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: settings.defaultSavePath, withIntermediateDirectories: true)
        session = LTSession(savePath: settings.defaultSavePath, configPath: configDir.path)
    }

    func start() {
        session.start()
        session.setListenPort(Int32(settings.listenPort))
        session.setDownloadRateLimit(Int32(settings.downloadLimit))
        session.setUploadRateLimit(Int32(settings.uploadLimit))
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session.stop()
    }

    /// Persist resume data immediately (e.g. on app quit).
    func saveAll() {
        session.saveResumeData()
    }

    private func poll() {
        torrents = session.torrents().map(Torrent.init)
        let s = session.sessionStats()
        stats = Stats(downloadRate: s.downloadRate,
                      uploadRate: s.uploadRate,
                      totalDownload: s.totalDownload,
                      totalUpload: s.totalUpload,
                      dhtNodes: Int(s.dhtNodes),
                      isListening: s.isListening)

        // Periodically flush resume data so torrents survive a crash/restart.
        tick += 1
        if tick % 20 == 0 { session.saveResumeData() }
    }

    // MARK: - Adding

    @discardableResult
    func addMagnet(_ uri: String, paused: Bool = false) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let hash = try session.addMagnet(trimmed, savePath: settings.defaultSavePath, paused: paused)
            poll()
            return hash
        } catch {
            NSLog("addMagnet failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func addTorrentFile(_ path: String, paused: Bool = false) -> String? {
        do {
            let hash = try session.addTorrentFile(atPath: path, savePath: settings.defaultSavePath, paused: paused)
            poll()
            return hash
        } catch {
            NSLog("addTorrentFile failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Actions

    func pause(_ hashes: [String])   { session.pause(hashes); poll() }
    func resume(_ hashes: [String])  { session.resume(hashes); poll() }
    func recheck(_ hashes: [String]) { session.forceRecheck(hashes); poll() }
    func remove(_ hashes: [String], deleteFiles: Bool) {
        session.remove(hashes, deleteFiles: deleteFiles); poll()
    }
    func queueTop(_ hashes: [String])    { session.queueTop(hashes); poll() }
    func queueUp(_ hashes: [String])     { session.queueUp(hashes); poll() }
    func queueDown(_ hashes: [String])   { session.queueDown(hashes); poll() }
    func queueBottom(_ hashes: [String]) { session.queueBottom(hashes); poll() }

    // MARK: - Files

    func files(for hash: String) -> [TorrentFile] {
        session.files(for: hash).map(TorrentFile.init)
    }

    func setFilePriorities(_ priorities: [Int], for hash: String) {
        session.setFilePriorities(priorities.map { NSNumber(value: $0) }, for: hash)
    }

    // MARK: - Detail panel queries

    func peers(for hash: String) -> [PeerInfo] {
        session.peers(for: hash).map(PeerInfo.init)
    }

    func trackers(for hash: String) -> [TrackerInfo] {
        session.trackers(for: hash).map(TrackerInfo.init)
    }

    func detail(for hash: String) -> TorrentDetail? {
        session.detail(for: hash).map(TorrentDetail.init)
    }

    func applyRateLimits() {
        session.setDownloadRateLimit(Int32(settings.downloadLimit))
        session.setUploadRateLimit(Int32(settings.uploadLimit))
        settings.save()
    }
}
