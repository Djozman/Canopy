import Foundation

// MARK: - Node entry

public struct NodeEntry: Codable {
    let nodeIDBytes: Data
    let ip: String
    let port: UInt16
    var failureCount: Int
    var lastSeen: Date

    var nodeID: NodeID { NodeID(bytes: nodeIDBytes)! }
}

// MARK: - K-Bucket

struct KBucket {
    let min: NodeID
    let max: NodeID
    var nodes: [NodeEntry]  // max 8, LRU-ordered (tail = most recently seen)

    var isFull: Bool { nodes.count >= 8 }

    /// True if our node ID falls within this bucket's range.
    func covers(_ id: NodeID) -> Bool {
        min <= id && id <= max
    }

    /// Split at arithmetic midpoint: min + (max - min) / 2 using 160-bit unsigned add + right-shift.
    /// Returns (lower, upper) where lower covers [min, midpoint] and upper covers (midpoint, max].
    func split() -> (KBucket, KBucket)? {
        guard isFull else { return nil }
        // Compute midpoint = min + (max - min) / 2
        let a = Array(min.bytes), b = Array(max.bytes)
        var diff = [UInt16](repeating: 0, count: 20)
        var carry: UInt16 = 0
        // diff = max - min (160-bit subtraction)
        for i in (0..<20).reversed() {
            let minVal = UInt16(a[i])
            let maxVal = UInt16(b[i]) + carry
            if maxVal >= minVal {
                diff[i] = maxVal - minVal
                carry = 0
            } else {
                diff[i] = maxVal + 256 - minVal
                carry = 1
            }
        }
        // diff >>= 1 (160-bit right shift)
        var half = [UInt16](repeating: 0, count: 20)
        var remainder: UInt16 = 0
        for i in 0..<20 {
            let val = (remainder << 8) | diff[i]
            half[i] = val >> 1
            remainder = val & 1
        }
        // midpoint = min + half
        var midBytes = [UInt8](repeating: 0, count: 20)
        carry = 0
        for i in (0..<20).reversed() {
            let sum = UInt16(a[i]) + half[i] + carry
            midBytes[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        // mid + 1 for upper bucket lower bound
        var upperMin = midBytes
        for i in (0..<20).reversed() {
            if upperMin[i] < 255 {
                upperMin[i] += 1
                break
            }
            upperMin[i] = 0
        }
        let midpoint = NodeID(bytes: Data(midBytes))!
        let upperBound = NodeID(bytes: Data(upperMin))!
        return (
            KBucket(min: min, max: midpoint, nodes: []),
            KBucket(min: upperBound, max: max, nodes: [])
        )
    }

    /// Redistribute this bucket's nodes into the two new buckets.
    func redistribute(into lower: inout KBucket, _ upper: inout KBucket) {
        for node in nodes {
            if node.nodeID <= lower.max {
                lower.nodes.append(node)
            } else {
                upper.nodes.append(node)
            }
        }
    }
}

// MARK: - Routing Table

public actor RoutingTable {
    private let ourID: NodeID
    private var buckets: [KBucket]
    private var refreshTimers: [Int: Task<Void, Never>] = [:]  // bucket index → timer

    public init(ourID: NodeID) {
        self.ourID = ourID
        self.buckets = [
            KBucket(min: NodeID(bytes: Data(repeating: 0, count: 20))!,
                    max: NodeID(bytes: Data(repeating: 0xFF, count: 20))!,
                    nodes: [])
        ]
    }

    // MARK: - Find Bucket

    private func bucketIndex(for id: NodeID) -> Int {
        for (i, bucket) in buckets.enumerated() {
            if bucket.min <= id && id <= bucket.max {
                return i
            }
        }
        // Fallback: insert into last matching or create new
        return buckets.count - 1
    }

    // MARK: - Insert

    /// Insert or update a node. Returns true if inserted, false if rejected.
    public func insert(nodeID: NodeID, ip: String, port: UInt16) async -> Bool {
        let idx = bucketIndex(for: nodeID)

        // Check if node already exists — update and move to tail
        if let existingIdx = buckets[idx].nodes.firstIndex(where: { $0.nodeID == nodeID }) {
            buckets[idx].nodes[existingIdx].failureCount = 0
            buckets[idx].nodes[existingIdx].lastSeen = Date()
            let entry = buckets[idx].nodes.remove(at: existingIdx)
            buckets[idx].nodes.append(entry)
            return true
        }

        let entry = NodeEntry(nodeIDBytes: nodeID.bytes, ip: ip, port: port, failureCount: 0, lastSeen: Date())

        // Not full — add
        if !buckets[idx].isFull {
            buckets[idx].nodes.append(entry)
            return true
        }

        // Full + covers our ID — split
        if buckets[idx].covers(ourID) {
            guard let (lower, upper) = buckets[idx].split() else { return false }
            var lo = lower; var up = upper
            buckets[idx].redistribute(into: &lo, &up)
            buckets[idx] = lo
            buckets.insert(up, at: idx + 1)
            // Retry insert into the correct new bucket
            return await insert(nodeID: nodeID, ip: ip, port: port)
        }

        // Full + doesn't cover our ID — reject (eviction requires ping, deferred)
        print("[Routing] Bucket \(idx) full, rejecting \(nodeID.debugDescription)")
        return false
    }

    /// Update lastSeen and reset failureCount when any message received from this node.
    public func markSeen(nodeID: NodeID) {
        let idx = bucketIndex(for: nodeID)
        if let i = buckets[idx].nodes.firstIndex(where: { $0.nodeID == nodeID }) {
            buckets[idx].nodes[i].lastSeen = Date()
            buckets[idx].nodes[i].failureCount = 0
        }
    }

    /// Increment failure count for a node (on timeout).
    public func markFailed(nodeID: NodeID) {
        let idx = bucketIndex(for: nodeID)
        if let i = buckets[idx].nodes.firstIndex(where: { $0.nodeID == nodeID }) {
            buckets[idx].nodes[i].failureCount += 1
        }
    }

    // MARK: - Find Closest

    /// Return up to K closest non-Bad nodes to target, sorted by XOR distance ascending.
    /// Only returns Good and Questionable nodes. Bad nodes are excluded unless <K total.
    public func findClosest(to target: NodeID, k: Int) -> [NodeEntry] {
        var all: [NodeEntry] = []
        for bucket in buckets {
            all.append(contentsOf: bucket.nodes)
        }
        let now = Date()
        let good = all.filter { $0.failureCount < 3 && $0.lastSeen.timeIntervalSince(now) > -900 }  // 15 min
        let questionable = all.filter { $0.failureCount < 3 && $0.lastSeen.timeIntervalSince(now) <= -900 }
        let bad = all.filter { $0.failureCount >= 3 }

        var result = (good + questionable).sorted { a, b in
            a.nodeID.xor(target) < b.nodeID.xor(target)
        }
        if result.count < k {
            result += bad.sorted { a, b in
                a.nodeID.xor(target) < b.nodeID.xor(target)
            }
        }
        return Array(result.prefix(k))
    }

    /// All nodes for persistence.
    public func allNodes() -> [NodeEntry] {
        buckets.flatMap(\.nodes)
    }

    /// Total node count.
    public var nodeCount: Int {
        buckets.reduce(0) { $0 + $1.nodes.count }
    }

    // MARK: - Persistence

    private static let storageURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".canopy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dht_routing_table.json")
    }()

