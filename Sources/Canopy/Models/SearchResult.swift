import Foundation

enum SearchCategory: String, CaseIterable, Identifiable, Sendable {
    case all, movies, tv, music, games, software, anime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Categories"
        case .movies: return "Movies"
        case .tv: return "TV"
        case .music: return "Music"
        case .games: return "Games"
        case .software: return "Software"
        case .anime: return "Anime"
        }
    }
}

struct SearchResult: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var size: Int64           // bytes, -1 if unknown
    var seeders: Int
    var leechers: Int
    var engine: String        // source plugin display name
    var magnet: String?
    var pageURL: String?
    var torrentURL: String?

    /// Best link to hand to the torrent engine.
    var downloadLink: String? { magnet ?? torrentURL }
}
