// FileTreeViewModel.swift — builds/sorts the file tree from bridge data

import ClibtorrentBridge
import Foundation

public enum FileSortOrder: Equatable {
    case nameAsc, nameDesc, sizeAsc, sizeDesc
    case progressAsc, progressDesc, priorityAsc, priorityDesc
}

@MainActor
public final class FileTreeViewModel: ObservableObject {
    @Published public private(set) var roots: [FileNode] = []
    @Published public var sortOrder: FileSortOrder = .nameAsc
    private var torrent: TorrentStatus
    private var treeBuilt = false
    /// Tracks renamed file paths by file index. Like qBittorrent's m_filePaths.
    /// We never re-read names from libtorrent after a rename.
    private var renamedPaths: [Int: String] = [:]
    private var lastTorrentId: String = ""

    public init(torrent: TorrentStatus) {
        self.torrent = torrent
        self.lastTorrentId = torrent.id
        refreshFiles()
    }

    public func refresh(torrent: TorrentStatus) {
        let isSameTorrent = torrent.id == lastTorrentId
        if !isSameTorrent {
            lastTorrentId = torrent.id
            treeBuilt = false
            renamedPaths.removeAll()
        }
        // Always update the torrent ref (for fresh handle), but only
        // rebuild the tree structure if it's a different torrent
        self.torrent = torrent
        if isSameTorrent {
            // Same torrent: just patch progress, preserve tree + renames
            if treeBuilt {
                refreshFiles()
            }
        } else {
            refreshFiles()
        }
    }

    public func refresh() {
        refreshFiles()
    }

    public func setSort(_ order: FileSortOrder) {
        sortOrder = order
        var r = roots
        applySort(&r, order: order)
        roots = r
    }

    public func setAllExpanded(_ expanded: Bool) {
        func update(_ nodes: [FileNode]) {
            for node in nodes where node.isFolder {
                node.isExpanded = expanded
                if let children = node.children { update(children) }
            }
        }
        update(roots)
    }

    public func toggleCheck(_ node: FileNode) {
        let newPriority: FilePriority = node.checkState == .off ? .normal : .dontDownload
        applyPriority(newPriority, to: node)
        objectWillChange.send()
    }

    public func fileURL(for node: FileNode) -> URL? {
        guard let handle = torrent.handle, let idx = node.fileIndex else { return nil }
        var size: Int64 = 0
        var priority: Int32 = 0
        // Use tracked rename if available, otherwise read from libtorrent
        let relPath: String
        if let renamed = renamedPaths[idx] {
            relPath = renamed
        } else {
            guard let path = handle.filePath(at: Int32(idx), size: &size, priority: &priority) else { return nil }
            relPath = path
        }
        return URL(fileURLWithPath: torrent.savePath).appendingPathComponent(relPath)
    }

    /// Build the full relative path for a node by walking the tree
    private func fullPath(for node: FileNode) -> String {
        func findPath(_ nodes: [FileNode], target: FileNode, prefix: String) -> String? {
            for n in nodes {
                let currentPath = prefix.isEmpty ? n.name : prefix + "/" + n.name
                if n.id == target.id { return currentPath }
                if let children = n.children {
                    if let found = findPath(children, target: target, prefix: currentPath) {
                        return found
                    }
                }
            }
            return nil
        }
        return findPath(roots, target: node, prefix: "") ?? node.name
    }

