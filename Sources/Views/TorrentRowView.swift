import SwiftUI

struct TorrentRowView: View {
    let torrent: TorrentHandle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(torrent.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if torrent.name == "Unknown" || torrent.meta.pieces.isEmpty {
                        Text(torrent.meta.infoHash.map { String(format: "%02x", $0) }.joined())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                stateLabel
            }

            ProgressView(value: torrent.progress)
                .tint(progressTint)

            HStack(spacing: 12) {
                let downloadedSize = Int64(torrent.progress * Double(torrent.totalSize))
                Text("\(formatSize(downloadedSize)) of \(formatSize(torrent.totalSize))")
                    .foregroundStyle(.secondary)
                if torrent.downloadSpeed > 0 {
                    Text("↓ \(formatSpeed(torrent.downloadSpeed))")
                        .foregroundStyle(.blue)
                }
                Text("↑ \(formatSpeed(torrent.uploadSpeed))")
                    .foregroundStyle(.green)
                if torrent.state == .downloading, torrent.eta > 0 {
                    Text(formatETA(torrent.eta)).foregroundStyle(.secondary)
                }
                if !torrent.statusMessage.isEmpty {
                    Text(torrent.statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var stateLabel: some View {
        Text(torrent.stateLabel)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateColor.opacity(0.15))
            .foregroundStyle(stateColor)
            .clipShape(.capsule)
    }

    private var stateColor: Color {
        switch torrent.state {
        case .downloading: .blue
        case .seeding: .green
        case .connecting, .metadata: .orange
        case .error: .red
        case .stopped, .checking: .secondary
        }
    }

    private var progressTint: Color {
        switch torrent.state {
        case .downloading: .blue
        case .seeding: .green
        case .error: .red
        default: .secondary
        }
    }
}
