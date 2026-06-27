import Foundation

/// A pluggable torrent search source. Implementations scrape/query a site at
/// runtime via URLSession and normalize results. Stateless so they are Sendable.
protocol SearchPlugin: Sendable {
    var name: String { get }
    func search(_ query: String, category: SearchCategory) async -> [SearchResult]
}

// Public trackers appended to magnet links built from an info-hash.
let commonTrackers: [String] = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://open.stealth.si:80/announce"
]

func makeMagnet(hash: String, name: String) -> String {
    let dn = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
    let trackers = commonTrackers
        .map { "&tr=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) }
        .joined()
    return "magnet:?xt=urn:btih:\(hash)&dn=\(dn)\(trackers)"
}

private func encode(_ q: String) -> String {
    q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
}

// MARK: - The Pirate Bay (apibay JSON)

struct PirateBayPlugin: SearchPlugin {
    let name = "The Pirate Bay"

    private struct Item: Decodable {
        let id: String
        let name: String
        let info_hash: String
        let seeders: String
        let leechers: String
        let size: String
    }

    private func cat(_ c: SearchCategory) -> Int {
        switch c {
        case .all: return 0
        case .movies, .tv, .anime: return 200   // Video
        case .music: return 100                 // Audio
        case .software: return 300               // Applications
        case .games: return 400                  // Games
        }
    }

    func search(_ query: String, category: SearchCategory) async -> [SearchResult] {
        guard let url = URL(string: "https://apibay.org/q.php?q=\(encode(query))&cat=\(cat(category))")
        else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let items = try JSONDecoder().decode([Item].self, from: data)
            let zeros = String(repeating: "0", count: 40)
            return items.compactMap { item in
                guard item.info_hash != zeros, !item.name.isEmpty else { return nil }
                return SearchResult(
                    name: item.name,
                    size: Int64(item.size) ?? -1,
                    seeders: Int(item.seeders) ?? 0,
                    leechers: Int(item.leechers) ?? 0,
                    engine: name,
                    magnet: makeMagnet(hash: item.info_hash, name: item.name),
                    pageURL: "https://thepiratebay.org/description.php?id=\(item.id)",
                    torrentURL: nil
                )
            }
        } catch {
            NSLog("PirateBay search failed: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - YTS (movies JSON API)

struct YTSPlugin: SearchPlugin {
    let name = "YTS"

    private struct Response: Decodable { let data: DataField }
    private struct DataField: Decodable { let movies: [Movie]? }
    private struct Movie: Decodable {
        let title: String
        let title_long: String?
        let url: String?
        let torrents: [Torrent]?
    }
    private struct Torrent: Decodable {
        let hash: String
        let quality: String
        let type: String?
        let seeds: Int?
        let peers: Int?
        let size_bytes: Int64?
    }

    func search(_ query: String, category: SearchCategory) async -> [SearchResult] {
        guard category == .all || category == .movies else { return [] }
        guard let url = URL(string: "https://yts.mx/api/v2/list_movies.json?limit=50&query_term=\(encode(query))")
        else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(Response.self, from: data)
            guard let movies = resp.data.movies else { return [] }
            var out: [SearchResult] = []
            for m in movies {
                let base = m.title_long ?? m.title
                for t in m.torrents ?? [] {
                    let nm = "\(base) [\(t.quality) \(t.type ?? "")]"
                        .trimmingCharacters(in: .whitespaces)
                    out.append(SearchResult(
                        name: nm,
                        size: t.size_bytes ?? -1,
                        seeders: t.seeds ?? 0,
                        leechers: t.peers ?? 0,
                        engine: name,
                        magnet: makeMagnet(hash: t.hash, name: nm),
                        pageURL: m.url,
                        torrentURL: nil
                    ))
                }
            }
            return out
        } catch {
            NSLog("YTS search failed: \(error.localizedDescription)")
            return []
        }
    }
}

// All built-in plugins.
let allSearchPlugins: [any SearchPlugin] = [PirateBayPlugin(), YTSPlugin()]
