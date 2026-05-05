// CanopyApp.swift — app entry point

import SwiftUI
import AppKit

@main
struct CanopyApp: App {
    @StateObject private var engine = TorrentEngine()
    @State private var pendingURL: URL?

    init() {
        claimDefaultHandlers()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .environmentObject(engine)
                .onOpenURL { url in
                    pendingURL = url
                }
                .onAppear {
                    if let url = pendingURL {
                        handleIncomingURL(url)
                        pendingURL = nil
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
                    if let url = pendingURL {
                        handleIncomingURL(url)
                        pendingURL = nil
                    }
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
        let saveDir = NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true)
            .first ?? NSHomeDirectory() + "/Downloads"

        if url.scheme == "magnet" {
            let handle = engine.fetchMetadata(
                uri: url.absoluteString,
                onFiles: { files in
                    var name = url.absoluteString
                    if let comps = URLComponents(string: url.absoluteString),
                       let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value {
                        name = dn
                    }
                    let pending = PendingTorrent(
                        source: .magnet(uri: url.absoluteString),
                        name: name,
                        totalSize: files.reduce(0) { $0 + $1.size },
                        savePath: saveDir,
                        files: files
                    )
                    NotificationCenter.default.post(name: .showPreAdd, object: pending, userInfo: ["handle": handle as Any])
                },
                onError: {}
            )
        } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            if let pending = engine.parse(torrentPath: url.path) {
                var p = pending
                p.savePath = saveDir
                NotificationCenter.default.post(name: .showPreAdd, object: p, userInfo: ["handle": NSNull()])
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
    static let showPreAdd = Notification.Name("ShowPreAdd")
}
