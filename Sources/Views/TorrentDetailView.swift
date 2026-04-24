import SwiftUI

struct TorrentDetailView: View {
    @Bindable var torrent: TorrentHandle
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            TabView {
                fileList
                    .tabItem { Label("Files", systemImage: "doc") }
                
                pieceMap
                    .tabItem { Label("Piece Map", systemImage: "square.grid.3x3") }
                
                Text("Peers (Coming Soon)")
                    .tabItem { Label("Peers", systemImage: "person.3") }
            }
            .padding()
        }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(torrent.name)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(torrent.meta.infoHash.map { String(format: "%02x", $0) }.joined())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(torrent.stateLabel)
                    .font(.headline)
                    .foregroundStyle(stateColor)
                Text("\(formatSize(Int64(torrent.progress * Double(torrent.totalSize)))) / \(formatSize(torrent.totalSize))")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var fileList: some View {
        List {
            ForEach(torrent.meta.files.indices, id: \.self) { index in
                let file = torrent.meta.files[index]
                HStack {
                    Toggle("", isOn: Binding(
                        get: { torrent.fileSelections[index] },
                        set: { torrent.updateFileSelection(at: index, selected: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    
                    VStack(alignment: .leading) {
                        Text(file.path.joined(separator: "/"))
                            .lineLimit(1)
                        Text(formatSize(file.length))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    
    private var pieceMap: some View {
        ScrollView {
            PieceMapView(pieces: torrent.pieces)
                .padding()
        }
    }
    
    private var stateColor: Color {
        switch torrent.state {
        case .downloading: .blue
        case .seeding: .green
        case .error: .red
        default: .orange
        }
    }
}
