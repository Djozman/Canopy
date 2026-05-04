# qBittorrent — SwiftUI + libtorrent

A native macOS SwiftUI frontend for qBittorrent, backed by libtorrent-rasterbar via a C bridge.

## Project structure

```
Sources/
├── App/
│   └── qBittorrentApp.swift          # @main entry point
├── Engine/
│   ├── TorrentEngine.swift           # Swift session wrapper + Combine publisher
│   └── Bridge/
│       ├── libtorrent_bridge.h       # C API header (imported by Swift)
│       ├── libtorrent_bridge.cpp     # C++ implementation
│       ├── QBridgingHeader.h         # Xcode bridging header
│       └── README_BRIDGE.md          # Detailed setup instructions
├── Models/
│   └── MockData.swift                # Sample data for UI prototyping
├── ViewModels/
│   └── TorrentListViewModel.swift    # Filter / search / aggregate logic
└── Views/
    ├── ContentView.swift             # Root NavigationSplitView
    ├── Helpers.swift                 # formatBytes / formatSpeed / colors
    ├── SidebarView.swift             # Category filter sidebar
    ├── TorrentRowView.swift          # List row with progress bar
    ├── TorrentDetailView.swift       # Tabs: General / Trackers / Peers / Files / Pieces
    ├── AddTorrentSheet.swift         # Add via magnet or .torrent file
    ├── SettingsView.swift            # Preferences (speed, queue, connection)
    └── StatusBarView.swift           # Bottom bar: total ↓↑ rates
```

## Quick start (mock UI only)

1. Create a new **macOS App** target in Xcode (SwiftUI, Swift).
2. Add all `.swift` files to the target.
3. Set the **minimum deployment target** to macOS 14+.
4. Build & run — the prototype runs entirely on mock data.

## Wiring up the real engine

See `Sources/Engine/Bridge/README_BRIDGE.md` for full libtorrent setup.

```bash
brew install libtorrent-rasterbar
```

Then add `libtorrent_bridge.cpp` to Compile Sources and configure Xcode build settings as described in the bridge README.

## Features implemented

- [x] 3-column NavigationSplitView (sidebar / list / detail)
- [x] Category filter sidebar with live counts
- [x] Per-torrent row: name, progress bar, speed, ETA, seeds/peers, ratio
- [x] Detail tabs: General, Trackers, Peers, Files, Piece map
- [x] Add torrent sheet (magnet URI + .torrent file picker)
- [x] Right-click context menu: pause/resume/recheck/remove/copy hash
- [x] Preferences sheet (speed limits, queue, connection flags)
- [x] Status bar: aggregate download/upload rate
- [x] C bridge: full libtorrent session, torrent, file, tracker, peer, alert, resume-data API
- [ ] Real engine wiring (swap MockData — see bridge README)
- [ ] Notifications for finished torrents
- [ ] Search-engine plugin support
- [ ] RSS feed manager
