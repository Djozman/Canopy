#!/usr/bin/env python3
"""
Canopy Complete Patch — ALL changes in one script.
Run from: /Users/amm/Canopy-main
Usage:    python3 canopy_complete.py
"""
import os, re

BASE = os.path.dirname(os.path.abspath(__file__))

def read(path):
    with open(os.path.join(BASE, path)) as f:
        return f.read()

def write(path, content):
    full = os.path.join(BASE, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w') as f:
        f.write(content)
    print(f"  ✅ {path}")

print("\n🔧 Canopy Complete Patch\n")

# ══════════════════════════════════════════════════════════════════════
# 1. FULL REWRITE: TorrentListViewModel.swift — multi-selection
# ══════════════════════════════════════════════════════════════════════
print("Writing TorrentListViewModel.swift:")
write("Sources/ViewModels/TorrentListViewModel.swift", r'''// TorrentListViewModel.swift

import Combine
import SwiftUI

enum FilterCategory: String, CaseIterable {
    case all = "All"
    case downloading = "Downloading"
    case seeding = "Seeding"
    case paused = "Paused"
    case finished = "Finished"
    case error = "Errored"
}

@MainActor
final class TorrentListViewModel: ObservableObject {
    @Published var torrents: [TorrentStatus] = []

    private var cancellables = Set<AnyCancellable>()

    init(engine: TorrentEngine) {
        engine.$torrents
            .receive(on: RunLoop.main)
            .assign(to: &$torrents)
        engine.startPolling()
    }

    @Published var selectedFilter: FilterCategory = .all
    @Published var searchText: String = ""
    @Published var selectedTorrentIDs: Set<String> = []

    var filtered: [TorrentStatus] {
        let base = torrents.filter { t in
            guard !searchText.isEmpty else { return true }
            return t.name.localizedCaseInsensitiveContains(searchText)
        }
        switch selectedFilter {
        case .all: return base
        case .downloading: return base.filter { !$0.isPaused && ($0.state == .downloading || $0.state == .downloadingMetadata) }
        case .seeding: return base.filter { !$0.isPaused && $0.state == .seeding }
        case .paused: return base.filter { $0.isPaused }
        case .finished: return base.filter { $0.state == .finished || $0.state == .seeding }
        case .error: return base.filter { $0.errorMessage != nil }
        }
    }

    var selectedTorrent: TorrentStatus? {
        guard let id = selectedTorrentIDs.first else { return nil }
        return torrents.first { $0.id == id }
    }

    var selectedTorrents: [TorrentStatus] {
        torrents.filter { selectedTorrentIDs.contains($0.id) }
    }

    var hasSelection: Bool { !selectedTorrentIDs.isEmpty }
    var selectionCount: Int { selectedTorrentIDs.count }

    var totalDownloadRate: Int { torrents.reduce(0) { $0 + $1.downloadRate } }
    var totalUploadRate: Int { torrents.reduce(0) { $0 + $1.uploadRate } }

    func filterCount(_ cat: FilterCategory) -> Int {
        switch cat {
        case .all: return torrents.count
        case .downloading: return torrents.filter { !$0.isPaused && ($0.state == .downloading || $0.state == .downloadingMetadata) }.count
        case .seeding: return torrents.filter { !$0.isPaused && $0.state == .seeding }.count
        case .paused: return torrents.filter { $0.isPaused }.count
        case .finished: return torrents.filter { $0.state == .finished || $0.state == .seeding }.count
        case .error: return torrents.filter { $0.errorMessage != nil }.count
        }
    }
}
''')

# ══════════════════════════════════════════════════════════════════════
# 2. FULL REWRITE: ContentView.swift — multi-select + bottom panel
# ══════════════════════════════════════════════════════════════════════
print("Writing ContentView.swift:")
write("Sources/Views/ContentView.swift", r'''// ContentView.swift — modern minimal transfer workspace

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
    @State private var inspectorHeight: CGFloat = 280
    @State private var dragStartHeight: CGFloat = 280
    @State private var pendingRemovals: [TorrentStatus] = []
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
                Divider().opacity(0.4)
                transferTable
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    resizeDivider
                    inspectorContent
                        .frame(height: inspectorHeight)
                        .animation(nil, value: inspectorHeight)
                }
                Divider().opacity(0.4)
                StatusBarView(
                    downloadRate: vm.totalDownloadRate,
                    uploadRate: vm.totalUploadRate,
                    torrentCount: vm.torrents.count
                )
            }
            .background(CanopyPalette.canvas)
            .toolbar { workspaceToolbar }
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
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
        .sheet(isPresented: $showUpdateSheet) {
            UpdateSheet(updater: updater)
        }
        .confirmationDialog(
            pendingRemovals.count == 1
                ? "Remove \"\(pendingRemovals[0].name)\"?"
                : "Remove \(pendingRemovals.count) torrents?",
            isPresented: Binding(
                get: { !pendingRemovals.isEmpty },
                set: { if !$0 { pendingRemovals = [] } }
            ),
            titleVisibility: .visible
        ) {
            let label = pendingRemovals.count == 1 ? "Torrent" : "Torrents"
            Button("Remove \(label)") {
                engine.removeSelected(pendingRemovals, deleteFiles: false)
                pendingRemovals = []
            }
            Button("Remove \(label) and Data", role: .destructive) {
                engine.removeSelected(pendingRemovals, deleteFiles: true)
                pendingRemovals = []
            }
            Button("Cancel", role: .cancel) {
                pendingRemovals = []
            }
        } message: {
            if pendingRemovals.count == 1 {
                Text("Removing downloaded data cannot be undone.")
            } else {
                Text("Removing \(pendingRemovals.count) torrents. Downloaded data deletion cannot be undone.")
            }
        }
        .onAppear {
            let saved = UserDefaults.standard.double(forKey: "canopyInspectorHeight")
            if saved > 100 { inspectorHeight = saved; dragStartHeight = saved }
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
        .onChange(of: vm.selectedTorrentIDs) { _, newValue in
            if !newValue.isEmpty { showInspector = true }
        }
        .onChange(of: vm.selectedFilter) { _, _ in
            let filteredIDs = Set(vm.filtered.map { $0.id })
            vm.selectedTorrentIDs = vm.selectedTorrentIDs.intersection(filteredIDs)
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

    // MARK: - Smooth resize divider

    private var resizeDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(height: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.set() }
                        else { NSCursor.arrow.set() }
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newHeight = dragStartHeight - value.translation.height
                                let clamped = max(120, min(700, newHeight))
                                var t = Transaction()
                                t.animation = nil
                                withTransaction(t) {
                                    inspectorHeight = clamped
                                }
                            }
                            .onEnded { _ in
                                dragStartHeight = inspectorHeight
                                UserDefaults.standard.set(Double(inspectorHeight), forKey: "canopyInspectorHeight")
                            }
                    )
            }
    }

    // MARK: - Header

    private var workspaceHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.selectedFilter.rawValue)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(vm.filtered.count) of \(vm.torrents.count) torrents")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if vm.hasSelection {
                Text("\(vm.selectionCount) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CanopyPalette.accent, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(CanopyPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(CanopyPalette.border.opacity(0.4), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: vm.hasSelection)
    }

    // MARK: - Transfer table (multi-select)

    private var transferTable: some View {
        Group {
            if vm.filtered.isEmpty {
                emptyState
            } else {
                Table(sortedTorrents, selection: $vm.selectedTorrentIDs, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { torrent in
                        TorrentNameCell(torrent: torrent) {
                            let saveURL = URL(fileURLWithPath: torrent.savePath)
                            if let fileURL = bestFileToOpen(torrent),
                               NSWorkspace.shared.open(fileURL) { return }
                            NSWorkspace.shared.open(saveURL)
                        }
                    }
                    .width(min: 120, ideal: 280, max: 1000)

                    TableColumn("Size", value: \.totalSize) { torrent in
                        Text(formatBytes(torrent.totalSize))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 86, max: 300)

                    TableColumn("Progress", value: \.progress) { torrent in
                        TorrentProgressCell(
                            progress: Double(torrent.progress),
                            color: torrent.statusColor
                        )
                    }
                    .width(min: 80, ideal: 135, max: 400)

                    TableColumn("Status", value: \.sortableStatus) { torrent in
                        TorrentStatusCell(torrent: torrent)
                    }
                    .width(min: 60, ideal: 105, max: 300)

                    TableColumn("Seeds", value: \.numSeeds) { torrent in
                        numericCell(torrent.numSeeds)
                    }
                    .width(min: 36, ideal: 48, max: 150)

                    TableColumn("Peers", value: \.numPeers) { torrent in
                        numericCell(torrent.numPeers)
                    }
                    .width(min: 36, ideal: 48, max: 150)

                    TableColumn("Down", value: \.downloadRate) { torrent in
                        SpeedCell(value: torrent.downloadRate, direction: .download)
                    }
                    .width(min: 60, ideal: 88, max: 250)

                    TableColumn("Up", value: \.uploadRate) { torrent in
                        SpeedCell(value: torrent.uploadRate, direction: .upload)
                    }
                    .width(min: 60, ideal: 88, max: 250)

                    TableColumn("ETA", value: \.etaSeconds) { torrent in
                        Text(formatETA(torrent.etaSeconds))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 40, ideal: 66, max: 150)

                    TableColumn("Ratio", value: \.ratioValue) { torrent in
                        Text(formatRatio(uploaded: torrent.totalUploaded, downloaded: torrent.totalDone))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 40, ideal: 60, max: 150)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu { selectionContextMenu }
                .onDeleteCommand {
                    if vm.hasSelection {
                        pendingRemovals = vm.selectedTorrents
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Inspector content (bottom panel)

    @ViewBuilder
    private var inspectorContent: some View {
        if let torrent = vm.selectedTorrent {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(torrent.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.bar)
                Divider().opacity(0.4)
                TorrentDetailView(torrent: torrent, engine: engine)
                    .id(torrent.id)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No Torrent Selected")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Select a torrent to inspect its activity, files, peers, and trackers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
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

    // MARK: - Pre-add window

    private func showPreAddWindow(
        pending: PendingTorrent,
        magnetHandle: LTTorrentHandle?,
        magnetIndex: Int,
        isStub: Bool
    ) {
        if !isStub, let holder = PreAddCoordinator.shared.windowForIndex(magnetIndex),
           let model = holder.model, let window = holder.window, window.isVisible {
            model.pending = pending
            model.rebuildTree()
            if !pending.name.isEmpty { window.title = pending.name }
            holder.magnetHandle = magnetHandle
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if isStub, magnetIndex == 0, let holder = PreAddCoordinator.shared.singleHolder,
           let model = holder.model, let window = holder.window, window.isVisible {
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
                if let handle = holder.magnetHandle {
                    engine.cancelMagnet(handle: handle)
                }
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
            object: window,
            queue: .main
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
        if magnetIndex == 0 {
            PreAddCoordinator.shared.singleHolder = holder
        }
        PreAddCoordinator.shared.consumeQueuedState(for: magnetIndex)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: vm.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(vm.searchText.isEmpty ? "No Torrents" : "No Results")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            Text(
                vm.searchText.isEmpty
                    ? "Add a torrent file or magnet link to begin."
                    : "Try a different search term or status filter."
            )
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            if vm.searchText.isEmpty {
                Button("Add Torrent\u{2026}") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar (multi-select aware)

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showAddSheet = true } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Add torrent")

            if vm.hasSelection {
                let selected = vm.selectedTorrents
                let anyRunning = selected.contains { !$0.isPaused }

                if anyRunning {
                    Button {
                        engine.pauseSelected(selected.filter { !$0.isPaused })
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause \(selected.filter { !$0.isPaused }.count) torrent(s)")
                } else {
                    Button {
                        engine.resumeSelected(selected)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Resume \(selected.count) torrent(s)")
                }

                Button {
                    pendingRemovals = selected
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove \(selected.count) torrent(s)")
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
                if vm.hasSelection {
                    Button("Force Re-check Selected") {
                        engine.recheckSelected(vm.selectedTorrents)
                    }
                    Button("Force Re-announce Selected") {
                        engine.reannounceSelected(vm.selectedTorrents)
                    }
                    Divider()
                }
                Button("Settings\u{2026}") { showSettings = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }

            if updater.updateAvailable {
                Button { showUpdateSheet = true } label: {
                    Label("Update Available", systemImage: "arrow.down.circle.fill")
                }
                .help("Install update")
            }
        }
    }

    // MARK: - Context menu (multi-select aware)

    @ViewBuilder
    private var selectionContextMenu: some View {
        if vm.selectedTorrents.count > 1 {
            let selected = vm.selectedTorrents
            let anyRunning = selected.contains { !$0.isPaused }
            if anyRunning {
                Button("Pause All Selected") {
                    engine.pauseSelected(selected.filter { !$0.isPaused })
                }
            }
            if selected.contains(where: { $0.isPaused }) {
                Button("Resume All Selected") {
                    engine.resumeSelected(selected.filter { $0.isPaused })
                }
            }
            Divider()
            Button("Force Re-check All") {
                engine.recheckSelected(selected)
            }
            Button("Force Re-announce All") {
                engine.reannounceSelected(selected)
            }
            Divider()
            Button("Reveal in Finder") {
                for torrent in selected {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: torrent.savePath)]
                    )
                }
            }
            Divider()
            Button("Remove \(selected.count) Selected\u{2026}", role: .destructive) {
                pendingRemovals = selected
            }
        } else if let torrent = vm.selectedTorrent {
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
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: torrent.savePath)]
                )
            }
            Button("Copy Info Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(torrent.id, forType: .string)
            }
            Divider()
            Button("Remove\u{2026}", role: .destructive) {
                pendingRemovals = [torrent]
            }
        }
    }
}

// MARK: - Smart open helper

func bestFileToOpen(_ torrent: TorrentStatus) -> URL? {
    let saveURL = URL(fileURLWithPath: torrent.savePath)
    let isComplete = (torrent.state == .finished || torrent.state == .seeding)
    guard isComplete, let handle = torrent.handle, handle.fileCount > 0 else { return nil }
    var outSize: Int64 = 0
    var outPriority: Int32 = 0
    guard let firstPath = handle.filePath(at: 0, size: &outSize, priority: &outPriority) else { return nil }
    if handle.fileCount == 1 {
        return saveURL.appendingPathComponent(firstPath)
    }
    let topLevel = firstPath.split(separator: "/").map(String.init).first ?? ""
    guard !topLevel.isEmpty else { return nil }
    return saveURL.appendingPathComponent(topLevel)
}

// MARK: - Window holder

final class PreAddWindowHolder {
    var window: NSWindow?
    var model: PreAddViewModel?
    var magnetHandle: LTTorrentHandle?
    var magnetIndex: Int = 0
    var closeObserver: NSObjectProtocol?
    deinit {
        if let obs = closeObserver { NotificationCenter.default.removeObserver(obs) }
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

    func windowForIndex(_ index: Int) -> PreAddWindowHolder? { indexedWindows[index] }

    func updateWindow(at index: Int, pending: PendingTorrent, handle: LTTorrentHandle?) {
        guard let holder = indexedWindows[index], let model = holder.model,
              let window = holder.window, window.isVisible else {
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
        case .idle: return ""
        case .downloading: return "Downloading\u{2026}"
        case .mounting: return "Mounting DMG\u{2026}"
        case .copying: return "Installing\u{2026}"
        case .relaunching: return "Relaunching\u{2026}"
        case .error: return ""
        }
    }
}
''')

# ══════════════════════════════════════════════════════════════════════
# 3. FULL REWRITE: SidebarView.swift
# ══════════════════════════════════════════════════════════════════════
print("Writing SidebarView.swift:")
write("Sources/Views/SidebarView.swift", r'''// SidebarView.swift — modern minimal navigation

import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: TorrentListViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Canopy")
                        .font(.system(size: 14, weight: .semibold))
                    Text("BitTorrent client")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            List(selection: $vm.selectedFilter) {
                Section("Transfers") {
                    ForEach(FilterCategory.allCases, id: \.self) { category in
                        Label {
                            HStack(spacing: 8) {
                                Text(category.rawValue)
                                    .font(.system(size: 13))
                                Spacer()
                                let count = vm.filterCount(category)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Color.secondary.opacity(0.12),
                                            in: Capsule()
                                        )
                                }
                            }
                        } icon: {
                            Image(systemName: iconName(for: category))
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 14))
                        }
                        .tag(category)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().opacity(0.4)

            HStack(spacing: 7) {
                Circle()
                    .fill(CanopyPalette.positive)
                    .frame(width: 6, height: 6)
                Text("Session active")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
        .background(.bar)
    }

    private func iconName(for category: FilterCategory) -> String {
        switch category {
        case .all: return "square.stack.3d.up"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "arrow.up.circle"
        case .paused: return "pause.circle"
        case .finished: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}
''')

# ══════════════════════════════════════════════════════════════════════
# 4. FULL REWRITE: StatusBarView.swift
# ══════════════════════════════════════════════════════════════════════
print("Writing StatusBarView.swift:")
write("Sources/Views/StatusBarView.swift", r'''// StatusBarView.swift — modern minimal session summary

import SwiftUI

struct StatusBarView: View {
    let downloadRate: Int
    let uploadRate: Int
    let torrentCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Label(
                "\(torrentCount) torrent\(torrentCount == 1 ? "" : "s")",
                systemImage: "square.stack.3d.up"
            )
            .foregroundStyle(.secondary)
            .font(.system(size: 11).monospacedDigit())

            Spacer()

            metric(icon: "arrow.down", value: downloadRate, color: CanopyPalette.download)
            metric(icon: "arrow.up", value: uploadRate, color: CanopyPalette.upload)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }

    private func metric(icon: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(value > 0 ? color : Color.secondary)
                .font(.system(size: 10))
            Text(formatSpeed(value))
                .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
                .font(.system(size: 11).monospacedDigit())
        }
    }
}
''')

# ══════════════════════════════════════════════════════════════════════
# 5. PATCH: TorrentEngine.swift — add batch ops + file ops
# ══════════════════════════════════════════════════════════════════════
print("Patching TorrentEngine.swift:")
path = "Sources/Engine/TorrentEngine.swift"
c = read(path)
if "pauseSelected" not in c:
    # Find the last closing brace of the class
    last_brace = c.rfind("}")
    insert_at = c.rfind("}", 0, last_brace)
    c = c[:insert_at] + """
    // MARK: - File operations

    public func renameFile(_ newName: String, at index: Int, on torrent: TorrentStatus) {
        guard let handle = torrent.handle else { return }
        DispatchQueue.global(qos: .utility).async {
            handle.renameFile(newName, at: Int32(index))
        }
    }

    public func fileURL(forFileIndex index: Int, in torrent: TorrentStatus) -> URL? {
        guard let handle = torrent.handle else { return nil }
        var size: Int64 = 0
        var priority: Int32 = 0
        guard let relPath = handle.filePath(at: Int32(index), size: &size, priority: &priority) else { return nil }
        return URL(fileURLWithPath: torrent.savePath).appendingPathComponent(relPath)
    }

    // MARK: - Batch operations

    func pauseSelected(_ torrents: [TorrentStatus]) {
        for t in torrents { pause(t) }
    }
    func resumeSelected(_ torrents: [TorrentStatus]) {
        for t in torrents { resume(t) }
    }
    func recheckSelected(_ torrents: [TorrentStatus]) {
        for t in torrents { recheck(t) }
    }
    func reannounceSelected(_ torrents: [TorrentStatus]) {
        for t in torrents { reannounce(t) }
    }
    func removeSelected(_ torrents: [TorrentStatus], deleteFiles: Bool) {
        for t in torrents { remove(t, deleteFiles: deleteFiles) }
    }
""" + c[insert_at:]
    write(path, c)
else:
    print(f"  ⏭️  TorrentEngine.swift (already has batch ops)")

# ══════════════════════════════════════════════════════════════════════
# 6. PATCH: LibtorrentWrapper.h — add renameFile
# ══════════════════════════════════════════════════════════════════════
print("Patching LibtorrentWrapper.h:")
path = "Sources/Engine/Bridge/ObjC/include/LibtorrentWrapper.h"
c = read(path)
if "renameFile" not in c:
    c = c.replace(
        "- (void)setFilePriority:(int)priority atIndex:(int)index;",
        "- (void)setFilePriority:(int)priority atIndex:(int)index;\n- (void)renameFile:(NSString *)newName atIndex:(int)index;",
        1)
    write(path, c)
else:
    print(f"  ⏭️  LibtorrentWrapper.h (already has renameFile)")

# ══════════════════════════════════════════════════════════════════════
# 7. PATCH: LibtorrentWrapper.mm — add renameFile impl
# ══════════════════════════════════════════════════════════════════════
print("Patching LibtorrentWrapper.mm:")
path = "Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm"
c = read(path)
if "renameFile" not in c:
    c = c.replace(
        """- (void)setFilePriority:(int)priority atIndex:(int)index {
    _handle.file_priority(lt::file_index_t{index},
                          lt::download_priority_t{(std::uint8_t)priority});
}""",
        """- (void)setFilePriority:(int)priority atIndex:(int)index {
    _handle.file_priority(lt::file_index_t{index},
                          lt::download_priority_t{(std::uint8_t)priority});
}

- (void)renameFile:(NSString *)newName atIndex:(int)index {
    if (index < 0 || !_handle.is_valid()) return;
    _handle.rename_file(lt::file_index_t{index},
                        std::string(newName.UTF8String));
}""",
        1)
    write(path, c)
else:
    print(f"  ⏭️  LibtorrentWrapper.mm (already has renameFile)")

# ══════════════════════════════════════════════════════════════════════
# 8. PATCH: FileTreeViewModel.swift — add fileURL + renameFile
# ══════════════════════════════════════════════════════════════════════
print("Patching FileTreeViewModel.swift:")
path = "Sources/ViewModels/FileTreeViewModel.swift"
c = read(path)
if "func fileURL(for node" not in c:
    c = c.replace(
        "public func setPriority(_ priority: FilePriority, on node: FileNode) {",
        """public func fileURL(for node: FileNode) -> URL? {
    guard let handle = torrent.handle, let idx = node.fileIndex else { return nil }
    var size: Int64 = 0
    var priority: Int32 = 0
    guard let relPath = handle.filePath(at: Int32(idx), size: &size, priority: &priority) else { return nil }
    return URL(fileURLWithPath: torrent.savePath).appendingPathComponent(relPath)
}

public func renameFile(_ newName: String, on node: FileNode) {
    guard let handle = torrent.handle, let idx = node.fileIndex else { return }
    handle.renameFile(newName, at: Int32(idx))
    node.name = newName
    objectWillChange.send()
}

public func setPriority(_ priority: FilePriority, on node: FileNode) {""",
        1)
    write(path, c)
else:
    print(f"  ⏭️  FileTreeViewModel.swift (already has fileURL)")

# ══════════════════════════════════════════════════════════════════════
# 9. PATCH: FilesTab.swift — add AppKit import + context menu + rename dialog
# ══════════════════════════════════════════════════════════════════════
print("Patching FilesTab.swift:")
path = "Sources/Views/FilesTab.swift"
c = read(path)

# Add AppKit import
if "import AppKit" not in c:
    c = c.replace(
        "import Combine\nimport SwiftUI",
        "import AppKit\nimport Combine\nimport SwiftUI",
        1)

# Add context menu + rename dialog
if ".contextMenu" not in c:
    # Insert context menu before the Divider that follows onTapGesture
    old = """        .onTapGesture(count: 2) {
            guard node.isFolder else { return }
            withAnimation(.easeInOut(duration: 0.14)) {
                node.isExpanded.toggle()
            }
        }
        Divider().opacity(0.35)"""

    new = """        .onTapGesture(count: 2) {
            guard node.isFolder else { return }
            withAnimation(.easeInOut(duration: 0.14)) {
                node.isExpanded.toggle()
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
                Button("Rename\\u{2026}") {
                    showRenameDialog(for: node)
                }
            } else if node.isFolder {
                Button("Open in Finder") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        Divider().opacity(0.35)"""

    c = c.replace(old, new, 1)

    # Add rename dialog method — insert before priorityMenu
    old2 = "    private var priorityMenu: some View {"
    new2 = """    private func showRenameDialog(for node: FileNode) {
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = "Enter a new name for \\\"\\(node.name)\\\""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = node.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != node.name else { return }
            vm.renameFile(newName, on: node)
        }
    }

    private var priorityMenu: some View {"""

    c = c.replace(old2, new2, 1)
    write(path, c)
else:
    print(f"  ⏭️  FilesTab.swift (already has context menu)")

print("\n📋 All changes applied:")
print("  • Multi-selection (Set<String>) + bulk operations")
print("  • Bottom inspector panel with smooth draggable divider")
print("  • Widened column resize ranges")
print("  • Modern minimal sidebar/statusbar")
print("  • File context menu: Open, Open in Finder, Rename")
print("  • Rename via libtorrent rename_file bridge")
print("\nBuild with: swift build && open Canopy.app")
