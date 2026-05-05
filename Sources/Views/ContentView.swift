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
    // Note: NOT @State. SwiftUI can re-evaluate body before a state write
    // is observable, which would let two showPreAdd notifications both see
    // a nil holder and each create a window. Using a process-wide singleton
    // makes the check reliable across rapid successive calls.
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
        // If a pre-add window already exists, update it in place. This makes
        // a second magnet click reuse the existing window instead of opening
        // a new one. We also bring it to front in case it was hidden.
        if let holder = PreAddCoordinator.shared.holder, let model = holder.model, let window = holder.window, window.isVisible {
            model.pending = pending
            model.rebuildTree()
            if !pending.name.isEmpty { holder.window?.title = pending.name }
            holder.magnetHandle = magnetHandle
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Stale holder (window already closed) — discard so we create fresh.
        if PreAddCoordinator.shared.holder?.window?.isVisible != true {
            PreAddCoordinator.shared.holder = nil
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
                PreAddCoordinator.shared.holder = nil
            },
            onCancel: {
                if let handle = holder.magnetHandle { engine.cancelMagnet(handle: handle) }
                holder.window?.close()
                PreAddCoordinator.shared.holder = nil
            }
        )

        let hosting = NSHostingController(rootView: rootView)
        let window  = NSWindow(contentViewController: hosting)
        window.title = pending.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]

        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        }

        // Clear the singleton if user closes via X / Cmd-W (otherwise we'd
        // be left with a stale holder.window that was already torn down).
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { _ in
            if PreAddCoordinator.shared.holder?.window === window {
                PreAddCoordinator.shared.holder = nil
            }
        }
        holder.closeObserver = observer

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        holder.window = window
        PreAddCoordinator.shared.holder = holder
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

final class PreAddWindowHolder {
    var window: NSWindow?
    var model: PreAddViewModel?
    var magnetHandle: LTTorrentHandle?
    var closeObserver: NSObjectProtocol?
}

/// Process-wide single-instance guard for the pre-add window. Plain stored
/// var on a singleton — set/read are synchronous on the main thread, no
/// SwiftUI re-evaluation latency, no risk of two notifications both seeing
/// nil and each creating a window.
@MainActor
final class PreAddCoordinator {
    static let shared = PreAddCoordinator()
    var holder: PreAddWindowHolder?
    private init() {}
}

// MARK: - Update sheet

private struct UpdateSheet: View {
    @ObservedObject var updater: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            if case .error(let msg) = updater.installState {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48)).foregroundStyle(.red)
                Text("Update Failed")
                    .font(.title2.weight(.semibold))
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Close") { dismiss() }
                    Button("Retry") { updater.resetError() }
                }
            } else if updater.installState == .relaunching {
                ProgressView()
                Text("Relaunching\u{2026}").font(.body)
            } else if updater.installState != .idle {
                ProgressView()
                Text(stateLabel(updater.installState)).font(.body)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(.blue)
                Text("Update Available")
                    .font(.title2.weight(.semibold))
                Text("Canopy \(updater.latestVersion ?? "") is ready to install.")
                    .font(.body).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Later") { dismiss() }.keyboardShortcut(.escape)
                    Button { updater.downloadAndInstall() } label: {
                        Text("Update Now")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(40)
        .frame(width: 400, height: 280)
    }

    private func stateLabel(_ state: UpdateChecker.InstallState) -> String {
        switch state {
        case .idle:        return ""
        case .downloading: return "Downloading\u{2026}"
        case .mounting:    return "Mounting DMG\u{2026}"
        case .copying:     return "Installing\u{2026}"
        case .relaunching: return "Relaunching\u{2026}"
        case .error:       return ""
        }
    }
}
