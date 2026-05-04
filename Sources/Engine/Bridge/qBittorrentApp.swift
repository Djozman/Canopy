import SwiftUI

@main
struct qBittorrentApp: App {
    @StateObject private var engine = TorrentEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
    }
}
