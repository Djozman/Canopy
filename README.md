# Canopy

A **native macOS BitTorrent client** written in SwiftUI, driving the **real
libtorrent engine** (libtorrent-rasterbar) through a thin Objective-C++ bridge.
No web UI, no separate server — the BitTorrent engine runs inside the app, with
full qBittorrent-style feature parity as the goal.

## Architecture

```
SwiftUI  →  EngineSession (Swift)  →  LibtorrentKit (Obj-C++ .mm)  →  libtorrent (C++)
```

- **LibtorrentKit** (`Sources/LibtorrentKit`) — Objective-C++ wrapper. Public
  headers are pure Obj-C (`LTSession`, `LTTorrentStats`, `LTFileEntry`, …); all
  libtorrent and Boost C++ types stay hidden inside `LTSession.mm`.
- **EngineSession** (`Sources/Canopy/Engine`) — the Swift session/domain layer
  that polls the engine, drains alerts, and republishes state to SwiftUI.
- **Features / Components** — the SwiftUI GUI (transfer list, filters, add sheet,
  files sheet, status bar).

## Requirements

- Apple Silicon Mac (arm64). For Intel, set `brewPrefix = "/usr/local"` in `Package.swift`.
- Xcode **Command Line Tools** (no full Xcode required).
- **libtorrent-rasterbar** installed via Homebrew:

```bash
brew install libtorrent-rasterbar
```

## Build & run

```bash
./scripts/build.sh --run            # debug build, wraps into build/Canopy.app, launches
./scripts/build.sh release --run    # optimized build
```

The script builds with SwiftPM (`swift build`), wraps the binary into a proper
`.app`, ad-hoc codesigns it, and (with `--run`) launches it.

## Status — Milestone E2 (engine foundation + persistence)

Working now:

- Real libtorrent session embedded in the app (DHT, LSD, UPnP, NAT-PMP on).
- Add by **magnet link** or **.torrent file**.
- **Alert pipeline** — add/metadata/resume-data alerts are drained each tick.
- **Resume-data persistence** — torrents are saved as `.fastresume` files under
  `~/Library/Application Support/Canopy/resume` and **reloaded on launch**, so
  your torrents (and progress) survive restarts. Saved every ~20s, on metadata
  arrival, and on quit.
- **Per-file priorities** — right-click a torrent → *Files…* to set each file to
  Do-not-download / Normal / High / Maximum.
- Live transfer list: name, size, progress, status, seeds/peers (+ swarm),
  down/up speed, ETA, ratio — sortable, multi-select.
- Resume / pause / force-recheck / remove (with or without data).
- Queue up/down/top/bottom, status filters sidebar, name search, status bar.
- Global download/upload rate limits and listen port.

## Roadmap to full qBittorrent parity

- **D1** — Torrent detail tabs: General, Trackers, Peers, Content/Files, Speed graph.
- **E3** — Categories & Tags, save-path rules, automatic torrent management, content layout.
- **P1** — Preferences (Behavior, Downloads, Connection, Speed, BitTorrent, Web UI, Advanced)
  mapped onto libtorrent `settings_pack`.
- **R1** — RSS (feeds, auto-download rules).
- **S1** — Search engine plugins.
- **X1** — Polish: execution log, statistics, scheduler, IP filter, drag & drop, full shortcuts.

## Note

This code is written against the libtorrent **2.0.x** API (the Homebrew default).
Paste any compiler error and it can be adjusted.
