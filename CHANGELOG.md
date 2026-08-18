# Changelog

## 3.1.0

### Features

- Added the ability to rename the torrent's root folder, any subfolder, and any
  individual file on the pre-add review screen before the torrent is added.
  Named paths are applied to libtorrent so downloaded content lands under the
  new names on disk.
- Name validation rejects empty names, names containing illegal characters
  (`/`, `\`, `:`, control), and same-type sibling collisions, with inline
  errors that preserve the original name.

### Interface

- The pre-add file tree rows and the root .folder now expose an inline rename
  (pencil) control; single-file torrents hide the root-folder rename.

## 3.0.0

### Interface

- Rebuilt the main window around a qBittorrent-inspired workflow.
- Added a top-left Canopy logo, product name, and visible 3.0.0 version.
- Added a compact multi-column transfer table and draggable lower inspector.
- Added live status counts, aggregate speeds, and a larger default window.

### Engine and build

- Repaired magnet metadata flow, removal behavior, and resume persistence.
- Ported the bridge to libtorrent 2.1 and strict bridge types.
- Replaced the hard-coded libtorrent ABI with compiler and linker flags read
  from the installed `libtorrent-rasterbar.pc`, so local and CI builds match the
  linked bottle's namespace configuration.
- Kept compatibility calls such as `torrent_info::files()`, `peer_info::ip`, and
  the portable single-argument torrent loader.
- Added tag-driven release CI with bundled runtime libraries, ZIP and DMG
  packages, and SHA-256 checksums.
- Kept application and bundle versions at 3.0.0.
