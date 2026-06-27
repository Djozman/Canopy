import SwiftUI

struct TransferListView: View {
    @EnvironmentObject var engine: EngineSession

    @State private var selection: Set<String> = []
    @State private var filter: StatusFilter = .all
    @State private var search: String = ""
    @State private var sortOrder: [KeyPathComparator<Torrent>] = [
        .init(\Torrent.queuePosition, order: .forward)
    ]
    @State private var showAddSheet = false
    @State private var filesTarget: FilesTarget?

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
            FilterSidebar(statusFilter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    table
                    if let sel = singleSelection {
                        DetailPanel(hash: sel)
                            .environmentObject(engine)
                            .frame(minHeight: 180, idealHeight: 240)
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
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        }
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

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let h = Array(ids)
        Group {
            Button("Resume") { engine.resume(h) }
            Button("Pause") { engine.pause(h) }
            Button("Force Recheck") { engine.recheck(h) }
            if ids.count == 1, let only = h.first {
                Button("Files\u{2026}") {
                    let name = engine.torrents.first { $0.infoHash == only }?.name ?? only
                    filesTarget = FilesTarget(hash: only, name: name)
                }
            }
        }
        Group {
            Menu("Queue") {
                Button("Move to Top") { engine.queueTop(h) }
                Button("Move Up") { engine.queueUp(h) }
                Button("Move Down") { engine.queueDown(h) }
                Button("Move to Bottom") { engine.queueBottom(h) }
            }
            Divider()
            Button("Remove", role: .destructive) { engine.remove(h, deleteFiles: false) }
            Button("Remove + delete files", role: .destructive) { engine.remove(h, deleteFiles: true) }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showAddSheet = true } label: {
                Label("Add", systemImage: "plus")
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
