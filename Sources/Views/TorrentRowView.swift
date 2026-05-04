// TorrentRowView.swift

import SwiftUI

struct TorrentRowView: View {
    let torrent: TorrentStatus
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ── Top row: name + badges ─────────────────────────────────────
            HStack(spacing: 6) {
                Text(torrent.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()

                // Status badge
                Text(torrent.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(torrent.statusColor)
                    .background(torrent.statusColor.opacity(0.12), in: Capsule())

                // Ratio
                Text("↑ \(formatRatio(uploaded: torrent.totalUploaded, downloaded: torrent.totalDone))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // ── Progress bar ───────────────────────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(torrent.statusColor)
                        .frame(width: max(0, geo.size.width * CGFloat(torrent.progress)), height: 4)
                }
            }
            .frame(height: 4)

            // ── Bottom row: sizes + speeds + ETA ──────────────────────────
            HStack(spacing: 12) {
                Text("\(formatBytes(torrent.totalDone)) / \(formatBytes(torrent.totalSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                if torrent.downloadRate > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .imageScale(.small)
                            .foregroundStyle(.blue)
                        Text(formatSpeed(torrent.downloadRate))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }

                if torrent.uploadRate > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .imageScale(.small)
                            .foregroundStyle(.green)
                        Text(formatSpeed(torrent.uploadRate))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }

                if torrent.etaSeconds >= 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .imageScale(.small)
                        Text(formatETA(torrent.etaSeconds))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .imageScale(.small)
                    Text("\(torrent.numSeeds)S / \(torrent.numPeers)P")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
