#!/usr/bin/env python3
"""
Canopy Polish 3 — fix rename path, single-line rows, instant expand
Run from: /Users/amm/Canopy-main
"""
import os

BASE = os.path.dirname(os.path.abspath(__file__))

def read(p):
    with open(os.path.join(BASE, p)) as f:
        return f.read()

def write(p, c):
    with open(os.path.join(BASE, p), 'w') as f:
        f.write(c)
    print(f"  ✅ {p}")

print("\n🔧 Canopy Polish 3\n")

# ══════════════════════════════════════════════════════════════════════
# 1. FileTreeViewModel.swift — fix rename to pass full path
# ══════════════════════════════════════════════════════════════════════
write('Sources/ViewModels/FileTreeViewModel.swift', r'''// FileTreeViewModel.swift — builds/sorts the file tree from bridge data

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

    public init(torrent: TorrentStatus) {
        self.torrent = torrent
        refreshFiles()
    }

    public func refresh(torrent: TorrentStatus) {
        self.torrent = torrent
        refreshFiles()
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
        guard let relPath = handle.filePath(at: Int32(idx), size: &size, priority: &priority) else { return nil }
        return URL(fileURLWithPath: torrent.savePath).appendingPathComponent(relPath)
    }

    /// Build the full relative path for a node by walking up its parent chain
    private func fullPath(for node: FileNode) -> String {
        // We need to find this node's path in the tree
        // Since FileNode doesn't have a parent reference, we search the tree
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
            // File rename: pass FULL relative path, not just filename
            // libtorrent's rename_file expects the complete path relative to save dir
            let currentPath = fullPath(for: node)
            let parentDir = (currentPath as NSString).deletingLastPathComponent
            let fullNewPath = parentDir.isEmpty ? newName : parentDir + "/" + newName

            handle.renameFile(fullNewPath, at: Int32(idx))
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
                        // Replace old folder prefix with new folder prefix
                        let relPath = currentPath.replacingOccurrences(of: oldFolderPath, with: newFolderPath)
                        handle.renameFile(relPath, at: Int32(idx))
                    }
                    if let children = n.children {
                        renameAll(children)
                    }
                }
            }

            // Find children of this node
            if let children = node.children {
                for child in children {
                    renameAll([child])
                }
            }
            node.name = newName
        }

        objectWillChange.send()
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

        // If tree is already built, just patch progress — don't rebuild structure
        // This prevents expand/collapse state from being lost
        if treeBuilt {
            patchProgress(roots, progress: progress)
            return
        }

        var infos: [(index: Int, path: String, size: Int64, downloaded: Int64, priority: Int)] = []

        for i in 0..<count {
            var size: Int64 = 0
            var priority: Int32 = 0
            guard let path = handle.filePath(at: Int32(i), size: &size, priority: &priority) else { continue }
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
                // Recompute folder aggregate
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
''')

