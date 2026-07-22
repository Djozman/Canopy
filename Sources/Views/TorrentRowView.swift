// TorrentRowView.swift — compact qBittorrent-style transfer table

import SwiftUI

private enum TorrentColumns {
    static let state: CGFloat = 22
    static let size: CGFloat = 82
    static let progress: CGFloat = 116
    static let status: CGFloat = 92
    static let swarm: CGFloat = 46
    static let speed: CGFloat = 88
    static let eta: CGFloat = 66
    static let ratio: CGFloat = 58
}

struct TorrentTableHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("").frame(width: TorrentColumns.state)
            header("Name", .leading).frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
            header("Size", .trailing).frame(width: TorrentColumns.size, alignment: .trailing)
            header("Progress", .leading).frame(width: TorrentColumns.progress, alignment: .leading)
            header("Status", .leading).frame(width: TorrentColumns.status, alignment: .leading)
            header("Seeds", .trailing).frame(width: TorrentColumns.swarm, alignment: .trailing)
            header("Peers", .trailing).frame(width: TorrentColumns.swarm, alignment: .trailing)
            header("Down", .trailing).frame(width: TorrentColumns.speed, alignment: .trailing)
            header("Up", .trailing).frame(width: TorrentColumns.speed, alignment: .trailing)
            header("ETA", .trailing).frame(width: TorrentColumns.eta, alignment: .trailing)
            header("Ratio", .trailing).frame(width: TorrentColumns.ratio, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: 27)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func header(_ title: String, _ alignment: Alignment) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct TorrentRowView: View {
    let torrent: TorrentStatus
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stateIcon).foregroundStyle(torrent.statusColor)
                .frame(width: TorrentColumns.state)
            Text(torrent.name).font(.callout.weight(.medium)).lineLimit(1).help(torrent.name)
                .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
            Text(formatBytes(torrent.totalSize)).frame(width: TorrentColumns.size, alignment: .trailing)
            ZStack {
                ProgressView(value: min(max(torrent.progress, 0), 1)).tint(torrent.statusColor)
                Text(String(format: "%.1f%%", min(max(torrent.progress, 0), 1) * 100))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }.frame(width: TorrentColumns.progress)
            Text(torrent.statusLabel).lineLimit(1).foregroundStyle(torrent.statusColor)
                .frame(width: TorrentColumns.status, alignment: .leading)
            Text("\(torrent.numSeeds)").frame(width: TorrentColumns.swarm, alignment: .trailing)
            Text("\(torrent.numPeers)").frame(width: TorrentColumns.swarm, alignment: .trailing)
            Text(formatSpeed(torrent.downloadRate)).foregroundStyle(torrent.downloadRate > 0 ? Color.blue : Color.secondary)
                .frame(width: TorrentColumns.speed, alignment: .trailing)
            Text(formatSpeed(torrent.uploadRate)).foregroundStyle(torrent.uploadRate > 0 ? Color.green : Color.secondary)
                .frame(width: TorrentColumns.speed, alignment: .trailing)
            Text(formatETA(torrent.etaSeconds)).frame(width: TorrentColumns.eta, alignment: .trailing)
            Text(formatRatio(uploaded: torrent.totalUploaded, downloaded: torrent.totalDone))
                .frame(width: TorrentColumns.ratio, alignment: .trailing)
        }
        .font(.caption.monospacedDigit()).padding(.vertical, 2).contentShape(Rectangle())
    }

    private var stateIcon: String {
        if torrent.errorMessage != nil { return "exclamationmark.triangle.fill" }
        if torrent.isPaused { return "pause.circle.fill" }
        switch torrent.state {
        case .downloading, .downloadingMetadata: return "arrow.down.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .checkingFiles, .checkingResumeData, .allocating: return "arrow.triangle.2.circlepath"
        }
    }
}
