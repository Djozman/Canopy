// StatusBarView.swift — thin bottom status bar

import SwiftUI

struct StatusBarView: View {
    let downloadRate: Int
    let uploadRate:   Int
    let torrentCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Text("\(torrentCount) torrent\(torrentCount == 1 ? "" : "s")")
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .foregroundStyle(.blue)
                    .imageScale(.small)
                Text(formatSpeed(downloadRate))
                    .monospacedDigit()
            }

            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .foregroundStyle(.green)
                    .imageScale(.small)
                Text(formatSpeed(uploadRate))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
