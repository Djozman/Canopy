import XCTest
@testable import CanopyEngine

final class HandshakeTests: XCTestCase {

    func testHandshakeRoundTrip() {
        let infoHash = Data(repeating: 0xAB, count: 20)
        let peerID = Data("-CA0100-123456789012".utf8)
        let handshake = Handshake(infoHash: infoHash, peerID: peerID, extensions: [0,0,0,0,0,0x10,0,0])
        let encoded = handshake.encode()
        XCTAssertEqual(encoded.count, 68)
        XCTAssertEqual(encoded[0], 19)

        let decoded = Handshake.decode(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.infoHash, infoHash)
        XCTAssertEqual(decoded?.peerID, peerID)
    }

    func testHandshakeRejectsWrongProtocol() {
        var data = Data([19])
        data.append(contentsOf: "Wrong protocol idxx".utf8)
        data.append(contentsOf: Data(repeating: 0, count: 48))
        XCTAssertNil(Handshake.decode(from: data))
    }

    func testHandshakeRejectsWrongLength() {
        let data = Data(repeating: 0, count: 67)
        XCTAssertNil(Handshake.decode(from: data))
    }
}

final class PeerMessageTests: XCTestCase {

    func testKeepAliveRoundTrip() {
        let msg = PeerMessage.keepAlive
        let encoded = msg.encode()
        XCTAssertEqual(encoded, Data([0, 0, 0, 0]))
        let bytes = Array(encoded)
        var offset = 0
        let decoded = PeerMessage.decode(from: bytes, readOffset: &offset)
        XCTAssertEqual(decoded, .keepAlive)
        XCTAssertEqual(offset, 4)
    }

    func testChokeRoundTrip() {
        let encoded = PeerMessage.choke.encode()
        let bytes = Array(encoded)
        var offset = 0
        XCTAssertEqual(PeerMessage.decode(from: bytes, readOffset: &offset), .choke)
    }

    func testUnchokeRoundTrip() {
        let encoded = PeerMessage.unchoke.encode()
        let bytes = Array(encoded)
        var offset = 0
        XCTAssertEqual(PeerMessage.decode(from: bytes, readOffset: &offset), .unchoke)
    }

    func testInterestedRoundTrip() {
        let encoded = PeerMessage.interested.encode()
        let bytes = Array(encoded)
        var offset = 0
        XCTAssertEqual(PeerMessage.decode(from: bytes, readOffset: &offset), .interested)
    }

    func testHaveRoundTrip() {
        let msg = PeerMessage.have(piece: 42)
        let bytes = Array(msg.encode())
        var offset = 0
        let decoded = PeerMessage.decode(from: bytes, readOffset: &offset)
        XCTAssertEqual(decoded, .have(piece: 42))
    }

    func testBitfieldRoundTrip() {
        let bits = Data([0b10101010])
        let msg = PeerMessage.bitfield(bits)
        let bytes = Array(msg.encode())
        var offset = 0
        let decoded = PeerMessage.decode(from: bytes, readOffset: &offset)
        XCTAssertEqual(decoded, .bitfield(bits))
    }

    func testRequestRoundTrip() {
        let msg = PeerMessage.request(piece: 5, begin: 16384, length: 16384)
        let bytes = Array(msg.encode())
        var offset = 0
        let decoded = PeerMessage.decode(from: bytes, readOffset: &offset)
        XCTAssertEqual(decoded, .request(piece: 5, begin: 16384, length: 16384))
    }

    func testPieceRoundTrip() {
        let block = Data(repeating: 0xFF, count: 16384)
        let msg = PeerMessage.piece(piece: 3, begin: 0, data: block)
        let bytes = Array(msg.encode())
        var offset = 0
        let decoded = PeerMessage.decode(from: bytes, readOffset: &offset)
        XCTAssertEqual(decoded, .piece(piece: 3, begin: 0, data: block))
        XCTAssertEqual(offset, bytes.count) // all bytes consumed
    }

    func testCancelRoundTrip() {
        let msg = PeerMessage.cancel(piece: 7, begin: 32768, length: 16384)
        let bytes = Array(msg.encode())
        var offset = 0
        let decoded = PeerMessage.decode(from: bytes, readOffset: &offset)
        XCTAssertEqual(decoded, .cancel(piece: 7, begin: 32768, length: 16384))
    }

    func testMultipleMessages() {
        let bytes = Array(PeerMessage.unchoke.encode() + PeerMessage.interested.encode() + PeerMessage.choke.encode())
        var offset = 0
        XCTAssertEqual(PeerMessage.decode(from: bytes, readOffset: &offset), .unchoke)
        XCTAssertEqual(PeerMessage.decode(from: bytes, readOffset: &offset), .interested)
        XCTAssertEqual(PeerMessage.decode(from: bytes, readOffset: &offset), .choke)
        XCTAssertEqual(offset, bytes.count)
    }

    func testDecodeNeedsMoreData() {
        // Incomplete message header (only 2 bytes of 4-byte length)
        let bytes: [UInt8] = [0, 0]
        var offset = 0
        XCTAssertNil(PeerMessage.decode(from: bytes, readOffset: &offset))
        XCTAssertEqual(offset, 0) // offset untouched since not enough data
    }

    func testFuzzRandomBytes() {
        // Phase 2 exit criteria: feed 10,000 random blobs, never crash
        for _ in 0..<10_000 {
            let length = Int.random(in: 0...512)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
            var offset = 0
            // Drain all parsable messages — decode returns nil when it can't parse
            while PeerMessage.decode(from: bytes, readOffset: &offset) != nil {}
            // Remaining data might be a partial message — that's fine
        }
        // If we got here without crashing, the test passes
    }

    func testOversizedMessageSkipped() {
        var bytes = [UInt8]()
        bytes.append(0x00)
        bytes.append(0x20)
        bytes.append(0x00)
        bytes.append(0x00)
        bytes.append(0x00)
        for _ in 0..<(2 * 1024 * 1024) { bytes.append(0x00) }
        var offset = 0
        let result = PeerMessage.decode(from: bytes, readOffset: &offset)
        XCTAssertNil(result)
        XCTAssertEqual(offset, bytes.count)
    }

    func testEmptyBitfield() {
        let msg = PeerMessage.bitfield(Data())
        let encoded = msg.encode()
        var offset = 0
        let decoded = PeerMessage.decode(from: Array(encoded), readOffset: &offset)
        XCTAssertEqual(decoded, .bitfield(Data()))
    }

    func testEmptyExtended() {
        let msg = PeerMessage.extended(id: 5, data: Data())
        let encoded = msg.encode()
        var offset = 0
        let decoded = PeerMessage.decode(from: Array(encoded), readOffset: &offset)
        XCTAssertEqual(decoded, .extended(id: 5, data: Data()))
    }

    func testZeroLengthMessageNotKeepAlive() {
        var offset = 0
        let result = PeerMessage.decode(from: [0, 0, 0, 0, 0], readOffset: &offset)
        XCTAssertEqual(result, .keepAlive)
    }
}
