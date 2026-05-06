/// Seed runner — downloads if needed, then seeds. Run LeechOnly in another terminal.
/// Run: swift run SeedOnly 2>/dev/null

import Foundation
import CanopyEngine

@main
struct SeedOnly {
    static func main() async {
        let torrentPath = "Tests/CanopyEngine/TestTorrents/debian-13.4.0-amd64-netinst.iso.torrent"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: torrentPath)),
              let torrent = try? TorrentParser.parse(data: data) else {
            print("[SeedOnly] ❌ Could not parse torrent")
            return
        }

        let savePath = "/tmp/canopy_live_test"
        let coord = DownloadCoordinator(torrent: torrent, savePath: savePath)

        do { try await coord.startListener(); print("[SeedOnly] 👂 Listening on 6881") }
        catch { print("[SeedOnly] ⚠️ Listener failed: \(error)") }

        // Resume if file is complete
        let isoPath = "\(savePath)/\(torrent.files[0].path)"
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: isoPath)[.size] as? Int64) ?? 0
        if fileSize == torrent.totalSize {
            let allPieces = Array(0..<torrent.pieces.count)
            try? JSONEncoder().encode(allPieces).write(to: URL(fileURLWithPath: "\(savePath)/.canopy_resume"), options: .atomic)
            print("[SeedOnly] ✅ Complete file found (\(fileSize) bytes)")
        }
        // Always call download() — it loads resume and opens file handles needed for seed()
        do {
            try await coord.download()
            print("[SeedOnly] ✅ Ready")
        } catch {
            print("[SeedOnly] ⚠️ \(error)")
        }

        print("[SeedOnly] 🌱 Seeding — run in another terminal:")
        print("     cd /Users/amm/Canopy && swift run LeechOnly 2>/dev/null")
        await coord.seed()
    }
}
