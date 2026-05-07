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
    private var hasSentStarted = false
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

    /// Announce to trackers with BEP 12 tier failover.
    /// Respects the tracker's interval — throws `TrackerError.noResponse` if called too early.
    public func announce(
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64? = nil
    ) async throws -> TrackerResponse {
        try await doAnnounce(bypassInterval: false, uploaded: uploaded, downloaded: downloaded, left: left)
    }

    /// Like `announce()` but bypasses the normal re-announce interval.
    /// Still respects `min_interval` (the tracker's hard throttle, usually 60s or unset).
    /// Use when all peers have dropped and we urgently need new ones.
    public func forceAnnounce(
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64? = nil
    ) async throws -> TrackerResponse {
        try await doAnnounce(bypassInterval: true, uploaded: uploaded, downloaded: downloaded, left: left)
    }

    // MARK: - Core announce logic

    private func doAnnounce(bypassInterval: Bool, uploaded: Int64, downloaded: Int64, left: Int64?) async throws -> TrackerResponse {
        totalUploaded = uploaded
        totalDownloaded = downloaded
        if let left { totalLeft = left }

        // Determine event: .started on first call, nil on subsequent calls.
        // hasSentStarted is set AFTER a successful announce — if all trackers fail,
        // we retry as "started" rather than losing the event forever.
        let event: TrackerEvent? = hasSentStarted ? nil : .started

        let now = Date()
        if bypassInterval {
            // Respect min_interval if set, otherwise use a 60s floor to avoid spamming.
            let floor = currentMinInterval > 0 ? TimeInterval(currentMinInterval) : 60
            if now.timeIntervalSince(lastAnnounceTime) < floor {
                throw TrackerError.noResponse
            }
        } else {
            let minWait = TimeInterval(max(currentMinInterval, currentInterval))
            if now.timeIntervalSince(lastAnnounceTime) < minWait {
                throw TrackerError.noResponse
            }
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
                    let resp: TrackerResponse
                    if urls[urlIndex].hasPrefix("udp://") {
                        let udp = try UDPTracker(url: urls[urlIndex])
                        resp = try await udp.announce(with: params)
                    } else {
                        resp = try await HTTPTracker.announce(to: urls[urlIndex], with: params)
                    }
                    if resp.isFailure {
                        continue
                    }
                    tiers[tierIndex].removeAll { $0 == urls[urlIndex] }
                    tiers[tierIndex].insert(urls[urlIndex], at: 0)

                    currentInterval = resp.interval
                    if let mini = resp.minInterval { currentMinInterval = mini }
                    lastAnnounceTime = now
                    if event == .started { hasSentStarted = true }
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
                group.addTask { [self] in try? await announceTo(url: url, with: params) }
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
                group.addTask { [self] in try? await announceTo(url: url, with: params) }
            }
        }
    }

    private func announceTo(url: String, with params: TrackerAnnounce) async throws {
        if url.hasPrefix("udp://") {
            let udp = try UDPTracker(url: url)
            try await udp.announce(with: params)
        } else {
            try await HTTPTracker.announce(to: url, with: params)
        }
    }
}
