#!/usr/bin/env python3
"""
Canopy Polish 4 — fix rename revert, fix all delays, match qBittorrent behavior
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

print("\n🔧 Canopy Polish 4 — fix rename revert + delays\n")

# ══════════════════════════════════════════════════════════════════════
# 1. TorrentDetailView.swift — stop refreshing on every totalDone change
#    qBittorrent only refreshes when the torrent changes, not on every poll
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/Views/TorrentDetailView.swift')

# Replace onChange(of: torrent.totalDone) with onChange(of: torrent.id)
c = c.replace(
    '.onChange(of: torrent.totalDone) { \\_, \\_ in fileTreeVM.refresh(torrent: torrent) }',
    '.onChange(of: torrent.id) { \\_, \\_ in fileTreeVM.refresh(torrent: torrent) }'
)

# Also remove the .onAppear refresh in FilesTab case — the VM already builds on init
c = c.replace(
    'case .files: FilesTab(vm: fileTreeVM) .onAppear { fileTreeVM.refresh(torrent: torrent) }',
    'case .files: FilesTab(vm: fileTreeVM)'
)

write('Sources/Views/TorrentDetailView.swift', c)

# ══════════════════════════════════════════════════════════════════════
# 2. FileTreeViewModel.swift — track renames, don't lose them on rebuild
#    qBittorrent keeps m_filePaths internally and never re-reads after rename
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/ViewModels/FileTreeViewModel.swift')

# Add renamedFiles dictionary to track renames
c = c.replace(
    'private var treeBuilt = false',
    'private var treeBuilt = false\n    private var renamedFiles: [Int: String] = [:]\n    private var lastTorrentId: String = ""'
)

# Update refresh(torrent:) to only rebuild when torrent ID changes
c = c.replace(
    '''public func refresh(torrent: TorrentStatus) {
        self.torrent = torrent
        refreshFiles()
    }''',
    '''public func refresh(torrent: TorrentStatus) {
        if torrent.id != lastTorrentId {
            lastTorrentId = torrent.id
            treeBuilt = false
            renamedFiles.removeAll()
        }
        self.torrent = torrent
        refreshFiles()
    }'''
)

# Update buildTree to apply renamed files
c = c.replace(
    '''let result = rootOrder.compactMap { rootDict[$0] }
        for node in result { computeFolderSize(node) }
        return result''',
    '''let result = rootOrder.compactMap { rootDict[$0] }
        // Apply any tracked renames
        applyRenames(to: result)
        for node in result { computeFolderSize(node) }
        return result'''
)

# Add applyRenames method before buildTree
c = c.replace(
    '    private func buildTree(',
    '''    private func applyRenames(to nodes: [FileNode]) {
        for node in nodes {
            if let idx = node.fileIndex, let renamed = renamedFiles[idx] {
                node.name = (renamed as NSString).lastPathComponent
            }
            if let children = node.children {
                applyRenames(to: children)
            }
        }
    }

    private func buildTree('''
)

# Update renameFile to track in renamedFiles dictionary
c = c.replace(
    '''if let idx = node.fileIndex {
            // File rename: pass FULL relative path, not just filename
            // libtorrent's rename_file expects the complete path relative to save dir
            let currentPath = fullPath(for: node)
            let parentDir = (currentPath as NSString).deletingLastPathComponent
            let fullNewPath = parentDir.isEmpty ? newName : parentDir + "/" + newName
            handle.renameFile(fullNewPath, at: Int32(idx))
            node.name = newName''',
    '''if let idx = node.fileIndex {
            let currentPath = fullPath(for: node)
            let parentDir = (currentPath as NSString).deletingLastPathComponent
            let fullNewPath = parentDir.isEmpty ? newName : parentDir + "/" + newName
            handle.renameFile(fullNewPath, at: Int32(idx))
            renamedFiles[idx] = fullNewPath
            node.name = newName'''
)

# Also track folder renames
c = c.replace(
    '''node.name = newName
        }
        objectWillChange.send()''',
    '''node.name = newName
        }
        // Track folder renames for all child files
        if node.isFolder, let children = node.children {
            func trackAll(_ nodes: [FileNode]) {
                for n in nodes {
                    if let idx = n.fileIndex {
                        let currentPath = fullPath(for: n)
                        let newPath = currentPath.replacingOccurrences(of: fullPath(for: node), with: node.name)
                        renamedFiles[idx] = newPath
                    }
                    if let kids = n.children { trackAll(kids) }
                }
            }
            trackAll(children)
        }
        objectWillChange.send()'''
)

write('Sources/ViewModels/FileTreeViewModel.swift', c)

# ══════════════════════════════════════════════════════════════════════
# 3. FilesTab.swift — increase timer to 10s, only progress patch
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/Views/FilesTab.swift')
c = c.replace(
    'private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()',
    'private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()'
)
write('Sources/Views/FilesTab.swift', c)

print("\n📋 Root causes and fixes:")
print("  1. Rename revert: onChange(of: torrent.totalDone) rebuilt tree from libtorrent")
print("     which still had old name (rename_file is async). Fixed: track renames in")
print("     renamedFiles dict, apply them after any rebuild. Like qBittorrent's m_filePaths.")
print("  2. All delays: onChange(of: torrent.totalDone) fired every 2s, causing mass")
print("     @Published updates on every FileNode. Fixed: only refresh on torrent.id change.")
print("  3. Timer reduced to 10s (progress only, no structure rebuild).")
print("\nBuild with: swift build")
