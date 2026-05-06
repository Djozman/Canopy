import XCTest
@testable import CanopyEngine

final class RealTorrentTests: XCTestCase {

    private func torrentData(named filename: String) throws -> Data {
        let dir = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("TestTorrents"))
        let url = dir.appendingPathComponent(filename)
        return try Data(contentsOf: url)
    }

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

    func testInfoHashMatchesKnownValue_archlinux() throws {
        let torrent = try TorrentParser.parse(data: torrentData(named: "archlinux-2026.05.01-x86_64.iso.torrent"))
        XCTAssertEqual(torrent.infoHash.hexString, "e337a880c4d0f552bab5b437fe1208d26130ccc5")
    }

    func testInfoHashMatchesKnownValue_ubuntu() throws {
        let torrent = try TorrentParser.parse(data: torrentData(named: "ubuntu-24.04.4-desktop-amd64.iso.torrent"))
        XCTAssertEqual(torrent.infoHash.hexString, "01c137287d6f0ed05a56742dae794f632c79ff3d")
    }

    func testInfoHashMatchesKnownValue_debian() throws {
        let torrent = try TorrentParser.parse(data: torrentData(named: "debian-13.4.0-amd64-netinst.iso.torrent"))
        XCTAssertEqual(torrent.infoHash.hexString, "3b1de9cb7011350fa152ec47419620aa153e19e7")
    }
}
