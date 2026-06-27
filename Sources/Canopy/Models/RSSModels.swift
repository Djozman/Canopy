import Foundation

struct RSSArticle: Identifiable, Codable, Hashable {
    var id: String            // guid / id / link
    var title: String
    var link: String          // article or page link
    var torrentURL: String?   // enclosure or magnet/.torrent link
    var date: Date?
    var isRead: Bool = false
    var isDownloaded: Bool = false
}

struct RSSFeed: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var url: String
    var title: String = ""
    var articles: [RSSArticle] = []
    var lastRefresh: Date?

    var displayTitle: String { title.isEmpty ? url : title }
    var unreadCount: Int { articles.filter { !$0.isRead }.count }
}

struct RSSRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var enabled: Bool = true
    var mustContain: String = ""
    var mustNotContain: String = ""
    var useRegex: Bool = false
    var affectedFeedURLs: [String] = []   // empty = all feeds
    var assignCategory: String = ""
    var savePath: String = ""
    var addPaused: Bool = false

    func appliesTo(feedURL: String) -> Bool {
        affectedFeedURLs.isEmpty || affectedFeedURLs.contains(feedURL)
    }

    func matches(_ title: String) -> Bool {
        guard enabled else { return false }
        if useRegex {
            if !mustContain.isEmpty, !regexMatch(mustContain, in: title) { return false }
            if !mustNotContain.isEmpty, regexMatch(mustNotContain, in: title) { return false }
            return true
        }
        let lower = title.lowercased()
        for term in tokens(mustContain) where !lower.contains(term) { return false }
        for term in tokens(mustNotContain) where lower.contains(term) { return false }
        return true
    }

    private func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    private func regexMatch(_ pattern: String, in text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}
