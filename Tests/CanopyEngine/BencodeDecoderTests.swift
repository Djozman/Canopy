import XCTest
@testable import CanopyEngine

final class BencodeDecoderTests: XCTestCase {

    func testDecodeInteger() throws {
        let (value, _) = try BencodeDecoder.decode(Data("i42e".utf8))
        XCTAssertEqual(value, .integer(42))
    }

    func testDecodeNegativeInteger() throws {
        let (value, _) = try BencodeDecoder.decode(Data("i-7e".utf8))
        XCTAssertEqual(value, .integer(-7))
    }

    func testDecodeString() throws {
        let (value, _) = try BencodeDecoder.decode(Data("4:spam".utf8))
        XCTAssertEqual(value, .string(Data("spam".utf8)))
    }

    func testDecodeEmptyString() throws {
        let (value, _) = try BencodeDecoder.decode(Data("0:".utf8))
        XCTAssertEqual(value, .string(Data()))
    }

    func testDecodeList() throws {
        let (value, _) = try BencodeDecoder.decode(Data("li1ei2ee".utf8))
        XCTAssertEqual(value, .list([.integer(1), .integer(2)]))
    }

    func testDecodeDict() throws {
        let (value, _) = try BencodeDecoder.decode(Data("d3:key5:valuee".utf8))
        XCTAssertEqual(value, .dict([("key", .string(Data("value".utf8)))]))
    }

    func testDecodeNested() throws {
        let info: BencodeValue = .dict([
            ("pieces", .string(Data(repeating: 97, count: 20))),
        ])
        let root: BencodeValue = .dict([
            ("info", info),
        ])
        let correctData = BencodeEncoder.encode(root)
        let (value, _) = try BencodeDecoder.decode(correctData)
        guard case .dict(let outer) = value else { XCTFail(); return }
        guard case .dict(let inner) = outer.first(where: { $0.0 == "info" })!.1 else { XCTFail(); return }
        guard case .string(let pieces) = inner.first(where: { $0.0 == "pieces" })!.1 else { XCTFail(); return }
        XCTAssertEqual(pieces.count, 20)
    }

    func testDecodeReturnsByteRange() throws {
        let data = Data("i42e".utf8)
        let (_, range) = try BencodeDecoder.decode(data)
        XCTAssertEqual(range, 0..<4)
    }
}
