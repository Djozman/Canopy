import Foundation

/// Stateful tracker session. Enforces interval tracking, event lifecycle (started → empty → stopped),
/// and proper BEP 12 tier failover with per-tier shuffle + promotion.
public actor TrackerSession {
    private let infoHash: Data
    private let peerID: Data
    private let port: UInt16
    private var tiers: [[String]]  // BEP 12 announce-list or [announce]

    private var lastAnnounceTime: Date = .distantPast
    private var currentInterval: Int = 0
    private var currentMinInterval: Int = 0
    private var lastEvent: TrackerEvent? = nil
    private var totalUploaded: Int64 = 0
    private var totalDownloaded: Int64 = 0
    private var totalLeft: Int64

    public init(infoHash: Data, peerID: Data, port: UInt16, announce: String?, announceList: [[String]]?, totalSize: Int64) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.totalLeft = totalSize

        if let announceList, !announceList.isEmpty {
            self.tiers = announceList
        } else if let announce {
            self.tiers = [[announce]]
        } else {
            self.tiers = []
        }
    }

    /// Announce to trackers with BEP 12 tier failover. Shuffles within each tier,
    /// tries URLs sequentially, promotes successful URL to front. Only moves to next
    /// tier if the entire current tier fails.
    /// Respects interval — returns cached result if re-announce not due yet.
    /// Sends .started on first call, nil event on subsequent calls.
    public func announce(
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64? = nil
    ) async throws -> TrackerResponse {
        totalUploaded = uploaded
        totalDownloaded = downloaded
        if let left { totalLeft = left }

        // Determine event: .started on first call, nil on regular re-announces
        let event: TrackerEvent? = lastEvent == nil ? .started : nil
        lastEvent = event

        // Check interval — don't re-announce too early
        let now = Date()
        let minWait = TimeInterval(max(currentMinInterval, min(currentInterval, 30)))
        if now.timeIntervalSince(lastAnnounceTime) < minWait {
            throw TrackerError.noResponse // caller can retry later
        }

        let params = TrackerAnnounce(
            infoHash: infoHash, peerID: peerID, port: port,
            uploaded: totalUploaded, downloaded: totalDownloaded,
            left: totalLeft, event: event
        )

        // BEP 12 tier failover: shuffle each tier, promote successful URL
        for tierIndex in 0..<tiers.count {
            var urls = tiers[tierIndex].shuffled()
            for urlIndex in 0..<urls.count {
                do {
                    let resp = try await HTTPTracker.announce(to: urls[urlIndex], with: params)
                    if resp.isFailure {
                        // Tracker rejected us — try next URL in this tier
                        continue
                    }
                    // Promote successful URL to front of tier
                    tiers[tierIndex].removeAll { $0 == urls[urlIndex] }
                    tiers[tierIndex].insert(urls[urlIndex], at: 0)

                    currentInterval = resp.interval
                    if let mini = resp.minInterval { currentMinInterval = mini }
                    lastAnnounceTime = now
                    return resp
                } catch {
                    // URL failed — try next in tier
                }
            }
        }

        throw TrackerError.noResponse
    }

    /// Send .stopped event to the active tracker in each tier and stop.
    public func stop() async {
        let params = TrackerAnnounce(
            infoHash: infoHash, peerID: peerID, port: port,
            uploaded: totalUploaded, downloaded: totalDownloaded,
            left: totalLeft, event: .stopped
        )
        await withTaskGroup(of: Void.self) { group in
            for tier in tiers {
                guard let url = tier.first else { continue }
                group.addTask { try? await HTTPTracker.announce(to: url, with: params) }
            }
        }
    }

    /// Send .completed event to the active tracker in each tier.
    public func completed() async {
        let params = TrackerAnnounce(
            infoHash: infoHash, peerID: peerID, port: port,
            uploaded: totalUploaded, downloaded: totalDownloaded,
            left: 0, event: .completed
        )
        await withTaskGroup(of: Void.self) { group in
            for tier in tiers {
                guard let url = tier.first else { continue }
                group.addTask { try? await HTTPTracker.announce(to: url, with: params) }
            }
        }
    }
}
