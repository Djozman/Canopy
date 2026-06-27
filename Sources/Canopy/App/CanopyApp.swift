import SwiftUI

@main
struct CanopyApp: App {
    @StateObject private var engine: EngineSession
    @StateObject private var rss: RSSManager
    @StateObject private var search: SearchManager

    init() {
        let settings = AppSettings.load()
        let engineObj = EngineSession(settings: settings)
        let rssObj = RSSManager()
        rssObj.onDownload = { url, category, savePath, paused in
            engineObj.addFromRemote(url, category: category, savePath: savePath, paused: paused)
        }
        _engine = StateObject(wrappedValue: engineObj)
        _rss = StateObject(wrappedValue: rssObj)
        _search = StateObject(wrappedValue: SearchManager())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(rss)
                .environmentObject(search)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear {
                    engine.start()
                    rss.startAutoRefresh()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("RSS", id: "rss") {
            RSSView()
                .environmentObject(rss)
                .environmentObject(engine)
                .frame(minWidth: 760, minHeight: 460)
        }

        Window("Search", id: "search") {
            SearchView()
                .environmentObject(search)
                .environmentObject(engine)
                .frame(minWidth: 760, minHeight: 480)
        }

        Window("Statistics", id: "stats") {
            StatisticsView()
                .environmentObject(engine)
        }

        Window("Log", id: "log") {
            LogView()
        }

        Settings {
            PreferencesView()
                .environmentObject(engine)
        }
    }
}
