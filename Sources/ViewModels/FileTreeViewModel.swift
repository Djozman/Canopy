// FileTreeViewModel.swift — builds/sorts the file tree from engine data

import Foundation
import CanopyEngine

public enum FileSortOrder {
    case nameAsc, nameDesc, sizeAsc, sizeDesc
}

@MainActor
public final class FileTreeViewModel: ObservableObject {
    @Published public private(set) var roots: [FileNode] = []
    @Published public var sortOrder: FileSortOrder = .nameAsc

    private let engine: CanopyEngine
    private let torrentID: String
    private var torrent: TorrentStatus
    private var treeBuilt = false

    public init(torrent: TorrentStatus, engine: CanopyEngine) {
        self.torrent = torrent
        self.engine = engine
        self.torrentID = torrent.id
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
        let count = engine.fileCount(for: torrentID)
        guard count > 0 else { return }

        let progress = engine.fileProgress(for: torrentID)
        var infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)] = []

        for i in 0..<count {
            guard let info = engine.fileInfos(at: i, for: torrentID) else { continue }
            let down: Int64 = i < progress.count ? progress[i] : 0
            infos.append((i, info.path, info.size, down, info.priority))
        }

        if !treeBuilt {
            roots = buildTree(infos)
            var r = roots
            applySort(&r, order: sortOrder)
            roots = r
            treeBuilt = true
        } else {
            patchTree(&roots, infos: infos)
            for node in roots { computeFolderSize(node) }
        }
    }

    private func patchTree(
        _ nodes: inout [FileNode],
        infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)]
    ) {
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
                node.downloaded = info.downloaded
                if let p = FilePriority(rawValue: info.priority), p != node.priority {
                    node.priority = p
                }
            } else if node.isFolder, var children = node.children {
                patchNodes(&children, byIndex: byIndex)
                node.children = children
            }
        }
    }

    private func refreshProgress() {
        let count = engine.fileCount(for: torrentID)
        guard count > 0 else { return }
        let progress = engine.fileProgress(for: torrentID)

        for i in 0..<count {
            let down: Int64 = i < progress.count ? progress[i] : 0
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
            if let idx = node.fileIndex {
                engine.setFilePriority(priority, at: idx, for: torrentID)
            }
        }
        if priority != .dontDownload {
            engine.resume(torrent)
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
