import Foundation
import Combine

/// Manages RSS feeds, their articles, and auto-download rules.
/// Networking happens at runtime via URLSession; matched articles are handed
/// to `onDownload` which the app wires to the torrent engine.
@MainActor
final class RSSManager: ObservableObject {
    @Published private(set) var feeds: [RSSFeed] = []
    @Published private(set) var rules: [RSSRule] = []
    @Published private(set) var isRefreshing = false

    /// (url, category, savePath, paused). Set by the app to add to the engine.
    var onDownload: ((String, String, String?, Bool) -> Void)?

    private let storeURL: URL
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 30 * 60

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Canopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("rss.json")
        load()
    }

    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
        Task { await refreshAll() }
    }

    // MARK: - Feeds

    func addFeed(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !feeds.contains(where: { $0.url == trimmed }) else { return }
        let feed = RSSFeed(url: trimmed)
        feeds.append(feed)
        save()
        Task { await refresh(feedID: feed.id) }
    }

    func removeFeed(_ id: UUID) {
        feeds.removeAll { $0.id == id }
        save()
    }

    func markRead(_ articleID: String, in feedID: UUID, read: Bool = true) {
        guard let fi = feeds.firstIndex(where: { $0.id == feedID }),
              let ai = feeds[fi].articles.firstIndex(where: { $0.id == articleID }) else { return }
        feeds[fi].articles[ai].isRead = read
        save()
    }

    func markAllRead(in feedID: UUID) {
        guard let fi = feeds.firstIndex(where: { $0.id == feedID }) else { return }
        for i in feeds[fi].articles.indices { feeds[fi].articles[i].isRead = true }
        save()
    }

    // MARK: - Refresh

    func refreshAll() async {
        let ids = feeds.map { $0.id }
        isRefreshing = true
        for id in ids { await refresh(feedID: id) }
        isRefreshing = false
    }

    func refresh(feedID: UUID) async {
        guard let feed = feeds.first(where: { $0.id == feedID }),
              let url = URL(string: feed.url) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = FeedParser().parse(data)
            apply(parsed: parsed, toFeedID: feedID)
        } catch {
            NSLog("RSS refresh failed for \(feed.url): \(error.localizedDescription)")
        }
    }

    private func apply(parsed: (title: String, articles: [RSSArticle]), toFeedID id: UUID) {
        guard let fi = feeds.firstIndex(where: { $0.id == id }) else { return }
        let existingIDs = Set(feeds[fi].articles.map { $0.id })
        let newOnes = parsed.articles.filter { !existingIDs.contains($0.id) }
        feeds[fi].articles = newOnes + feeds[fi].articles
        if feeds[fi].title.isEmpty, !parsed.title.isEmpty { feeds[fi].title = parsed.title }
        feeds[fi].lastRefresh = Date()
        let feedURL = feeds[fi].url
        save()
        applyRules(to: newOnes, feedID: id, feedURL: feedURL)
    }

    // MARK: - Rules

    func addRule(_ rule: RSSRule) { rules.append(rule); save() }
    func updateRule(_ rule: RSSRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule; save() }
    }
    func removeRule(_ id: UUID) { rules.removeAll { $0.id == id }; save() }

    private func applyRules(to articles: [RSSArticle], feedID: UUID, feedURL: String) {
        guard !articles.isEmpty else { return }
        for article in articles {
            for rule in rules where rule.appliesTo(feedURL: feedURL) && rule.matches(article.title) {
                download(article, in: feedID,
                         category: rule.assignCategory,
                         savePath: rule.savePath.isEmpty ? nil : rule.savePath,
                         paused: rule.addPaused)
                break   // first matching rule wins
            }
        }
    }

    // MARK: - Download

    func download(_ article: RSSArticle, in feedID: UUID,
                  category: String = "", savePath: String? = nil, paused: Bool = false) {
        guard let target = article.torrentURL ?? (article.link.hasPrefix("magnet:") ? article.link : nil) else { return }
        onDownload?(target, category, savePath, paused)
        if let fi = feeds.firstIndex(where: { $0.id == feedID }),
           let ai = feeds[fi].articles.firstIndex(where: { $0.id == article.id }) {
            feeds[fi].articles[ai].isDownloaded = true
            feeds[fi].articles[ai].isRead = true
            save()
        }
    }

    // MARK: - Persistence

    private struct Store: Codable { var feeds: [RSSFeed]; var rules: [RSSRule] }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return }
        feeds = s.feeds
        rules = s.rules
    }

    private func save() {
        let s = Store(feeds: feeds, rules: rules)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

// MARK: - Feed parsing (RSS 2.0 + Atom)

final class FeedParser: NSObject, XMLParserDelegate {
    private var articles: [RSSArticle] = []
    private var feedTitle = ""

    private var inItem = false
    private var element = ""
    private var text = ""

    private var curTitle = ""
    private var curLink = ""
    private var curGUID = ""
    private var curDate = ""
    private var curEnclosure: String?
    private var curAtomHref: String?

    func parse(_ data: Data) -> (title: String, articles: [RSSArticle]) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return (feedTitle, articles)
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attrs: [String: String]) {
        element = name
        text = ""
        let lower = name.lowercased()
        if lower == "item" || lower == "entry" {
            inItem = true
            curTitle = ""; curLink = ""; curGUID = ""; curDate = ""
            curEnclosure = nil; curAtomHref = nil
        } else if lower == "enclosure" {
            if let u = attrs["url"] { curEnclosure = u }
        } else if lower == "link" {
            // Atom: <link href="..." rel="..."/>
            if let href = attrs["href"] {
                let rel = attrs["rel"] ?? "alternate"
                if rel == "alternate" || curAtomHref == nil { curAtomHref = href }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let lower = name.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "title":
            if inItem { curTitle = value } else if feedTitle.isEmpty { feedTitle = value }
        case "link":
            if inItem, !value.isEmpty { curLink = value }
        case "guid", "id":
            if inItem { curGUID = value }
        case "pubdate", "published", "updated", "dc:date", "date":
            if inItem, curDate.isEmpty { curDate = value }
        case "item", "entry":
            let link = !curLink.isEmpty ? curLink : (curAtomHref ?? "")
            let torrent = curEnclosure ?? (isTorrentLike(link) ? link : curAtomHref)
            let identifier = !curGUID.isEmpty ? curGUID : (!link.isEmpty ? link : curTitle)
            let article = RSSArticle(
                id: identifier,
                title: curTitle.isEmpty ? "(untitled)" : curTitle,
                link: link,
                torrentURL: torrent,
                date: FeedParser.parseDate(curDate)
            )
            articles.append(article)
            inItem = false
        default:
            break
        }
        text = ""
    }

    private func isTorrentLike(_ s: String) -> Bool {
        s.hasPrefix("magnet:") || s.lowercased().contains(".torrent")
    }

    private static let formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",      // RFC822
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",       // RFC3339
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }
}
