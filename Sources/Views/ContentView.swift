// ContentView.swift — root NavigationSplitView

import SwiftUI
import AppKit
import ClibtorrentBridge

struct ContentView: View {
    @StateObject private var vm: TorrentListViewModel
    @State private var showAddSheet  = false
    @State private var showSettings  = false
    let engine: TorrentEngine

    init(engine: TorrentEngine) {
        self.engine = engine
        _vm = StateObject(wrappedValue: TorrentListViewModel(engine: engine))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search torrents\u{2026}", text: $vm.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                if vm.filtered.isEmpty {
                    emptyState
                } else {
                    List(vm.filtered, selection: $vm.selectedTorrentID) { torrent in
                        TorrentRowView(torrent: torrent,
                                       isSelected: vm.selectedTorrentID == torrent.id)
                            .tag(torrent.id)
                            .contextMenu { contextMenu(for: torrent) }
                    }
                    .listStyle(.inset)
                }

                Divider()
                StatusBarView(downloadRate: vm.totalDownloadRate,
                              uploadRate:   vm.totalUploadRate,
                              torrentCount: vm.torrents.count)
            }
            .navigationTitle(vm.selectedFilter.rawValue)
            .toolbar { listToolbar }
            .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        } detail: {
            if let t = vm.selectedTorrent {
                TorrentDetailView(torrent: t, engine: engine)
            } else {
                ContentUnavailableView(
                    "Select a torrent",
                    systemImage: "arrow.down.circle",
                    description: Text("Pick a torrent from the list to see details.")
                )
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTorrentSheet(engine: engine, onNext: { pending, magnetHandle in
                showPreAddWindow(pending: pending, magnetHandle: magnetHandle)
            })
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPreAdd)) { notif in
            guard let pending = notif.object as? PendingTorrent else { return }
            let handle = (notif.userInfo?["handle"] as? LTTorrentHandle) ?? nil
            showPreAddWindow(pending: pending, magnetHandle: handle)
        }
    }

    // MARK: - Pre-add window

    private func showPreAddWindow(pending: PendingTorrent, magnetHandle: LTTorrentHandle?) {
        let holder = PreAddWindowHolder()
        let model  = PreAddViewModel(pending: pending)

        let rootView = PreAddSheet(
            model: model,
            onConfirm: { confirmed in
                if let handle = magnetHandle {
                    engine.commitMagnet(handle: handle,
                                        savePath: confirmed.savePath,
                                        files: confirmed.files)
                } else {
                    engine.confirm(confirmed)
                }
                holder.window?.close()
            },
            onCancel: {
                if let handle = magnetHandle { engine.cancelMagnet(handle: handle) }
                holder.window?.close()
            }
        )

        let hosting = NSHostingController(rootView: rootView)
        let window  = NSWindow(contentViewController: hosting)
        window.title = pending.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]

        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        }

        window.makeKeyAndOrderFront(nil)
        holder.window = window

        // Magnet: when metadata arrives, populate the file list and rebuild the tree
        if pending.isMagnet, let handle = magnetHandle {
            engine.onMetadataReady(for: handle) { [weak model] files in
                guard let model else { return }
                DispatchQueue.main.async {
                    model.pending.files     = files
                    model.pending.totalSize = files.reduce(0) { $0 + $1.size }
                    if !handle.name.isEmpty { model.pending.name = handle.name }
                    model.rebuildTree()          // ← build folder tree from new file list
                    window.title = model.pending.name
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label(vm.searchText.isEmpty ? "No torrents" : "No results",
                  systemImage: vm.searchText.isEmpty ? "tray" : "magnifyingglass")
        } description: {
            Text(vm.searchText.isEmpty
                 ? "Add a torrent or magnet link to get started."
                 : "Try a different search term.")
        } actions: {
            if vm.searchText.isEmpty {
                Button("Add Torrent") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showAddSheet = true } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gear")
            }
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Button("Pause All")  { engine.pauseSession() }
            Button("Resume All") { engine.resumeSession() }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for t: TorrentStatus) -> some View {
        if t.isPaused {
            Button("Resume") { engine.resume(t) }
        } else {
            Button("Pause")  { engine.pause(t) }
        }
        Divider()
        Button("Force Re-check")    { engine.recheck(t) }
        Button("Force Re-announce") { engine.reannounce(t) }
        Divider()
        Menu("Remove") {
            Button("Remove torrent only")                       { engine.remove(t) }
            Button("Remove torrent + data", role: .destructive) { engine.remove(t, deleteFiles: true) }
        }
        Divider()
        Button("Copy Hash") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t.id, forType: .string)
        }
        Button("Open Save Folder") {
            NSWorkspace.shared.open(URL(fileURLWithPath: t.savePath))
        }
    }
}

// MARK: - Window holder

private final class PreAddWindowHolder {
    var window: NSWindow?
}
