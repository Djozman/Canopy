import XCTest
@testable import CanopyEngine

final class MetadataMessageTests: XCTestCase {

    func testRequestRoundTrip() {
        let msg = buildMetadataRequest(piece: 3, extensionID: 2)
        guard case .extended(2, let data) = msg else { XCTFail(); return }
        let parsed = parseMetadataMessage(from: data)
        XCTAssertEqual(parsed, .request(piece: 3))
    }

    func testRejectRoundTrip() {
        let msg = buildMetadataReject(piece: 5, extensionID: 1)
        guard case .extended(1, let data) = msg else { XCTFail(); return }
        let parsed = parseMetadataMessage(from: data)
        XCTAssertEqual(parsed, .reject(piece: 5))
    }

    func testDataRoundTrip() {
        let payload = Data((0..<16384).map { UInt8($0 % 256) })
        let msg = buildMetadataData(piece: 0, totalSize: 32768, data: payload, extensionID: 3)
        guard case .extended(3, let data) = msg else { XCTFail(); return }
        let parsed = parseMetadataMessage(from: data)
        guard case .data(let piece, let totalSize, let p) = parsed else { XCTFail(); return }
        XCTAssertEqual(piece, 0)
        XCTAssertEqual(totalSize, 32768)
        XCTAssertEqual(p, payload)
    }

    func testDataWithNullBytesInPayload() {
        var payload = Data(repeating: 0xFF, count: 100)
        payload[50] = 0x00
        payload[51] = 0x00
        let msg = buildMetadataData(piece: 0, totalSize: 16384, data: payload, extensionID: 1)
        guard case .extended(1, let data) = msg else { XCTFail(); return }
        let parsed = parseMetadataMessage(from: data)
        guard case .data(_, _, let p) = parsed else { XCTFail(); return }
        XCTAssertEqual(p[50], 0x00)
        XCTAssertEqual(p[51], 0x00)
        XCTAssertEqual(p.count, 100)
    }

    func testPayloadSeparatedFromDictViaRange() {
        // Verify the payload is correctly separated from the bencoded dict
        let payload = Data([0xAA, 0xBB, 0xCC])
        let msg = buildMetadataData(piece: 1, totalSize: 16384, data: payload, extensionID: 2)
        guard case .extended(2, let data) = msg else { XCTFail(); return }
        // data should contain the bencoded dict followed by the raw payload bytes
        let parsed = parseMetadataMessage(from: data)
        guard case .data(_, _, let p) = parsed else { XCTFail(); return }
        XCTAssertEqual(p, payload)
    }

    func testMalformedMessageReturnsNil() {
        let junk = Data([0x00, 0x01, 0x02])
        XCTAssertNil(parseMetadataMessage(from: junk))
    }
}
