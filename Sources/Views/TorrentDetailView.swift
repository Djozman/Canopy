// TorrentDetailView.swift

import SwiftUI

enum DetailTab: String, CaseIterable {
    case general  = "General"
    case trackers = "Trackers"
    case peers    = "Peers"
    case files    = "Files"
    case content  = "Content"
}

struct TorrentDetailView: View {
    let torrent: TorrentStatus
    let engine: TorrentEngine
    @State private var tab: DetailTab = .general
    @StateObject private var fileTreeVM: FileTreeViewModel

    init(torrent: TorrentStatus, engine: TorrentEngine) {
        self.torrent = torrent
        self.engine = engine
        _fileTreeVM = StateObject(wrappedValue: FileTreeViewModel(torrent: torrent))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            ScrollView {
                switch tab {
                case .general:  GeneralTab(torrent: torrent)
                case .trackers: TrackersTab()
                case .peers:    PeersTab()
                case .files:    FilesTab(vm: fileTreeVM)
                                    .onAppear { fileTreeVM.refresh(torrent: torrent) }
                                    .onChange(of: torrent.totalDone) { fileTreeVM.refresh(torrent: torrent) }
                case .content:  ContentTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(torrent.name)
        .navigationSubtitle(torrent.statusLabel)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    let torrent: TorrentStatus

    var body: some View {
        Form {
            Section("Transfer") {
                row("Downloaded",  "\(formatBytes(torrent.totalDone)) of \(formatBytes(torrent.totalSize))")
                row("Uploaded",    formatBytes(torrent.totalUploaded))
                row("Ratio",       formatRatio(uploaded: torrent.totalUploaded, downloaded: torrent.totalDone))
                row("Down speed",  formatSpeed(torrent.downloadRate))
                row("Up speed",    formatSpeed(torrent.uploadRate))
                row("ETA",         formatETA(torrent.etaSeconds))
            }
            Section("Swarm") {
                row("Seeds",  "\(torrent.numSeeds)")
                row("Peers",  "\(torrent.numPeers)")
            }
            Section("Info") {
                row("Save path", torrent.savePath)
                row("Hash",      torrent.id)
                if let err = torrent.errorMessage {
                    row("Error", err)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

// MARK: - Trackers Tab

private struct TrackersTab: View {
    let trackers = [
        ("udp://tracker.opentrackr.org:1337/announce", true,  "120 seeds / 45 peers"),
        ("udp://open.tracker.cl:1337/announce",        true,  "98 seeds / 30 peers"),
        ("udp://tracker.torrent.eu.org:451/announce",  false, "Connection timed out"),
        ("http://tracker.bt4g.com:2095/announce",      true,  "44 seeds / 12 peers"),
    ]

    var body: some View {
        Table(trackers.enumerated().map { TrackerRow(id: $0.offset, url: $0.element.0, working: $0.element.1, message: $0.element.2) }) {
            TableColumn("URL")    { Text($0.url).font(.caption).foregroundStyle($0.working ? Color.primary : Color.red) }
            TableColumn("Status") { Text($0.working ? "Working" : "Error").font(.caption).foregroundStyle($0.working ? Color.green : Color.red) }
            TableColumn("Info")   { Text($0.message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
    }
}

private struct TrackerRow: Identifiable {
    let id: Int; let url: String; let working: Bool; let message: String
}

// MARK: - Peers Tab

private struct PeersTab: View {
    let peers = [
        ("192.168.1.45",  "qBittorrent 5.0.0",   0.92, "↓ 1.2 MiB/s", "↑ 45 KiB/s"),
        ("10.0.0.12",     "Transmission 4.0.3",   0.77, "↓ 800 KiB/s", "↑ 120 KiB/s"),
        ("203.0.113.5",   "Deluge 2.1.1",         1.0,  "↓ 0",          "↑ 200 KiB/s"),
        ("198.51.100.22", "μTorrent 3.6.0",       0.33, "↓ 400 KiB/s", "↑ 0"),
    ]

    var body: some View {
        Table(peers.enumerated().map { PeerRow(id: $0.offset, ip: $0.element.0, client: $0.element.1, progress: $0.element.2, down: $0.element.3, up: $0.element.4) }) {
            TableColumn("IP")       { Text($0.ip).font(.caption).monospacedDigit() }
            TableColumn("Client")   { Text($0.client).font(.caption) }
            TableColumn("Progress") { Text(String(format: "%.0f%%", $0.progress * 100)).font(.caption).monospacedDigit() }
            TableColumn("Down")     { Text($0.down).font(.caption).foregroundStyle(.blue) }
            TableColumn("Up")       { Text($0.up).font(.caption).foregroundStyle(.green) }
        }
        .padding()
    }
}

private struct PeerRow: Identifiable {
    let id: Int; let ip: String; let client: String; let progress: Double; let down: String; let up: String
}

// MARK: - Content Tab (piece map)

private struct ContentTab: View {
    private let cols = 40
    private let total = 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Piece map (\(total) pieces × 512 KiB)")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(10), spacing: 2), count: cols), spacing: 2) {
                ForEach(0..<total, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(i) / Double(total) < 0.69 ? Color.blue : Color.green)
                        .frame(width: 10, height: 10)
                }
            }
        }
        .padding()
    }
}
