import Foundation
import Observation

// Global engine — owns all active torrents. Injected into the SwiftUI environment.
@Observable
@MainActor
final class TorrentEngine {
    var torrents: [TorrentHandle] = []
    var saveDirectory: URL

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let dir = downloads.appendingPathComponent("Canopy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveDirectory = dir

        if let saved = UserDefaults.standard.string(forKey: "canopy.saveDir"),
           let url = URL(string: saved) {
            saveDirectory = url
        }
        
        Task { await DHT.shared.start() }
    }

    // MARK: - Public API

    func add(torrentFileData: Data) throws {
        let meta = try Metainfo.parse(torrentFileData)
        guard !torrents.contains(where: { $0.meta.infoHash == meta.infoHash }) else { return }
        let handle = TorrentHandle(meta: meta, saveDir: saveDirectory)
        torrents.append(handle)
        handle.start()
    }

    func remove(_ handle: TorrentHandle, deleteFiles: Bool = false) {
        handle.stop()
        torrents.removeAll { $0.id == handle.id }
        if deleteFiles {
            let dir = saveDirectory.appendingPathComponent(handle.meta.name)
            try? FileManager.default.removeItem(at: dir)
            let file = saveDirectory.appendingPathComponent(handle.meta.name)
            try? FileManager.default.removeItem(at: file)
        }
    }

    func pause(_ handle: TorrentHandle) { handle.stop() }

    func resume(_ handle: TorrentHandle) { handle.start() }

    func setSaveDirectory(_ url: URL) {
        saveDirectory = url
        UserDefaults.standard.set(url.absoluteString, forKey: "canopy.saveDir")
    }

    // MARK: - Computed stats

    var totalDownloadSpeed: Int64 { torrents.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: Int64 { torrents.reduce(0) { $0 + $1.uploadSpeed } }
}
