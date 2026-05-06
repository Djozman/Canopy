import Foundation

public struct TorrentFile: Equatable {
    public let announce: String
    public let announceList: [[String]]?
    public let name: String
    public let pieceLength: Int64
    public let pieces: [Data]
    public let files: [FileEntry]
    public let infoHash: Data
    public let totalSize: Int64
    public let isPrivate: Bool

    public struct FileEntry: Equatable {
        public let path: String
        public let size: Int64
    }
}
