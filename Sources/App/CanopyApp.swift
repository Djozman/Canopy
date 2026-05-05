// CanopyApp.swift — app entry point

import SwiftUI
import AppKit

@main
struct CanopyApp: App {
    @StateObject private var engine = TorrentEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .environmentObject(engine)
                .onAppear {
                    claimDefaultHandlers()
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

    private func claimDefaultHandlers() {
        let bundleID = "com.canopy.client"
        LSSetDefaultHandlerForURLScheme("magnet" as CFString, bundleID as CFString)
        LSSetDefaultRoleHandlerForContentType("org.bittorrent.torrent" as CFString, .all, bundleID as CFString)
    }
}

extension Notification.Name {
    static let openAddTorrent = Notification.Name("OpenAddTorrent")
}
