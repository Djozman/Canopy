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
        Log.dht.info("Starting bootstrap...")
        let nodeID = await session.nodeID

        // Load saved routing table first so we have existing nodes to query
        // even if all bootstrap routers are down.
        await session.loadRoutingTable()

        var anyResponded = false

        // Ping each router
        for (ip, port) in routers {
            let txID = makeTransactionID(0)
            let data = buildPing(txID: txID, ourID: nodeID)
            do {
                _ = try await session.sendQuery(to: ip, port: port, txID: txID, data: data)
                anyResponded = true
                Log.dht.info("✅ Router \(ip):\(port) responded")
            } catch {
                Log.dht.warning("⚠️ Router \(ip):\(port) failed: \(error)")
            }
        }

        guard anyResponded else {
            Log.dht.error("❌ No routers responded — DHT will populate from incoming queries")
            return false
        }

        // Pass 1: iterative self-lookup
        Log.dht.info("Running self-lookup...")
        let _ = await session.findNode(target: nodeID)
        Log.dht.info("Self-lookup complete")

        // Pass 2: per-bucket findNode for stale buckets (deferred to refresh timer)
        Log.dht.info("Bootstrap complete")
        return true
    }
}
