/// Quick UDP tracker test. Run: swift run UDPTest 2>/dev/null
import Foundation
import CanopyEngine

@main
struct UDPTest {
    static func main() async {
        do {
            let udp = try UDPTracker(url: "udp://tracker.opentrackr.org:1337/announce")
            // Use debian netinst info hash — known active torrent
            let debianHash = Data([0x3b, 0x1d, 0xe9, 0xcb, 0x70, 0x11, 0x35, 0x0f, 0xa1, 0x52, 0xec, 0x47, 0x41, 0x96, 0x20, 0xaa, 0x15, 0x3e, 0x19, 0xe7])
            let announce = TrackerAnnounce(
                infoHash: debianHash,
                peerID: Data("-CA0100-123456789012".utf8),
                port: 6881,
                left: 0,
                event: nil
            )
            let resp = try await udp.announce(with: announce)
            print("[UDPTest] interval=\(resp.interval) seeders=\(resp.complete ?? 0) leechers=\(resp.incomplete ?? 0) peers=\(resp.peers.count)")
            for p in resp.peers.prefix(5) {
                print("[UDPTest]   peer: \(p.ip):\(p.port)")
            }
            if resp.isFailure {
                print("[UDPTest] ❌ Failure: \(resp.failureReason ?? "unknown")")
            } else if !resp.peers.isEmpty {
                print("[UDPTest] ✅ UDP tracker working — \(resp.peers.count) peers")
            }
        } catch {
            print("[UDPTest] ❌ Error: \(error)")
        }
    }
}
