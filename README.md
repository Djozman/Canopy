# Canopy

A native BitTorrent client for macOS, built with SwiftUI and powered by
libtorrent-rasterbar.

Canopy keeps the interface small and Mac-native while exposing the controls that
matter: magnet links, `.torrent` files, file priorities, live transfer details,
peers, trackers, piece progress, queue limits, and persistent sessions.

> **Version 3.1.0** — rename torrents before install, plus the
> qBittorrent-inspired transfer workspace, reliable downloads, persistent
> sessions, and Homebrew libtorrent 2.x compatibility.

## Highlights

- **qBittorrent-inspired native interface** — compact transfer columns, status
  filters, a draggable lower inspector, aggregate speed bar, keyboard shortcuts,
  light/dark mode, and native macOS controls.
- **libtorrent 2.x engine** — BitTorrent v1/v2, DHT, LSD, UPnP, NAT-PMP,
  trackers, peers, recheck, and reannounce.
- **Safe pre-add flow** — inspect files, choose a destination, skip files, and
  set priorities before payload data is downloaded.
- **Rename before install** — rename the root folder, any subfolder, or any
  file on the pre-add screen; downloaded content lands under the new names.
- **Reliable magnet handling** — metadata is fetched without pausing the
  torrent, payload transfer remains disabled until confirmation, and stalled
  metadata requests time out cleanly.
- **Persistent sessions** — atomic resume-data snapshots restore torrents and
  progress after relaunch.
- **Live detail views** — transfer statistics, tracker state, connected peers,
  recursive files, and an adaptive piece map.
- **Real preferences** — speed limits, queue limits, listen port, discovery,
  port mapping, anonymous mode, and default save location are applied to
  libtorrent.
- **Browser integration** — registers for `magnet:` links and `.torrent`
  documents.

## Interface

Canopy 3.1.0 uses a dense transfer-management layout inspired by qBittorrent
while remaining a native SwiftUI macOS app:

- The top-left brand panel shows the Canopy logo and exact `3.1.0` version.
- The sidebar filters transfer states and displays live counts.
- The table keeps progress, state, swarm counts, speeds, ETA, and ratio visible.
- A draggable lower inspector exposes General, Trackers, Peers, Files, and Pieces.
- The toolbar provides add, pause/resume, remove, reannounce, update, and settings.
- The bottom status bar shows aggregate download and upload rates.

The first window opens at `1220 × 760` points and remains fully resizable.

### Controls

| Action | Control |
| --- | --- |
| Add torrent | `⌘N` |
| Select transfer | Click a row |
| Transfer actions | Right-click a row |
| Filter transfers | Choose a sidebar status |
| Search | Use **Filter torrent list** |
| Resize inspector | Drag the horizontal divider |

## Requirements

| Requirement              | Version                  |
| ------------------------ | ------------------------ |
| macOS                    | 14 Sonoma or newer       |
| Xcode command-line tools | Swift 5.10 or newer      |
| libtorrent-rasterbar     | Homebrew 2.x             |
| Boost                    | Current Homebrew release |

Apple Silicon and Intel Homebrew prefixes are supported. SwiftPM reads the
installed `libtorrent-rasterbar.pc` file through `pkg-config`, ensuring the
headers and linked library use the same ABI flags on local Macs and GitHub
Actions. An installed development build may still depend on Homebrew unless the
distribution bundle packages those libraries.

## Install and run from source

```bash
xcode-select --install
brew install libtorrent-rasterbar boost

git clone https://github.com/Djozman/Canopy.git
cd Canopy
swift run
```

For an optimized build:

```bash
swift build -c release
```

## Build a macOS app bundle

The repository includes a bundle script:

```bash
./build_app.sh
open Canopy.app
```

The generated app is ad-hoc and not notarized. On first launch, macOS may
require **Control-click → Open**.

For a distributable ZIP and DMG with Homebrew runtime libraries bundled inside
the app, run:

```bash
./package_release.sh
```

Release files are written to `dist/`. The package is ad-hoc signed; public
releases should eventually use a Developer ID certificate and notarization.

## Publish version 3.1.0 with GitHub Actions

The release workflow runs when the `v3.1.0` tag is pushed. It verifies both
bundle versions, runs the tests, builds the app, bundles libtorrent and OpenSSL,
creates ZIP and DMG packages, generates SHA-256 checksums, and publishes a
GitHub Release.

```bash
git switch main
git pull --ff-only
git status
swift test
git push origin main
git tag -a v3.1.0 -m "Canopy 3.1.0"
git push origin v3.1.0
```

Monitor the **Release** workflow in the repository's Actions tab. When it
finishes, the GitHub Releases page contains the ZIP, DMG, and checksum file.
If the tag must be corrected before a release is published, delete it locally
and remotely, fix the commit, and create the tag again.

## Using Canopy

### Add a magnet link

1. Press **⌘N** or click **Add Torrent**.
2. Paste one or more magnet links.
3. Wait for metadata, then choose files and priorities.
4. Select a destination and click **Add Torrent**.

Canopy fetches metadata in `upload_mode`, which prevents payload pieces from
downloading before confirmation. A 45-second timeout reports unreachable or
invalid magnets instead of leaving an endless spinner.

