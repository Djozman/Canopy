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

    public init() {
        queue.async { [weak self] in
            guard let self else { return }
            let s = LibtorrentSession()
            DispatchQueue.main.async { self.session = s }
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
        queue.async {
            guard let session else { return }
            session.popAlerts { type, _, _, _ in
                if type == LTAlertType.torrentFinished {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .torrentFinished, object: nil)
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    public static let torrentFinished = Notification.Name("TorrentFinished")
}
