// TorrentDetailView.swift — native inspector for the selected transfer

import AppKit
import SwiftUI

enum DetailTab: String, CaseIterable {
    case overview = "Overview"
    case files = "Files"
    case peers = "Peers"
    case trackers = "Trackers"
    case pieces = "Pieces"
}

struct TorrentDetailView: View {
    let torrent: TorrentStatus
    let engine: TorrentEngine
    @State private var tab: DetailTab = .overview
    @StateObject private var fileTreeVM: FileTreeViewModel

    init(torrent: TorrentStatus, engine: TorrentEngine) {
        self.torrent = torrent
        self.engine = engine
        _fileTreeVM = StateObject(wrappedValue: FileTreeViewModel(torrent: torrent))
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()

            Picker("Section", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch tab {
                case .overview:
                    OverviewTab(torrent: torrent)
                case .files:
                    FilesTab(vm: fileTreeVM)
                        .onAppear { fileTreeVM.refresh(torrent: torrent) }
                case .peers:
                    PeersTab(torrent: torrent)
                case .trackers:
                    TrackersTab(torrent: torrent)
                case .pieces:
                    PiecesTab(torrent: torrent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CanopyPalette.canvas)
        .onChange(of: torrent.totalDone) { _, _ in
            fileTreeVM.refresh(torrent: torrent)
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: stateIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(torrent.statusColor)
                    .font(.system(size: 18))
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(torrent.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(torrent.statusLabel)
                        .font(.caption)
                        .foregroundStyle(torrent.statusColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    torrent.isPaused ? engine.resume(torrent) : engine.pause(torrent)
                } label: {
                    Image(systemName: torrent.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(torrent.isPaused ? "Resume" : "Pause")

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: torrent.savePath))
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Open save folder")
            }

            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(torrent.statusColor)
                            .frame(width: geometry.size.width * CGFloat(clampedProgress))
                    }
                }
                .frame(height: 6)

                Text(String(format: "%.1f%%", clampedProgress * 100))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Label(formatSpeed(torrent.downloadRate), systemImage: "arrow.down")
                    .foregroundStyle(torrent.downloadRate > 0 ? CanopyPalette.download : .secondary)
                Label(formatSpeed(torrent.uploadRate), systemImage: "arrow.up")
                    .foregroundStyle(torrent.uploadRate > 0 ? CanopyPalette.upload : .secondary)
                Spacer()
                Text(formatETA(torrent.etaSeconds))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(12)
        .background(.bar)
    }

    private var clampedProgress: Double {
        min(max(Double(torrent.progress), 0), 1)
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

private struct OverviewTab: View {
    let torrent: TorrentStatus

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                InspectorSection(title: "Transfer") {
                    InspectorRow("Downloaded", "\(formatBytes(torrent.totalDone)) of \(formatBytes(torrent.totalSize))")
                    InspectorRow("Uploaded", formatBytes(torrent.totalUploaded))
                    InspectorRow("Ratio", formatRatio(uploaded: torrent.totalUploaded, downloaded: torrent.totalDone))
                    InspectorRow("Download speed", formatSpeed(torrent.downloadRate))
                    InspectorRow("Upload speed", formatSpeed(torrent.uploadRate))
                    if torrent.state != .seeding, torrent.state != .finished {
                        InspectorRow("Remaining", formatETA(torrent.etaSeconds))
                    }
                }

                InspectorSection(title: "Connections") {
                    InspectorRow("Seeds", "\(torrent.numSeeds)")
                    InspectorRow("Peers", "\(torrent.numPeers)")
                }

                InspectorSection(title: "Location") {
                    InspectorRow("Save path", torrent.savePath, selectable: true)
                    InspectorRow("Info hash", torrent.id, selectable: true)
                }

                if let error = torrent.errorMessage {
                    InspectorSection(title: "Error") {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(CanopyPalette.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) { content }
                .padding(10)
                .background(CanopyPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(CanopyPalette.border.opacity(0.6), lineWidth: 1)
                }
        }
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String
    let selectable: Bool

    init(_ label: String, _ value: String, selectable: Bool = false) {
        self.label = label
        self.value = value
        self.selectable = selectable
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            valueText
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if selectable {
            Text(value)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } else {
            Text(value)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct TrackersTab: View {
    let torrent: TorrentStatus
    @State private var rows: [TrackerRow] = []
    @State private var timer: Timer?

    var body: some View {
        Group {
            if rows.isEmpty {
                empty("No trackers", icon: "antenna.radiowaves.left.and.right.slash")
            } else {
                List(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(row.working ? CanopyPalette.positive : CanopyPalette.danger)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.url)
                                .font(.caption)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text(row.working ? "Working · Tier \(row.tier)" : "Unavailable · Tier \(row.tier)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { start() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func start() {
        refresh()
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 5, repeats: true) { _ in refresh() }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func refresh() {
        guard let handle = torrent.handle else { rows = []; return }
        rows = (0..<Int(handle.trackerCount)).compactMap { index in
            guard let info = handle.trackerInfo(at: Int32(index)) else { return nil }
            return TrackerRow(
                id: index,
                url: info["url"] as? String ?? "",
                tier: (info["tier"] as? NSNumber)?.intValue ?? 0,
                working: info["working"] as? Bool ?? false
            )
        }
    }

    private func empty(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrackerRow: Identifiable {
    let id: Int
    let url: String
    let tier: Int
    let working: Bool
}

private struct PeersTab: View {
    let torrent: TorrentStatus
    @State private var rows: [PeerRow] = []
    @State private var timer: Timer?

    var body: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash").font(.title2).foregroundStyle(.tertiary)
                    Text("No connected peers").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(row.ip):\(row.port)")
                                .font(.caption.monospacedDigit().weight(.medium))
                            Spacer()
                            Text(String(format: "%.0f%%", row.progress * 100))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(row.client.isEmpty ? "Unknown client" : row.client)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("↓ \(formatSpeed(row.downSpeed))")
                                .foregroundStyle(CanopyPalette.download)
                            Text("↑ \(formatSpeed(row.upSpeed))")
                                .foregroundStyle(CanopyPalette.upload)
                        }
                        .font(.caption2.monospacedDigit())
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { start() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func start() {
        refresh()
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 3, repeats: true) { _ in refresh() }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func refresh() {
        guard let handle = torrent.handle else { rows = []; return }
        rows = (0..<Int(handle.peerCount)).compactMap { index in
            guard let info = handle.peerInfo(at: Int32(index)) else { return nil }
            return PeerRow(
                id: index,
                ip: info["ip"] as? String ?? "",
                port: (info["port"] as? NSNumber)?.intValue ?? 0,
                client: info["client"] as? String ?? "",
                progress: (info["progress"] as? NSNumber)?.doubleValue ?? 0,
                downSpeed: (info["downSpeed"] as? NSNumber)?.intValue ?? 0,
                upSpeed: (info["upSpeed"] as? NSNumber)?.intValue ?? 0
            )
        }
    }
}

private struct PeerRow: Identifiable {
    let id: Int
    let ip: String
    let port: Int
    let client: String
    let progress: Double
    let downSpeed: Int
    let upSpeed: Int
}

private struct PiecesTab: View {
    let torrent: TorrentStatus
    @State private var pieceSize: Int64 = 0
    @State private var bits: [Bool] = []
    @State private var timer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if bits.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3").font(.title2).foregroundStyle(.tertiary)
                        Text("Piece map unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    let complete = bits.filter { $0 }.count
                    Text("\(complete) of \(bits.count) pieces · \(formatBytes(pieceSize)) each")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 9, maximum: 9), spacing: 2)],
                        spacing: 2
                    ) {
                        ForEach(bits.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(bits[index] ? CanopyPalette.positive : Color.primary.opacity(0.10))
                                .frame(width: 9, height: 9)
                        }
                    }
                }
            }
            .padding(12)
        }
        .onAppear { start() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func start() {
        refresh()
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 4, repeats: true) { _ in refresh() }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func refresh() {
        guard let handle = torrent.handle, handle.pieceCount > 0 else {
            bits = []
            return
        }
        pieceSize = handle.pieceSize
        bits = handle.pieceDownloadedBits().map { $0 != 0 }
    }
}
