import SwiftUI

struct StatusBarView: View {
    let stats: EngineSession.Stats
    let torrentCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Label(stats.isListening ? "Listening" : "Not listening",
                  systemImage: stats.isListening ? "network" : "network.slash")
                .foregroundStyle(stats.isListening ? .green : .red)
            Divider().frame(height: 13)
            Label("\(torrentCount)", systemImage: "square.stack.3d.up")
            Spacer()
            Label(Formatters.speed(stats.downloadRate), systemImage: "arrow.down")
                .foregroundStyle(.green)
            Label(Formatters.speed(stats.uploadRate), systemImage: "arrow.up")
                .foregroundStyle(.blue)
        }
        .font(.caption)
        .lineLimit(1)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
