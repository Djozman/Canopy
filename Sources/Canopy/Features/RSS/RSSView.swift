import SwiftUI

struct RSSView: View {
    @EnvironmentObject var rss: RSSManager
    @EnvironmentObject var engine: EngineSession

    @State private var selectedFeed: UUID?
    @State private var showAddFeed = false
    @State private var newFeedURL = ""
    @State private var showRules = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedFeed) {
                Section("Feeds") {
                    ForEach(rss.feeds) { feed in
                        HStack {
                            Label(feed.displayTitle, systemImage: "dot.radiowaves.up.forward")
                                .lineLimit(1)
                            Spacer()
                            if feed.unreadCount > 0 {
                                Text("\(feed.unreadCount)")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .tag(feed.id)
                        .contextMenu {
                            Button("Refresh") { Task { await rss.refresh(feedID: feed.id) } }
                            Button("Mark All Read") { rss.markAllRead(in: feed.id) }
                            Divider()
                            Button("Remove Feed", role: .destructive) { rss.removeFeed(feed.id) }
                        }
                    }
                }
            }
            .frame(minWidth: 200)
            .toolbar {
                ToolbarItemGroup {
                    Button { showAddFeed = true } label: { Label("Add Feed", systemImage: "plus") }
                    Button { showRules = true } label: { Label("Rules", systemImage: "slider.horizontal.3") }
                    Button { Task { await rss.refreshAll() } } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                    .disabled(rss.isRefreshing)
                }
            }
        } detail: {
            articleList
        }
        .sheet(isPresented: $showAddFeed) { addFeedSheet }
        .sheet(isPresented: $showRules) { RSSRulesView().environmentObject(rss).environmentObject(engine) }
        .navigationTitle("RSS")
    }

    @ViewBuilder
    private var articleList: some View {
        if let id = selectedFeed, let feed = rss.feeds.first(where: { $0.id == id }) {
            if feed.articles.isEmpty {
                ContentUnavailableView2(title: "No Articles", systemImage: "tray",
                                        message: "Refresh the feed to load articles.")
            } else {
                List {
                    ForEach(feed.articles) { article in
                        articleRow(article, feedID: id)
                    }
                }
            }
        } else {
            ContentUnavailableView2(title: "Select a Feed", systemImage: "dot.radiowaves.up.forward",
                                    message: "Choose a feed to see its articles.")
        }
    }

    private func articleRow(_ article: RSSArticle, feedID: UUID) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .fontWeight(article.isRead ? .regular : .semibold)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let d = article.date {
                        Text(d, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    if article.isDownloaded {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
            Spacer()
            if article.torrentURL != nil || article.link.hasPrefix("magnet:") {
                Button {
                    rss.download(article, in: feedID)
                } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .help("Download")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { rss.markRead(article.id, in: feedID) }
        .contextMenu {
            if article.torrentURL != nil || article.link.hasPrefix("magnet:") {
                Button("Download") { rss.download(article, in: feedID) }
            }
            Button(article.isRead ? "Mark Unread" : "Mark Read") {
                rss.markRead(article.id, in: feedID, read: !article.isRead)
            }
            if let url = URL(string: article.link), !article.link.isEmpty {
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var addFeedSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add RSS Feed").font(.title2.bold())
            TextField("https://example.com/feed.xml", text: $newFeedURL)
                .textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { showAddFeed = false; newFeedURL = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    rss.addFeed(newFeedURL)
                    newFeedURL = ""
                    showAddFeed = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newFeedURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 150)
    }
}

/// Minimal stand-in for ContentUnavailableView (keeps a wide deployment range).
struct ContentUnavailableView2: View {
    let title: String
    let systemImage: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
