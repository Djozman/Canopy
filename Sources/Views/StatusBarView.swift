// StatusBarView.swift — modern minimal session summary

import SwiftUI

struct StatusBarView: View {
    let downloadRate: Int
    let uploadRate: Int
    let torrentCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Label(
                "\(torrentCount) torrent\(torrentCount == 1 ? "" : "s")",
                systemImage: "square.stack.3d.up"
            )
            .foregroundStyle(.secondary)
            .font(.system(size: 11).monospacedDigit())

            Spacer()

            metric(icon: "arrow.down", value: downloadRate, color: CanopyPalette.download)
            metric(icon: "arrow.up", value: uploadRate, color: CanopyPalette.upload)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }

    private func metric(icon: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(value > 0 ? color : Color.secondary)
                .font(.system(size: 10))
            Text(formatSpeed(value))
                .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
                .font(.system(size: 11).monospacedDigit())
        }
    }
}
