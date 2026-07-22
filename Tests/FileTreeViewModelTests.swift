// FileTreeViewModelTests.swift

import XCTest
@testable import Canopy

final class FileTreeViewModelTests: XCTestCase {

    func testParentCheckedWhenAllChildrenSelected() {
        let parent = FileNode(name: "Folder", children: [
            FileNode(name: "a.mkv", priority: .normal, children: nil),
            FileNode(name: "b.mkv", priority: .normal, children: nil),
        ])
        XCTAssertEqual(parent.checkState, .on)
    }

    func testParentUncheckedWhenAllChildrenSkipped() {
        let parent = FileNode(name: "Folder", children: [
            FileNode(name: "a.mkv", priority: .dontDownload, children: nil),
            FileNode(name: "b.mkv", priority: .dontDownload, children: nil),
        ])
        XCTAssertEqual(parent.checkState, .off)
    }

    func testParentMixedWhenSomeChildrenSkipped() {
        let parent = FileNode(name: "Folder", children: [
            FileNode(name: "a.mkv", priority: .normal, children: nil),
            FileNode(name: "b.mkv", priority: .dontDownload, children: nil),
        ])
        XCTAssertEqual(parent.checkState, .mixed)
    }

    func testLeafFileIsNotAFolder() {
        let leaf = FileNode(name: "file.mkv", children: nil)
        XCTAssertFalse(leaf.isFolder)
    }

    func testFolderIsAFolder() {
        let folder = FileNode(name: "Folder", children: [])
        XCTAssertTrue(folder.isFolder)
    }

    func testProgressZero() {
        let file = FileNode(name: "f", size: 100, downloaded: 0, children: nil)
        XCTAssertEqual(file.progress, 0)
    }

    func testProgressComplete() {
        let file = FileNode(name: "f", size: 100, downloaded: 100, children: nil)
        XCTAssertEqual(file.progress, 1.0)
    }

    func testProgressIsClampedAboveOne() {
        let file = FileNode(name: "f", size: 100, downloaded: 125, children: nil)
        XCTAssertEqual(file.progress, 1.0)
    }

    func testProgressIsClampedBelowZero() {
        let file = FileNode(name: "f", size: 100, downloaded: -1, children: nil)
        XCTAssertEqual(file.progress, 0)
    }
}
