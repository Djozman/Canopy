import Foundation
import LibtorrentKit

/// A connected peer for the Peers tab.
struct PeerInfo: Identifiable, Hashable {
    var id: String { address }
    let address: String
    let client: String
    let flags: String
    let connection: String
    let progress: Double
    let downSpeed: Int64
    let upSpeed: Int64
    let downloaded: Int64
    let uploaded: Int64
    let isSeed: Bool

    init(_ p: LTPeerEntry) {
        address = p.address
        client = p.client
        flags = p.flags
        connection = p.connection
        progress = p.progress
        downSpeed = p.downSpeed
        upSpeed = p.upSpeed
        downloaded = p.downloaded
        uploaded = p.uploaded
        isSeed = p.isSeed
    }
}

/// A tracker for the Trackers tab.
struct TrackerInfo: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let tier: Int
    let status: String
    let message: String
    let numSeeds: Int
    let numLeeches: Int
    let numDownloaded: Int

    init(_ t: LTTrackerEntry) {
        url = t.url
        tier = Int(t.tier)
        status = t.status
        message = t.message
        numSeeds = Int(t.numSeeds)
        numLeeches = Int(t.numLeeches)
        numDownloaded = Int(t.numDownloaded)
    }
}

/// Extended detail for the General tab.
struct TorrentDetail {
    let infoHash: String
    let name: String
    let savePath: String
    let comment: String
    let creator: String
    let creationDate: Int64
    let totalSize: Int64
    let pieceLength: Int64
    let numPieces: Int
    let piecesHave: Int
    let activeDuration: Int64
    let seedingDuration: Int64
    let finishedDuration: Int64
    let addedTime: Int64
    let completedTime: Int64
    let lastSeenComplete: Int64
    let distributedCopies: Double
    let totalDownload: Int64
    let totalUpload: Int64
    let sessionDownload: Int64
    let sessionUpload: Int64
    let downloadRate: Int64
    let uploadRate: Int64
    let numConnections: Int
    let ratio: Double
    let progress: Double

    init(_ d: LTTorrentDetail) {
        infoHash = d.infoHash
        name = d.name
        savePath = d.savePath
        comment = d.comment
        creator = d.creator
        creationDate = d.creationDate
        totalSize = d.totalSize
        pieceLength = d.pieceLength
        numPieces = Int(d.numPieces)
        piecesHave = Int(d.piecesHave)
        activeDuration = d.activeDuration
        seedingDuration = d.seedingDuration
        finishedDuration = d.finishedDuration
        addedTime = d.addedTime
        completedTime = d.completedTime
        lastSeenComplete = d.lastSeenComplete
        distributedCopies = d.distributedCopies
        totalDownload = d.totalDownload
        totalUpload = d.totalUpload
        sessionDownload = d.sessionDownload
        sessionUpload = d.sessionUpload
        downloadRate = d.downloadRate
        uploadRate = d.uploadRate
        numConnections = Int(d.numConnections)
        ratio = d.ratio
        progress = d.progress
    }
}
