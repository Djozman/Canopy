// ContentView.swift — root NavigationSplitView

import SwiftUI
import AppKit
import ClibtorrentBridge

struct ContentView: View {
    @StateObject private var vm: TorrentListViewModel
    @StateObject private var updater = UpdateChecker(owner: "Djozman", repo: "Canopy")
    @State private var showAddSheet  = false
    @State private var showSettings  = false
    @State private var showUpdateSheet = false
    @State private var currentPreAddHolder: PreAddWindowHolder?
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
        .sheet(isPresented: $showUpdateSheet) {
            UpdateSheet(updater: updater)
        }
        .onAppear {
            Task { await updater.checkForUpdate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPreAdd)) { notif in
            guard let pending = notif.userInfo?["pending"] as? PendingTorrent else { return }
            let handle = (notif.userInfo?["handle"] as? LTTorrentHandle) ?? nil
            showPreAddWindow(pending: pending, magnetHandle: handle)
        }
    }

    // MARK: - Pre-add window

    private func showPreAddWindow(pending: PendingTorrent, magnetHandle: LTTorrentHandle?) {
        // If window already exists, update model in-place
        if let holder = currentPreAddHolder, let model = holder.model {
            model.pending = pending
            model.rebuildTree()
            if !pending.name.isEmpty { holder.window?.title = pending.name }
            holder.magnetHandle = magnetHandle
            return
        }

        let holder = PreAddWindowHolder()
        let model  = PreAddViewModel(pending: pending)
        holder.model = model
        holder.magnetHandle = magnetHandle

        let rootView = PreAddSheet(
            model: model,
            onConfirm: { confirmed in
                if let handle = holder.magnetHandle {
                    engine.commitMagnet(handle: handle,
                                        savePath: confirmed.savePath,
                                        files: confirmed.files)
                } else {
                    engine.confirm(confirmed)
                }
                holder.window?.close()
                currentPreAddHolder = nil
            },
            onCancel: {
                if let handle = holder.magnetHandle { engine.cancelMagnet(handle: handle) }
                holder.window?.close()
                currentPreAddHolder = nil
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
        NSApp.activate(ignoringOtherApps: true)
        holder.window = window
        currentPreAddHolder = holder
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
            if updater.updateAvailable {
                Button { showUpdateSheet = true } label: {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                }
                .foregroundStyle(.blue)
            }
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
    var model: PreAddViewModel?
    var magnetHandle: LTTorrentHandle?
}

// MARK: - Update sheet

private struct UpdateSheet: View {
    @ObservedObject var updater: UpdateChecker
    @Environment(\.dismiss) private var dismiss
    @State private var isDownloading = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Update Available")
                .font(.title2.weight(.semibold))
            Text("Canopy \(updater.latestVersion ?? "") is ready to install.\nYour current version will be replaced.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Later") { dismiss() }
                    .keyboardShortcut(.escape)
                Button {
                    isDownloading = true
                    updater.downloadAndInstall()
                } label: {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    }
                    Text("Update Now")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
            }
        }
        .padding(40)
        .frame(width: 400, height: 280)
    }
}
