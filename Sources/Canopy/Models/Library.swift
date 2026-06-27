import Foundation

/// A user-defined category. An optional save path overrides the default
/// download location for torrents in this category (qBittorrent parity).
struct CategoryDef: Identifiable, Hashable, Codable {
    var name: String
    var savePath: String?   // nil/empty = use the default save path
    var id: String { name }
}

/// Per-torrent metadata that libtorrent itself does not track.
struct TorrentMeta: Codable, Hashable {
    var category: String = ""
    var tags: [String] = []
}

/// The full library of categories, tags, and per-torrent assignments.
/// Persisted as JSON alongside the resume data.
struct LibraryData: Codable {
    var categories: [CategoryDef] = []
    var tags: [String] = []
    var assignments: [String: TorrentMeta] = [:]

    func savePath(forCategory name: String) -> String? {
        guard let def = categories.first(where: { $0.name == name }),
              let sp = def.savePath, !sp.isEmpty else { return nil }
        return sp
    }
}
