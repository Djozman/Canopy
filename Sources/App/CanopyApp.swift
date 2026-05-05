// CanopyApp.swift — app entry point

import SwiftUI
import AppKit
import ClibtorrentBridge

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// De-duplicate URL openings. macOS sometimes calls open(urls:) twice in
    /// rapid succession for the same magnet (e.g. when LaunchServices is
    /// confused), and apps that just register multiple times can also hit
    /// this. We reject duplicate URLs that arrive within a 2 s window.
    private var recentURLs: [(url: URL, at: Date)] = []
    private let dedupeWindow: TimeInterval = 2.0

    func application(_ application: NSApplication, open urls: [URL]) {
        let now = Date()
        recentURLs.removeAll { now.timeIntervalSince($0.at) > dedupeWindow }
        for url in urls {
            if recentURLs.contains(where: { $0.url == url }) {
                NSLog("[Canopy] dedupe: ignoring duplicate URL \(url.absoluteString.prefix(80))")
                continue
            }
            recentURLs.append((url, now))
            CanopyApp.handleIncomingURL(url)
        }
        // Always reactivate the existing instance so macOS doesn't spawn
        // another window — and bring the main window to front.
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            win.makeKeyAndOrderFront(nil)
        }
    }

    /// Dock-icon click / Reopen → bring existing main window forward instead
    /// of showing the launch window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let win = NSApp.windows.first(where: { $0.canBecomeMain }) {
            win.makeKeyAndOrderFront(nil)
            return false
        }
        return true
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
