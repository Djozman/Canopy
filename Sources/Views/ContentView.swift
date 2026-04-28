import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var selection: Set<UUID> = []
    @State private var isTargeted = false
    @State private var addError: String?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                torrentList
                statusBar
            }
            .navigationTitle("Canopy")
            .toolbar { toolbarContent }
        } detail: {
            if let firstId = selection.first,
               let torrent = engine.torrents.first(where: { $0.id == firstId }) {
                TorrentDetailView(torrent: torrent)
            } else {
                Text("Select a torrent to view details")
                    .foregroundStyle(.secondary)
            }
        }
        // Watch all torrents for `needsFileSelection` (covers magnets that resolved
        // across an app restart). Pops the file-selection window. The magnet add flow
        // handles its own selection inside its own window so this won't double-fire.
        .onChange(of: engine.torrents.map { $0.needsFileSelection }) { _, _ in
            openFileSelectionWindowIfNeeded()
        }
        .onAppear { openFileSelectionWindowIfNeeded() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .top) {
            if let err = addError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(err).font(.callout)
                    Spacer()
                    Button("Dismiss") { addError = nil }.buttonStyle(.borderless)
                }
                .padding(.horizontal).padding(.vertical, 6)
                .background(.yellow.opacity(0.15))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: addError)
    }

    // MARK: - Subviews

    private var torrentList: some View {
        Group {
            if engine.torrents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    List(filteredTorrents, selection: $selection) { torrent in
                        TorrentRowView(torrent: torrent)
                            .tag(torrent.id)
                            .contextMenu { contextMenu(for: torrent) }
                    }
                    .listStyle(.inset)
                    .searchable(text: $searchText, placement: .sidebar, prompt: "Search torrents…")
                    
                    Divider()
                    HStack {
                        Text("\(engine.torrents.count) torrents")
                        Spacer()
                        if !searchText.isEmpty {
                            Text("\(filteredTorrents.count) found")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredTorrents: [TorrentHandle] {
        let sorted = engine.torrents.sorted(by: { $0.dateAdded > $1.dateAdded })
        if searchText.isEmpty { return sorted }
        return sorted.filter { 
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.meta.infoHash.map { String(format: "%02x", $0) }.joined().localizedCaseInsensitiveContains(searchText)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green.gradient)
            Text("Drop a .torrent file to start")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            isTargeted ?
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(8) : nil
        )
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(formatSpeed(engine.totalDownloadSpeed), systemImage: "arrow.down")
            Label(formatSpeed(engine.totalUploadSpeed), systemImage: "arrow.up")
            Spacer()
            Text("\(engine.torrents.count) torrent\(engine.torrents.count == 1 ? "" : "s")")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { openWindow(id: "add-torrent") } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .keyboardShortcut("o")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openWindow(id: "add-magnet") } label: {
                Label("Add Magnet", systemImage: "link.badge.plus")
            }
            .keyboardShortcut("m")
        }
        ToolbarItem {
            if !selection.isEmpty {
                Menu {
                    Button("Pause") {
                        selected().forEach { engine.pause($0) }
                    }
                    Button("Resume") {
                        selected().forEach { engine.resume($0) }
                    }
                    Divider()
                    Button("Remove", role: .destructive) {
                        selected().forEach { engine.remove($0) }
                        selection.removeAll()
                    }
                    Button("Remove & Delete Files", role: .destructive) {
                        selected().forEach { engine.remove($0, deleteFiles: true) }
                        selection.removeAll()
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for torrent: TorrentHandle) -> some View {
        if torrent.state == .stopped || torrent.state == .error {
            Button("Resume") { engine.resume(torrent) }
        } else {
            Button("Pause") { engine.pause(torrent) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(nil,
                inFileViewerRootedAtPath: engine.saveDirectory.path)
        }
        Divider()
        Button("Remove", role: .destructive) { engine.remove(torrent) }
        Button("Remove & Delete Files", role: .destructive) { engine.remove(torrent, deleteFiles: true) }
    }

    // MARK: - Helpers

    private func selected() -> [TorrentHandle] {
        engine.torrents.filter { selection.contains($0.id) }
    }

    /// Opens the dedicated file-selection Window if any torrent has `needsFileSelection`
    /// set. The window itself reads engine state to find the right torrent.
    private func openFileSelectionWindowIfNeeded() {
        if engine.torrents.contains(where: { $0.needsFileSelection && $0.meta.files.count > 1 }) {
            openWindow(id: "file-selection")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension == "torrent",
                  let fileData = try? Data(contentsOf: url)
            else { return }
            DispatchQueue.main.async {
                do { try engine.add(torrentFileData: fileData) }
                catch { addError = error.localizedDescription }
            }
        }
        return true
    }
}
