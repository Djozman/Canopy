import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject var engine: EngineSession

    private var totalDownloaded: Int64 { engine.torrents.reduce(0) { $0 + $1.allTimeDownload } }
    private var totalUploaded: Int64 { engine.torrents.reduce(0) { $0 + $1.allTimeUpload } }
    private var overallRatio: Double {
        totalDownloaded > 0 ? Double(totalUploaded) / Double(totalDownloaded) : 0
    }
    private var activePeers: Int { engine.torrents.reduce(0) { $0 + $1.connectionsCount } }
    private var seeding: Int { engine.torrents.filter { !$0.paused && ($0.state == .seeding || $0.state == .finished) }.count }
    private var downloading: Int { engine.torrents.filter { !$0.paused && $0.state == .downloading }.count }

    var body: some View {
        Form {
            Section("Transfer (this session)") {
                row("Download speed", Formatters.speed(engine.stats.downloadRate))
                row("Upload speed", Formatters.speed(engine.stats.uploadRate))
                row("Downloaded", Formatters.bytes(engine.stats.totalDownload))
                row("Uploaded", Formatters.bytes(engine.stats.totalUpload))
            }
            Section("All-time") {
                row("Total downloaded", Formatters.bytes(totalDownloaded))
                row("Total uploaded", Formatters.bytes(totalUploaded))
                row("Global ratio", Formatters.ratio(overallRatio))
            }
            Section("Torrents") {
                row("Total", "\(engine.torrents.count)")
                row("Downloading", "\(downloading)")
                row("Seeding", "\(seeding)")
                row("Connected peers", "\(activePeers)")
            }
            Section("Network") {
                row("DHT nodes", "\(engine.stats.dhtNodes)")
                row("Listening", engine.stats.isListening ? "Yes" : "No")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Statistics")
        .frame(minWidth: 360, minHeight: 460)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
