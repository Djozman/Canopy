// TorrentRowView.swift — native table cells for the transfer workspace

import SwiftUI

extension TorrentStatus {
    var sortableStatus: String { statusLabel }
    var ratioValue: Double {
        guard totalDone > 0 else { return 0 }
        return Double(totalUploaded) / Double(totalDone)
    }
}

struct TorrentNameCell: View {
    let torrent: TorrentStatus
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: stateIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(torrent.statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(torrent.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let error = torrent.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(CanopyPalette.danger)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .help(torrent.name)
        .onTapGesture(count: 2, perform: onOpen)
    }

    private var stateIcon: String {
        if torrent.errorMessage != nil { return "exclamationmark.triangle.fill" }
        if torrent.isPaused { return "pause.circle.fill" }
        switch torrent.state {
        case .downloading, .downloadingMetadata: return "arrow.down.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .checkingFiles, .checkingResumeData, .allocating:
            return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

struct TorrentProgressCell: View {
    let progress: Double
    let color: Color

    private var value: Double { min(max(progress, 0), 1) }

    var body: some View {
        HStack(spacing: 7) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(color)
                        .frame(width: max(value > 0 ? 2 : 0, geometry.size.width * value))
                }
            }
            .frame(height: 6)

            Text(String(format: "%.1f%%", value * 100))
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(String(format: "%.1f percent", value * 100))
    }
}

struct TorrentStatusCell: View {
    let torrent: TorrentStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(torrent.statusColor)
                .frame(width: 6, height: 6)
            Text(torrent.statusLabel)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .font(.caption)
    }
}

struct SpeedCell: View {
    let value: Int
    let direction: Direction

    enum Direction { case download, upload }

    var body: some View {
        Text(formatSpeed(value))
            .font(.caption.monospacedDigit())
            .foregroundStyle(value > 0 ? activeColor : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var activeColor: Color {
        direction == .download ? CanopyPalette.download : CanopyPalette.upload
    }
}
