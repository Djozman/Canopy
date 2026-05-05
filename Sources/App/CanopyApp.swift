// CanopyApp.swift — app entry point

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .incomingURL, object: url)
        }
    }
}

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = TorrentEngine()

    init() {
        claimDefaultHandlers()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .environmentObject(engine)
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
    static let incomingURL = Notification.Name("IncomingURL")
}
