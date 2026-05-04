// FileTreeViewModel.swift — builds/sorts the file tree from bridge data

import Foundation
import ClibtorrentBridge

public enum FileSortOrder {
    case nameAsc, nameDesc, sizeAsc, sizeDesc
}

@MainActor
public final class FileTreeViewModel: ObservableObject {
    @Published public private(set) var roots: [FileNode] = []
    @Published public var sortOrder: FileSortOrder = .nameAsc

    private var torrent: TorrentStatus
    /// Whether the tree has been built at least once. On first build we
    /// replace roots entirely; on subsequent refreshes we patch in-place
    /// so user-toggled isExpanded states are preserved.
    private var treeBuilt = false

    public init(torrent: TorrentStatus) {
        self.torrent = torrent
        refreshFiles()
    }

    public func refresh(torrent: TorrentStatus) {
        self.torrent = torrent
        if roots.isEmpty {
            refreshFiles()
        } else {
            refreshProgress()
        }
    }

    public func setSort(_ order: FileSortOrder) {
        sortOrder = order
        var r = roots
        applySort(&r, order: order)
        roots = r
    }

    public func toggleCheck(_ node: FileNode) {
        let newPriority: FilePriority = node.checkState == .off ? .normal : .dontDownload
        applyPriority(newPriority, to: node)
    }

    public func setPriority(_ priority: FilePriority, on node: FileNode) {
        applyPriority(priority, to: node)
    }

    // MARK: - Private

