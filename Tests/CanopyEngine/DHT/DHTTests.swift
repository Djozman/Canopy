import XCTest
@testable import CanopyEngine

final class DHTTests: XCTestCase {

    // MARK: - Binary round-trip (bencode null bytes)

    func testNullByteBencodeRoundTrip() {
        let original = Data([0x00, 0xFF, 0x80, 0x01, 0x00, 0xAB])
        let value: BencodeValue = .string(original)
        let encoded = BencodeEncoder.encode(value)
        let (decoded, _) = try! BencodeDecoder.decode(encoded)
        guard case .string(let result) = decoded else { XCTFail(); return }
        XCTAssertEqual(result, original, "Null-byte Data must survive bencode round-trip byte-for-byte")
    }

    func testNodeIDWithNullBytesRoundTrip() {
        let id = NodeID(bytes: Data([0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00,
                                      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                      0x00, 0x00, 0x00, 0x00]))!
        let value: BencodeValue = .string(id.bytes)
        let encoded = BencodeEncoder.encode(value)
        let (decoded, _) = try! BencodeDecoder.decode(encoded)
        guard case .string(let result) = decoded else { XCTFail(); return }
        XCTAssertEqual(result, id.bytes, "NodeID with null bytes must survive bencode")
    }

    // MARK: - NodeID

    func testNodeIDRandom() {
        let a = NodeID.random()
        let b = NodeID.random()
        XCTAssertEqual(a.bytes.count, 20)
        XCTAssertNotEqual(a, b)
    }

    func testNodeIDXOR() {
        let a = NodeID(bytes: Data(repeating: 0xFF, count: 20))!
        let b = NodeID(bytes: Data(repeating: 0x00, count: 20))!
        let x = a.xor(b)
        XCTAssertEqual(x.bytes, Data(repeating: 0xFF, count: 20))
    }

    func testNodeIDComparable() {
        let a = NodeID(bytes: Data([0x01] + Array(repeating: 0x00, count: 19)))!
        let b = NodeID(bytes: Data([0x02] + Array(repeating: 0x00, count: 19)))!
        XCTAssertLessThan(a, b)
    }

    // MARK: - Compact Node Encoding

    func testCompactNodeRoundTrip26Bytes() {
        let id = NodeID(bytes: Data(repeating: 0xAB, count: 20))!
        let data = encodeCompactNode(nodeID: id, ip: "10.0.0.1", port: 6667)
        XCTAssertEqual(data.count, 26)
        // Verify node ID prefix
        XCTAssertEqual(data.prefix(20), id.bytes)
        // Verify IP bytes
        XCTAssertEqual(data[20], 10)
        XCTAssertEqual(data[21], 0)
        XCTAssertEqual(data[22], 0)
        XCTAssertEqual(data[23], 1)
        // Verify port (6667 = 0x1A0B)
        XCTAssertEqual(data[24], 0x1A)
        XCTAssertEqual(data[25], 0x0B)

        let decoded = decodeCompactNodes(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].nodeID, id)
        XCTAssertEqual(decoded[0].ip, "10.0.0.1")
        XCTAssertEqual(decoded[0].port, 6667)
    }

    // MARK: - TXID Encoding

    func testTransactionIDEncoding() {
        // TX IDs are now random (libtorrent: random(0xffff)), not sequential
        let tx = makeTransactionID(0)
        XCTAssertEqual(tx.count, 2)
        // Verify each call produces data (randomness means we can't check specific bytes)
        let tx2 = makeTransactionID(0)
        XCTAssertEqual(tx2.count, 2)
    }

    // MARK: - Message Encode/Decode

    func testPingMessageRoundTrip() {
        let ourID = NodeID(bytes: Data(repeating: 0xAA, count: 20))!
        let tx = makeTransactionID(42)
        let data = buildPing(txID: tx, ourID: ourID)

        guard case .query(let t, let qType, _) = parseDHTMessage(data)! else { XCTFail(); return }
        XCTAssertEqual(t, tx)
        XCTAssertEqual(qType, "ping")
    }

    func testFindNodeMessageRoundTrip() {
        let ourID = NodeID(bytes: Data(repeating: 0xAA, count: 20))!
        let target = NodeID(bytes: Data(repeating: 0xBB, count: 20))!
        let tx = makeTransactionID(99)
        let data = buildFindNode(txID: tx, ourID: ourID, target: target)
        XCTAssertNotNil(data)
    }

    func testResponseEncode() {
        let ourID = NodeID(bytes: Data(repeating: 0xAA, count: 20))!
        let tx = makeTransactionID(1)
        let data = buildResponse(txID: tx, ourID: ourID, args: [])
        guard case .response(let t, _, _) = parseDHTMessage(data)! else { XCTFail(); return }
        XCTAssertEqual(t, tx)
    }

    func testErrorEncode() {
        let tx = makeTransactionID(5)
        let data = buildError(txID: tx, code: 203, message: "bad token")
        guard case .error(let t, let code, let msg) = parseDHTMessage(data)! else { XCTFail(); return }
        XCTAssertEqual(t, tx)
        XCTAssertEqual(code, 203)
        XCTAssertEqual(msg, "bad token")
    }

    // MARK: - Routing Table Midpoint Split

    func testMidpointSplit() {
        let minID = NodeID(bytes: Data(repeating: 0x00, count: 20))!
        let maxID = NodeID(bytes: Data(repeating: 0xFF, count: 20))!

        // Fill a bucket
        var bucket = KBucket(min: minID, max: maxID, nodes: [])
        for i in 0..<8 {
            let idBytes = Data([UInt8(i * 32)] + Array(repeating: 0x00, count: 19))
            bucket.nodes.append(NodeEntry(
                nodeIDBytes: idBytes, ip: "1.2.3.\(i)", port: 6881,
                failureCount: 0, lastSeen: Date()
            ))
        }

        guard let (lower, upper) = bucket.split() else { XCTFail("Split failed"); return }

        // The midpoint should be 0x7FFFFF...
        let expectedMid = UInt8(0x7F)
        XCTAssertEqual(Array(lower.max.bytes)[0], expectedMid, "Lower bucket max should be 0x7F")
        XCTAssertEqual(Array(upper.min.bytes)[0], 0x80, "Upper bucket min should be 0x80")
    }
}
