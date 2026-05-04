// PreAddViewModel.swift

import Foundation
import SwiftUI

@MainActor
public final class PreAddViewModel: ObservableObject {
    @Published public var pending: PendingTorrent

    // Flat-to-tree conversion. Rebuilt when pending.files changes.
    @Published public private(set) var tree: [FileNode] = []

    // A synthetic root node whose checkState aggregates the whole tree.
    // Not displayed — used only for the select-all header checkbox.
    public private(set) var treeRoot: FileNode?

    public init(pending: PendingTorrent) {
        self.pending = pending
        rebuildTree()
    }

    // MARK: - Tree building
    //
    // PendingFile.path is a relative path like
    //   "Show.S01/Episode01.mkv"
    //   "Show.S01/Episode02.mkv"
    //   "extras/bonus.mp4"
    //   "readme.txt"
    //
    // We split on "/" and build a folder tree, then attach each leaf
    // to its FileNode so priority syncs back to pending.files.

    public func rebuildTree() {
        let root = buildTree(from: pending.files)
        treeRoot = root
        tree = root.children ?? []
    }

    private func buildTree(from files: [PendingFile]) -> FileNode {
        let root = FileNode(name: "__root__", children: [])

        for file in files {
            let components = file.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)

            guard !components.isEmpty else { continue }

            var current = root
            // Walk / create folder nodes for all but the last component
            for folderName in components.dropLast() {
                if let existing = current.children?.first(where: { $0.name == folderName && $0.isFolder }) {
                    current = existing
                } else {
                    let folder = FileNode(name: folderName, children: [])
                    current.children?.append(folder)
                    current.size += file.size   // will be corrected below
                    current = folder
                }
            }

            // Leaf file node
            let leaf = FileNode(
                name:      components.last!,
                size:      file.size,
                fileIndex: file.id,
                priority:  file.priority
            )
            current.children?.append(leaf)
        }

        // Recompute folder sizes bottom-up
        recomputeSizes(root)
        return root
    }

    @discardableResult
    private func recomputeSizes(_ node: FileNode) -> Int64 {
        guard node.isFolder, let children = node.children else { return node.size }
        let total = children.reduce(0) { $0 + recomputeSizes($1) }
        node.size = total
        return total
    }

    // MARK: - Priority sync (tree → flat)
    //
    // After any node.priority change, walk the tree and copy leaf priorities
    // back into pending.files so onConfirm sends correct data to libtorrent.

    public func syncFilePriorities() {
        guard let root = treeRoot else { return }
        var map: [Int: FilePriority] = [:]
        collectLeafPriorities(root, into: &map)
        for i in pending.files.indices {
            if let p = map[pending.files[i].id] {
                pending.files[i].priority = p
            }
        }
    }

    private func collectLeafPriorities(_ node: FileNode, into map: inout [Int: FilePriority]) {
        if let idx = node.fileIndex {
            map[idx] = node.priority
            return
        }
        node.children?.forEach { collectLeafPriorities($0, into: &map) }
    }

    // MARK: - Folder checkbox
    //
    // Setting a folder’s priority recursively sets all leaf descendants.

    public func setFolderPriority(node: FileNode, priority: FilePriority) {
        setAllLeaves(node, priority: priority)
        syncFilePriorities()
    }

    private func setAllLeaves(_ node: FileNode, priority: FilePriority) {
        if node.fileIndex != nil {
            node.priority = priority
            return
        }
        node.children?.forEach { setAllLeaves($0, priority: priority) }
    }

    // MARK: - Select all toggle

    public func toggleAll() {
        let current = treeRoot?.checkState ?? .on
        let newPrio: FilePriority = current == .on ? .dontDownload : .normal
        if let root = treeRoot { setAllLeaves(root, priority: newPrio) }
        syncFilePriorities()
    }

    // MARK: - Sort (re-sorts root children)

    public func sort(by order: FileSortOrder) {
        guard let root = treeRoot else { return }
        sortChildren(of: root, order: order)
        tree = root.children ?? []
    }

    private func sortChildren(of node: FileNode, order: FileSortOrder) {
        guard var children = node.children else { return }
        switch order {
        case .nameAsc:  children.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDesc: children.sort { $0.name.localizedCompare($1.name) == .orderedDescending }
        case .sizeAsc:  children.sort { $0.size < $1.size }
        case .sizeDesc: children.sort { $0.size > $1.size }
        }
        node.children = children
        children.forEach { sortChildren(of: $0, order: order) }
    }
}