# ══════════════════════════════════════════════════════════════════════
# 2. FilesTab.swift — single-line rows like qBittorrent, instant expand
# ══════════════════════════════════════════════════════════════════════
write('Sources/Views/FilesTab.swift', r'''// FilesTab.swift — compact live file inspector

import AppKit
import Combine
import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: FileTreeViewModel
    @State private var expanded = false
    @State private var selectedNodeIDs: Set<UUID> = []
    @State private var renamingNodeID: UUID?
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(leafCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    sortItem("Name", ascending: .nameAsc, descending: .nameDesc)
                    sortItem("Size", ascending: .sizeAsc, descending: .sizeDesc)
                    sortItem("Progress", ascending: .progressAsc, descending: .progressDesc)
                    sortItem("Priority", ascending: .priorityAsc, descending: .priorityDesc)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    expanded.toggle()
                    vm.setAllExpanded(expanded)
                } label: {
                    Image(systemName: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Collapse all folders" : "Expand all folders")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(CanopyPalette.surface)
            Divider()
            if vm.roots.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for file metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.roots) { node in
                            FileInspectorRow(
                                node: node,
                                depth: 0,
                                vm: vm,
                                selectedNodeIDs: $selectedNodeIDs,
                                renamingNodeID: $renamingNodeID
                            )
                        }
                    }
                }
            }
        }
        .onReceive(refreshTimer) { _ in vm.refresh() }
    }

    @ViewBuilder
    private func sortItem(
        _ label: String,
        ascending: FileSortOrder,
        descending: FileSortOrder
    ) -> some View {
        Button {
            vm.setSort(vm.sortOrder == ascending ? descending : ascending)
        } label: {
            if vm.sortOrder == ascending {
                Label("\(label) — Ascending", systemImage: "checkmark")
            } else if vm.sortOrder == descending {
                Label("\(label) — Descending", systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var leafCount: Int {
        func count(_ nodes: [FileNode]) -> Int {
            nodes.reduce(0) { partial, node in
                partial + (node.children.map(count) ?? 1)
            }
        }
        return count(vm.roots)
    }
}

private struct FileInspectorRow: View {
    @ObservedObject var node: FileNode
    let depth: Int
    let vm: FileTreeViewModel
    @Binding var selectedNodeIDs: Set<UUID>
    @Binding var renamingNodeID: UUID?
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { selectedNodeIDs.contains(node.id) }
    private var isRenaming: Bool { renamingNodeID == node.id }

    var body: some View {
        // Single-line row — like qBittorrent's QTreeView with uniform row heights
        HStack(spacing: 6) {
            // Indentation
            Color.clear.frame(width: CGFloat(depth) * 16)

            // Expand/collapse chevron
            if node.isFolder {
                Button {
                    node.isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 20)
            }

            // Checkbox
            NativeCheckbox(state: node.checkState) {
                vm.toggleCheck(node)
            }

            // File/folder icon
            Image(systemName: node.isFolder ? "folder.fill" : fileIcon(node.name))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(node.isFolder ? CanopyPalette.warning : Color.secondary)
                .frame(width: 14)

            // Name (with inline rename)
            if isRenaming {
                TextField("Name", text: Binding(
                    get: { node.name },
                    set: { node.name = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
            } else {
                Text(node.name)
                    .font(.caption.weight(node.isFolder ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Progress bar (compact, fixed width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(progressColor)
                    .frame(width: 60 * node.progress)
            }
            .frame(width: 60, height: 4)

            // Progress percentage
            Text(String(format: "%.0f%%", node.progress * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            // Size
            Text(formatBytes(node.size))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            // Priority (files only)
            if !node.isFolder {
                priorityMenu
            } else {
                Color.clear.frame(width: 50)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { handleSelect() }
        .onTapGesture(count: 2) {
            if node.isFolder {
                node.isExpanded.toggle()
            } else {
                if let url = vm.fileURL(for: node) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .contextMenu {
            if !node.isFolder, node.fileIndex != nil {
                Button("Open") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Open in Finder") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Divider()
                Button("Rename") {
                    selectedNodeIDs = [node.id]
                    renamingNodeID = node.id
                    renameFocused = true
                }
            } else if node.isFolder {
                Button("Open in Finder") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Rename") {
                    selectedNodeIDs = [node.id]
                    renamingNodeID = node.id
                    renameFocused = true
                }
            }
        }
        Divider().opacity(0.3)
        if node.isFolder, node.isExpanded, let children = node.children {
            ForEach(children) { child in
                FileInspectorRow(
                    node: child,
                    depth: depth + 1,
                    vm: vm,
                    selectedNodeIDs: $selectedNodeIDs,
                    renamingNodeID: $renamingNodeID
                )
            }
        }
    }

    private func handleSelect() {
        if isRenaming {
            commitRename()
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            if selectedNodeIDs.contains(node.id) {
                selectedNodeIDs.remove(node.id)
            } else {
                selectedNodeIDs.insert(node.id)
            }
        } else {
            selectedNodeIDs = [node.id]
        }
    }

    private var rowBackground: Color {
        if isRenaming { return Color.accentColor.opacity(0.15) }
        if isSelected { return Color.accentColor.opacity(0.20) }
        return Color.clear
    }

    private func commitRename() {
        let newName = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && renamingNodeID != nil {
            vm.renameFile(newName, on: node)
        }
        renamingNodeID = nil
        renameFocused = false
    }

    private func cancelRename() {
        renamingNodeID = nil
        renameFocused = false
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(FilePriority.allCases, id: \.self) { priority in
                Button {
                    vm.setPriority(priority, on: node)
                } label: {
                    if priority == node.priority {
                        Label(priority.label, systemImage: "checkmark")
                    } else {
                        Text(priority.label)
                    }
                }
            }
        } label: {
            Text(node.priority.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 50)
    }

    private var progressColor: Color {
        if node.progress >= 1 { return CanopyPalette.positive }
        if node.progress > 0 { return CanopyPalette.download }
        return Color.secondary.opacity(0.45)
    }
}
''')

print("\n📋 Changes:")
print("  1. Rename: pass FULL relative path to libtorrent (fixes folder/file path)")
print("  2. Rename: folder rename iterates all child files (like qBittorrent doRenameFolder)")
print("  3. Rows: single-line, 24px height (like qBittorrent uniform row heights)")
print("  4. Progress bar: fixed 60px width (not stretching)")
print("  5. Expand: treeBuilt flag prevents rebuild on refresh, only patches progress")
print("  6. Timer: 5 seconds (less interference with expand/collapse)")
print("\nBuild with: swift build")
