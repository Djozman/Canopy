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
    @Published private(set) var library = LibraryData()
    @Published var settings: AppSettings

    private let session: LTSession
    private var timer: Timer?
    private var tick = 0
    private let libraryURL: URL

    init(settings: AppSettings) {
        self.settings = settings
        let fm = FileManager.default
        let configDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Canopy", isDirectory: true)
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: settings.defaultSavePath, withIntermediateDirectories: true)
        libraryURL = configDir.appendingPathComponent("library.json")
        session = LTSession(savePath: settings.defaultSavePath, configPath: configDir.path)
        loadLibrary()
    }

    func start() {
        session.start()
        applyAllSettings()
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
        saveLibrary()
    }

    private func poll() {
        torrents = session.torrents().map { s in
            var t = Torrent(s)
            if let m = library.assignments[t.infoHash] {
                t.category = m.category
                t.tags = m.tags
            }
            return t
        }
        let s = session.sessionStats()
        stats = Stats(downloadRate: s.downloadRate,
                      uploadRate: s.uploadRate,
                      totalDownload: s.totalDownload,
                      totalUpload: s.totalUpload,
                      dhtNodes: Int(s.dhtNodes),
                      isListening: s.isListening)

        // Enforce the global share-ratio limit by pausing finished torrents.
        if settings.shareRatioLimit > 0 {
            let over = torrents.filter {
                !$0.paused && $0.progress >= 1.0 && $0.ratio >= settings.shareRatioLimit
            }
            if !over.isEmpty { session.pause(over.map { $0.infoHash }) }
        }

        // Periodically flush resume data so torrents survive a crash/restart.
        tick += 1
        if tick % 20 == 0 { session.saveResumeData() }
    }

    // MARK: - Adding

    @discardableResult
    func addMagnet(_ uri: String, paused: Bool = false, category: String = "") -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let savePath = library.savePath(forCategory: category) ?? settings.defaultSavePath
            let hash = try session.addMagnet(trimmed, savePath: savePath, paused: paused)
            assignOnAdd(hash: hash, category: category)
            poll()
            return hash
        } catch {
            NSLog("addMagnet failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func addTorrentFile(_ path: String, paused: Bool = false, category: String = "") -> String? {
        do {
            let savePath = library.savePath(forCategory: category) ?? settings.defaultSavePath
            let hash = try session.addTorrentFile(atPath: path, savePath: savePath, paused: paused)
            assignOnAdd(hash: hash, category: category)
            poll()
            return hash
        } catch {
            NSLog("addTorrentFile failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func assignOnAdd(hash: String?, category: String) {
        guard let hash, !category.isEmpty else { return }
        var m = library.assignments[hash] ?? TorrentMeta()
        m.category = category
        library.assignments[hash] = m
        saveLibrary()
    }

    /// Adds a torrent from a remote magnet or .torrent URL (used by RSS).
    func addFromRemote(_ urlString: String, category: String = "",
                       savePath: String? = nil, paused: Bool = false) {
        let resolved = savePath ?? library.savePath(forCategory: category) ?? settings.defaultSavePath
        if urlString.hasPrefix("magnet:") {
            do {
                let hash = try session.addMagnet(urlString, savePath: resolved, paused: paused)
                assignOnAdd(hash: hash, category: category)
                poll()
            } catch { NSLog("RSS magnet add failed: \(error.localizedDescription)") }
            return
        }
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".torrent")
            try? data.write(to: tmp)
            Task { @MainActor in
                do {
                    let hash = try self.sessionAddFile(tmp.path, savePath: resolved, paused: paused)
                    self.assignOnAdd(hash: hash, category: category)
                    self.poll()
                } catch { NSLog("RSS file add failed: \(error.localizedDescription)") }
            }
        }.resume()
    }

    private func sessionAddFile(_ path: String, savePath: String, paused: Bool) throws -> String? {
        try session.addTorrentFile(atPath: path, savePath: savePath, paused: paused)
    }

    // MARK: - Actions

    func pause(_ hashes: [String])   { session.pause(hashes); poll() }
    func resume(_ hashes: [String])  { session.resume(hashes); poll() }
    func recheck(_ hashes: [String]) { session.forceRecheck(hashes); poll() }
    func remove(_ hashes: [String], deleteFiles: Bool) {
        session.remove(hashes, deleteFiles: deleteFiles)
        for h in hashes { library.assignments[h] = nil }
        saveLibrary()
        poll()
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

    // MARK: - Categories & Tags

    func createCategory(_ name: String, savePath: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !library.categories.contains(where: { $0.name == trimmed }) {
            library.categories.append(CategoryDef(name: trimmed, savePath: savePath))
            library.categories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            saveLibrary()
        }
    }

    func removeCategory(_ name: String) {
        library.categories.removeAll { $0.name == name }
        for (h, var m) in library.assignments where m.category == name {
            m.category = ""
            library.assignments[h] = m
        }
        saveLibrary()
        poll()
    }

    func setCategory(_ name: String, for hashes: [String]) {
        for h in hashes {
            var m = library.assignments[h] ?? TorrentMeta()
            m.category = name
            library.assignments[h] = m
        }
        // If the category defines a save path, relocate the torrents' storage.
        if let sp = library.savePath(forCategory: name) {
            for h in hashes { session.moveStorage(h, to: sp) }
        }
        saveLibrary()
        poll()
    }

    func clearCategory(for hashes: [String]) {
        for h in hashes {
            var m = library.assignments[h] ?? TorrentMeta()
            m.category = ""
            library.assignments[h] = m
        }
        saveLibrary()
        poll()
    }

    func createTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !library.tags.contains(trimmed) else { return }
        library.tags.append(trimmed)
        library.tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        saveLibrary()
    }

    func deleteTag(_ name: String) {
        library.tags.removeAll { $0 == name }
        for (h, var m) in library.assignments where m.tags.contains(name) {
            m.tags.removeAll { $0 == name }
            library.assignments[h] = m
        }
        saveLibrary()
        poll()
    }

    func addTag(_ tag: String, for hashes: [String]) {
        createTag(tag)
        for h in hashes {
            var m = library.assignments[h] ?? TorrentMeta()
            if !m.tags.contains(tag) { m.tags.append(tag) }
            library.assignments[h] = m
        }
        saveLibrary()
        poll()
    }

    func removeTag(_ tag: String, for hashes: [String]) {
        for h in hashes {
            guard var m = library.assignments[h] else { continue }
            m.tags.removeAll { $0 == tag }
            library.assignments[h] = m
        }
        saveLibrary()
        poll()
    }

    func toggleTag(_ tag: String, for hashes: [String]) {
        let allHave = hashes.allSatisfy { (library.assignments[$0]?.tags ?? []).contains(tag) }
        if allHave { removeTag(tag, for: hashes) } else { addTag(tag, for: hashes) }
    }

    // MARK: - Persistence

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              let decoded = try? JSONDecoder().decode(LibraryData.self, from: data) else { return }
        library = decoded
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    // MARK: - Settings

    /// Pushes every preference value into the libtorrent session and persists.
    func applyAllSettings() {
        session.setListenPort(Int32(settings.listenPort))
        session.setDownloadRateLimit(Int32(settings.downloadLimit))
        session.setUploadRateLimit(Int32(settings.uploadLimit))
        session.setMaxConnections(Int32(settings.maxConnections))
        session.setMaxUploads(Int32(settings.maxUploads))
        session.setDHTEnabled(settings.enableDHT,
                              lsd: settings.enableLSD,
                              upnp: settings.enableUPnP,
                              natpmp: settings.enableNATPMP)
        session.setEncryptionPolicy(Int32(settings.encryption))
        if settings.queueingEnabled {
            session.setQueueLimitsDownloads(Int32(settings.maxActiveDownloads),
                                            seeds: Int32(settings.maxActiveUploads),
                                            total: Int32(settings.maxActiveTotal))
        } else {
            session.setQueueLimitsDownloads(-1, seeds: -1, total: -1)
        }
        settings.save()
    }
}