### Add a `.torrent` file

Choose **.torrent file** in the add window, select the file, review its
contents, and confirm the destination. Missing destination directories are
created automatically.

### Manage transfers

Right-click a torrent to pause, resume, recheck, reannounce, remove it, copy its
info hash, or open its destination. Removing a torrent without data now
preserves downloaded files; **Remove torrent + data** explicitly deletes payload
data.

## Architecture

```text
┌──────────────────────────────────────────────────────┐
│ SwiftUI                                              │
│ Sidebar · torrent list · details · files · settings │
├──────────────────────────────────────────────────────┤
│ TorrentEngine (@MainActor)                           │
│ Immutable status snapshots · serial engine queue     │
│ metadata coordination · polling · persistence        │
├──────────────────────────────────────────────────────┤
│ ClibtorrentBridge (Objective-C++)                    │
│ Swift-safe API · session · handles · alerts          │
├──────────────────────────────────────────────────────┤
│ libtorrent-rasterbar 2.x                             │
└──────────────────────────────────────────────────────┘
```

The public bridge header contains only Objective-C types, so Swift imports it
directly. All C++ and libtorrent types stay in `LibtorrentWrapper.mm`. Session
operations are serialized on a utility queue; SwiftUI receives immutable
snapshots on the main actor.

## Project layout

```text
Sources/
├── App/CanopyApp.swift
├── Engine/
│   ├── TorrentEngine.swift
│   └── Bridge/ObjC/
│       ├── include/LibtorrentWrapper.h
│       └── LibtorrentWrapper.mm
├── Models/
├── ViewModels/
├── Views/
├── Assets.xcassets/
└── Info.plist
Tests/
Package.swift
build_app.sh
```

## Reliability changes in 3.0.0

- Fixed metadata-only magnets being paused, which prevented tracker/DHT
  discovery and caused downloads to remain stuck.
- Added destination creation and validation before adding torrents or committing
  magnets.
- Added magnet failure reporting and a bounded metadata timeout.
- Fixed removal flags so “torrent only” no longer deletes libtorrent’s part file
  or user data.
- Added v1 and v2 hash handling when tracking removals and resume files.
- Made resume snapshots periodic and atomic, with a bounded shutdown wait.
- Removed invalid handles before publishing torrent snapshots.
- Made the piece map read fresh status rather than stale cached state.
- Connected the Settings UI to the actual libtorrent session.
- Fixed the global **⌘N** command and add-window error presentation.
- Fixed unsafe Objective-C array casting in file progress updates.
- Preserved multi-magnet metadata that arrives before its window is ready.
- Corrected release builds, deployment targets, bundle identifiers, and version
  metadata.
- Rebuilt the main window as a qBittorrent-inspired workspace with a branded
  sidebar, dense transfer table, draggable inspector, and aggregate status bar.
- Added the Canopy logo and exact 3.0.0 version to the top-left brand panel. In
  3.1.0 that badge reads 3.1.0.
- Removed the hard-coded libtorrent ABI. SwiftPM now consumes the exact compiler
  and linker flags from the installed `libtorrent-rasterbar.pc`, preventing
  namespace mismatches across macOS 14, macOS 15, and local Homebrew bottles.
- Added tag-driven release CI that tests, bundles runtime libraries, produces
  ZIP and DMG packages, and publishes SHA-256 checksums.
- Updated interface naming, adaptive piece grid, empty states, and settings.

## Development

```bash
swift test
swift build
swift build -c release
```

The GitHub Actions workflow tests and builds on macOS 14 and macOS 15.

### Bridge rules

- Keep `LibtorrentWrapper.h` free of C++ types and libtorrent headers.
- Access the session through `TorrentEngine` rather than directly from views.
- Perform session mutations on the engine’s serial queue.
- Publish UI state on the main actor.
- Never broaden “remove torrent” into data deletion without explicit user
  intent.

## Troubleshooting

### `libtorrent` headers or library not found

```bash
brew reinstall libtorrent-rasterbar boost
brew --prefix libtorrent-rasterbar
brew --prefix boost
```

If Homebrew is installed in a nonstandard location, export `HOMEBREW_PREFIX`
before building.

### Magnet metadata does not arrive

Confirm the magnet contains a valid `xt=urn:btih:` or `xt=urn:btmh:` value and
that DHT or at least one reachable tracker is available. Canopy reports a
timeout instead of downloading payload data blindly.

### App does not open after building

```bash
xattr -cr Canopy.app
codesign --force --deep --sign - Canopy.app
open Canopy.app
```

### Downloads do not resume after relaunch

Resume data is stored under:

```text
~/Library/Application Support/Canopy/Resume/
```

Check that the download destination still exists and is writable.

## Security and privacy

Torrent traffic reveals network information to peers and trackers by design.
Anonymous mode adjusts libtorrent behavior but is not a VPN and does not make
BitTorrent activity anonymous. Download only content you are authorized to
access.

## Contributing

Bug reports and pull requests are welcome. Include the macOS version, Mac
architecture, libtorrent version, steps to reproduce, and relevant Console logs
prefixed with `[Canopy]`.

## License

No license file is currently included. All rights remain with the repository
owner unless a license is added.
