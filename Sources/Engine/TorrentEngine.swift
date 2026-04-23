import Foundation
import Observation
import Network

// Global engine — owns all active torrents. Injected into the SwiftUI environment.
@Observable
@MainActor
final class TorrentEngine {
    var torrents: [TorrentHandle] = []
    var saveDirectory: URL
    private var listener: NWListener?
    
    private var torrentsDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Canopy/torrents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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
        loadPersistedTorrents()
        startListener()
    }

    private func startListener() {
        guard let port = NWEndpoint.Port(rawValue: 6881) else { return }
        do {
            listener = try NWListener(using: .tcp, on: port)
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleInboundConnection(connection)
                }
            }
            listener?.start(queue: .global())
            print("[Canopy] Listening for inbound peers on port 6881")
        } catch {
            print("[Canopy] Failed to start NWListener on port 6881: \(error)")
        }
    }

    private func handleInboundConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 68, maximumLength: 68) { [weak self] data, _, _, error in
            guard let self = self, let data = data, data.count == 68, error == nil else {
                connection.cancel()
                return
            }
            
            // Validate BitTorrent handshake prefix
            guard data[0] == 19,
                  String(data: data[1..<20], encoding: .utf8) == "BitTorrent protocol" else {
                connection.cancel()
                return
            }
            
            let remoteSupportsExt = (data[25] & 0x10) != 0
            let infoHash = data[28..<48]
            
            Task { @MainActor in
                if let handle = self.torrents.first(where: { $0.meta.infoHash == infoHash }) {
                    handle.acceptInbound(connection, remoteSupportsExt: remoteSupportsExt)
                } else {
                    connection.cancel() // Not a torrent we are active on
                }
            }
        }
    }

    private func loadPersistedTorrents() {
        let fm = FileManager.default
        let dir = torrentsDir
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "torrent" {
            if let data = try? Data(contentsOf: file) {
                try? add(torrentFileData: data, persist: false)
            }
        }
    }

    // MARK: - Public API

    func add(torrentFileData: Data, persist: Bool = true) throws {
        let meta = try Metainfo.parse(torrentFileData)
        guard !torrents.contains(where: { $0.meta.infoHash == meta.infoHash }) else { return }
        
        if persist {
            let hashStr = meta.infoHash.map { String(format: "%02x", $0) }.joined()
            let file = torrentsDir.appendingPathComponent("\(hashStr).torrent")
            try? torrentFileData.write(to: file)
        }
        
        let handle = TorrentHandle(meta: meta, saveDir: saveDirectory)
        torrents.append(handle)
        handle.start()
    }

    func remove(_ handle: TorrentHandle, deleteFiles: Bool = false) {
        torrents.removeAll { $0.id == handle.id }
        
        Task {
            await handle.stopAndWait()
            
            if deleteFiles {
                let dir = saveDirectory.appendingPathComponent(handle.meta.name)
                do { try FileManager.default.removeItem(at: dir) } catch { print("[Canopy] Failed to remove dir/file: \(error)") }
                
                let file = saveDirectory.appendingPathComponent(handle.meta.name)
                do { try FileManager.default.removeItem(at: file) } catch { print("[Canopy] Failed to remove file: \(error)") }
                
                let hashStr = handle.meta.infoHash.map { String(format: "%02x", $0) }.joined()
                let stateFile = saveDirectory.appendingPathComponent(".canopy_state_\(hashStr)")
                do { 
                    try FileManager.default.removeItem(at: stateFile) 
                    print("[Canopy] Successfully deleted state file: \(stateFile.path)")
                } catch { 
                    print("[Canopy] Failed to delete state file: \(error)") 
                }
            }
            
            let hashStr = handle.meta.infoHash.map { String(format: "%02x", $0) }.joined()
            let torrentFile = torrentsDir.appendingPathComponent("\(hashStr).torrent")
            try? FileManager.default.removeItem(at: torrentFile)
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
