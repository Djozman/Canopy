// TorrentListViewModel.swift

import SwiftUI
import Combine

enum FilterCategory: String, CaseIterable {
    case all          = "All"
    case downloading  = "Downloading"
    case seeding      = "Seeding"
    case paused       = "Paused"
    case finished     = "Finished"
    case error        = "Errored"
}

@MainActor
final class TorrentListViewModel: ObservableObject {

    // In production, swap MockData for engine.torrents via Combine.
    // @Published var torrents: [TorrentStatus] = []
    // private var cancellables = Set<AnyCancellable>()
    //
    // init(engine: TorrentEngine) {
    //     engine.$torrents
    //         .receive(on: RunLoop.main)
    //         .assign(to: &$torrents)
    // }

    @Published var torrents: [TorrentStatus] = []
    private var cancellables = Set<AnyCancellable>()

    init(engine: TorrentEngine) {
        engine.$torrents
            .receive(on: RunLoop.main)
            .assign(to: &$torrents)
        engine.startPolling()
    }
    @Published var selectedFilter: FilterCategory = .all
    @Published var searchText: String = ""
    @Published var selectedTorrentID: String? = nil

    var filtered: [TorrentStatus] {
        let base = torrents.filter { t in
            guard !searchText.isEmpty else { return true }
            return t.name.localizedCaseInsensitiveContains(searchText)
        }
        switch selectedFilter {
        case .all:         return base
        case .downloading: return base.filter { !$0.isPaused && ($0.state == .downloading || $0.state == .downloadingMetadata) }
        case .seeding:     return base.filter { !$0.isPaused && $0.state == .seeding }
        case .paused:      return base.filter { $0.isPaused }
        case .finished:    return base.filter { $0.state == .finished || $0.state == .seeding }
        case .error:       return base.filter { $0.errorMessage != nil }
        }
    }

    var selectedTorrent: TorrentStatus? {
        guard let id = selectedTorrentID else { return nil }
        return torrents.first { $0.id == id }
    }

    // Aggregate stats for status bar
    var totalDownloadRate: Int { torrents.reduce(0) { $0 + $1.downloadRate } }
    var totalUploadRate:   Int { torrents.reduce(0) { $0 + $1.uploadRate   } }

    func filterCount(_ cat: FilterCategory) -> Int {
        switch cat {
        case .all:         return torrents.count
        case .downloading: return torrents.filter { !$0.isPaused && ($0.state == .downloading || $0.state == .downloadingMetadata) }.count
        case .seeding:     return torrents.filter { !$0.isPaused && $0.state == .seeding }.count
        case .paused:      return torrents.filter { $0.isPaused }.count
        case .finished:    return torrents.filter { $0.state == .finished || $0.state == .seeding }.count
        case .error:       return torrents.filter { $0.errorMessage != nil }.count
        }
    }
}