    private func refreshFiles() {
        guard let handle = torrent.handle else { return }
        let count = Int(handle.fileCount)
        guard count > 0 else { return }

        let progress = handle.fileProgressAll() as [AnyObject]
        var infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)] = []

        for i in 0..<count {
            var outSize: Int64 = 0
            var outPriority: Int32 = 0
            guard let path = handle.filePath(at: Int32(i), size: &outSize, priority: &outPriority) else { continue }
            let down: Int64 = i < progress.count ? (progress[i] as! NSNumber).int64Value : 0
            infos.append((i, path, outSize, down, Int(outPriority)))
        }

        if !treeBuilt {
            // First build: create all nodes fresh
            roots = buildTree(infos)
            var r = roots
            applySort(&r, order: sortOrder)
            roots = r
            treeBuilt = true
        } else {
            // Subsequent refreshes: patch existing nodes in-place so
            // isExpanded / user interactions survive the timer tick.
            patchTree(&roots, infos: infos)
            // Re-compute folder sizes without replacing nodes
            for node in roots { computeFolderSize(node) }
        }
    }

    /// Walk the existing tree and update mutable data (progress, priority).
    /// Nodes are matched by fileIndex for leaves and by name for folders.
    /// We never replace a node object — only mutate its properties.
    private func patchTree(
        _ nodes: inout [FileNode],
        infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)]
    ) {
        // Build a flat index -> info map for O(1) lookup
        var byIndex: [Int: (size: Int64, downloaded: Int64, priority: Int)] = [:]
        for info in infos {
            byIndex[info.index] = (info.size, info.downloaded, info.priority)
        }
        patchNodes(&nodes, byIndex: byIndex)
    }

    private func patchNodes(
        _ nodes: inout [FileNode],
        byIndex: [Int: (size: Int64, downloaded: Int64, priority: Int)]
    ) {
        for node in nodes {
            if let idx = node.fileIndex, let info = byIndex[idx] {
                // Leaf: update live data only, never touch isExpanded
                node.downloaded = info.downloaded
                // Only sync priority if libtorrent disagrees (e.g. after re-check)
                if let p = FilePriority(rawValue: info.priority), p != node.priority {
                    node.priority = p
                }
            } else if node.isFolder, var children = node.children {
                // Folder: recurse, keep the same node object
                patchNodes(&children, byIndex: byIndex)
                node.children = children
            }
        }
    }

    private func refreshProgress() {
        guard let handle = torrent.handle else { return }
        let count = Int(handle.fileCount)
        guard count > 0 else { return }
        let progress = handle.fileProgressAll() as [AnyObject]

        for i in 0..<count {
            let down: Int64 = i < progress.count ? (progress[i] as! NSNumber).int64Value : 0
            patchProgress(nodes: roots, fileIndex: i, downloaded: down)
        }
        for node in roots { computeFolderSize(node) }
    }

    private func patchProgress(nodes: [FileNode], fileIndex: Int, downloaded: Int64) {
        for n in nodes {
            if let children = n.children {
                patchProgress(nodes: children, fileIndex: fileIndex, downloaded: downloaded)
            } else if n.fileIndex == fileIndex {
                n.downloaded = downloaded
                return
            }
        }
    }

    private func applyPriority(_ priority: FilePriority, to node: FileNode) {
        if let children = node.children {
            for child in children { applyPriority(priority, to: child) }
        } else {
            node.priority = priority
            if let idx = node.fileIndex, let handle = torrent.handle {
                handle.setFilePriority(Int32(priority.rawValue), at: Int32(idx))
            }
        }

        if priority != .dontDownload, let handle = torrent.handle {
            handle.resume()
        }
    }

    private func buildTree(
        _ infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)]
    ) -> [FileNode] {
        var rootDict:  [String: FileNode] = [:]
        var rootOrder: [String] = []

        for info in infos {
            var comps = info.path.split(separator: "/").map(String.init)
            let fileName = comps.removeLast()

            let leaf = FileNode(name: fileName, size: info.size,
                                downloaded: info.downloaded, fileIndex: info.index,
                                priority: FilePriority(rawValue: info.priority) ?? .normal,
                                children: nil)

            if comps.isEmpty {
                let key = fileName
                if rootDict[key] == nil { rootOrder.append(key) }
                rootDict[key] = leaf
            } else {
                let top = comps[0]
                if rootDict[top] == nil {
                    rootDict[top] = FileNode(name: top, children: [])
                    rootOrder.append(top)
                }
                insert(leaf, pathComponents: Array(comps.dropFirst()), into: rootDict[top]!)
            }
        }

        let result = rootOrder.compactMap { rootDict[$0] }
        for node in result { computeFolderSize(node) }
        return result
    }

    private func insert(_ leaf: FileNode, pathComponents: [String], into folder: FileNode) {
        if pathComponents.isEmpty {
            folder.children?.append(leaf)
            return
        }
        let next = pathComponents[0]
        if let existing = folder.children?.first(where: { $0.name == next && $0.isFolder }) {
            insert(leaf, pathComponents: Array(pathComponents.dropFirst()), into: existing)
        } else {
            let sub = FileNode(name: next, children: [])
            folder.children?.append(sub)
            insert(leaf, pathComponents: Array(pathComponents.dropFirst()), into: sub)
        }
    }

    @discardableResult
    private func computeFolderSize(_ node: FileNode) -> (Int64, Int64) {
        guard let children = node.children else { return (node.size, node.downloaded) }
        var totalSize: Int64 = 0
        var totalDone: Int64 = 0
        for child in children {
            let s = computeFolderSize(child)
            totalSize += s.0
            totalDone += s.1
        }
        node.size       = totalSize
        node.downloaded = totalDone
        return (totalSize, totalDone)
    }

    private func applySort(_ nodes: inout [FileNode], order: FileSortOrder) {
        nodes.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch order {
            case .nameAsc:  return a.name.localizedCompare(b.name) == .orderedAscending
            case .nameDesc: return a.name.localizedCompare(b.name) == .orderedDescending
            case .sizeAsc:  return a.size < b.size
            case .sizeDesc: return a.size > b.size
            }
        }
        for i in nodes.indices {
            if var children = nodes[i].children {
                applySort(&children, order: order)
                nodes[i].children = children
            }
        }
    }
}
