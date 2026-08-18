// PreAddRenameTests.swift

import XCTest
@testable import Canopy

@MainActor
final class PreAddRenameTests: XCTestCase {

    private func makeMultiFilePending() -> PendingTorrent {
        PendingTorrent(
            source: .file(path: "/tmp/show.torrent"),
            name: "Show",
            totalSize: 60,
            savePath: "/tmp",
            files: [
                PendingFile(id: 0, path: "Show/Season1/Ep01.mkv", size: 20),
                PendingFile(id: 1, path: "Show/Season1/Ep02.mkv", size: 20),
                PendingFile(id: 2, path: "Show/extras/bonus.mp4", size: 20),
            ]
        )
    }

    // T007: renaming the root folder rewrites the top-level path component
    // of every contained file.
    func testRenameRootFolderCascadesToAllFiles() {
        let model = PreAddViewModel(pending: makeMultiFilePending())
        guard let root = model.tree.first(where: { $0.isFolder }) else {
            return XCTFail("expected a root folder")
        }

        let result = model.rename(node: root, to: "NewName")
        XCTAssertNil(result)

        let paths = Set(model.pending.files.map(\.path))
        XCTAssertTrue(paths.contains("NewName/Season1/Ep01.mkv"))
        XCTAssertTrue(paths.contains("NewName/Season1/Ep02.mkv"))
        XCTAssertTrue(paths.contains("NewName/extras/bonus.mp4"))
    }

    // T008: a single-file torrent is treated as single-file (no root-folder
    // rename); isSingleFile is exposed to hide the root-folder control.
    func testSingleFileTorrentIsSingleFile() {
        let pending = PendingTorrent(
            source: .file(path: "/tmp/movie.torrent"),
            name: "movie",
            totalSize: 10,
            savePath: "/tmp",
            files: [PendingFile(id: 0, path: "movie.mkv", size: 10)]
        )
        let model = PreAddViewModel(pending: pending)
        XCTAssertTrue(model.isSingleFile)
    }

    // T012: renaming a subfolder rewrites the corresponding path component
    // for all descendant files.
    func testRenameSubfolderCascadesToDescendants() {
        let model = PreAddViewModel(pending: makeMultiFilePending())
        guard let root = model.tree.first(where: { $0.isFolder }) else {
            return XCTFail("expected a root folder")
        }
        guard let season = root.children?.first(where: { $0.isFolder && $0.name == "Season1" }) else {
            return XCTFail("expected Season1 subfolder")
        }

        let result = model.rename(node: season, to: "S01")
        XCTAssertNil(result)

        let paths = Set(model.pending.files.map(\.path))
        XCTAssertTrue(paths.contains("Show/S01/Ep01.mkv"))
        XCTAssertTrue(paths.contains("Show/S01/Ep02.mkv"))
        XCTAssertTrue(paths.contains("Show/extras/bonus.mp4"))
    }

    // T015: renaming a file updates only the leaf node's path (last component).
    func testRenameFileUpdatesOnlyThatLeaf() {
        let model = PreAddViewModel(pending: makeMultiFilePending())
        guard let root = model.tree.first(where: { $0.isFolder }) else {
            return XCTFail("expected a root folder")
        }
        var target: FileNode?
        func findFile(_ n: FileNode) {
            if target != nil { return }
            if let idx = n.fileIndex, idx == 0 { target = n; return }
            n.children?.forEach(findFile)
        }
        findFile(root)
        guard let file = target else { return XCTFail("expected Ep01.mkv leaf") }

        let result = model.rename(node: file, to: "Episode01.mkv")
        XCTAssertNil(result)

        let paths = Set(model.pending.files.map(\.path))
        XCTAssertTrue(paths.contains("Show/Season1/Episode01.mkv"))
        XCTAssertTrue(paths.contains("Show/Season1/Ep02.mkv"))
        XCTAssertTrue(paths.contains("Show/extras/bonus.mp4"))
    }

    // T018: renames preserve file priorities.
    func testRenamePreservesPriorities() {
        var pending = makeMultiFilePending()
        pending.files[0].priority = .high
        pending.files[1].priority = .dontDownload

        let model = PreAddViewModel(pending: pending)
        model.syncFilePriorities()
        guard let root = model.tree.first(where: { $0.isFolder }) else {
            return XCTFail("expected a root folder")
        }
        _ = model.rename(node: root, to: "Renamed")

        let byPath = Dictionary(uniqueKeysWithValues: model.pending.files.map { ($0.path, $0.priority) })
        XCTAssertEqual(byPath["Renamed/Season1/Ep01.mkv"], .high)
        XCTAssertEqual(byPath["Renamed/Season1/Ep02.mkv"], .dontDownload)
    }

    // FR-007: empty, illegal-character, and duplicate-sibling names are rejected.
    func testRenameValidationRejectsInvalidNames() {
        let model = PreAddViewModel(pending: makeMultiFilePending())
        guard let root = model.tree.first(where: { $0.isFolder }) else {
            return XCTFail("expected a root folder")
        }
        guard let season = root.children?.first(where: { $0.isFolder && $0.name == "Season1" }) else {
            return XCTFail("expected Season1")
        }

        XCTAssertEqual(model.rename(node: season, to: "   "), .empty)
        XCTAssertEqual(model.rename(node: season, to: "bad/name"), .illegalCharacter("/"))

        // Duplicate sibling: rename Ep01.mkv to Ep02.mkv (same parent, same type).
        var ep01: FileNode?
        func findFile(_ n: FileNode) {
            if ep01 != nil { return }
            if let idx = n.fileIndex, idx == 0 { ep01 = n; return }
            n.children?.forEach(findFile)
        }
        findFile(season)
        XCTAssertEqual(model.rename(node: ep01!, to: "Ep02.mkv"), .duplicateSibling)
    }
}