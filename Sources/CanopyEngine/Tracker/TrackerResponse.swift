import Foundation

public struct TrackerResponse {
    /// If non-nil, the tracker rejected the request.
    public let failureReason: String?

    /// Optional warning message from the tracker.
    public let warningMessage: String?

    /// Recommended re-announce interval in seconds.
    public let interval: Int

    /// Minimum interval to respect (tracker may specify a smaller value than interval).
    public let minInterval: Int?

    /// Opaque tracker ID sent back on re-announce (optional).
    public let trackerID: String?

    /// Number of complete peers (seeders).
    public let complete: Int?

    /// Number of incomplete peers (leechers).
    public let incomplete: Int?

    /// Parsed peer list.
    public let peers: [Peer]

    public init(
        failureReason: String? = nil,
        warningMessage: String? = nil,
        interval: Int = 1800,
        minInterval: Int? = nil,
        trackerID: String? = nil,
        complete: Int? = nil,
        incomplete: Int? = nil,
        peers: [Peer] = []
    ) {
        self.failureReason = failureReason
        self.warningMessage = warningMessage
        self.interval = interval
        self.minInterval = minInterval
        self.trackerID = trackerID
        self.complete = complete
        self.incomplete = incomplete
        self.peers = peers
    }

    /// True if the tracker returned a failure reason.
    public var isFailure: Bool { failureReason != nil }
}
