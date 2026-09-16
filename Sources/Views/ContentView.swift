// ContentView.swift — modern minimal transfer workspace

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
        ResizeDividerView(height: $inspectorHeight, startHeight: $dragStartHeight)
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

// MARK: - Native resize divider (bypasses SwiftUI gestures for smooth dragging)

struct ResizeDividerView: NSViewRepresentable {
    @Binding var height: CGFloat
    @Binding var startHeight: CGFloat
    let minHeight: CGFloat = 120
    let maxHeight: CGFloat = 700

    func makeNSView(context: Context) -> DividerNSView {
        let v = DividerNSView()
        v.minHeight = minHeight
        v.maxHeight = maxHeight
        v.currentHeight = height
        v.onHeightChange = { newHeight in
            var t = Transaction()
            t.animation = nil
            withTransaction(t) {
                height = newHeight
            }
        }
        v.onDragEnd = {
            UserDefaults.standard.set(Double(height), forKey: "canopyInspectorHeight")
        }
        return v
    }

    func updateNSView(_ nsView: DividerNSView, context: Context) {
        nsView.minHeight = minHeight
        nsView.maxHeight = maxHeight
        nsView.currentHeight = height
    }
}

final class DividerNSView: NSView {
    var minHeight: CGFloat = 120
    var maxHeight: CGFloat = 700
    var currentHeight: CGFloat = 280
    var onHeightChange: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var dragStartY: CGFloat = 0
    private var dragStartHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 3).isActive = true
    }

    override func resetCursorRects() {
        let hitRect = NSRect(x: 0, y: -6, width: bounds.width, height: 15)
        addCursorRect(hitRect, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
        dragStartHeight = currentHeight
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY
        let newHeight = dragStartHeight + delta
        let clamped = max(minHeight, min(maxHeight, newHeight))
        onHeightChange?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
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
