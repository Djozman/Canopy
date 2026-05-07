import Foundation

/// DHT bootstrap — populates the routing table from known routers.
public enum DHTBootstrap {

    /// Bootstrap routers (BEP 5 well-known nodes).
    public static let routers: [(String, UInt16)] = [
        ("router.bittorrent.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.libtorrent.org", 25401),
    ]

    /// Run full bootstrap against a DHT session. Returns true if at least one router responded.
    public static func bootstrap(session: DHTSession) async -> Bool {
        print("[Bootstrap] Starting bootstrap...")
        let nodeID = await session.nodeID
        var anyResponded = false

        // Ping each router
        for (ip, port) in routers {
            let txID = makeTransactionID(0)
            let data = buildPing(txID: txID, ourID: nodeID)
            do {
                _ = try await session.sendQuery(to: ip, port: port, txID: txID, data: data)
                anyResponded = true
                print("[Bootstrap] ✅ Router \(ip):\(port) responded")
            } catch {
                print("[Bootstrap] ⚠️ Router \(ip):\(port) failed: \(error)")
            }
        }

        guard anyResponded else {
            print("[Bootstrap] ❌ No routers responded — DHT will populate from incoming queries")
            return false
        }

        // Pass 1: iterative self-lookup
        print("[Bootstrap] Running self-lookup...")
        let _ = await session.findNode(target: nodeID)
        print("[Bootstrap] Self-lookup complete")

        // Pass 2: per-bucket findNode for stale buckets (deferred to refresh timer)
        print("[Bootstrap] Bootstrap complete")
        return true
    }
}
