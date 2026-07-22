# Changelog

## 3.0.0

### Interface

- Rebuilt the main window around a qBittorrent-inspired workflow.
- Added a top-left Canopy logo, product name, and visible 3.0.0 version.
- Added a compact multi-column transfer table and draggable lower inspector.
- Added live status counts, aggregate speeds, and a larger default window.

### Engine and build

- Repaired magnet metadata flow, removal behavior, and resume persistence.
- Ported the bridge to libtorrent 2.1 and strict bridge types.
- Matched the ABI version 2 compatibility surface used by Homebrew and CI,
  including `torrent_info::files()`, `peer_info::ip`, and two-argument torrent
  loading.
- Added tag-driven release CI with bundled runtime libraries, ZIP and DMG
  packages, and SHA-256 checksums.
- Kept application and bundle versions at 3.0.0.
