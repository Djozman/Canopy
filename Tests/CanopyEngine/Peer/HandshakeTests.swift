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
        var data = encoded
        let decoded = PeerMessage.decode(from: &data)
        XCTAssertEqual(decoded, .keepAlive)
    }

    func testChokeRoundTrip() {
        let encoded = PeerMessage.choke.encode()
        var data = encoded
        XCTAssertEqual(PeerMessage.decode(from: &data), .choke)
    }

    func testUnchokeRoundTrip() {
        let encoded = PeerMessage.unchoke.encode()
        var data = encoded
        XCTAssertEqual(PeerMessage.decode(from: &data), .unchoke)
    }

    func testInterestedRoundTrip() {
        let encoded = PeerMessage.interested.encode()
        var data = encoded
        XCTAssertEqual(PeerMessage.decode(from: &data), .interested)
    }

    func testHaveRoundTrip() {
        let msg = PeerMessage.have(piece: 42)
        var data = msg.encode()
        let decoded = PeerMessage.decode(from: &data)
        XCTAssertEqual(decoded, .have(piece: 42))
    }

    func testBitfieldRoundTrip() {
        let bits = Data([0b10101010])
        let msg = PeerMessage.bitfield(bits)
        var data = msg.encode()
        let decoded = PeerMessage.decode(from: &data)
        XCTAssertEqual(decoded, .bitfield(bits))
    }

    func testRequestRoundTrip() {
        let msg = PeerMessage.request(piece: 5, begin: 16384, length: 16384)
        var data = msg.encode()
        let decoded = PeerMessage.decode(from: &data)
        XCTAssertEqual(decoded, .request(piece: 5, begin: 16384, length: 16384))
    }

    func testPieceRoundTrip() {
        let block = Data(repeating: 0xFF, count: 16384)
        let msg = PeerMessage.piece(piece: 3, begin: 0, data: block)
        var data = msg.encode()
        let decoded = PeerMessage.decode(from: &data)
        XCTAssertEqual(decoded, .piece(piece: 3, begin: 0, data: block))
        XCTAssertEqual(data.count, 0)
    }

    func testCancelRoundTrip() {
        let msg = PeerMessage.cancel(piece: 7, begin: 32768, length: 16384)
        var data = msg.encode()
        let decoded = PeerMessage.decode(from: &data)
        XCTAssertEqual(decoded, .cancel(piece: 7, begin: 32768, length: 16384))
    }

    func testMultipleMessages() {
        var data = PeerMessage.unchoke.encode() + PeerMessage.interested.encode() + PeerMessage.choke.encode()
        XCTAssertEqual(PeerMessage.decode(from: &data), .unchoke)
        XCTAssertEqual(PeerMessage.decode(from: &data), .interested)
        XCTAssertEqual(PeerMessage.decode(from: &data), .choke)
        XCTAssertEqual(data.count, 0)
    }

    func testDecodeNeedsMoreData() {
        // Incomplete message header (only 2 bytes of 4-byte length)
        var data = Data([0, 0])
        XCTAssertNil(PeerMessage.decode(from: &data))
        XCTAssertEqual(data.count, 2) // data untouched
    }
}
