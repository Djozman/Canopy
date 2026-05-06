/// Standalone runner for Phase 4 live download test.
/// Run: swift run -c debug LiveDownload 2>&1 | grep -v "^warning:"
/// (XCTest runner SIGTRAPs on Network.framework usage — this bypasses it.)

import Foundation
import CanopyEngine

@main
struct LiveDownload {
    static func main() async {
        print("[LiveTest] Phase 4 live download test — connecting to real tracker...")

        // Use the debian netinst torrent (small, well-seeded)
        let torrentPath = "Tests/CanopyEngine/TestTorrents/debian-13.4.0-amd64-netinst.iso.torrent"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: torrentPath)) else {
            print("[LiveTest] ❌ Could not read torrent file at \(torrentPath)")
            return
        }

        let torrent: TorrentFile
        do {
            torrent = try TorrentParser.parse(data: data)
        } catch {
            print("[LiveTest] ❌ Parse failed: \(error)")
            return
        }

        print("[LiveTest] Parsed: \(torrent.name), \(torrent.files.count) file(s), \(torrent.pieces.count) pieces")
        print("[LiveTest] Info hash: \(torrent.infoHash.hexString)")

        let savePath = "/tmp/canopy_live_test"
        try? FileManager.default.removeItem(atPath: savePath)

        let coord = DownloadCoordinator(torrent: torrent, savePath: savePath)

        do {
            print("[LiveTest] Starting download (300s timeout)...")
            try await withTimeout(seconds: 300) { try await coord.download() }
            print("[LiveTest] ✅ Download complete!")
        } catch DownloadError.allPeersDisconnected {
            print("[LiveTest] ⚠️ All peers disconnected, retrying once...")
            let coord2 = DownloadCoordinator(torrent: torrent, savePath: savePath)
            do {
                try await coord2.download()
                print("[LiveTest] ✅ Download complete on retry!")
            } catch {
                print("[LiveTest] ❌ Retry failed: \(error)")
            }
        } catch {
            print("[LiveTest] ❌ Download failed: \(error)")
        }

        // Verify
        if let files = try? FileManager.default.contentsOfDirectory(atPath: savePath) {
            for f in files {
                let path = "\(savePath)/\(f)"
                let attr = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attr?[.size] as? Int64) ?? 0
                print("[LiveTest]   \(f): \(size) bytes")
            }
            if files.isEmpty {
                print("[LiveTest] ❌ No files downloaded")
            }
        }
    }
}

func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}
