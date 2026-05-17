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
    private var currentTrackerID: String? = nil
    private var hasSentStarted = false
    private var totalUploaded: Int64 = 0
    private var totalDownloaded: Int64 = 0
    private var totalLeft: Int64
    private var failureCounts: [String: Int] = [:]     // per-URL failure counter
    private var cooldownUntil: [String: Date] = [:]    // per-URL backoff cooldown

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
            // Respect min_interval if set, otherwise use a 30s floor to avoid spamming.
            let floor = currentMinInterval > 0 ? TimeInterval(currentMinInterval) : 30
            if now.timeIntervalSince(lastAnnounceTime) < floor {
                Log.tracker.debug("Skipping force-announce — within \(Int(floor))s floor")
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
            left: totalLeft, event: event, trackerID: currentTrackerID
        )

        // BEP 12 tier failover: shuffle each tier, promote successful URL
        for tierIndex in 0..<tiers.count {
            let urls = tiers[tierIndex].shuffled()
            for urlIndex in 0..<urls.count {
                let url = urls[urlIndex]
                // Skip if in exponential backoff cooldown
                if let cooldown = cooldownUntil[url], now < cooldown { continue }
                do {
                    let resp: TrackerResponse
                    if url.hasPrefix("udp://") {
                        let udp = try UDPTracker(url: url)
                        resp = try await udp.announce(with: params)
                    } else {
                        resp = try await HTTPTracker.announce(to: url, with: params)
                    }
                    if resp.isFailure {
                        continue
                    }
                    tiers[tierIndex].removeAll { $0 == url }
                    tiers[tierIndex].insert(url, at: 0)
                    failureCounts.removeValue(forKey: url)
                    cooldownUntil.removeValue(forKey: url)

                    currentInterval = max(resp.interval, 300)  // libtorrent: min_announce_interval floor
                    if let mini = resp.minInterval { currentMinInterval = mini }
                    if let tid = resp.trackerID { currentTrackerID = tid }
                    lastAnnounceTime = now
                    if event == .started { hasSentStarted = true }
                    return resp
                } catch {
                    // URL failed — apply exponential backoff
                    let failures = (failureCounts[url] ?? 0) + 1
                    failureCounts[url] = failures
                    let delay = TimeInterval(min(1 << min(failures, 6), 60))
                    cooldownUntil[url] = now.addingTimeInterval(delay)
                    Log.tracker.warning("⚠️ \(url) failed (strike \(failures)) — backoff \(Int(delay))s")
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
            _ = try await udp.announce(with: params)
        } else {
            _ = try await HTTPTracker.announce(to: url, with: params)
        }
    }
}
