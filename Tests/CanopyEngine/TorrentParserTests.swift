import XCTest
@testable import CanopyEngine

final class TorrentParserTests: XCTestCase {

    func testParseSingleFile() throws {
        let announce = "http://tracker.example.com/announce"
        let name = "test.txt"
        let pieces = Data(repeating: 97, count: 20) // 20 'a' bytes

        let info: BencodeValue = .dict([
            ("length", .integer(12345)),
            ("name", .string(Data(name.utf8))),
            ("piece length", .integer(262144)),
            ("pieces", .string(pieces)),
        ])

        let root: BencodeValue = .dict([
            ("announce", .string(Data(announce.utf8))),
            ("info", info),
        ])

        let data = BencodeEncoder.encode(root)
        let tf = try TorrentParser.parse(data: data)

        XCTAssertEqual(tf.name, name)
        XCTAssertEqual(tf.files.count, 1)
        XCTAssertEqual(tf.files[0].size, 12345)
        XCTAssertEqual(tf.files[0].path, name)
        XCTAssertEqual(tf.totalSize, 12345)
        XCTAssertEqual(tf.pieceLength, 262144)
        XCTAssertEqual(tf.pieces.count, 1)
        XCTAssertEqual(tf.announce, announce)
        XCTAssertFalse(tf.isPrivate)
        XCTAssertEqual(tf.infoHash.count, 20)
    }

    func testParseMultiFile() throws {
        let announce = "http://tracker.example.com/announce"
        let pieces = Data(repeating: 97, count: 20)

        let file1: BencodeValue = .dict([
            ("length", .integer(100)),
            ("path", .list([.string(Data("file1".utf8))])),
        ])
        let file2: BencodeValue = .dict([
            ("length", .integer(200)),
            ("path", .list([.string(Data("folder".utf8)), .string(Data("file2".utf8))])),
        ])

        let info: BencodeValue = .dict([
            ("files", .list([file1, file2])),
            ("name", .string(Data("test".utf8))),
            ("piece length", .integer(262144)),
            ("pieces", .string(pieces)),
            ("private", .integer(1)),
        ])

        let root: BencodeValue = .dict([
            ("announce", .string(Data(announce.utf8))),
            ("info", info),
        ])

        let data = BencodeEncoder.encode(root)
        let tf = try TorrentParser.parse(data: data)

        XCTAssertEqual(tf.name, "test")
        XCTAssertEqual(tf.files.count, 2)
        XCTAssertEqual(tf.files[0].path, "test/file1")
        XCTAssertEqual(tf.files[0].size, 100)
        XCTAssertEqual(tf.files[1].path, "test/folder/file2")
        XCTAssertEqual(tf.files[1].size, 200)
        XCTAssertEqual(tf.totalSize, 300)
        XCTAssertTrue(tf.isPrivate)
    }

    func testInfoHashStable() throws {
        let info: BencodeValue = .dict([
            ("length", .integer(12345)),
            ("name", .string(Data("test.txt".utf8))),
            ("piece length", .integer(262144)),
            ("pieces", .string(Data(repeating: 97, count: 20))),
        ])

        let root: BencodeValue = .dict([
            ("announce", .string(Data("http://tracker.example.com/announce".utf8))),
            ("info", info),
        ])

        let data = BencodeEncoder.encode(root)
        let a = try TorrentParser.parse(data: data)
        let b = try TorrentParser.parse(data: data)
        XCTAssertEqual(a.infoHash, b.infoHash)
    }
}
