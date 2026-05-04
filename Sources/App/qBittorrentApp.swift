// qBittorrentApp.swift — app entry point

import SwiftUI

@main
struct QBittorrentApp: App {
    @StateObject private var engine = TorrentEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .environmentObject(engine)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Torrent…") {
                    NotificationCenter.default.post(name: .openAddTorrent, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openAddTorrent = Notification.Name("OpenAddTorrent")
}
