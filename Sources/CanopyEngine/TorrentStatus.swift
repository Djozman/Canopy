import Foundation

public enum TorrentState: Int, Sendable {
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

public struct TorrentStatus: Identifiable, Sendable {
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

    public init(id: String, name: String, savePath: String, totalSize: Int64, totalDone: Int64,
                totalUploaded: Int64, downloadRate: Int, uploadRate: Int, progress: Float,
                numSeeds: Int, numPeers: Int, etaSeconds: Int64, state: TorrentState,
                isPaused: Bool, errorMessage: String?) {
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
    }
}

extension Notification.Name {
    public static let torrentFinished = Notification.Name("TorrentFinished")
}
