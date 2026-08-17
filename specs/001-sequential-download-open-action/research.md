# Research: Sequential Download & Smart Double-Click

## Sequential Download via libtorrent

### Decision
Expose `torrent_handle::set_sequential_download(bool)` through the ObjC++
bridge and add a `setSequentialDownload(_:enabled:)` method to `TorrentEngine`.

### Rationale
libtorrent provides a built-in `torrent_flags::sequential_download` flag that
causes the piece picker to request pieces in order from 0 to N-1. This is the
standard approach used by all major BitTorrent clients (qBittorrent, Transmission,
Deluge). No custom piece-picking logic is needed.

### Implementation detail
- `LTTorrentHandle` gains a `sequentialDownload` property (getter reads
  `flags & torrent_flags::sequential_download`, setter calls
  `set_flags(sequential_download)` / `unset_flags(sequential_download)`)
- `TorrentEngine.setSequentialDownload(_:enabled:)` dispatches to the engine's
  serial queue and calls `handle.setSequentialDownload(enabled)`
- `TorrentStatus` gains `isSequentialDownload` populated from the handle's flag
  during snapshot building

### Alternatives considered
- Custom piece-picker wrapper: rejected — libtorrent's built-in flag is
  sufficient and avoids maintaining custom piece-selection logic
- Per-file sequential download: rejected — libtorrent does not support this;
  sequential download is always per-torrent

## Smart Double-Click File Detection

### Decision
For completed torrents, determine the "best file to open" by inspecting the
torrent's file list. Single-file torrents open that file with the system
default application. Multi-file torrents open the containing folder in Finder.
For incomplete torrents, preserve the existing reveal-in-Finder behavior. If
opening a single file fails (no default application registered), fall back to
revealing the containing folder in Finder.

### Rationale
The user explicitly requested: single file → open it with default application;
multi-file folder → open folder in Finder. For incomplete torrents, preserve
the existing reveal-in-Finder behavior. If opening a single file fails (no
default app), fall back to revealing the folder.

### Implementation detail
- For a single-file torrent, the file path is the torrent's save path with the
  file name appended
- `NSWorkspace.shared.open(fileURL)` opens the file with default application
- `NSWorkspace.shared.open(folderURL)` opens the folder in Finder
- If `NSWorkspace.shared.open(fileURL)` returns `false`, fall back to
  `NSWorkspace.shared.open(folderURL)`

### Alternatives considered
- Always open save folder (current behavior): rejected — user explicitly
  requested file-opening behavior for single-file torrents
- Prompt user to choose: rejected — adds friction; double-click should be
  immediate
- Open single file, fall back to folder on failure: accepted — if
  NSWorkspace cannot open the file, reveal the folder in Finder

## UI Placement for Sequential Download Toggle

### Decision
Place the sequential download toggle in the torrent's context menu (right-click)
and add a visual indicator in the torrent row name cell.

### Rationale
The context menu is the existing pattern for per-torrent actions (pause, resume,
remove, recheck, reannounce). Adding a sequential download toggle there is
consistent. The visual indicator (icon or badge) in the name cell provides
at-a-glance awareness of the mode.

### Alternatives considered
- Toolbar button: rejected — only works when a torrent is selected; less
  discoverable
- Inspector panel toggle: viable secondary location — could be added to the
  Overview tab in TorrentDetailView
- Separate column in torrent table: rejected — too much visual weight for a
  toggle most users will rarely change