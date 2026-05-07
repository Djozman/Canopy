import XCTest
@testable import CanopyEngine

final class MetadataDownloaderTests: XCTestCase {

    func testSinglePieceMetadata() async {
        let infoDict = Data((0..<1000).map { UInt8($0 % 256) })
        let infoHash = SHA1.hash(infoDict)
        let downloader = MetadataDownloader(infoHash: infoHash)

        await downloader.receivePiece(index: 0, totalSize: 1000, data: infoDict)
        let complete = await downloader.isComplete
        XCTAssertTrue(complete)
        let assembled = await downloader.assembleAndVerify()
        XCTAssertNotNil(assembled)
        XCTAssertEqual(assembled, infoDict)
    }

    func testMultiPieceOutOfOrder() async {
        let totalData = Data((0..<40000).map { UInt8($0 % 256) })
        let infoHash = SHA1.hash(totalData)
        let downloader = MetadataDownloader(infoHash: infoHash)

        await downloader.receivePiece(index: 2, totalSize: 40000, data: totalData.subdata(in: 32768..<40000))
        await downloader.receivePiece(index: 0, totalSize: 40000, data: totalData.subdata(in: 0..<16384))
        await downloader.receivePiece(index: 1, totalSize: 40000, data: totalData.subdata(in: 16384..<32768))

        let complete = await downloader.isComplete
        XCTAssertTrue(complete)
        let assembled = await downloader.assembleAndVerify()
        XCTAssertEqual(assembled, totalData)
    }

    func testSHA1MismatchResets() async {
        let infoDict = Data((0..<16384).map { UInt8($0 % 256) })
        let wrongHash = Data(repeating: 0x00, count: 20)
        let downloader = MetadataDownloader(infoHash: wrongHash)

        await downloader.receivePiece(index: 0, totalSize: 16384, data: infoDict)
        let complete = await downloader.isComplete
        XCTAssertTrue(complete)
        let assembled = await downloader.assembleAndVerify()
        XCTAssertNil(assembled, "SHA1 mismatch should return nil")
        let stillComplete = await downloader.isComplete
        XCTAssertFalse(stillComplete)
    }

    func testOversizedLastPieceTruncated() async {
        let realData = Data(repeating: 0xAB, count: 1000)
        let infoHash = SHA1.hash(realData)
        let downloader = MetadataDownloader(infoHash: infoHash)

        let oversized = Data(repeating: 0xAB, count: 16000)
        await downloader.receivePiece(index: 0, totalSize: 1000, data: oversized)

        let complete = await downloader.isComplete
        XCTAssertTrue(complete)
        let assembled = await downloader.assembleAndVerify()
        XCTAssertEqual(assembled?.count, 1000)
        XCTAssertEqual(assembled, realData)
    }

    func testNextNeededPiece() async {
        let infoDict = Data(repeating: 0xCC, count: 50000)
        let infoHash = SHA1.hash(infoDict)
        let downloader = MetadataDownloader(infoHash: infoHash)

        let first = await downloader.nextNeededPiece
        XCTAssertEqual(first, nil)

        await downloader.receivePiece(index: 1, totalSize: 50000, data: Data(repeating: 0xCC, count: 16384))
        let np = await downloader.nextNeededPiece
        XCTAssertEqual(np, 0)
        let pc = await downloader.pieceCount
        XCTAssertEqual(pc, 4)

        await downloader.receivePiece(index: 0, totalSize: 50000, data: Data(repeating: 0xCC, count: 16384))
        let np2 = await downloader.nextNeededPiece
        XCTAssertEqual(np2, 2)
    }
}
