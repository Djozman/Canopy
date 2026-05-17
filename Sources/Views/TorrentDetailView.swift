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
                case .trackers: TrackersTab(torrent: torrent, engine: engine)
                case .peers:    PeersTab(torrent: torrent, engine: engine)
                case .files:    FilesTab(vm: fileTreeVM)
                                    .onAppear { fileTreeVM.refresh(torrent: torrent) }
                                    .onChange(of: torrent.totalDone) { _ in fileTreeVM.refresh(torrent: torrent) }
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
                if torrent.state != .seeding, torrent.state != .finished {
                    row("ETA", formatETA(torrent.etaSeconds))
                }
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
    let torrent: TorrentStatus
    let engine: TorrentEngine

    @State private var trackerRows: [TrackerRow] = []
    @State private var timer: Timer?

    var body: some View {
        Table(trackerRows) {
            TableColumn("URL") { row in
                Text(row.url).font(.caption).foregroundStyle(row.working ? Color.primary : Color.red)
            }
            TableColumn("Tier") { row in
                Text(String(row.tier)).font(.caption).monospacedDigit()
            }
            TableColumn("Status") { row in
                Text(row.working ? "Working" : "Error").font(.caption)
                    .foregroundStyle(row.working ? Color.green : Color.red)
            }
        }
        .padding()
        .onAppear { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in refresh() } }
        .onDisappear { timer?.invalidate() }
    }

    private func refresh() {
        guard let h = torrent.handle else { return }
        let count = Int(h.trackerCount)
        var rows: [TrackerRow] = []
        for i in 0..<count {
            if let info = h.trackerInfo(at: Int32(i)) {
                rows.append(TrackerRow(
                    id: i,
                    url: info["url"] as? String ?? "",
                    tier: (info["tier"] as? NSNumber)?.intValue ?? 0,
                    working: info["working"] as? Bool ?? false
                ))
            }
        }
        trackerRows = rows
    }
}

private struct TrackerRow: Identifiable {
    let id: Int; let url: String; let tier: Int; let working: Bool
}

// MARK: - Peers Tab

private struct PeersTab: View {
    let torrent: TorrentStatus
    let engine: TorrentEngine

    @State private var peerRows: [PeerRow] = []
    @State private var timer: Timer?

    var body: some View {
        Table(peerRows) {
            TableColumn("IP") { row in
                Text(row.ip).font(.caption).monospacedDigit()
            }
            TableColumn("Port") { row in
                Text(String(row.port)).font(.caption).monospacedDigit()
            }
            TableColumn("Client") { row in
                Text(row.client).font(.caption)
            }
            TableColumn("Progress") { row in
                Text(String(format: "%.0f%%", row.progress * 100)).font(.caption).monospacedDigit()
            }
            TableColumn("Down") { row in
                Text(formatBytes(Int64(row.downSpeed)) + "/s").font(.caption).foregroundStyle(.blue)
            }
            TableColumn("Up") { row in
                Text(formatBytes(Int64(row.upSpeed)) + "/s").font(.caption).foregroundStyle(.green)
            }
        }
        .padding()
        .onAppear { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in refresh() } }
        .onDisappear { timer?.invalidate() }
    }

    private func refresh() {
        guard let h = torrent.handle else { return }
        let count = Int(h.peerCount)
        var rows: [PeerRow] = []
        for i in 0..<count {
            if let info = h.peerInfo(at: Int32(i)) {
                rows.append(PeerRow(
                    id: i,
                    ip: info["ip"] as? String ?? "",
                    port: (info["port"] as? NSNumber)?.intValue ?? 0,
                    client: info["client"] as? String ?? "",
                    progress: (info["progress"] as? NSNumber)?.doubleValue ?? 0,
                    downSpeed: (info["downSpeed"] as? NSNumber)?.intValue ?? 0,
                    upSpeed: (info["upSpeed"] as? NSNumber)?.intValue ?? 0
                ))
            }
        }
        peerRows = rows
    }
}

private struct PeerRow: Identifiable {
    let id: Int; let ip: String; let port: Int; let client: String
    let progress: Double; let downSpeed: Int; let upSpeed: Int
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
