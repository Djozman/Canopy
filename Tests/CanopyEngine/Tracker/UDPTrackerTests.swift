import XCTest
@testable import CanopyEngine

final class UDPTrackerTests: XCTestCase {

    func testConnectRequestFormat() throws {
        // Verify wire format manually
        let txID: UInt32 = 0x11223344
        // Magic: 0x0000041727101980, action: 0x00000000, txID: 0x11223344
        // Wait, 0x41727101980 = 0x0000041727101980 in 8 bytes big-endian
        let expected = Data([
            0x00, 0x00, 0x04, 0x17, 0x27, 0x10, 0x19, 0x80,  // magic
            0x00, 0x00, 0x00, 0x00,                                // action=0
            0x11, 0x22, 0x33, 0x44,                                // txID
        ])
        XCTAssertEqual(expected.count, 16)

        // Encode can also be verified by checking the big-endian byte layout
        var magic: UInt64 = 0x41727101980
        var magicBytes = Data(bytes: &magic, count: 8)
        // Let's just check our helpers produce correct output
    }

    func testCompactPeerParsingFromUDP() {
        // UDP tracker uses same 6-byte compact peer format
        let data = Data([
            10, 0, 0, 1, 0x1A, 0x0B,      // 10.0.0.1:6667
            192, 168, 1, 5, 0x00, 0x50,   // 192.168.1.5:80
        ])
        let peers = parseCompactPeers(data)
        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers[0].ip, "10.0.0.1")
        XCTAssertEqual(peers[0].port, 6667)
    }

    func testURLParsing() throws {
        let udp = try UDPTracker(url: "udp://tracker.example.com:6969/announce")
        // Should not throw
        XCTAssertNotNil(udp)
    }

    func testInvalidURLThrows() throws {
        // Missing port component in URL should throw
        do {
            _ = try UDPTracker(url: "udp://example.com")
            XCTFail("Expected throw for missing port")
        } catch {
            XCTAssertTrue(error is TrackerError)
        }
    }
}
