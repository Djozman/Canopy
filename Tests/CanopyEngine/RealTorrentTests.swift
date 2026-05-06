import XCTest
@testable import CanopyEngine

final class RealTorrentTests: XCTestCase {

    func testAllTestTorrentsParse() throws {
        let dir = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("TestTorrents"))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "torrent" }

        XCTAssertGreaterThan(files.count, 5, "Need at least a few test torrents")

        for url in files {
            let data = try Data(contentsOf: url)
            let torrent = try TorrentParser.parse(data: data)
            XCTAssertFalse(torrent.name.isEmpty, "Name empty for \(url.lastPathComponent)")
            XCTAssertGreaterThan(torrent.totalSize, 0, "Zero size for \(url.lastPathComponent)")
            XCTAssertFalse(torrent.pieces.isEmpty, "No pieces for \(url.lastPathComponent)")
            XCTAssertEqual(torrent.infoHash.count, 20, "infoHash wrong size for \(url.lastPathComponent)")
            XCTAssertFalse(torrent.files.isEmpty, "No files for \(url.lastPathComponent)")
        }
    }

    func testInfoHashStableOnReread() throws {
        let dir = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("TestTorrents"))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "torrent" }

        for url in files {
            let a = try TorrentParser.parse(data: Data(contentsOf: url))
            let b = try TorrentParser.parse(data: Data(contentsOf: url))
            XCTAssertEqual(a.infoHash, b.infoHash, "infoHash not stable for \(url.lastPathComponent)")
        }
    }
}
