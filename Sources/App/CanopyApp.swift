// CanopyApp.swift — app entry point

import SwiftUI

@main
struct CanopyApp: App {
    @StateObject private var engine = TorrentEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .environmentObject(engine)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Torrent\u{2026}") {
                    NotificationCenter.default.post(name: .openAddTorrent, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "magnet" {
            engine.addMagnetLink(url.absoluteString, saveTo: defaultSavePath)
        } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            engine.addTorrentFile(at: url.path, saveTo: defaultSavePath)
        }
    }

    private var defaultSavePath: String {
        NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true)
            .first ?? NSHomeDirectory() + "/Downloads"
    }
}

extension Notification.Name {
    static let openAddTorrent = Notification.Name("OpenAddTorrent")
}
