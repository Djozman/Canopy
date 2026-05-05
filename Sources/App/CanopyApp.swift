// CanopyApp.swift — app entry point

import SwiftUI
import AppKit
import ClibtorrentBridge

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            CanopyApp.handleIncomingURL(url)
        }
    }
}

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let engine = TorrentEngine()
    @State var pendingPreAdd: PendingTorrent?
    @State var pendingMagnetHandle: LTTorrentHandle?

    init() {
        CanopyApp.engine = engine
        claimDefaultHandlers()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .environmentObject(engine)
                .onAppear {
                    if let p = pendingPreAdd {
                        pendingPreAdd = nil
                        let h = pendingMagnetHandle
                        pendingMagnetHandle = nil
                        NotificationCenter.default.post(
                            name: .showPreAdd, object: nil,
                            userInfo: ["pending": p, "handle": h as Any]
                        )
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .showPreAdd)) { notif in
                    // handled by ContentView's own onReceive
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

    static var engine: TorrentEngine!

    static func handleIncomingURL(_ url: URL) {
        let saveDir = NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true)
            .first ?? NSHomeDirectory() + "/Downloads"

        if url.scheme == "magnet" {
            var name = url.absoluteString
            if let comps = URLComponents(string: url.absoluteString),
               let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value {
                name = dn
            }
            // Show PreAddSheet immediately with spinner while fetching
            let pending = PendingTorrent(
                source: .magnet(uri: url.absoluteString),
                name: name, totalSize: 0, savePath: saveDir, files: []
            )
            NotificationCenter.default.post(
                name: .showPreAdd, object: nil,
                userInfo: ["pending": pending, "handle": NSNull(), "fetching": true]
            )
            // Start metadata fetch in background
            var magnetHandle: LTTorrentHandle?
            magnetHandle = engine.fetchMetadata(
                uri: url.absoluteString,
                onFiles: { files in
                    let newPending = PendingTorrent(
                        source: .magnet(uri: url.absoluteString),
                        name: name,
                        totalSize: files.reduce(0) { $0 + $1.size },
                        savePath: saveDir,
                        files: files
                    )
                    NotificationCenter.default.post(
                        name: .showPreAdd, object: nil,
                        userInfo: ["pending": newPending, "handle": magnetHandle as Any]
                    )
                },
                onError: {}
            )
        } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            if let pending = engine.parse(torrentPath: url.path) {
                var p = pending
                p.savePath = saveDir
                NotificationCenter.default.post(
                    name: .showPreAdd, object: nil,
                    userInfo: ["pending": p, "handle": NSNull()]
                )
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
