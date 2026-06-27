import Foundation
import LibtorrentKit

/// Swift-side value type built from a libtorrent status snapshot.
struct Torrent: Identifiable, Hashable {
    let infoHash: String
    var id: String { infoHash }

    var name: String
    var totalWanted: Int64
    var totalDone: Int64
    var progress: Double
    var downloadRate: Int64
    var uploadRate: Int64
    var allTimeDownload: Int64
    var allTimeUpload: Int64
    var numSeeds: Int
    var numPeers: Int
    var numComplete: Int
    var numIncomplete: Int
    var connectionsCount: Int
    var ratio: Double
    var eta: Int64
    var addedTime: Int64
    var completedTime: Int64
    var queuePosition: Int
    var state: LTTorrentState
    var paused: Bool
    var savePath: String
    var errorMessage: String?

    init(_ s: LTTorrentStats) {
        infoHash = s.infoHash
        name = s.name.isEmpty ? s.infoHash : s.name
        totalWanted = s.totalWanted
        totalDone = s.totalDone
        progress = s.progress
        downloadRate = s.downloadRate
        uploadRate = s.uploadRate
        allTimeDownload = s.allTimeDownload
        allTimeUpload = s.allTimeUpload
        numSeeds = Int(s.numSeeds)
        numPeers = Int(s.numPeers)
        numComplete = Int(s.numComplete)
        numIncomplete = Int(s.numIncomplete)
        connectionsCount = Int(s.connectionsCount)
        ratio = s.ratio
        eta = s.eta
        addedTime = s.addedTime
        completedTime = s.completedTime
        queuePosition = Int(s.queuePosition)
        state = s.state
        paused = s.paused
        savePath = s.savePath
        errorMessage = s.errorMessage
    }
}
