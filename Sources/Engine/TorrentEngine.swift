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
        // Default save dir is the user's Downloads folder directly — no auto-created
        // "Canopy" subfolder. Each multi-file torrent already creates its own subfolder
        // under the save dir; single-file torrents land at the top level.
        saveDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        if let saved = UserDefaults.standard.string(forKey: "canopy.saveDir"),
           let url = URL(string: saved) {
            saveDirectory = url
        }

        // Restore persisted MSE mode. Defaults to `.enabled` (prefer encryption with
        // plaintext fallback). Set to `.disabled` for plaintext-only or `.forced`
        // for encrypted-only.
        if let raw = UserDefaults.standard.string(forKey: "canopy.mseMode"),
           let mode = MSEMode(rawValue: raw) {
            PeerConnection.defaultMode = mode
        } else {
            PeerConnection.defaultMode = .enabled
        }

        // In-memory MSE round-trip — catches regressions in DH / RC4 / VC sync / IA.
        Task { _ = await MSESelfTest.run() }

        Task { await DHT.shared.start() }
        Task { await LocalPeerDiscovery.shared.start(localPort: 6881) }
        loadPersistedTorrents()
        startListener()
        Task { await PortForwarder(port: 6881).start() }
    }

    /// Settings binding — read/write `PeerConnection.defaultMode` and persist to
    /// UserDefaults so the next launch restores the user's choice.
    var mseMode: MSEMode {
        get { PeerConnection.defaultMode }
        set {
            PeerConnection.defaultMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "canopy.mseMode")
        }
    }

    private var udpListener: NWListener?

    private func startListener() {
        guard let port = NWEndpoint.Port(rawValue: 6881) else { return }
        do {
            // Inbound TCP gets the same noDelay + keepalive tuning as outbound.
            let tcpParams = NWParameters.tcp
            if let tcp = tcpParams.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = 30
            }
            listener = try NWListener(using: tcpParams, on: port)
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
        // Peek 1 byte: `0x13` → plaintext BT (`19 BitTorrent protocol...`); anything else
        // → MSE responder (peer's first 96 bytes are their DH public key, never `19`).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] firstData, _, _, error in
            guard let self = self, let firstData = firstData, !firstData.isEmpty, error == nil else {
                connection.cancel(); return
            }
            if firstData[firstData.startIndex] == 19 {
                self.handleInboundPlaintext(connection, firstByte: firstData)
            } else if PeerConnection.defaultMode == .disabled {
                // MSE rejected by config — drop the peer.
                connection.cancel()
            } else {
                self.handleInboundMSE(connection, firstByte: firstData)
            }
        }
    }

    private func handleInboundPlaintext(_ connection: NWConnection, firstByte: Data) {
        connection.receive(minimumIncompleteLength: 67, maximumLength: 67) { [weak self] data, _, _, error in
            guard let self = self, let data = data, data.count == 67, error == nil else {
                connection.cancel(); return
            }
            var full = firstByte
            full.append(data)
            guard String(data: full[1..<20], encoding: .utf8) == "BitTorrent protocol" else {
                connection.cancel(); return
            }
            let remoteSupportsExt = (full[25] & 0x10) != 0
            let infoHash = full[28..<48]
            Task { @MainActor in
                if let handle = self.torrents.first(where: { $0.meta.infoHash == infoHash }) {
                    await handle.acceptInbound(connection, remoteSupportsExt: remoteSupportsExt)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func handleInboundMSE(_ connection: NWConnection, firstByte: Data) {
        let knownHashes: [Data] = self.torrents.map { $0.meta.infoHash }
        let stream = MSEStream(connection: connection, prebuffer: firstByte)
        Task.detached {
            do {
                let result = try await withMSETimeout(seconds: MSEConst.handshakeTimeoutSeconds) {
                    try await MSEResponder.run(
                        stream: stream,
                        knownInfoHashes: knownHashes,
                        mode: PeerConnection.defaultMode)
                }
                guard result.ia.count >= 68,
                      result.ia[result.ia.startIndex] == 19,
                      String(data: result.ia[(result.ia.startIndex+1)..<(result.ia.startIndex+20)],
                             encoding: .utf8) == "BitTorrent protocol",
                      result.ia[(result.ia.startIndex+28)..<(result.ia.startIndex+48)] == result.infoHash
                else { connection.cancel(); return }
                let remoteSupportsExt = (result.ia[result.ia.startIndex+25] & 0x10) != 0

                await MainActor.run { [weak self] in
                    guard let self else { connection.cancel(); return }
                    if let handle = self.torrents.first(where: { $0.meta.infoHash == result.infoHash }) {
                        Task {
                            await handle.acceptInboundMSE(connection: connection,
                                                          cipher: result.cipher,
                                                          decryptedLeftover: result.decryptedLeftover,
                                                          remoteSupportsExt: remoteSupportsExt)
                        }
                    } else {
                        connection.cancel()
                    }
                }
            } catch {
                print("[Canopy] Inbound MSE handshake failed: \(error.localizedDescription)")
                connection.cancel()
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
        // Snapshot of known SKEYs so the uTP MSE responder can identify the peer's torrent.
        utp.mseKnownInfoHashes = { [weak self] in
            guard let self else { return [] }
            return await MainActor.run { self.torrents.map { $0.meta.infoHash } }
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
        // Stop the torrent first
        handle.stop()

        torrents.removeAll { $0.id == handle.id }

        Task {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {}

            await handle.closeFileHandles()

            if deleteFiles {
                let path = handle.saveDirectory.appendingPathComponent(handle.meta.name)
                do {
                    try FileManager.default.removeItem(at: path)
                    print("[Canopy] Deleted: \(path.lastPathComponent)")
                } catch {
                    print("[Canopy] Failed to delete \(path.lastPathComponent): \(error)")
                }
                
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
