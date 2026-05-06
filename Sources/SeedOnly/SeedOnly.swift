/// Minimal seed-only runner for testing upload.
/// Run: swift run -c debug SeedOnly 2>/dev/null
/// Requires: a completed download at /tmp/canopy_live_test/

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
        // Write a complete resume file so the engine knows all pieces are done
        let allPieces = Array(0..<torrent.pieces.count)
        if let resumeData = try? JSONEncoder().encode(allPieces) {
            try? resumeData.write(to: URL(fileURLWithPath: "\(savePath)/.canopy_resume"), options: .atomic)
            print("[SeedOnly] Wrote full resume file (\(allPieces.count) pieces)")
        }

        let coord = DownloadCoordinator(torrent: torrent, savePath: savePath)

        do {
            try await coord.startListener()
            print("[SeedOnly] 👂 Listener started")
        } catch {
            print("[SeedOnly] ⚠️ Listener failed: \(error)")
        }

        // Download will complete instantly since resume has all pieces
        do {
            try await coord.download()
            print("[SeedOnly] ✅ Ready to seed")
        } catch {
            print("[SeedOnly] Download error: \(error) — seeding anyway")
        }

        print("[SeedOnly] 🌱 Seeding — add peer via transmission-remote then Ctrl+C")
        print("     transmission-remote -t 1 --peer-add '127.0.0.1:6881'")
        print("     transmission-remote -t 1 --start")
        await coord.seed()
    }
}
