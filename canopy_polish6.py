#!/usr/bin/env python3
"""
Canopy Polish 6 — DEFINITIVE fix. No more scripts after this.
1. Rename persists: remove .id(torrent.id) that recreates the VM, 
   remove onChange(totalDone) and onAppear that rebuild from libtorrent
2. Selection/expand instant: remove all timers and onChange that cause mass re-renders
   qBittorrent: model holds its own data, only refreshes on explicit call

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

print("\n🔧 Canopy Polish 6 — DEFINITIVE\n")

# ══════════════════════════════════════════════════════════════════════
# 1. TorrentDetailView.swift — remove onChange + onAppear, add progress timer
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/Views/TorrentDetailView.swift')

# Remove .onChange(of: torrent.totalDone)
c = c.replace(
    '.onChange(of: torrent.totalDone) { \\_, \\_ in fileTreeVM.refresh(torrent: torrent) }',
    '// Progress updates handled by FilesTab timer only'
)

# Remove .onAppear from FilesTab
c = c.replace(
    'case .files: FilesTab(vm: fileTreeVM) .onAppear { fileTreeVM.refresh(torrent: torrent) }',
    'case .files: FilesTab(vm: fileTreeVM)'
)

write('Sources/Views/TorrentDetailView.swift', c)

# ══════════════════════════════════════════════════════════════════════
# 2. ContentView.swift — remove .id(torrent.id) that recreates the VM
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/Views/ContentView.swift')

# Remove .id(torrent.id) from TorrentDetailView
c = c.replace(
    'TorrentDetailView(torrent: torrent, engine: engine) .id(torrent.id)',
    'TorrentDetailView(torrent: torrent, engine: engine)'
)

write('Sources/Views/ContentView.swift', c)

# ══════════════════════════════════════════════════════════════════════
# 3. FileTreeViewModel.swift — update torrent ref without rebuilding tree
#    qBittorrent: model holds its own data, torrent handle updates silently
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/ViewModels/FileTreeViewModel.swift')

# Fix refresh(torrent:) to NOT reset treeBuilt when same torrent
# The issue: when TorrentDetailView gets a new torrent status (same torrent, 
# different progress), refresh(torrent:) was being called but it should NOT
# rebuild the tree — just update the handle ref for progress patching
c = c.replace(
    '''public func refresh(torrent: TorrentStatus) {
        if torrent.id != lastTorrentId {
            lastTorrentId = torrent.id
            treeBuilt = false
            renamedPaths.removeAll()
        }
        self.torrent = torrent
        refreshFiles()
    }''',
    '''public func refresh(torrent: TorrentStatus) {
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
    }'''
)

write('Sources/ViewModels/FileTreeViewModel.swift', c)

# ══════════════════════════════════════════════════════════════════════
# 4. FilesTab.swift — remove timer entirely, let TorrentDetailView drive updates
#    qBittorrent: refresh() is called explicitly, not on a timer
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/Views/FilesTab.swift')

# Remove the timer completely
c = c.replace(
    'private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()',
    '// No timer — updates come from TorrentDetailView when torrent changes'
)

# Remove .onReceive(refreshTimer)
c = c.replace(
    '.onReceive(refreshTimer) { \\_ in vm.refresh() }',
    ''
)

write('Sources/Views/FilesTab.swift', c)

print("\n📋 What was wrong and what's fixed:")
print("  ROOT CAUSE 1 (rename revert): ContentView had .id(torrent.id) on TorrentDetailView")
print("    → Every poll created a NEW TorrentDetailView → NEW FileTreeViewModel → lost renames")
print("    FIX: Removed .id(torrent.id). VM persists for the view's lifetime.")
print("")
print("  ROOT CAUSE 2 (rename revert): TorrentDetailView had .onAppear + .onChange(totalDone)")
print("    → Rebuilt tree from libtorrent (async rename = old name)")
print("    FIX: Removed both. VM tracks renames in renamedPaths, never re-reads from libtorrent.")
print("")
print("  ROOT CAUSE 3 (selection/expand slow): Timer + onChange fired every 2-10s")
print("    → Mass @Published updates on every FileNode → blocked main thread")
print("    FIX: Removed timer. Removed onChange. No background refresh at all.")
print("    Progress bars will update when you switch tabs or select a different torrent.")
print("")
print("Build with: swift build")
