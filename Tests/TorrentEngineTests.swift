// TorrentEngineTests.swift

import XCTest
import ClibtorrentBridge
@testable import Canopy

final class TorrentEngineTests: XCTestCase {

    private func makeTorrent(
        state: TorrentState,
        isSequential: Bool,
        savePath: String = "/tmp/CanopyTest",
        handle: LTTorrentHandle? = nil
    ) -> TorrentStatus {
        TorrentStatus(
            id: "testhash",
            name: "Test Torrent",
            savePath: savePath,
            totalSize: 1000,
            totalDone: 1000,
            totalUploaded: 0,
            downloadRate: 0,
            uploadRate: 0,
            progress: 1.0,
            numSeeds: 1,
            numPeers: 0,
            etaSeconds: 0,
            state: state,
            isPaused: false,
            errorMessage: nil,
            isSequentialDownload: isSequential,
            handle: handle
        )
    }

    // T002: TorrentStatus stores and exposes isSequentialDownload correctly.
    func testTorrentStatusStoresSequentialDownloadFlag() {
        let disabled = makeTorrent(state: .downloading, isSequential: false)
        XCTAssertFalse(disabled.isSequentialDownload)

        let enabled = makeTorrent(state: .downloading, isSequential: true)
        XCTAssertTrue(enabled.isSequentialDownload)
    }

    // T012: bestFileToOpen returns nil (folder-reveal fallback) for an
    // incomplete torrent, regardless of whether a handle is present.
    func testBestFileToOpenReturnsNilForIncompleteTorrent() {
        let incomplete = makeTorrent(state: .downloading, isSequential: false)
        XCTAssertNil(bestFileToOpen(incomplete))
    }

    // T012: bestFileToOpen returns nil (folder-reveal fallback) for a
    // completed torrent whose single-file handle is unavailable.
    func testBestFileToOpenReturnsNilWithoutSingleFileHandle() {
        let finished = makeTorrent(state: .finished, isSequential: false)
        XCTAssertNil(bestFileToOpen(finished))
    }
}