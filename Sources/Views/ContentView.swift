// ContentView.swift — native macOS transfer workspace

import AppKit
import ClibtorrentBridge
import SwiftUI

struct ContentView: View {
    @StateObject private var vm: TorrentListViewModel
    @StateObject private var updater = UpdateChecker(owner: "Djozman", repo: "Canopy")
    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var showUpdateSheet = false
    @State private var showInspector = true
    @State private var pendingRemoval: TorrentStatus?
    @FocusState private var searchFocused: Bool
    @State private var sortOrder = [KeyPathComparator(\TorrentStatus.name)]

    let engine: TorrentEngine

    init(engine: TorrentEngine) {
        self.engine = engine
        _vm = StateObject(wrappedValue: TorrentListViewModel(engine: engine))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 250)
        } detail: {
            VStack(spacing: 0) {
                workspaceHeader
                Divider()
                transferTable
                Divider()
                StatusBarView(
                    downloadRate: vm.totalDownloadRate,
                    uploadRate: vm.totalUploadRate,
                    torrentCount: vm.torrents.count
                )
            }
            .background(CanopyPalette.canvas)
            .toolbar { workspaceToolbar }
            .inspector(isPresented: $showInspector) {
                inspectorContent
                    .inspectorColumnWidth(min: 340, ideal: 430, max: 600)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_100, minHeight: 680)
        .sheet(isPresented: $showAddSheet) {
            AddTorrentSheet(
                engine: engine,
                onNext: { pending, magnetHandle in
                    showPreAddWindow(
                        pending: pending,
                        magnetHandle: magnetHandle,
                        magnetIndex: 0,
                        isStub: true
                    )
                }
            )
        }
        .sheet(isPresented: $showSettings) { SettingsView(engine: engine) }
        .sheet(isPresented: $showUpdateSheet) { UpdateSheet(updater: updater) }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "torrent")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Torrent") {
                if let torrent = pendingRemoval { engine.remove(torrent) }
                pendingRemoval = nil
            }
            Button("Remove Torrent and Data", role: .destructive) {
                if let torrent = pendingRemoval { engine.remove(torrent, deleteFiles: true) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Removing downloaded data cannot be undone.")
        }
        .onAppear {
            Task { await updater.checkForUpdate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAddTorrent)) { _ in
            showAddSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPreAdd)) { notification in
            guard let pending = notification.userInfo?["pending"] as? PendingTorrent else { return }
            let handle = notification.userInfo?["handle"] as? LTTorrentHandle
            let index = notification.userInfo?["magnetIndex"] as? Int ?? 0
            showPreAddWindow(
                pending: pending,
                magnetHandle: handle,
                magnetIndex: index,
                isStub: true
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTorrentSearch)) { _ in
            searchFocused = true
        }
        .onChange(of: vm.selectedTorrentID) { _, newValue in
            if newValue != nil { showInspector = true }
        }
        .onChange(of: vm.selectedFilter) { _, _ in
            if let selected = vm.selectedTorrentID,
               !vm.filtered.contains(where: { $0.id == selected }) {
                vm.selectedTorrentID = nil
            }
        }
        .onExitCommand {
            if searchFocused || !vm.searchText.isEmpty {
                vm.searchText = ""
                searchFocused = false
            }
        }
    }

    private var sortedTorrents: [TorrentStatus] {
        guard !sortOrder.isEmpty else { return vm.filtered }
        return vm.filtered.sorted(using: sortOrder)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.selectedFilter.rawValue)
                    .font(.headline)
                Text("\(vm.filtered.count) of \(vm.torrents.count) torrents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(CanopyPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(CanopyPalette.border.opacity(0.7), lineWidth: 1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
    }

    private var transferTable: some View {
        Group {
            if vm.filtered.isEmpty {
                emptyState
            } else {
                Table(sortedTorrents, selection: $vm.selectedTorrentID, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { torrent in
                        TorrentNameCell(torrent: torrent) {
                            let saveURL = URL(fileURLWithPath: torrent.savePath)
                            if let fileURL = bestFileToOpen(torrent),
                               NSWorkspace.shared.open(fileURL) {
                                return
                            }
                            NSWorkspace.shared.open(saveURL)
                        }
                    }
                    .width(min: 180, ideal: 280, max: 520)

                    TableColumn("Size", value: \.totalSize) { torrent in
                        Text(formatBytes(torrent.totalSize))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 86, max: 110)

                    TableColumn("Progress", value: \.progress) { torrent in
                        TorrentProgressCell(
                            progress: Double(torrent.progress),
                            color: torrent.statusColor
                        )
                    }
                    .width(min: 110, ideal: 135, max: 180)

                    TableColumn("Status", value: \.sortableStatus) { torrent in
                        TorrentStatusCell(torrent: torrent)
                    }
                    .width(min: 86, ideal: 105, max: 160)

                    TableColumn("Seeds", value: \.numSeeds) { torrent in
                        numericCell(torrent.numSeeds)
                    }
                    .width(48)

                    TableColumn("Peers", value: \.numPeers) { torrent in
                        numericCell(torrent.numPeers)
                    }
                    .width(48)

                    TableColumn("Down", value: \.downloadRate) { torrent in
                        SpeedCell(value: torrent.downloadRate, direction: .download)
                    }
                    .width(min: 72, ideal: 88, max: 110)

                    TableColumn("Up", value: \.uploadRate) { torrent in
                        SpeedCell(value: torrent.uploadRate, direction: .upload)
                    }
                    .width(min: 72, ideal: 88, max: 110)

                    TableColumn("ETA", value: \.etaSeconds) { torrent in
                        Text(formatETA(torrent.etaSeconds))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 52, ideal: 66, max: 90)

                    TableColumn("Ratio", value: \.ratioValue) { torrent in
                        Text(formatRatio(uploaded: torrent.totalUploaded, downloaded: torrent.totalDone))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 48, ideal: 60, max: 80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu { selectedTorrentContextMenu }
                .onDeleteCommand {
                    if let torrent = vm.selectedTorrent { pendingRemoval = torrent }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let torrent = vm.selectedTorrent {
            TorrentDetailView(torrent: torrent, engine: engine)
                .id(torrent.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No Torrent Selected")
                    .font(.headline)
                Text("Select a torrent to inspect its activity, files, peers, and trackers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func numericCell(_ value: Int) -> some View {
        Text("\(value)")
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .trailing)
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

        window.contentMinSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        let frameName = "Canopy.PreAddWindow.\(min(magnetIndex, 3))"
        if !window.setFrameUsingName(frameName) {
            window.setContentSize(NSSize(width: 860, height: 620))
            if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
                let parentFrame = parent.frame
                let frame = window.frame
                window.setFrameOrigin(NSPoint(
                    x: parentFrame.midX - frame.width / 2,
                    y: parentFrame.midY - frame.height / 2
                ))
            } else {
                window.center()
            }
        }
        window.setFrameAutosaveName(frameName)

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


    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: vm.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(vm.searchText.isEmpty ? "No Torrents" : "No Results")
                .font(.title3.weight(.medium))
            Text(
                vm.searchText.isEmpty
                    ? "Add a torrent file or magnet link to begin."
                    : "Try a different search term or status filter."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if vm.searchText.isEmpty {
                Button("Add Torrent…") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Add torrent")

            if let torrent = vm.selectedTorrent {
                Button {
                    torrent.isPaused ? engine.resume(torrent) : engine.pause(torrent)
                } label: {
                    Label(
                        torrent.isPaused ? "Resume" : "Pause",
                        systemImage: torrent.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(torrent.isPaused ? "Resume selected torrent" : "Pause selected torrent")

                Button {
                    pendingRemoval = torrent
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove selected torrent")
            }

            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide inspector" : "Show inspector")

            Menu {
                Button("Pause All") { engine.pauseSession() }
                Button("Resume All") { engine.resumeSession() }
                Divider()
                Button("Settings…") { showSettings = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }

            if updater.updateAvailable {
                Button {
                    showUpdateSheet = true
                } label: {
                    Label("Update Available", systemImage: "arrow.down.circle.fill")
                }
                .help("Install update")
            }
        }
    }

    @ViewBuilder
    private var selectedTorrentContextMenu: some View {
        if let torrent = vm.selectedTorrent {
            if torrent.isPaused {
                Button("Resume") { engine.resume(torrent) }
            } else {
                Button("Pause") { engine.pause(torrent) }
            }
            Divider()
            Button("Force Re-check") { engine.recheck(torrent) }
            Button("Force Re-announce") { engine.reannounce(torrent) }
            Toggle("Download in Order", isOn: Binding(
                get: { torrent.isSequentialDownload },
                set: { engine.setSequentialDownload(torrent, enabled: $0) }
            ))
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: torrent.savePath)
                ])
            }
            Button("Copy Info Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(torrent.id, forType: .string)
            }
            Divider()
            Button("Remove…", role: .destructive) { pendingRemoval = torrent }
        }
    }
}

// MARK: - Smart open helper

/// Returns the download folder URL for a torrent.
func bestFileToOpen(_ torrent: TorrentStatus) -> URL? {
    let saveURL = URL(fileURLWithPath: torrent.savePath)
    // Only completed torrents open a specific file.
    let isComplete = (torrent.state == .finished || torrent.state == .seeding)
    guard isComplete, let handle = torrent.handle, handle.fileCount == 1 else {
        return nil
    }
    var outSize: Int64 = 0
    var outPriority: Int32 = 0
    let filePath = handle.filePath(at: 0, size: &outSize, priority: &outPriority)
    return filePath.map { saveURL.appendingPathComponent($0) }
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
