import XCTest
@testable import CanopyEngine

final class TrackerAnnounceTests: XCTestCase {

    func testQueryStringEncoding() {
        let infoHash = Data(repeating: 0xAB, count: 20)
        let peerID = Data("-CA0100-123456789012".utf8)
        let announce = TrackerAnnounce(
            infoHash: infoHash,
            peerID: peerID,
            port: 6881,
            left: 1000,
            event: .started
        )

        let qs = announce.queryString()

        XCTAssertTrue(qs.contains("info_hash="))
        XCTAssertTrue(qs.contains("peer_id="))
        XCTAssertTrue(qs.contains("port=6881"))
        XCTAssertTrue(qs.contains("left=1000"))
        XCTAssertTrue(qs.contains("compact=1"))
        XCTAssertTrue(qs.contains("event=started"))
        XCTAssertTrue(qs.contains("uploaded=0"))
        XCTAssertTrue(qs.contains("downloaded=0"))
    }

    func testEmptyEventOmitted() {
        let announce = TrackerAnnounce(
            infoHash: Data(repeating: 0, count: 20),
            peerID: Data(repeating: 0, count: 20),
            port: 0, left: 0, event: nil
        )
        let qs = announce.queryString()
        XCTAssertFalse(qs.contains("event"))
    }

    func testInfoHashIsPercentEncoded() {
        let infoHash = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
                              0x00, 0xFF, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60,
                              0x70, 0x80, 0x90, 0xA0])
        let announce = TrackerAnnounce(
            infoHash: infoHash,
            peerID: Data(repeating: 65, count: 20),
            port: 0, left: 0
        )
        let qs = announce.queryString()
        // Percent-encoded values should not contain raw non-ASCII bytes
        XCTAssertFalse(qs.contains("\u{01}"))
        XCTAssertFalse(qs.contains("\u{FF}"))
        // But should contain percent-encoded forms
        XCTAssertTrue(qs.contains("%FF"))
        // Regular ASCII letters should pass through unencoded
        XCTAssertTrue(qs.contains("peer_id="))
    }
}

final class HTTPTrackerParseTests: XCTestCase {

    func testParseCompactPeersEmpty() {
        XCTAssertEqual(parseCompactPeers(Data()).count, 0)
    }

    func testParseCompactPeersMalformed() {
        // 7 bytes, not divisible by 6
        let data = Data([1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(parseCompactPeers(data).count, 0)
    }

    func testParseTrackerSuccessResponse() throws {
        let resp: BencodeValue = .dict([
            ("interval", .integer(1800)),
            ("complete", .integer(5)),
            ("incomplete", .integer(3)),
            ("peers", .string(Data([10, 0, 0, 1, 0x1A, 0x0B]))), // 10.0.0.1:6667
        ])
        let data = BencodeEncoder.encode(resp)
        let parsed = try HTTPTracker.parseResponse(data)
        XCTAssertNil(parsed.failureReason)
        XCTAssertEqual(parsed.interval, 1800)
        XCTAssertEqual(parsed.complete, 5)
        XCTAssertEqual(parsed.incomplete, 3)
        XCTAssertEqual(parsed.peers.count, 1)
        XCTAssertEqual(parsed.peers[0].ip, "10.0.0.1")
        XCTAssertEqual(parsed.peers[0].port, 6667)
    }

    func testParseTrackerFailureResponse() throws {
        let resp: BencodeValue = .dict([
            ("failure reason", .string(Data("torrent not registered".utf8))),
        ])
        let data = BencodeEncoder.encode(resp)
        let parsed = try HTTPTracker.parseResponse(data)
        XCTAssertEqual(parsed.failureReason, "torrent not registered")
        XCTAssertTrue(parsed.isFailure)
    }

    func testParseTrackerWarningResponse() throws {
        let resp: BencodeValue = .dict([
            ("warning message", .string(Data("using non-default port".utf8))),
            ("interval", .integer(1800)),
        ])
        let data = BencodeEncoder.encode(resp)
        let parsed = try HTTPTracker.parseResponse(data)
        XCTAssertEqual(parsed.warningMessage, "using non-default port")
        XCTAssertNil(parsed.failureReason)
    }

    func testParsePlainPeers() throws {
        let peers: BencodeValue = .list([
            .dict([("ip", .string(Data("10.0.0.1".utf8))), ("port", .integer(8080))]),
            .dict([("ip", .string(Data("10.0.0.2".utf8))), ("port", .integer(9090))]),
        ])
        let parsed = try HTTPTracker.parsePeers(from: [("peers", peers)])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].ip, "10.0.0.1")
        XCTAssertEqual(parsed[0].port, 8080)
        XCTAssertEqual(parsed[1].ip, "10.0.0.2")
        XCTAssertEqual(parsed[1].port, 9090)
    }

    func testParseCompactPeersMultiple() {
        let data = Data([
            10, 0, 0, 1, 0x1A, 0x0B,      // 10.0.0.1:6667
            192, 168, 1, 5, 0x00, 0x50,   // 192.168.1.5:80
            8, 8, 8, 8, 0x01, 0xBB,       // 8.8.8.8:443
        ])
        let peers = parseCompactPeers(data)
        XCTAssertEqual(peers.count, 3)
        XCTAssertEqual(peers[1].ip, "192.168.1.5")
        XCTAssertEqual(peers[1].port, 80)
        XCTAssertEqual(peers[2].ip, "8.8.8.8")
        XCTAssertEqual(peers[2].port, 443)
    }
}
