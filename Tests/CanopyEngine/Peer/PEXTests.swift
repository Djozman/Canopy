import XCTest
@testable import CanopyEngine

final class PEXTests: XCTestCase {

    func testEncodeCompactPeer() {
        let peer = Peer(ip: "10.0.0.1", port: 6667)
        let data = encodeCompactPeer(peer)
        XCTAssertEqual(data.count, 6)
        XCTAssertEqual(data[0], 10)
        XCTAssertEqual(data[1], 0)
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 1)
        // port 6667 = 0x1A0B big-endian
        XCTAssertEqual(data[4], 0x1A)
        XCTAssertEqual(data[5], 0x0B)
    }

    func testParsePEXMessageRoundTrip() {
        let added = [
            Peer(ip: "10.0.0.1", port: 6667),
            Peer(ip: "192.168.1.5", port: 80),
            Peer(ip: "8.8.8.8", port: 443),
        ]
        let dropped = [
            Peer(ip: "172.16.0.1", port: 9999),
        ]

        // Build and parse
        guard let msg = buildPEXMessage(added: added, dropped: dropped, utPEXID: 1) else {
            XCTFail("buildPEXMessage returned nil")
            return
        }
        guard case .extended(1, let data) = msg else {
            XCTFail("Expected .extended(1, _)")
            return
        }

        let parsed = parsePEXMessage(from: data)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.added.count, 3)
        XCTAssertEqual(parsed?.added[0].ip, "10.0.0.1")
        XCTAssertEqual(parsed?.added[0].port, 6667)
        XCTAssertEqual(parsed?.added[1].ip, "192.168.1.5")
        XCTAssertEqual(parsed?.dropped.count, 1)
        XCTAssertEqual(parsed?.dropped[0].ip, "172.16.0.1")
        XCTAssertEqual(parsed?.dropped[0].port, 9999)
    }

    func testParseEmptyPEXMessage() {
        let dict: BencodeValue = .dict([
            ("added", .string(Data())),
            ("dropped", .string(Data())),
        ])
        let data = BencodeEncoder.encode(dict)
        let parsed = parsePEXMessage(from: data)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.added.count, 0)
        XCTAssertEqual(parsed?.dropped.count, 0)
    }

    func testParsePEXMessageWithAddedf() {
        // added.f is a separate key — should be ignored
        let dict: BencodeValue = .dict([
            ("added", .string(Data([10,0,0,1,0x1A,0x0B]))), // one peer
            ("added.f", .string(Data([0x01]))),
            ("dropped", .string(Data())),
        ])
        let data = BencodeEncoder.encode(dict)
        let parsed = parsePEXMessage(from: data)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.added.count, 1)
        XCTAssertEqual(parsed?.added[0].ip, "10.0.0.1")
    }

    func testBuildPEXMessageEmpty() {
        // Empty lists should return nil
        XCTAssertNil(buildPEXMessage(added: [], dropped: [], utPEXID: 1))
        // nil utPEXID should return nil
        XCTAssertNil(buildPEXMessage(added: [Peer(ip: "1.2.3.4", port: 5)], dropped: [], utPEXID: nil))
    }

    func testBuildPEXMessageSingleAdded() {
        // Only added, no dropped
        let added = [Peer(ip: "1.2.3.4", port: 5)]
        guard let msg = buildPEXMessage(added: added, dropped: [], utPEXID: 2) else {
            XCTFail("Should not be nil")
            return
        }
        guard case .extended(2, let data) = msg else { XCTFail("Wrong msg"); return }
        let parsed = parsePEXMessage(from: data)
        XCTAssertEqual(parsed?.added.count, 1)
        XCTAssertEqual(parsed?.dropped.count, 0)
    }
}