    public func renameFile(_ newName: String, on node: FileNode) {
        guard let handle = torrent.handle else { return }

        if let idx = node.fileIndex {
            // File rename: pass FULL relative path to libtorrent
            let currentPath = fullPath(for: node)
            let parentDir = (currentPath as NSString).deletingLastPathComponent
            let fullNewPath = parentDir.isEmpty ? newName : parentDir + "/" + newName
            handle.renameFile(fullNewPath, at: Int32(idx))
            // Track the rename so we never re-read the old name from libtorrent
            renamedPaths[idx] = fullNewPath
            node.name = newName
        } else if node.isFolder {
            // Folder rename: rename every file inside this folder
            let oldFolderPath = fullPath(for: node)
            let parentDir = (oldFolderPath as NSString).deletingLastPathComponent
            let newFolderPath = parentDir.isEmpty ? newName : parentDir + "/" + newName

            func renameAll(_ nodes: [FileNode]) {
                for n in nodes {
                    if let idx = n.fileIndex {
                        let currentPath = fullPath(for: n)
                        let relPath = currentPath.replacingOccurrences(of: oldFolderPath, with: newFolderPath)
                        handle.renameFile(relPath, at: Int32(idx))
                        renamedPaths[idx] = relPath
                    }
                    if let children = n.children {
                        renameAll(children)
                    }
                }
            }
            if let children = node.children {
                renameAll(children)
            }
            node.name = newName
        }

        objectWillChange.send()
    }

    private func applyPriority(_ priority: FilePriority, to node: FileNode) {
        node.priority = priority
        guard let handle = torrent.handle, let idx = node.fileIndex else { return }
        handle.setFilePriority(Int32(priority.rawValue), at: Int32(idx))
        if let children = node.children {
            for child in children {
                applyPriority(priority, to: child)
            }
        }
    }

    public func setPriority(_ priority: FilePriority, on node: FileNode) {
        applyPriority(priority, to: node)
        objectWillChange.send()
    }

    // MARK: - Private

    private func refreshFiles() {
        guard let handle = torrent.handle else { return }
        let count = Int(handle.fileCount)
        guard count > 0 else { return }

        let progress = handle.fileProgressAll() as [AnyObject]

        // If tree is already built, just patch progress — don't rebuild
        if treeBuilt {
            patchProgress(roots, progress: progress)
            return
        }

        var infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)] = []

        for i in 0..<count {
            var size: Int64 = 0
            var priority: Int32 = 0
            // Use tracked rename if available
            let path: String
            if let renamed = renamedPaths[i] {
                path = renamed
            } else {
                guard let p = handle.filePath(at: Int32(i), size: &size, priority: &priority) else { continue }
                path = p
            }
            let downloaded = i < progress.count ? Int64(progress[i].int64Value) : 0
            infos.append((index: i, path: path, size: size, downloaded: downloaded, priority: Int(priority)))
        }

        let newRoots = buildTree(from: infos)
        roots = newRoots
        treeBuilt = true
    }

    /// Patch progress values in-place without rebuilding tree structure
    private func patchProgress(_ nodes: [FileNode], progress: [AnyObject]) {
        for node in nodes {
            if let idx = node.fileIndex, idx < progress.count {
                node.downloaded = Int64(progress[idx].int64Value)
            }
            if let children = node.children {
                patchProgress(children, progress: progress)
                var totalSize: Int64 = 0
                var totalDone: Int64 = 0
                for child in children {
                    totalSize += child.size
                    totalDone += child.downloaded
                }
                node.size = totalSize
                node.downloaded = totalDone
            }
        }
    }

    private func buildTree(from infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)]) -> [FileNode] {
        var rootDict: [String: FileNode] = [:]
        var rootOrder: [String] = []

        for info in infos {
            var comps = info.path.split(separator: "/").map(String.init)
            let fileName = comps.removeLast()
            let leaf = FileNode(
                name: fileName,
                size: info.size,
                downloaded: info.downloaded,
                fileIndex: info.index,
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
        node.size = totalSize
        node.downloaded = totalDone
        return (totalSize, totalDone)
    }

    // MARK: - Sorting

    private func applySort(_ nodes: inout [FileNode], order: FileSortOrder) {
        nodes.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch order {
            case .nameAsc: return a.name.localizedCompare(b.name) == .orderedAscending
            case .nameDesc: return a.name.localizedCompare(b.name) == .orderedDescending
            case .sizeAsc: return a.size < b.size
            case .sizeDesc: return a.size > b.size
            case .progressAsc: return a.progress < b.progress
            case .progressDesc: return a.progress > b.progress
            case .priorityAsc: return a.priority.rawValue < b.priority.rawValue
            case .priorityDesc: return a.priority.rawValue > b.priority.rawValue
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
