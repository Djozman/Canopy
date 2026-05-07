public struct CoordinatorSnapshot {
    public let downloaded: Int64
    public let uploaded: Int64
    public let completedPieces: Int
    public let totalPieces: Int
    public let connectedPeers: Int
    public let seederCount: Int
    public let state: TorrentState
    public let isPaused: Bool
    public let errorMessage: String?
}
