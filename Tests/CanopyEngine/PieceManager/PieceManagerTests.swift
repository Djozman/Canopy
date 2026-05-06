import XCTest
@testable import CanopyEngine

final class PieceManagerTests: XCTestCase {

    func testInitialState() async {
        let pm = PieceManager(
            pieceCount: 10, pieceLength: 262144, totalSize: 2621440,
            expectedHashes: Array(repeating: Data(repeating: 0, count: 20), count: 10)
        )
        let count = await pm.pieceCount
        XCTAssertEqual(count, 10)
        let p = await pm.progress
        XCTAssertEqual(p, 0)
        let done = await pm.isComplete
        XCTAssertFalse(done)
    }

    func testMarkHave() async {
        let pm = PieceManager(
            pieceCount: 2, pieceLength: 100, totalSize: 200,
            expectedHashes: Array(repeating: Data(repeating: 0, count: 20), count: 2)
        )
        await pm.markHave(piece: 0)
        let has = await pm.hasPiece(0)
        XCTAssertTrue(has)
        let p = await pm.progress
        XCTAssertEqual(p, 0.5)
    }

    func testNextNeededPiece() async {
        let pm = PieceManager(
            pieceCount: 3, pieceLength: 100, totalSize: 300,
            expectedHashes: Array(repeating: Data(repeating: 0, count: 20), count: 3)
        )
        let first = await pm.nextNeededPiece()
        XCTAssertEqual(first, 0)
        await pm.markHave(piece: 0)
        let second = await pm.nextNeededPiece()
        XCTAssertEqual(second, 1)
    }

    func testNextBlockRequests() async {
        let pm = PieceManager(
            pieceCount: 1, pieceLength: 50000, totalSize: 50000,
            expectedHashes: [Data(repeating: 0, count: 20)]
        )
        let requests = await pm.nextBlockRequests(for: 0, count: 5)
        // 50000 bytes → ceil(50000/16384) = 4 blocks
        XCTAssertEqual(requests.count, 4)
        // First block: begin=0, length=16384
        XCTAssertEqual(requests[0].begin, 0)
        XCTAssertEqual(requests[0].length, 16384)
        // Last block: partial
        XCTAssertEqual(requests[3].begin, 49152)
        XCTAssertEqual(requests[3].length, 848)  // 50000 - 49152
    }

    func testStoreAndAssemble() async {
        let expectedHash = SHA1.hash(Data(repeating: 0xFF, count: 32768))
        let pm = PieceManager(
            pieceCount: 1, pieceLength: 32768, totalSize: 32768,
            expectedHashes: [expectedHash]
        )
        // Store two 16384-byte blocks
        await pm.storeBlock(piece: 0, begin: 0, data: Data(repeating: 0xFF, count: 16384))
        await pm.storeBlock(piece: 0, begin: 16384, data: Data(repeating: 0xFF, count: 16384))
        // Try assemble
        let assembled = await pm.tryAssemble(piece: 0)
        XCTAssertNotNil(assembled)
        XCTAssertEqual(assembled?.count, 32768)
        let complete = await pm.isComplete
        XCTAssertTrue(complete)
    }

    func testHashMismatchDiscardsBlocks() async {
        let wrongHash = Data(repeating: 0, count: 20)
        let pm = PieceManager(
            pieceCount: 1, pieceLength: 16384, totalSize: 16384,
            expectedHashes: [wrongHash]
        )
        await pm.storeBlock(piece: 0, begin: 0, data: Data(repeating: 0xFF, count: 16384))
        let assembled = await pm.tryAssemble(piece: 0)
        XCTAssertNil(assembled, "Should fail SHA1")
        // Block should be discarded — next requests should re-request it
        let requests = await pm.nextBlockRequests(for: 0)
        XCTAssertEqual(requests.count, 1)
    }

    func testBitfieldRoundTrip() {
        var bf = Bitfield(size: 8)
        XCTAssertFalse(bf.isSet(0))
        bf.set(0)
        XCTAssertTrue(bf.isSet(0))
        XCTAssertEqual(bf.count, 1)
        bf.set(0)
        XCTAssertEqual(bf.count, 1)
    }
}


final class DiskMapperTests: XCTestCase {

    func testSingleFileMapping() {
        let files = [TorrentFile.FileEntry(path: "test.iso", size: 1000000)]
        let mapper = DiskMapper(files: files, pieceLength: 262144)
        let (fileIdx, fileOffset, length) = mapper.map(piece: 0, blockBegin: 0)
        XCTAssertEqual(fileIdx, 0)
        XCTAssertEqual(fileOffset, 0)
        XCTAssertEqual(length, 262144) // block fits within file
    }

    func testMultiFileMapping() {
        let files = [
            TorrentFile.FileEntry(path: "a.txt", size: 1000),
            TorrentFile.FileEntry(path: "b.txt", size: 50000),
        ]
        let mapper = DiskMapper(files: files, pieceLength: 16384)
        // Block within first file — clamped to file boundary
        let (f0, o0, l0) = mapper.map(piece: 0, blockBegin: 0)
        XCTAssertEqual(f0, 0)
        XCTAssertEqual(o0, 0)
        XCTAssertEqual(l0, 1000)  // clamped to first file boundary

        // Block spanning into second file
        let (f1, o1, l1) = mapper.map(piece: 0, blockBegin: 1000)
        XCTAssertEqual(f1, 1)
        XCTAssertEqual(o1, 0)
        XCTAssertEqual(l1, 15384) // 16384 - 1000
    }
}
