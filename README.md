# Canopy v2.0

A native macOS BitTorrent client built with SwiftUI and libtorrent-rasterbar.

<p align="center">
  <img src="Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.icns" width="128" alt="Canopy icon">
</p>

## Features

- **Native macOS SwiftUI** — 3-column NavigationSplitView with sidebar, list, and detail panels
- **Real libtorrent engine** — Full BitTorrent v1/v2 support via an Objective-C++ bridge to libtorrent-rasterbar 2.x
- **Pre-add file selection** — Parse `.torrent` files before adding, select/deselect files, set per-file priorities
- **Magnet metadata mode** — Fetch file lists from magnet links before adding; choose files before downloading starts
- **File tree browser** — Expandable folders, tri-state checkboxes, sort by name/size, live progress bars
- **Category filters** — Sidebar with live counts: All, Downloading, Seeding, Paused, Finished, Errored
- **Full context menu** — Pause, resume, recheck, reannounce, remove (with/without data), copy hash, open folder
- **Preferences** — Speed limits, queue settings, DHT/LSD/UPnP/NAT-PMP toggles, listen port, anonymous mode
- **Live status bar** — Aggregate download/upload rates, torrent count
- **Build with SPM** — No Xcode required: `swift run` builds and launches

## Quick Start

```bash
# 1. Install dependencies
brew install libtorrent-rasterbar boost

# 2. Clone
git clone https://github.com/Djozman/Canopy.git
cd Canopy

# 3. Build & run
swift run
```

## Project Structure

```
Sources/
├── App/
│   └── CanopyApp.swift              # @main entry point
├── Engine/
│   ├── TorrentEngine.swift          # ObservableObject session wrapper
│   └── Bridge/
│       └── ObjC/
│           ├── LibtorrentWrapper.h  # Pure ObjC header (Swift-visible)
│           └── LibtorrentWrapper.mm # C++/ObjC++ implementation
├── Models/
│   ├── FileNode.swift               # Tree node for file browser
│   ├── MockData.swift               # Sample data for UI prototyping
│   └── PendingTorrent.swift         # Pre-add file metadata holder
├── ViewModels/
│   ├── FileTreeViewModel.swift      # Builds/sorts/patches the file tree
│   └── TorrentListViewModel.swift   # Filter/search/aggregate logic
├── Views/
│   ├── ContentView.swift            # Root NavigationSplitView
│   ├── SidebarView.swift            # Category filter sidebar
│   ├── TorrentRowView.swift         # List row with progress bar
│   ├── TorrentDetailView.swift      # Tabs: General, Trackers, Peers, Files, Content
│   ├── AddTorrentSheet.swift        # Magnet URI + .torrent file picker
│   ├── PreAddSheet.swift            # Pre-add file selection window
│   ├── FilesTab.swift               # Recursive file tree with checkboxes
│   ├── SettingsView.swift           # Preferences (speed, queue, connection)
│   ├── StatusBarView.swift          # Bottom bar with total ↓↑ rates
│   └── Helpers.swift                # formatBytes, formatSpeed, formatETA, colors
└── Assets.xcassets/
    └── AppIcon.appiconset/          # App icon
```

## Architecture

```
┌──────────────────────────────────────────┐
│              SwiftUI Views               │
│  (ContentView, FilesTab, PreAddSheet…)   │
├──────────────────────────────────────────┤
│            TorrentEngine                 │
│  (@MainActor ObservableObject)           │
│  - Polls libtorrent every 0.5s          │
│  - Drains alerts every 0.2s             │
│  - Parses torrents pre-add              │
│  - Magnet metadata mode                 │
├──────────────────────────────────────────┤
│     ClibtorrentBridge (ObjC++)           │
│  LibtorrentWrapper.h / .mm              │
│  - LTTorrentHandle: per-torrent API     │
│  - LibtorrentSession: session lifecycle │
│  - Pure ObjC header → Swift can import  │
├──────────────────────────────────────────┤
│         libtorrent-rasterbar             │
│  (Homebrew, C++17, Boost)               │
└──────────────────────────────────────────┘
```

The bridge uses the Objective-C++ pattern: the `.h` header is pure Objective-C (readable by Swift), while the `.mm` implementation contains all C++ logic and libtorrent headers. No manual C struct conversion or `UnsafeMutableRawPointer` in Swift.

## Requirements

- macOS 15 (Sequoia) or later
- [Homebrew](https://brew.sh)
- libtorrent-rasterbar 2.x (`brew install libtorrent-rasterbar`)
- Boost (`brew install boost`)
- Swift 6.0+

## Development

```bash
swift build          # compile
swift run            # build & launch
swift build -c release  # release build
```
