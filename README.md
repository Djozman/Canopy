# Canopy v2.0.5

A native macOS BitTorrent client built with SwiftUI and libtorrent-rasterbar.

<p align="center">
  <img src="Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.icns" width="128" alt="Canopy icon">
</p>

## Features

- **Native macOS SwiftUI** — 3-column NavigationSplitView with sidebar, list, and detail panels
- **Real libtorrent engine** — Full BitTorrent v1/v2 support via an Objective-C++ bridge to libtorrent-rasterbar 2.x
- **Pre-add file selection** — Parse `.torrent` files before adding; select/deselect files, set per-file priorities, choose save path
- **Magnet metadata fetch** — Fetch file lists from magnet links before downloading; file selection sheet shows before any data is downloaded
- **Magnet link handler** — Click magnet links in your browser and they open directly in Canopy with the pre-add sheet
- **Default torrent handler** — Canopy registers as the default app for `.torrent` files and `magnet:` URLs
- **File tree browser** — Expandable folders, tri-state checkboxes, sort by name/size, live progress bars, per-file priority picker
- **Category filters** — Sidebar with live counts: All, Downloading, Seeding, Paused, Finished, Errored
- **Full context menu** — Pause, resume, recheck, reannounce, remove (with/without data), copy hash, open folder
- **Preferences** — Speed limits, queue settings, DHT/LSD/UPnP/NAT-PMP toggles, listen port, anonymous mode
- **Live status bar** — Aggregate download/upload rates, torrent count
- **In-app updates** — Checks GitHub releases on launch; one-click download and install with automatic relaunch
- **Single instance** — Only one Canopy instance runs at a time; URL opens reuse the existing window
- **Build with SPM** — `swift run` builds and launches; no Xcode required

## Quick Start

```bash
# 1. Install dependencies (2 Homebrew packages)
brew install libtorrent-rasterbar boost

# 2. Clone
git clone https://github.com/Djozman/Canopy.git
cd Canopy

# 3. Build & run
swift run
```

Or download the latest DMG from [Releases](https://github.com/Djozman/Canopy/releases).

> **Note on first launch:** Right-click Canopy.app → Open to bypass Gatekeeper (not notarized yet).

## Project Structure

```
Sources/
├── App/
│   └── CanopyApp.swift              # @main entry point, URL handler, AppDelegate
├── Engine/
│   ├── TorrentEngine.swift          # @MainActor ObservableObject session wrapper
│   └── Bridge/
│       └── ObjC/
│           ├── LibtorrentWrapper.h  # Pure ObjC header (Swift-visible)
│           └── LibtorrentWrapper.mm # C++/ObjC++ implementation
├── Models/
│   ├── FileNode.swift               # Recursive tree node for file browser
│   ├── MockData.swift               # Sample data for UI prototyping
│   └── PendingTorrent.swift         # Pre-add file metadata holder
├── ViewModels/
│   ├── FileTreeViewModel.swift      # Builds/sorts/patches the file tree
│   ├── TorrentListViewModel.swift   # Filter/search/aggregate logic
│   └── UpdateChecker.swift          # GitHub release poller, DMG download/install
├── Views/
│   ├── ContentView.swift            # Root NavigationSplitView, PreAddSheet window
│   ├── SidebarView.swift            # Category filter sidebar
│   ├── TorrentRowView.swift         # List row with progress bar
│   ├── TorrentDetailView.swift      # Tabs: General, Trackers, Peers, Files, Content
│   ├── AddTorrentSheet.swift        # Magnet URI + .torrent file picker
│   ├── PreAddSheet.swift            # Pre-add file selection window
│   ├── FilesTab.swift               # Recursive file tree with checkboxes
│   ├── SettingsView.swift           # Preferences (speed, queue, connection)
│   ├── StatusBarView.swift          # Bottom bar with total download/upload rates
│   └── Helpers.swift                # formatBytes, formatSpeed, formatETA, colors
└── Assets.xcassets/
    └── AppIcon.appiconset/          # App icon
```

## Architecture

```
┌──────────────────────────────────────────┐
│              SwiftUI Views               │
│  ContentView, FilesTab, PreAddSheet…     │
├──────────────────────────────────────────┤
│            TorrentEngine                 │
│  @MainActor ObservableObject             │
│  - Polls libtorrent every 0.5s           │
│  - Drains alerts every 0.2s              │
│  - Parses torrents pre-add               │
│  - Magnet metadata mode                  │
│  - Manages pending removals              │
├──────────────────────────────────────────┤
│     ClibtorrentBridge (ObjC++)           │
│  LibtorrentWrapper.h / .mm               │
│  - LTTorrentHandle: per-torrent API      │
│  - LibtorrentSession: session lifecycle  │
│  - Pure ObjC header → Swift can import   │
├──────────────────────────────────────────┤
│     libtorrent-rasterbar 2.x             │
│  (Homebrew, C++17, Boost)                │
└──────────────────────────────────────────┘
```

The bridge uses the Objective-C++ pattern: the `.h` header is pure Objective-C (readable by Swift), while the `.mm` implementation contains all C++ logic and libtorrent headers. No manual C struct conversion or `UnsafeMutableRawPointer` in Swift.

## Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| libtorrent-rasterbar | Homebrew | BitTorrent protocol engine (C++17) |
| Boost | Homebrew | Required by libtorrent headers |

Runtime dependencies: macOS 15+ only. No other package managers or frameworks needed.

## Development

```bash
swift build                    # compile
swift run                      # build & launch
swift build -c release         # release build
open Canopy.app                # launch the built app bundle
```

To create a DMG for distribution:

```bash
swift build -c release
cp .build/arm64-apple-macosx/release/Canopy Canopy.app/Contents/MacOS/Canopy
xattr -cr Canopy.app && codesign --force --sign - Canopy.app
create-dmg --volname "Canopy v2.0.5" \\
  --window-pos 400 200 --window-size 660 500 --icon-size 128 \\
  --icon "Canopy.app" 160 190 --app-drop-link 500 190 \\
  Canopy-2.0.5.dmg Canopy.app
```
