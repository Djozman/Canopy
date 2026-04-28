import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add Torrent (.torrent file)

/// Two-phase add flow for `.torrent` files:
///   1. Pick / drop the file
///   2. Full-screen file picker with per-file checkboxes (folder-grouped), then "Start"
struct AddTorrentView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow
    /// Caller-supplied dismiss — used when this view is presented inline (legacy usage).
    /// In the standard window-scene path, `dismissWindow(id:)` is called instead.
    var onDismiss: (() -> Void)? = nil
    private func dismiss() {
        if let onDismiss { onDismiss() } else { dismissWindow(id: "add-torrent") }
    }

    @State private var isTargeted = false
    @State private var error: String?

    @State private var parsedMeta: Metainfo?
    @State private var torrentData: Data?
    @State private var fileSelections: [Bool] = []
    /// User-chosen save dir — set in the pick phase via the Save-To row, applied at
    /// `startDownload` time. Defaults to the engine's `saveDirectory`.
    @State private var saveDir: URL?

    var body: some View {
        Group {
            if let meta = parsedMeta {
                FileSelectionConfirmView(
                    title: meta.name,
                    files: meta.files,
                    totalSize: meta.totalSize,
                    fileSelections: $fileSelections,
                    saveDir: Binding(
                        get: { saveDir ?? engine.saveDirectory },
                        set: { saveDir = $0 }),
                    primaryLabel: "Start Download",
                    secondaryLabel: "Back",
                    onSecondary: {
                        parsedMeta = nil
                        torrentData = nil
                        fileSelections = []
                    },
                    onCancel: { dismiss() },
                    onConfirm: { startDownload(meta: meta) },
                    error: error
                )
            } else {
                pickPhase
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background(WindowAccessor { window in
            // Resize per phase: small for pick, large for confirm/select.
            let target: CGSize = parsedMeta == nil
                ? CGSize(width: 540, height: 420)
                : CGSize(width: 880, height: 640)
            if window.frame.size != target {
                resizeWindow(to: target)
            }
        })
        .onChange(of: parsedMeta?.infoHash) { _, _ in
            // Resize on phase change — reread the size that matches `parsedMeta != nil`.
            let target: CGSize = parsedMeta == nil
                ? CGSize(width: 540, height: 420)
                : CGSize(width: 880, height: 640)
            resizeWindow(to: target)
        }
    }

    // MARK: Pick phase

    private var pickPhase: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Add Torrent").font(.title2.bold())
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            dropZone
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Spacer()
        }
        .padding(32)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 2, dash: [8])
            )
            .background(Color.secondary.opacity(0.04))
            .frame(maxWidth: .infinity, minHeight: 320)
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 48))
                    Text("Drop .torrent file here")
                        .font(.title3)
                    Text("or")
                        .foregroundStyle(.secondary)
                    Button("Choose File…") { openFilePicker() }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let fileData = try? Data(contentsOf: url)
                    else { return }
                    DispatchQueue.main.async { parseTorrent(fileData) }
                }
                return true
            }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        parseTorrent(data)
    }

    private func parseTorrent(_ data: Data) {
        do {
            let meta = try Metainfo.parse(data)
            torrentData = data
            parsedMeta = meta
            fileSelections = Array(repeating: true, count: meta.files.count)
            saveDir = engine.saveDirectory
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startDownload(meta: Metainfo) {
        guard let data = torrentData else { return }
        let dir = saveDir ?? engine.saveDirectory
        let sel = fileSelections.allSatisfy { $0 } ? nil : fileSelections
        do {
            try engine.add(torrentFileData: data, saveDirectory: dir, fileSelections: sel)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add Magnet

/// Three-phase add flow for magnet links:
///   1. Paste / type the magnet URI
///   2. "Resolving metadata…" while peers fetch the info-dict
///   3. Full-screen file picker, then "Start"
///
/// While the user is in phase 3, the engine has `awaitingFileSelection = true` so no
/// piece data is requested — the disk doesn't fill before the user picks files.
struct MagnetView: View {
    @Environment(TorrentEngine.self) private var engine
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var swiftUIDismiss
    private func dismiss() {
        if let onDismiss { onDismiss() } else { swiftUIDismiss() }
    }

    var onAdd: (UUID) -> Void = { _ in }

    enum Phase { case input, resolving, selecting, error }
    @State private var phase: Phase = .input
    @State private var magnetText = ""
    @State private var errorText: String?
    @State private var torrentId: UUID?
    /// true only when addMagnet() added a brand-new entry to the engine.
    /// false when the magnet matched an already-existing torrent.
    /// cancelMagnet() only calls engine.remove() when this is true.
    @State private var torrentIsNew = false
    @State private var resolvingTask: Task<Void, Never>?
    @State private var saveDir: URL?    // chosen save location for this magnet

    var body: some View {
        Group {
            switch phase {
            case .input:    inputView
            case .resolving: resolvingView
            case .selecting:
                if let id = torrentId,
                   let torrent = engine.torrents.first(where: { $0.id == id }) {
                    FileSelectionConfirmView(
                        title: torrent.meta.name,
                        files: torrent.meta.files,
                        totalSize: torrent.meta.totalSize,
                        fileSelections: Binding(
                            get: { torrent.fileSelections },
                            set: { newValue in
                                for i in newValue.indices where i < torrent.fileSelections.count {
                                    if torrent.fileSelections[i] != newValue[i] {
                                        torrent.updateFileSelection(at: i, selected: newValue[i])
                                    }
                                }
                            }
                        ),
                        saveDir: Binding(
                            get: { saveDir ?? engine.saveDirectory },
                            set: { saveDir = $0 }
                        ),
                        primaryLabel: "Start Download",
                        secondaryLabel: nil,
                        onSecondary: nil,
                        onCancel: { cancelMagnet() },
                        onConfirm: {
                            // Apply chosen save-dir before releasing the gate so the
                            // PieceStore is built at the right location.
                            if let dir = saveDir, dir != engine.saveDirectory {
                                torrent.setSaveDirectory(dir)
                            }
                            torrent.fileSelectionCompleted()
                            onAdd(id)
                            dismiss()
                        },
                        error: nil,
                        saveDirEditable: true
                    )
                } else {
                    inputView   // torrent removed externally; fall back
                }
            case .error:    errorView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fills the window
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear { resolvingTask?.cancel() }
    }

    // MARK: Phase 1 — input

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Magnet Link").font(.title2.bold())
            Text("Paste a magnet URI. Once metadata arrives from peers, you'll choose which files to download.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("magnet:?xt=urn:btih:…", text: $magnetText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)
                .onAppear {
                    if let str = NSPasteboard.general.string(forType: .string),
                       str.lowercased().hasPrefix("magnet:"),
                       Magnet.parse(str) != nil {
                        magnetText = str
                    }
                }

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }

            // Save directory picker
            HStack {
                Text("Save to:").font(.callout)
                Text(saveDir?.path ?? engine.saveDirectory.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { chooseSaveDirForMagnet() }
                    .buttonStyle(.borderless)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { addMagnet() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(magnetText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(32)
        .frame(minWidth: 400)
    }

    private func chooseSaveDirForMagnet() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK { saveDir = panel.url }
    }

    // MARK: Phase 2 — resolving

    private var resolvingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Resolving torrent metadata…")
                .font(.title3)
            if let id = torrentId,
               let torrent = engine.torrents.first(where: { $0.id == id }) {
                VStack(spacing: 6) {
                    Text(torrent.meta.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if torrent.metadataTotalPieces > 0 {
                        Text("Metadata pieces: \(torrent.metadataPiecesCount) / \(torrent.metadataTotalPieces)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Connected peers: \(torrent.peersCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancelMagnet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
    }

    // MARK: Phase 4 — error

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(errorText ?? "Unknown error").font(.headline)
            Button("Back") { phase = .input; errorText = nil }
        }
        .padding(32)
    }

    // MARK: Actions

    private func addMagnet() {
        let uri = magnetText.trimmingCharacters(in: .whitespaces)
        do {
            // Snapshot count before adding so we can tell if a new entry was created.
            let countBefore = engine.torrents.count
            let id = try engine.addMagnet(uri)
            torrentId = id
            // engine.addMagnet returns the existing ID when the torrent is already present.
            // Only mark as new (and therefore eligible for removal on cancel) when the
            // engine actually appended a fresh TorrentHandle.
            torrentIsNew = engine.torrents.count > countBefore
            phase = .resolving
            // Watch the torrent until its metadata resolves (meta.pieces becomes non-empty
            // and meta.files.count is known). Then transition to the file picker.
            resolvingTask = Task { [id] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    await MainActor.run {
                        guard let torrent = engine.torrents.first(where: { $0.id == id }) else {
                            errorText = "Torrent disappeared"
                            phase = .error
                            return
                        }
                        if !torrent.meta.pieces.isEmpty {
                            // Metadata resolved. If multi-file, show picker; else just
                            // confirm and dismiss.
                            if torrent.meta.files.count > 1 {
                                phase = .selecting
                            } else {
                                torrent.fileSelectionCompleted()
                                onAdd(id)
                                dismiss()
                            }
                            resolvingTask?.cancel()
                        }
                    }
                }
            }
        } catch {
            errorText = error.localizedDescription
            phase = .error
        }
    }

    private func cancelMagnet() {
        resolvingTask?.cancel()
        // Only remove the torrent if this view created it. If addMagnet() returned an
        // already-existing torrent's ID (duplicate magnet), we must NOT remove it.
        if torrentIsNew,
           let id = torrentId,
           let torrent = engine.torrents.first(where: { $0.id == id }) {
            engine.remove(torrent)
        }
        dismiss()
    }
}

// MARK: - Shared full-screen file selection view

/// Reused by both the .torrent confirm phase and the magnet "metadata resolved" phase.
/// Shows the title, a folder-grouped checkbox tree, a select-all toggle, the running
/// "selected of total" size summary, save-directory chooser, and the Start/Cancel buttons.
struct FileSelectionConfirmView: View {
    let title: String
    let files: [FileEntry]
    let totalSize: Int64
    @Binding var fileSelections: [Bool]
    @Binding var saveDir: URL
    let primaryLabel: String
    let secondaryLabel: String?
    let onSecondary: (() -> Void)?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let error: String?
    var saveDirEditable: Bool = true

    /// Sort order applied to top-level rows (folders + standalone files).
    enum SortMode: String, CaseIterable, Identifiable {
        case nameAsc, nameDesc, sizeAsc, sizeDesc
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nameAsc:  "Name (A–Z)"
            case .nameDesc: "Name (Z–A)"
            case .sizeAsc:  "Size (smallest first)"
            case .sizeDesc: "Size (largest first)"
            }
        }
    }
    @State private var sortMode: SortMode = .nameAsc
    /// Folders that are currently expanded. Empty by default — every folder starts collapsed
    /// so a 1000-file torrent shows ~10 folder rows instead of all 1000 files.
    @State private var expandedFolders: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row
            HStack(spacing: 10) {
                Image(systemName: "tray.full.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                    .lineLimit(2)
                Spacer()
            }

            Divider()

            // Toolbar: select all + sort + summary
            HStack(spacing: 12) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    let target = !allSelected
                    for i in fileSelections.indices { fileSelections[i] = target }
                }
                .buttonStyle(.borderless)

                if hasFolders {
                    Button(allFoldersExpanded ? "Collapse All" : "Expand All") {
                        if allFoldersExpanded { expandedFolders.removeAll() }
                        else { expandedFolders = Set(folderNames) }
                    }
                    .buttonStyle(.borderless)
                }

                Picker("", selection: $sortMode) {
                    ForEach(SortMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .labelsHidden()

                Spacer()

                Text("\(formatBytes(selectedSize)) of \(formatBytes(totalSize))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // File tree — fills available vertical space, dense rows
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedTopLevel, id: \.id) { row in
                        topLevelRow(row)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))

            // Save location
            if saveDirEditable {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text("Save to:").font(.callout)
                    Text(saveDir.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseSaveDir() }
                        .buttonStyle(.borderless)
                }
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            // Actions
            HStack {
                if let secondaryLabel, let onSecondary {
                    Button(secondaryLabel, action: onSecondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(primaryLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedSize == 0)
            }
        }
        .padding(28)
    }

    // MARK: - Top-level model

    /// One entry in the top-level list — either a folder (with its children file indices)
    /// or a standalone file at the root.
    private struct TopLevelRow: Identifiable {
        enum Kind { case folder(name: String, fileIndices: [Int]); case file(index: Int) }
        let kind: Kind
        let totalSize: Int64
        let displayName: String
        var id: String {
            switch kind {
            case .folder(let n, _): "f:\(n)"
            case .file(let i):      "x:\(i)"
            }
        }
    }

    /// Pre-sort, pre-grouped top-level rows. Folders aggregate every child file's size.
    private var topLevelRows: [TopLevelRow] {
        var groups: [String: [Int]] = [:]
        var standalone: [Int] = []
        for (idx, file) in files.enumerated() {
            if file.path.count > 1 {
                groups[file.path[0], default: []].append(idx)
            } else {
                standalone.append(idx)
            }
        }
        var rows: [TopLevelRow] = []
        for (folder, indices) in groups {
            let total = indices.reduce(Int64(0)) { $0 + files[$1].length }
            rows.append(TopLevelRow(kind: .folder(name: folder, fileIndices: indices),
                                    totalSize: total, displayName: folder))
        }
        for idx in standalone {
            rows.append(TopLevelRow(kind: .file(index: idx),
                                    totalSize: files[idx].length,
                                    displayName: files[idx].name))
        }
        return rows
    }

    private var sortedTopLevel: [TopLevelRow] {
        topLevelRows.sorted { a, b in
            switch sortMode {
            case .nameAsc:  a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            case .nameDesc: a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedDescending
            case .sizeAsc:  a.totalSize < b.totalSize
            case .sizeDesc: a.totalSize > b.totalSize
            }
        }
    }

    private var folderNames: [String] {
        topLevelRows.compactMap {
            if case .folder(let n, _) = $0.kind { return n } else { return nil }
        }
    }

    private var hasFolders: Bool { !folderNames.isEmpty }

    private var allFoldersExpanded: Bool {
        !folderNames.isEmpty && folderNames.allSatisfy { expandedFolders.contains($0) }
    }

    private var allSelected: Bool { fileSelections.allSatisfy { $0 } }

    private var selectedSize: Int64 {
        zip(files, fileSelections).reduce(0) { $0 + ($1.1 ? $1.0.length : 0) }
    }

    // MARK: - Row rendering (dense, collapsible)

    @ViewBuilder
    private func topLevelRow(_ row: TopLevelRow) -> some View {
        switch row.kind {
        case .file(let idx):
            fileRow(index: idx, indent: false)
        case .folder(let name, let fileIndices):
            folderRow(name: name, fileIndices: fileIndices)
        }
    }

    @ViewBuilder
    private func folderRow(name: String, fileIndices: [Int]) -> some View {
        let isExpanded = expandedFolders.contains(name)
        let allSel = fileIndices.allSatisfy { idx in
            idx < fileSelections.count && fileSelections[idx]
        }
        let total = fileIndices.reduce(Int64(0)) { $0 + files[$1].length }

        VStack(alignment: .leading, spacing: 0) {
            // Folder header — chevron toggles expand/collapse, checkbox selects all children
            HStack(spacing: 6) {
                Button {
                    if isExpanded { expandedFolders.remove(name) }
                    else          { expandedFolders.insert(name) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { allSel },
                    set: { newValue in
                        for idx in fileIndices where idx < fileSelections.count {
                            fileSelections[idx] = newValue
                        }
                    }
                ))
                .toggleStyle(.checkbox)

                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("(\(fileIndices.count))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(formatBytes(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { expandedFolders.remove(name) }
                else          { expandedFolders.insert(name) }
            }

            if isExpanded {
                ForEach(sortedChildren(of: fileIndices), id: \.self) { idx in
                    fileRow(index: idx, indent: true)
                }
            }
        }
    }

    private func sortedChildren(of indices: [Int]) -> [Int] {
        indices.sorted { lhs, rhs in
            switch sortMode {
            case .nameAsc:  files[lhs].name.localizedCaseInsensitiveCompare(files[rhs].name) == .orderedAscending
            case .nameDesc: files[lhs].name.localizedCaseInsensitiveCompare(files[rhs].name) == .orderedDescending
            case .sizeAsc:  files[lhs].length < files[rhs].length
            case .sizeDesc: files[lhs].length > files[rhs].length
            }
        }
    }

    @ViewBuilder
    private func fileRow(index: Int, indent: Bool) -> some View {
        HStack(spacing: 6) {
            if indent {
                Spacer().frame(width: 22)   // align under the folder's chevron+checkbox
            }
            Toggle("", isOn: Binding(
                get: { index < fileSelections.count ? fileSelections[index] : true },
                set: { newValue in
                    if index < fileSelections.count { fileSelections[index] = newValue }
                }
            ))
            .toggleStyle(.checkbox)
            Image(systemName: "doc")
                .foregroundStyle(.tertiary)
                .font(.caption)
            Text(files[index].name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(formatBytes(files[index].length))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
    }

    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            saveDir = url
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}

// MARK: - File Selection Window (fallback for restart-resolved magnets)

/// Hosts `FileSelectionConfirmView` for whichever active torrent is currently flagged
/// `needsFileSelection`. Only relevant when a magnet was added in a previous session
/// and just got its metadata back this launch — the normal magnet flow handles its own
/// selection inside the magnet window.
struct FileSelectionWindowView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var saveDir: URL?

    private var pendingTorrent: TorrentHandle? {
        engine.torrents.first { $0.needsFileSelection && $0.meta.files.count > 1 }
    }

    var body: some View {
        Group {
            if let torrent = pendingTorrent {
                FileSelectionConfirmView(
                    title: torrent.meta.name,
                    files: torrent.meta.files,
                    totalSize: torrent.meta.totalSize,
                    fileSelections: Binding(
                        get: { torrent.fileSelections },
                        set: { newValue in
                            for i in newValue.indices where i < torrent.fileSelections.count {
                                if torrent.fileSelections[i] != newValue[i] {
                                    torrent.updateFileSelection(at: i, selected: newValue[i])
                                }
                            }
                        }
                    ),
                    saveDir: Binding(
                        get: { saveDir ?? torrent.saveDirectory },
                        set: { saveDir = $0 }
                    ),
                    primaryLabel: "Start Download",
                    secondaryLabel: nil,
                    onSecondary: nil,
                    onCancel: { dismissWindow(id: "file-selection") },
                    onConfirm: {
                        if let dir = saveDir, dir != torrent.saveDirectory {
                            torrent.setSaveDirectory(dir)
                        }
                        torrent.fileSelectionCompleted()
                        dismissWindow(id: "file-selection")
                    },
                    error: nil,
                    saveDirEditable: true
                )
            } else {
                // Nothing pending — close ourselves.
                Color.clear.onAppear { dismissWindow(id: "file-selection") }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}
