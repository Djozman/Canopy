import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct TransferListView: View {
    @EnvironmentObject var engine: EngineSession
    @Environment(\.openWindow) private var openWindow

    @State private var selection: Set<String> = []
    @State private var filter: TransferFilter = .status(.all)
    @State private var search: String = ""
    @State private var sortOrder: [KeyPathComparator<Torrent>] = [
        .init(\Torrent.queuePosition, order: .forward)
    ]
    @State private var showAddSheet = false
    @State private var filesTarget: FilesTarget?

    // Category / tag creation
    @State private var pendingHashes: [String] = []
    @State private var showNewCategory = false
    @State private var newCatName = ""
    @State private var newCatPath = ""
    @State private var showCatImporter = false
    @State private var showNewTag = false
    @State private var newTagName = ""

    // Set location / rename / per-torrent rate
    @State private var showLocation = false
    @State private var locationTarget: String?
    @State private var locationPath = ""
    @State private var showLocationImporter = false
    @State private var showRename = false
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var showRate = false
    @State private var rateTargets: [String] = []
    @State private var rateIsDownload = true
    @State private var rateValue = ""
    @State private var showShare = false
    @State private var shareTarget: String?
    @State private var shareRatio = ""
    @State private var shareMinutes = ""

    private var filtered: [Torrent] {
        var rows = engine.torrents.filter { filter.matches($0) }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            rows = rows.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }
        return rows.sorted(using: sortOrder)
    }

    private var singleSelection: String? {
        guard selection.count == 1, let only = selection.first,
              engine.torrents.contains(where: { $0.infoHash == only }) else { return nil }
        return only
    }

    var body: some View {
        NavigationSplitView {
            FilterSidebar(filter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    table
                        .frame(minHeight: 240, idealHeight: 520)
                    if let sel = singleSelection {
                        DetailPanel(hash: sel)
                            .environmentObject(engine)
                            .frame(minHeight: 160, idealHeight: 260)
                    }
                }
                Divider()
                StatusBarView(stats: engine.stats, torrentCount: engine.torrents.count)
            }
            .navigationTitle("Canopy")
            .searchable(text: $search, placement: .toolbar, prompt: "Filter by name")
            .toolbar { toolbarContent }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTorrentSheet().environmentObject(engine)
        }
        .sheet(item: $filesTarget) { target in
            FilesSheet(target: target).environmentObject(engine)
        }
        .sheet(isPresented: $showNewCategory) { newCategorySheet }
        .sheet(isPresented: $showNewTag) { newTagSheet }
        .sheet(isPresented: $showLocation) { locationSheet }
        .sheet(isPresented: $showRename) { renameSheet }
        .sheet(isPresented: $showRate) { rateSheet }
        .sheet(isPresented: $showShare) { shareSheet }
    }

    private var table: some View {
        // Two Groups keep us under the 10-column limit of @TableColumnBuilder.
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            Group {
                queueColumn
                nameColumn
                sizeColumn
                progressColumn
                statusColumn
            }
            Group {
                seedsColumn
                peersColumn
                downColumn
                upColumn
                ratioColumn
                etaColumn
                categoryColumn
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            engine.remove(Array(selection), deleteFiles: false)
        }
        .dropDestination(for: URL.self) { urls, _ in handleDrop(urls) }
    }

    /// Handles .torrent files and magnet links dropped onto the list.
    private func handleDrop(_ urls: [URL]) -> Bool {
        var handled = false
        for url in urls {
            if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                _ = engine.addTorrentFile(url.path)
                handled = true
            } else if url.scheme == "magnet" {
                _ = engine.addMagnet(url.absoluteString)
                handled = true
            }
        }
        return handled
    }

    // MARK: - Columns (each broken out so the type-checker stays fast)

    private var queueColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("#", value: \Torrent.queuePosition) { (t: Torrent) in
            Text(verbatim: t.queuePosition >= 0 ? "\(t.queuePosition + 1)" : "\u{2013}")
                .foregroundStyle(.secondary)
        }
        .width(36)
    }

    private var nameColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Name", value: \Torrent.name) { (t: Torrent) in
            Text(t.name).lineLimit(1)
        }
        .width(min: 220, ideal: 320)
    }

    private var sizeColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Size", value: \Torrent.totalWanted) { (t: Torrent) in
            Text(verbatim: Formatters.bytes(t.totalWanted))
        }
        .width(90)
    }

    private var progressColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Progress", value: \Torrent.progress) { (t: Torrent) in
            ProgressCell(progress: t.progress)
        }
        .width(min: 120, ideal: 150)
    }

    private var statusColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Status", value: \Torrent.statusSortKey) { (t: Torrent) in
            Text(t.statusText)
        }
        .width(120)
    }

    private var seedsColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Seeds", value: \Torrent.numSeeds) { (t: Torrent) in
            Text(verbatim: "\(t.numSeeds) (\(t.numComplete))")
        }
        .width(80)
    }

    private var peersColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Peers", value: \Torrent.numPeers) { (t: Torrent) in
            Text(verbatim: "\(t.numPeers) (\(t.numIncomplete))")
        }
        .width(80)
    }

    private var downColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Down", value: \Torrent.downloadRate) { (t: Torrent) in
            Text(verbatim: Formatters.speed(t.downloadRate))
        }
        .width(90)
    }

    private var upColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Up", value: \Torrent.uploadRate) { (t: Torrent) in
            Text(verbatim: Formatters.speed(t.uploadRate))
        }
        .width(90)
    }

    private var ratioColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Ratio", value: \Torrent.ratio) { (t: Torrent) in
            Text(verbatim: String(format: "%.2f", t.ratio))
        }
        .width(60)
    }

    private var etaColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("ETA", value: \Torrent.eta) { (t: Torrent) in
            Text(verbatim: Formatters.eta(t.eta))
        }
        .width(80)
    }

    private var categoryColumn: some TableColumnContent<Torrent, KeyPathComparator<Torrent>> {
        TableColumn("Category", value: \Torrent.category) { (t: Torrent) in
            Text(t.category.isEmpty ? "\u{2014}" : t.category)
                .foregroundStyle(.secondary)
        }
        .width(120)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func bittorrentMenu(for h: [String]) -> some View {
        let ts = engine.torrents.filter { h.contains($0.infoHash) }
        Menu("BitTorrent") {
            Toggle("Sequential Download", isOn: Binding(
                get: { ts.contains { $0.sequentialDownload } },
                set: { engine.setSequential($0, for: h) }))
            Toggle("Download First/Last Pieces First", isOn: Binding(
                get: { ts.contains { $0.firstLastPiece } },
                set: { engine.setFirstLastPiece($0, for: h) }))
            Toggle("Super Seeding", isOn: Binding(
                get: { ts.contains { $0.superSeeding } },
                set: { engine.setSuperSeeding($0, for: h) }))
        }
    }


    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let h = Array(ids)
        Group {
            Button("Resume") { engine.resume(h) }
            Button("Pause") { engine.pause(h) }
            Button("Force Resume") { engine.forceResume(h) }
            Button("Force Recheck") { engine.recheck(h) }
            Button("Force Reannounce") { engine.forceReannounce(h) }
        }
        Group {
            limitRateMenu(for: h)
            if ids.count == 1, let only = h.first {
                Button("Files\u{2026}") {
                    let name = engine.torrents.first { $0.infoHash == only }?.name ?? only
                    filesTarget = FilesTarget(hash: only, name: name)
                }
                Button("Set Location\u{2026}") { beginSetLocation(only) }
                Button("Rename\u{2026}") { beginRename(only) }
                copyMenu(for: only)
                Button("Share Limits\u{2026}") { beginShareLimits(only) }
            }
        }
        Group {
            categoryMenu(for: h)
            tagsMenu(for: h)
            Menu("Queue") {
                Button("Move to Top") { engine.queueTop(h) }
                Button("Move Up") { engine.queueUp(h) }
                Button("Move Down") { engine.queueDown(h) }
                Button("Move to Bottom") { engine.queueBottom(h) }
            }
            bittorrentMenu(for: h)
            Divider()
            Button("Remove", role: .destructive) { engine.remove(h, deleteFiles: false) }
            Button("Remove + delete files", role: .destructive) { engine.remove(h, deleteFiles: true) }
        }
    }

    @ViewBuilder
    private func categoryMenu(for h: [String]) -> some View {
        Menu("Category") {
            Button("None") { engine.clearCategory(for: h) }
            if !engine.library.categories.isEmpty { Divider() }
            ForEach(engine.library.categories) { c in
                Button {
                    engine.setCategory(c.name, for: h)
                } label: {
                    if allInCategory(c.name, h) {
                        Label(c.name, systemImage: "checkmark")
                    } else {
                        Text(c.name)
                    }
                }
            }
            Divider()
            Button("New Category\u{2026}") {
                pendingHashes = h
                newCatName = ""; newCatPath = ""
                showNewCategory = true
            }
        }
    }

    @ViewBuilder
    private func tagsMenu(for h: [String]) -> some View {
        Menu("Tags") {
            ForEach(engine.library.tags, id: \.self) { tag in
                Button {
                    engine.toggleTag(tag, for: h)
                } label: {
                    if allHaveTag(tag, h) {
                        Label(tag, systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
            if !engine.library.tags.isEmpty { Divider() }
            Button("New Tag\u{2026}") {
                pendingHashes = h
                newTagName = ""
                showNewTag = true
            }
        }
    }

    private func allInCategory(_ name: String, _ h: [String]) -> Bool {
        !h.isEmpty && h.allSatisfy { hash in
            engine.torrents.first { $0.infoHash == hash }?.category == name
        }
    }

    private func allHaveTag(_ tag: String, _ h: [String]) -> Bool {
        !h.isEmpty && h.allSatisfy { hash in
            engine.torrents.first { $0.infoHash == hash }?.tags.contains(tag) ?? false
        }
    }

    // MARK: - New category / tag sheets

    private var newCategorySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Category").font(.title2.bold())
            TextField("Name", text: $newCatName).textFieldStyle(.roundedBorder)
            HStack {
                Text("Save path:").foregroundStyle(.secondary)
                Text(newCatPath.isEmpty ? "Default" : newCatPath)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose\u{2026}") { showCatImporter = true }
                if !newCatPath.isEmpty {
                    Button("Clear") { newCatPath = "" }
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { showNewCategory = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = newCatName.trimmingCharacters(in: .whitespaces)
                    engine.createCategory(name, savePath: newCatPath.isEmpty ? nil : newCatPath)
                    if !pendingHashes.isEmpty { engine.setCategory(name, for: pendingHashes) }
                    showNewCategory = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCatName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 200)
        .fileImporter(isPresented: $showCatImporter,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { newCatPath = url.path }
        }
    }

    private var newTagSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag").font(.title2.bold())
            TextField("Name", text: $newTagName).textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { showNewTag = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = newTagName.trimmingCharacters(in: .whitespaces)
                    engine.createTag(name)
                    if !pendingHashes.isEmpty { engine.addTag(name, for: pendingHashes) }
                    showNewTag = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 150)
    }

    // MARK: - Copy / limit-rate menus

    @ViewBuilder
    private func copyMenu(for hash: String) -> some View {
        Menu("Copy") {
            Button("Magnet Link") { copyMagnet(hash) }
            Button("Name") {
                copyToPasteboard(engine.torrents.first { $0.infoHash == hash }?.name ?? "")
            }
            Button("Info Hash") { copyToPasteboard(hash) }
        }
    }

    @ViewBuilder
    private func limitRateMenu(for h: [String]) -> some View {
        Menu("Limit Download Rate") {
            Button("Unlimited") { for x in h { engine.setTorrentDownloadLimit(0, for: x) } }
            ForEach([50, 100, 250, 500, 1000, 2000, 5000], id: \.self) { kb in
                Button("\(kb) KiB/s") { for x in h { engine.setTorrentDownloadLimit(kb * 1024, for: x) } }
            }
            Button("Custom\u{2026}") { beginRate(h, download: true) }
        }
        Menu("Limit Upload Rate") {
            Button("Unlimited") { for x in h { engine.setTorrentUploadLimit(0, for: x) } }
            ForEach([50, 100, 250, 500, 1000, 2000, 5000], id: \.self) { kb in
                Button("\(kb) KiB/s") { for x in h { engine.setTorrentUploadLimit(kb * 1024, for: x) } }
            }
            Button("Custom\u{2026}") { beginRate(h, download: false) }
        }
    }

    private func beginSetLocation(_ hash: String) {
        locationTarget = hash
        locationPath = engine.torrents.first { $0.infoHash == hash }?.savePath ?? ""
        showLocation = true
    }

    private func beginRename(_ hash: String) {
        renameTarget = hash
        renameText = engine.torrents.first { $0.infoHash == hash }?.name ?? ""
        showRename = true
    }

    private func beginRate(_ hashes: [String], download: Bool) {
        rateTargets = hashes
        rateIsDownload = download
        rateValue = ""
        showRate = true
    }

    private func copyToPasteboard(_ str: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    private func copyMagnet(_ hash: String) {
        if let m = engine.magnetURI(for: hash) { copyToPasteboard(m) }
    }

    // MARK: - Set location / rename / rate sheets

    private var locationSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Location").font(.title2.bold())
            HStack {
                TextField("Save path", text: $locationPath).textFieldStyle(.roundedBorder)
                Button("Choose\u{2026}") { showLocationImporter = true }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { showLocation = false }.keyboardShortcut(.cancelAction)
                Button("Move") {
                    if let t = locationTarget {
                        let p = locationPath.trimmingCharacters(in: .whitespaces)
                        if !p.isEmpty { engine.moveStorage(t, to: p) }
                    }
                    showLocation = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 540, height: 170)
        .fileImporter(isPresented: $showLocationImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { locationPath = url.path }
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Torrent").font(.title2.bold())
            TextField("Name", text: $renameText).textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { showRename = false }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    if let t = renameTarget {
                        engine.renameTorrent(renameText.trimmingCharacters(in: .whitespaces), for: t)
                    }
                    showRename = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 150)
    }

    private func beginShareLimits(_ hash: String) {
        shareTarget = hash
        let cur = engine.seedingLimits(for: hash)
        shareRatio = cur.ratio > 0 ? String(format: "%.2f", cur.ratio) : ""
        shareMinutes = cur.minutes > 0 ? "\(cur.minutes)" : ""
        showShare = true
    }

    private var shareSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Limits").font(.title2.bold())
            Text("Pause this torrent once it reaches either limit. Leave blank for no limit.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Stop at ratio:")
                Spacer()
                TextField("\u{221E}", text: $shareRatio).frame(width: 100).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Stop after seeding (minutes):")
                Spacer()
                TextField("\u{221E}", text: $shareMinutes).frame(width: 100).textFieldStyle(.roundedBorder)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { showShare = false }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let t = shareTarget {
                        let r = Double(shareRatio.trimmingCharacters(in: .whitespaces)) ?? -1
                        let m = Int(shareMinutes.trimmingCharacters(in: .whitespaces)) ?? -1
                        engine.setSeedingLimits(ratio: r, minutes: m, for: t)
                    }
                    showShare = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }

    private var rateSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rateIsDownload ? "Download Rate Limit" : "Upload Rate Limit").font(.title2.bold())
            HStack {
                TextField("0 = unlimited", text: $rateValue).textFieldStyle(.roundedBorder)
                Text("KiB/s")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { showRate = false }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let kb = Int(rateValue.trimmingCharacters(in: .whitespaces)) ?? 0
                    for x in rateTargets {
                        if rateIsDownload { engine.setTorrentDownloadLimit(kb * 1024, for: x) }
                        else { engine.setTorrentUploadLimit(kb * 1024, for: x) }
                    }
                    showRate = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380, height: 160)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showAddSheet = true } label: {
                Label("Add", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            Button { openWindow(id: "search") } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            Button { openWindow(id: "rss") } label: {
                Label("RSS", systemImage: "dot.radiowaves.left.and.right")
            }
            Button { openWindow(id: "stats") } label: {
                Label("Statistics", systemImage: "chart.bar")
            }
            Button { openWindow(id: "log") } label: {
                Label("Log", systemImage: "list.bullet.rectangle")
            }
            Button { engine.toggleAltSpeedLimits() } label: {
                Label("Alt Speed", systemImage: engine.altLimitsActive ? "tortoise.fill" : "hare.fill")
            }
            Button { engine.resume(Array(selection)) } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .disabled(selection.isEmpty)
            Button { engine.pause(Array(selection)) } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(selection.isEmpty)
            Button(role: .destructive) { engine.remove(Array(selection), deleteFiles: false) } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
    }
}

// MARK: - Status display helpers

extension Torrent {
    var statusText: String {
        if paused { return "Paused" }
        switch state {
        case .downloading: return "Downloading"
        case .downloadingMetadata: return "Metadata"
        case .seeding: return "Seeding"
        case .finished: return "Finished"
        case .checkingFiles: return "Checking"
        case .checkingResumeData: return "Checking resume"
        case .error: return "Error"
        default: return "Unknown"
        }
    }

    var statusSortKey: Int {
        if paused { return 100 }
        switch state {
        case .downloading: return 0
        case .downloadingMetadata: return 1
        case .seeding: return 2
        case .finished: return 3
        case .checkingFiles, .checkingResumeData: return 4
        case .error: return 5
        default: return 9
        }
    }
}
