// StatusBarView.swift — global transfer status

import SwiftUI

struct StatusBarView: View {
    let downloadRate: Int
    let uploadRate: Int
    let torrentCount: Int

    var body: some View {
        HStack(spacing: 18) {
            Label("\(torrentCount) torrent\(torrentCount == 1 ? "" : "s")", systemImage: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            Label("Session active", systemImage: "network").foregroundStyle(.secondary)
            Spacer()
            metric("Download", "arrow.down", downloadRate, .blue)
            metric("Upload", "arrow.up", uploadRate, .green)
        }
        .font(.caption.monospacedDigit()).padding(.horizontal, 12).frame(height: 29).background(.bar)
    }

    private func metric(_ label: String, _ icon: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
            Text(formatSpeed(value)).fontWeight(.medium)
        }
    }
}
