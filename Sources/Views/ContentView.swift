// ContentView.swift — qBittorrent-inspired transfer workspace

import AppKit
import ClibtorrentBridge
import SwiftUI

struct ContentView: View {
    @StateObject private var vm: TorrentListViewModel
    @StateObject private var updater = UpdateChecker(owner: "Djozman", repo: "Canopy")
    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var showUpdateSheet = false
    @State private var ctrlClickMonitor: Any?
    let engine: TorrentEngine

    init(engine: TorrentEngine) {
        self.engine = engine
        _vm = StateObject(wrappedValue: TorrentListViewModel(engine: engine))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                listHeader
                Divider()
                VSplitView {
                    VStack(spacing: 0) {
                        TorrentTableHeader()
                        Divider()
                        if vm.filtered.isEmpty {
                            emptyState
                        } else {
                            List(vm.filtered, selection: $vm.selectedTorrentID) { torrent in
                                TorrentRowView(
                                    torrent: torrent,
                                    isSelected: vm.selectedTorrentID == torrent.id
                                )
                                .tag(torrent.id)
                                .contextMenu { contextMenu(for: torrent) }
                            }
                            .listStyle(.inset)
                            .environment(\.defaultMinListRowHeight, 36)
                        }
                    }
                    .frame(minHeight: 260, idealHeight: 410)
                    .background(Color(nsColor: .textBackgroundColor))

                    Group {
                        if let torrent = vm.selectedTorrent {
                            TorrentDetailView(torrent: torrent, engine: engine)
                                .id(torrent.id)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "rectangle.split.3x1")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(.tertiary)
                                Text("Select a torrent").font(.headline)
                                Text("Transfer details, trackers, peers, files, and pieces appear here.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 245, idealHeight: 330)
                }
                Divider()
                StatusBarView(
                    downloadRate: vm.totalDownloadRate,
                    uploadRate: vm.totalUploadRate,
                    torrentCount: vm.torrents.count)
            }
            .toolbar { listToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showAddSheet) {
            AddTorrentSheet(
                engine: engine,
                onNext: { pending, magnetHandle in
                    showPreAddWindow(
                        pending: pending, magnetHandle: magnetHandle,
                        magnetIndex: 0, isStub: true)
                })
        }
        .sheet(isPresented: $showSettings) { SettingsView(engine: engine) }
        .sheet(isPresented: $showUpdateSheet) { UpdateSheet(updater: updater) }
        .onAppear {
            Task { await updater.checkForUpdate() }
            ctrlClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
                event.modifierFlags.contains(.control) ? nil : event
            }
        }
        .onDisappear {
            if let monitor = ctrlClickMonitor as? AnyObject {
                NSEvent.removeMonitor(monitor)
                ctrlClickMonitor = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAddTorrent)) { _ in
            showAddSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPreAdd)) { notification in
            guard let pending = notification.userInfo?["pending"] as? PendingTorrent else { return }
            let handle = notification.userInfo?["handle"] as? LTTorrentHandle
            let index = notification.userInfo?["magnetIndex"] as? Int ?? 0
            showPreAddWindow(
                pending: pending, magnetHandle: handle,
                magnetIndex: index, isStub: true)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.selectedFilter.rawValue).font(.headline)
                Text("\(vm.filtered.count) shown · \(vm.torrents.count) total")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter torrent list", text: $vm.searchText)
                    .textFieldStyle(.plain)
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 270, height: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func showPreAddWindow(
        pending: PendingTorrent, magnetHandle: LTTorrentHandle?,
        magnetIndex: Int, isStub: Bool
    ) {
        // For non-stub (metadata arrived), update the existing window
        if !isStub, let holder = PreAddCoordinator.shared.windowForIndex(magnetIndex),
            let model = holder.model, let window = holder.window, window.isVisible
        {
            model.pending = pending
            model.rebuildTree()
            if !pending.name.isEmpty { window.title = pending.name }
            holder.magnetHandle = magnetHandle
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // For index 0 stubs, reuse the existing single-holder window
        if isStub, magnetIndex == 0,
            let holder = PreAddCoordinator.shared.singleHolder,
            let model = holder.model,
            let window = holder.window,
            window.isVisible
        {
            model.pending = pending
            model.rebuildTree()
            if !pending.name.isEmpty { window.title = pending.name }
            holder.magnetHandle = magnetHandle
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let holder = PreAddWindowHolder()
        holder.magnetIndex = magnetIndex
        let model = PreAddViewModel(pending: pending)
        holder.model = model
        holder.magnetHandle = magnetHandle

        let rootView = PreAddSheet(
            model: model,
            onConfirm: { confirmed in
                if let handle = holder.magnetHandle {
                    engine.commitMagnet(
                        handle: handle,
                        savePath: confirmed.savePath,
                        files: confirmed.files)
                } else {
                    engine.confirm(confirmed)
                }
                holder.window?.close()
            },
            onCancel: {
                if let handle = holder.magnetHandle { engine.cancelMagnet(handle: handle) }
                holder.window?.close()
            }
        )

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = pending.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]

        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        }

        let idx = magnetIndex
        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                PreAddCoordinator.shared.activeWindows.removeAll { $0.window === window }
                if PreAddCoordinator.shared.singleHolder?.window === window {
                    PreAddCoordinator.shared.singleHolder = nil
                }
                PreAddCoordinator.shared.indexedWindows.removeValue(forKey: idx)
            }
        }
        holder.closeObserver = obs

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        holder.window = window
        PreAddCoordinator.shared.activeWindows.append(holder)
        PreAddCoordinator.shared.indexedWindows[magnetIndex] = holder
        if magnetIndex == 0 { PreAddCoordinator.shared.singleHolder = holder }
        PreAddCoordinator.shared.consumeQueuedState(for: magnetIndex)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: vm.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(vm.searchText.isEmpty ? "No torrents" : "No results")
                .font(.title2)
            Text(
                vm.searchText.isEmpty
                    ? "Add a torrent or magnet link to get started."
                    : "Try a different search term."
            )
            .foregroundStyle(.secondary)
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
                Button {
                    showUpdateSheet = true
                } label: {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                }
                .foregroundStyle(.blue)
            }
            Button {
                showAddSheet = true
            } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Button("Pause All") { engine.pauseSession() }
            Button("Resume All") { engine.resumeSession() }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for t: TorrentStatus) -> some View {
        if t.isPaused {
            Button("Resume") { engine.resume(t) }
        } else {
            Button("Pause") { engine.pause(t) }
        }
        Divider()
        Button("Force Re-check") { engine.recheck(t) }
        Button("Force Re-announce") { engine.reannounce(t) }
        Divider()
        Menu("Remove") {
            Button("Remove torrent only") { engine.remove(t) }
            Button("Remove torrent + data", role: .destructive) {
                engine.remove(t, deleteFiles: true)
            }
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
    var magnetIndex: Int = 0
    var closeObserver: NSObjectProtocol?

    deinit {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

@MainActor
final class PreAddCoordinator {
    static let shared = PreAddCoordinator()
    var singleHolder: PreAddWindowHolder?
    var activeWindows: [PreAddWindowHolder] = []
    var indexedWindows: [Int: PreAddWindowHolder] = [:]
    private var queuedUpdates: [Int: (PendingTorrent, LTTorrentHandle?)] = [:]
    private var queuedErrors: [Int: String] = [:]
    private init() {}

    func windowForIndex(_ index: Int) -> PreAddWindowHolder? {
        indexedWindows[index]
    }

    func updateWindow(at index: Int, pending: PendingTorrent, handle: LTTorrentHandle?) {
        guard let holder = indexedWindows[index],
            let model = holder.model,
            let window = holder.window,
            window.isVisible
        else {
            queuedUpdates[index] = (pending, handle)
            return
        }
        model.pending = pending
        model.rebuildTree()
        if !pending.name.isEmpty { window.title = pending.name }
        holder.magnetHandle = handle
    }

    func failWindow(at index: Int, message: String) {
        guard let model = indexedWindows[index]?.model else {
            queuedErrors[index] = message
            return
        }
        model.errorMessage = message
    }

    func consumeQueuedState(for index: Int) {
        if let (pending, handle) = queuedUpdates.removeValue(forKey: index) {
            updateWindow(at: index, pending: pending, handle: handle)
        }
        if let message = queuedErrors.removeValue(forKey: index) {
            failWindow(at: index, message: message)
        }
    }
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
                    Button {
                        updater.downloadAndInstall()
                    } label: {
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
        case .idle: return ""
        case .downloading: return "Downloading\u{2026}"
        case .mounting: return "Mounting DMG\u{2026}"
        case .copying: return "Installing\u{2026}"
        case .relaunching: return "Relaunching\u{2026}"
        case .error: return ""
        }
    }
}
