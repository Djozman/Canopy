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
        Task { await PortForwarder(port: 6881).start() }
    }

    private var udpListener: NWListener?

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
            
            let udpOpts = NWParameters.udp
            udpListener = try NWListener(using: udpOpts, on: port)
            udpListener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleInboundUTPConnection(connection)
                }
            }
            udpListener?.start(queue: .global())
            
            print("[Canopy] Listening for inbound TCP and uTP peers on port 6881")
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

            guard data[0] == 19,
                  String(data: data[1..<20], encoding: .utf8) == "BitTorrent protocol" else {
                connection.cancel()
                return
            }

            let remoteSupportsExt = (data[25] & 0x10) != 0
            let infoHash = data[28..<48]

            Task { @MainActor in
                if let handle = self.torrents.first(where: { $0.meta.infoHash == infoHash }) {
                    await handle.acceptInbound(connection, remoteSupportsExt: remoteSupportsExt)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private var pendingUTPConnections: [UTPConnection] = []

    private func handleInboundUTPConnection(_ connection: NWConnection) {
        let utp = UTPConnection(incomingConnection: connection)
        utp.onInboundHandshake = { [weak self, weak utp] infoHash, supportsExt in
            guard let self = self, let utp = utp else { return false }
            return await MainActor.run {
                if let handle = self.torrents.first(where: { $0.meta.infoHash == infoHash }) {
                    handle.acceptInboundUTP(utp, remoteSupportsExt: supportsExt)
                    return true
                }
                return false
            }
        }
        pendingUTPConnections.append(utp)
        Task { await utp.connect() }
    }

    private func loadPersistedTorrents() {
        let fm = FileManager.default
        let dir = torrentsDir
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        for file in files {
            let hashStr = file.deletingPathExtension().lastPathComponent
            let saveDir = perTorrentSaveDir(hashStr: hashStr)
            let fileSel = perTorrentFileSelections(hashStr: hashStr)

            if file.pathExtension == "torrent" {
                guard let data = try? Data(contentsOf: file) else { continue }
                try? add(torrentFileData: data, saveDirectory: saveDir, fileSelections: fileSel, persist: false)
            } else if file.pathExtension == "info" {
                // Magnet-resolved info-dict
                guard let rawInfo = try? Data(contentsOf: file),
                      let infoHash = Data(hex: hashStr) else { continue }
                let trackers = (UserDefaults.standard.array(forKey: "canopy.torrent.\(hashStr).trackers") as? [String]) ?? []
                guard let meta = try? Metainfo.fromInfoDict(rawInfo, infoHash: infoHash,
                                                            trackers: trackers.isEmpty ? [] : [trackers]) else { continue }
                guard !torrents.contains(where: { $0.meta.infoHash == meta.infoHash }) else { continue }
                let handle = TorrentHandle(meta: meta, saveDir: saveDir ?? saveDirectory,
                                          fileSelections: fileSel,
                                          persistCallback: makePersistCallback(hashStr: hashStr))
                torrents.append(handle)
                handle.start()
            } else if file.pathExtension == "magnet" {
                guard let uri = try? String(contentsOf: file, encoding: .utf8),
                      let magnet = Magnet.parse(uri) else { continue }
                guard !torrents.contains(where: { $0.meta.infoHash == magnet.infoHash }) else { continue }
                let magnetMeta = Metainfo.forMagnet(infoHash: magnet.infoHash,
                                                    name: magnet.name ?? "Unknown",
                                                    trackers: magnet.trackers)
                let handle = TorrentHandle(meta: magnetMeta, saveDir: saveDirectory,
                                           persistCallback: makePersistCallback(hashStr: hashStr))
                torrents.append(handle)
                handle.start()
            }
        }
    }

    // MARK: - Public API

    func add(torrentFileData: Data, saveDirectory: URL? = nil, fileSelections: [Bool]? = nil,
             persist: Bool = true) throws {
        let meta = try Metainfo.parse(torrentFileData)
        guard !torrents.contains(where: { $0.meta.infoHash == meta.infoHash }) else { return }

        let dir = saveDirectory ?? self.saveDirectory
        let hashStr = meta.infoHash.map { String(format: "%02x", $0) }.joined()

        if persist {
            let file = torrentsDir.appendingPathComponent("\(hashStr).torrent")
            try? torrentFileData.write(to: file)
            if let dir = saveDirectory {
                UserDefaults.standard.set(dir.absoluteString, forKey: "canopy.torrent.\(hashStr).saveDir")
            }
            if let sel = fileSelections, let data = try? JSONEncoder().encode(sel) {
                UserDefaults.standard.set(data, forKey: "canopy.torrent.\(hashStr).fileSelections")
            }
        }

        let handle = TorrentHandle(meta: meta, saveDir: dir, fileSelections: fileSelections)
        torrents.append(handle)
        handle.start()
    }

    @discardableResult
    func addMagnet(_ uri: String, saveDirectory: URL? = nil) throws -> UUID {
        guard let magnet = Magnet.parse(uri) else {
            throw NSError(domain: "Canopy", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid magnet link"])
        }
        if let existing = torrents.first(where: { $0.meta.infoHash == magnet.infoHash }) {
            return existing.id
        }

        let dir = saveDirectory ?? self.saveDirectory
        let hashStr = magnet.infoHash.map { String(format: "%02x", $0) }.joined()
        let magnetMeta = Metainfo.forMagnet(infoHash: magnet.infoHash,
                                            name: magnet.name ?? "Unknown",
                                            trackers: magnet.trackers)
        let handle = TorrentHandle(meta: magnetMeta, saveDir: dir, fileSelections: nil,
                                   persistCallback: makePersistCallback(hashStr: hashStr))
        torrents.append(handle)
        
        // Persist the magnet link so it survives restarts
        let file = torrentsDir.appendingPathComponent("\(hashStr).magnet")
        try? uri.write(to: file, atomically: true, encoding: .utf8)
        
        handle.start()
        return handle.id
    }

    func remove(_ handle: TorrentHandle, deleteFiles: Bool = false) {
        torrents.removeAll { $0.id == handle.id }

        Task {
            await handle.stopAndWait()

            if deleteFiles {
                let dir = handle.saveDirectory.appendingPathComponent(handle.meta.name)
                try? FileManager.default.removeItem(at: dir)
                let file = handle.saveDirectory.appendingPathComponent(handle.meta.name)
                try? FileManager.default.removeItem(at: file)
                let hashStr = handle.meta.infoHash.map { String(format: "%02x", $0) }.joined()
                let stateFile = handle.saveDirectory.appendingPathComponent(".canopy_state_\(hashStr)")
                try? FileManager.default.removeItem(at: stateFile)
            }

            let hashStr = handle.meta.infoHash.map { String(format: "%02x", $0) }.joined()
            try? FileManager.default.removeItem(at: torrentsDir.appendingPathComponent("\(hashStr).torrent"))
            try? FileManager.default.removeItem(at: torrentsDir.appendingPathComponent("\(hashStr).info"))
            try? FileManager.default.removeItem(at: torrentsDir.appendingPathComponent("\(hashStr).magnet"))
            UserDefaults.standard.removeObject(forKey: "canopy.torrent.\(hashStr).saveDir")
            UserDefaults.standard.removeObject(forKey: "canopy.torrent.\(hashStr).fileSelections")
            UserDefaults.standard.removeObject(forKey: "canopy.torrent.\(hashStr).trackers")
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

    // MARK: - Helpers

    private func perTorrentSaveDir(hashStr: String) -> URL? {
        guard let str = UserDefaults.standard.string(forKey: "canopy.torrent.\(hashStr).saveDir") else { return nil }
        return URL(string: str)
    }

    private func perTorrentFileSelections(hashStr: String) -> [Bool]? {
        guard let data = UserDefaults.standard.data(forKey: "canopy.torrent.\(hashStr).fileSelections") else { return nil }
        return try? JSONDecoder().decode([Bool].self, from: data)
    }

    private func makePersistCallback(hashStr: String) -> (Data, Metainfo) -> Void {
        { [weak self] rawInfo, newMeta in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let file = self.torrentsDir.appendingPathComponent("\(hashStr).info")
                try? rawInfo.write(to: file)
                try? FileManager.default.removeItem(at: self.torrentsDir.appendingPathComponent("\(hashStr).magnet"))
                let trackers = newMeta.announceList.flatMap { $0 }
                UserDefaults.standard.set(trackers, forKey: "canopy.torrent.\(hashStr).trackers")
            }
        }
    }
}
