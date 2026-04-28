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
                
                peersTab
                    .tabItem { Label("Peers", systemImage: "person.3") }

                trackersTab
                    .tabItem { Label("Trackers", systemImage: "antenna.radiowaves.left.and.right") }
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
                Text("\(formatSize(torrent.bytesReceived)) / \(formatSize(torrent.selectedSize))")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var fileList: some View {
        List {
            ForEach(torrent.meta.files.indices, id: \.self) { index in
                fileRow(at: index)
            }
        }
    }

    @ViewBuilder
    private func fileRow(at index: Int) -> some View {
        let file = torrent.meta.files[index]
        let selected = index < torrent.fileSelections.count && torrent.fileSelections[index]
        let progress = index < torrent.fileProgresses.count ? torrent.fileProgresses[index] : 0
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected },
                set: { torrent.updateFileSelection(at: index, selected: $0) }
            ))
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(file.path.joined(separator: "/"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(selected ? .primary : .secondary)
                    Spacer()
                    if selected {
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Skipped")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(formatSize(file.length))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                // Only show the progress bar for selected files. For deselected files
                // the value is always 0 and would just be a flat empty bar — cleaner
                // to omit it so adjacent rows don't visually look "kinda downloaded".
                if selected {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(progress >= 1 ? .green : .blue)
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    private var pieceMap: some View {
        ScrollView {
            PieceMapView(pieces: torrent.pieces)
                .padding()
        }
    }
    
    private var peersTab: some View {
        Group {
            if torrent.peerInfos.isEmpty {
                ContentUnavailableView("No Peers", systemImage: "person.3",
                    description: Text("Peers will appear here once connections are established."))
            } else {
                Table(torrent.peerInfos) {
                    TableColumn("Address") { row in
                        HStack(spacing: 4) {
                            Text(row.transport)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(row.transport == "TCP"
                                    ? Color.blue.opacity(0.15)
                                    : Color.purple.opacity(0.15))
                                .foregroundStyle(row.transport == "TCP" ? .blue : .purple)
                                .clipShape(.capsule)
                            Text("\(row.host):\(row.port)")
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Status") { row in
                        Text(row.state.capitalized)
                            .foregroundStyle(row.state == "active" ? .primary : .secondary)
                    }
                    TableColumn("↓") { row in
                        Text(row.dlSpeed > 0 ? formatSpeed(row.dlSpeed) : "—")
                            .foregroundStyle(row.dlSpeed > 0 ? .blue : .secondary)
                            .monospacedDigit()
                    }
                    TableColumn("↑") { row in
                        Text(row.ulSpeed > 0 ? formatSpeed(row.ulSpeed) : "—")
                            .foregroundStyle(row.ulSpeed > 0 ? .green : .secondary)
                            .monospacedDigit()
                    }
                    TableColumn("Pieces") { row in
                        Text(row.totalPieces > 0
                             ? "\(row.piecesHeld) / \(row.totalPieces)"
                             : "—")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    TableColumn("Flags") { row in
                        Text(row.flags)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var trackersTab: some View {
        let allTrackers = torrent.meta.announceList.flatMap { $0 }
        return Group {
            if allTrackers.isEmpty {
                ContentUnavailableView("No Trackers", systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("This torrent has no trackers (DHT / PEX only)."))
            } else {
                List(allTrackers, id: \.self) { url in
                    HStack(spacing: 8) {
                        // Protocol badge
                        let scheme = URL(string: url)?.scheme?.uppercased() ?? "?"
                        Text(scheme)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(schemeColor(scheme).opacity(0.15))
                            .foregroundStyle(schemeColor(scheme))
                            .clipShape(.capsule)
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func schemeColor(_ scheme: String) -> Color {
        switch scheme {
        case "UDP":   return .purple
        case "HTTP":  return .blue
        case "HTTPS": return .green
        default:      return .secondary
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
