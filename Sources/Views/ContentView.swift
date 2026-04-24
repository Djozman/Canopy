import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TorrentEngine.self) private var engine
    @State private var showAdd = false
    @State private var showMagnet = false
    @State private var selection: Set<UUID> = []
    @State private var isTargeted = false
    @State private var addError: String?

    var body: some View {
        VStack(spacing: 0) {
            torrentList
            statusBar
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAdd) {
            AddTorrentView()
                .environment(engine)
        }
        .sheet(isPresented: $showMagnet) {
            MagnetView()
                .environment(engine)
        }
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
                List(engine.torrents, selection: $selection) { torrent in
                    TorrentRowView(torrent: torrent)
                        .contextMenu { contextMenu(for: torrent) }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button { showAdd = true } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .keyboardShortcut("o")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showMagnet = true } label: {
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
