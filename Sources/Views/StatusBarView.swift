// StatusBarView.swift — quiet session summary

import SwiftUI

struct StatusBarView: View {
    let downloadRate: Int
    let uploadRate: Int
    let torrentCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Label(
                "\(torrentCount) torrent\(torrentCount == 1 ? "" : "s")",
                systemImage: "square.stack.3d.up"
            )
            .foregroundStyle(.secondary)

            Spacer()

            metric(icon: "arrow.down", value: downloadRate, color: CanopyPalette.download)
            metric(icon: "arrow.up", value: uploadRate, color: CanopyPalette.upload)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    private func metric(icon: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(value > 0 ? color : Color.secondary)
            Text(formatSpeed(value))
                .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
        }
    }
}
