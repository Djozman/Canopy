import SwiftUI

/// Bottom detail panel for a single selected torrent, mirroring qBittorrent's
/// tabbed properties pane: General, Trackers, Peers, Content, Speed.
struct DetailPanel: View {
    @EnvironmentObject var engine: EngineSession
    let hash: String

    @State private var tab: Tab = .general
    @State private var downHistory: [Int64] = []
    @State private var upHistory: [Int64] = []

    private let maxSamples = 90

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case trackers = "Trackers"
        case peers = "Peers"
        case content = "Content"
        case speed = "Speed"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .general: return "info.circle"
            case .trackers: return "antenna.radiowaves.left.and.right"
            case .peers: return "person.2"
            case .content: return "folder"
            case .speed: return "waveform.path.ecg"
            }
        }
    }

    private var torrent: Torrent? {
        engine.torrents.first { $0.infoHash == hash }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            ScrollView {
                content.padding(12)
            }
        }
        .onChange(of: engine.torrents) { _ in sample() }
        .onAppear { sample() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:  GeneralTab(detail: engine.detail(for: hash), torrent: torrent)
        case .trackers: TrackersTab(trackers: engine.trackers(for: hash))
        case .peers:    PeersTab(peers: engine.peers(for: hash))
        case .content:  ContentTab(files: engine.files(for: hash))
        case .speed:    SpeedGraph(download: downHistory, upload: upHistory)
                            .frame(minHeight: 160)
        }
    }

    private func sample() {
        guard let t = torrent else { return }
        downHistory.append(t.downloadRate)
        upHistory.append(t.uploadRate)
        if downHistory.count > maxSamples { downHistory.removeFirst(downHistory.count - maxSamples) }
        if upHistory.count > maxSamples { upHistory.removeFirst(upHistory.count - maxSamples) }
    }
}

// MARK: - General

private struct GeneralTab: View {
    let detail: TorrentDetail?
    let torrent: Torrent?

    var body: some View {
        if let d = detail {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 8) {
                row("Name", d.name)
                row("Save path", d.savePath)
                row("Total size", Formatters.bytes(d.totalSize))
                row("Pieces", "\(d.piecesHave) / \(d.numPieces) (\(Formatters.bytes(d.pieceLength)) each)")
                row("Progress", String(format: "%.1f%%", d.progress * 100))
                row("Ratio", String(format: "%.2f", d.ratio))
                row("Downloaded", Formatters.bytes(d.totalDownload))
                row("Uploaded", Formatters.bytes(d.totalUpload))
                row("Down speed", Formatters.speed(d.downloadRate))
                row("Up speed", Formatters.speed(d.uploadRate))
                row("Connections", "\(d.numConnections)")
                row("Availability", String(format: "%.3f", d.distributedCopies))
                row("Active time", Formatters.duration(d.activeDuration))
                row("Seeding time", Formatters.duration(d.seedingDuration))
                row("Added", Formatters.date(d.addedTime))
                row("Completed", d.completedTime > 0 ? Formatters.date(d.completedTime) : "\u{2014}")
                row("Created by", d.creator.isEmpty ? "\u{2014}" : d.creator)
                row("Created on", d.creationDate > 0 ? Formatters.date(d.creationDate) : "\u{2014}")
            }
            if !d.comment.isEmpty {
                Divider().padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comment").font(.caption).foregroundStyle(.secondary)
                    Text(d.comment).textSelection(.enabled)
                }
            }
        } else {
            ContentUnavailableLabel("No metadata yet")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).lineLimit(2)
        }
    }
}

// MARK: - Trackers

private struct TrackersTab: View {
    let trackers: [TrackerInfo]
    var body: some View {
        if trackers.isEmpty {
            ContentUnavailableLabel("No trackers")
        } else {
            Table(trackers) {
                TableColumn("Tier") { Text("\($0.tier)") }.width(40)
                TableColumn("URL", value: \.url)
                TableColumn("Status", value: \.status).width(110)
                TableColumn("Seeds") { Text($0.numSeeds >= 0 ? "\($0.numSeeds)" : "\u{2014}") }.width(60)
                TableColumn("Leeches") { Text($0.numLeeches >= 0 ? "\($0.numLeeches)" : "\u{2014}") }.width(60)
                TableColumn("Downloaded") { Text($0.numDownloaded >= 0 ? "\($0.numDownloaded)" : "\u{2014}") }.width(80)
                TableColumn("Message", value: \.message)
            }
            .frame(minHeight: 160)
        }
    }
}

// MARK: - Peers

private struct PeersTab: View {
    let peers: [PeerInfo]
    var body: some View {
        if peers.isEmpty {
            ContentUnavailableLabel("No connected peers")
        } else {
            Table(peers) {
                TableColumn("Address", value: \.address).width(150)
                TableColumn("Client", value: \.client)
                TableColumn("Flags", value: \.flags).width(70)
                TableColumn("Conn", value: \.connection).width(50)
                TableColumn("Progress") { Text(String(format: "%.0f%%", $0.progress * 100)) }.width(70)
                TableColumn("Down") { Text(Formatters.speed($0.downSpeed)) }.width(90)
                TableColumn("Up") { Text(Formatters.speed($0.upSpeed)) }.width(90)
            }
            .frame(minHeight: 160)
        }
    }
}

// MARK: - Content (files)

private struct ContentTab: View {
    let files: [TorrentFile]
    var body: some View {
        if files.isEmpty {
            ContentUnavailableLabel("No files yet")
        } else {
            Table(files) {
                TableColumn("Name", value: \.path)
                TableColumn("Size") { Text(Formatters.bytes($0.size)) }.width(90)
                TableColumn("Progress") { Text(String(format: "%.0f%%", $0.progress * 100)) }.width(70)
                TableColumn("Priority") { Text($0.priorityLabel) }.width(110)
            }
            .frame(minHeight: 160)
        }
    }
}

// Simple unavailable label for older SDK fallbacks.
private struct ContentUnavailableLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}