    public func saveToDisk() {
        let nodes = allNodes().filter { $0.failureCount < 3 }
        guard let data = try? JSONEncoder().encode(nodes) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    public func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let nodes = try? JSONDecoder().decode([NodeEntry].self, from: data) else { return }
        let now = Date()
        let cutoff = now.addingTimeInterval(-86400)  // 24 hours
        for var entry in nodes {
            guard entry.lastSeen > cutoff else { continue }
            // Mark as Questionable if last seen >15 min ago
            if entry.lastSeen.timeIntervalSince(now) < -900 {
                entry.failureCount = 0  // not failed, just stale
            }
            _ = Task { await self.insert(nodeID: entry.nodeID, ip: entry.ip, port: entry.port) }
            // Update lastSeen + failureCount after insert
            markSeen(nodeID: entry.nodeID)
            if entry.failureCount > 0 {
                // Replay failures — approximate
            }
        }
        print("[Routing] Loaded \(nodeCount) nodes from disk")
    }

    // MARK: - Timers

    public func startRefreshTimers() {
        for (i, bucket) in buckets.enumerated() {
            refreshTimers[i]?.cancel()
            refreshTimers[i] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(900))  // 15 minutes
                    guard let self = self else { break }
                    await self.refreshBucket(at: i)
                }
            }
        }
    }

    private func refreshBucket(at index: Int) {
        guard index < buckets.count else { return }
        let bucket = buckets[index]
        // Pick a random ID in the bucket's range
        let a = Array(bucket.min.bytes)
        let b = Array(bucket.max.bytes)
        var randomBytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &randomBytes)
        // Clamp to range
        var clamped = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 {
            clamped[i] = max(a[i], min(b[i], randomBytes[i]))
        }
        let targetID = NodeID(bytes: Data(clamped))!
        // The refresh itself (findNode) is triggered by the caller
        print("[Routing] 🔄 Refreshing bucket \(index) with target \(targetID.debugDescription)")
    }

    // MARK: - Shutdown

    public func shutdown() {
        for timer in refreshTimers.values { timer.cancel() }
        refreshTimers.removeAll()
    }
}
