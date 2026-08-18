# Research: Rename Before Install

## libtorrent Pre-Add Rename Mechanism

### Decision
Apply renamed paths differently by add path:
- **`.torrent` files**: populate `add_torrent_params::renamed_files`
  (`std::map<file_index_t, std::string>`) before `add_torrent(...)`.
- **Magnets**: call `torrent_handle::rename_file(index, new_path)` on the
  existing handle during `commitMagnet` (before resuming).

### Rationale
libtorrent provides `add_torrent_params::renamed_files`, documented as "a map of
file indices in the torrent and new filenames to be applied before the torrent
is added" (`add_torrent_params.hpp:355-357`). For `.torrent` adds this cleanly
replaces the file layout. Magnets are added first for metadata and committed
later, so `renamed_files` is already consumed at magnet-add time; the committed
handle must instead use `torrent_handle::rename_file(file_index_t, std::string)`
(`torrent_handle.hpp:1412`).

### Alternatives considered
- Only use `renamed_files` for both: rejected — magnets needed metadata before
  the rename map would be known, so the map cannot be set at initial add.
- Rename files on disk after download (FileManager.moveItem): rejected — the
  user wants the file paths to be correct from the start so download/checks
  target the right location and resume data stays consistent.

## Representing Renamed Paths in the Pre-Add Model

### Decision
Keep `PendingFile.path` as the relative path and add a parallel per-file
"final name" that can differ from the original. Folder renames rewrite the path
prefix for every contained file; file renames rewrite the last component.

### Rationale
The current `PendingFile` uses an Immutable-ish struct with a `path`. Renames
need to be tracked and resolved into libtorrent's `renamed_files` map or
`rename_file` calls. Modeling a mapping from file index → new relative path is
the smallest change that preserves priorities (which already key off file
index).

### Alternatives considered
- Mutating `PendingFile.path` in place: viable and simple, but discards the
  original path (needed only for UI display of "old → new"). Since the spec
  does not require showing the old name, mutating `path` is acceptable and
  simplest (constitution II).
- A separate rename registry: rejected as an unnecessary abstraction.

## Single-File vs Multi-File Root Folder

### Decision
For multi-file torrents the root-folder rename rewrites the top-level path
component of every file. For single-file torrents the root-folder control is
hidden (the file name itself is edited via the file-rename control).

### Rationale
Per clarified behavior, a single-file torrent has no wrapping folder on disk, so
there is nothing to rename at the folder level.

### Alternatives considered
- Creating a wrapping folder for single-file torrents: rejected — changes the
  on-disk layout and contradicts the clarified requirement.

## Validation Rules

### Decision
Reject and keep the original name (inline error) when a name is: empty; contains
a `/` or other illegal filename characters; or collides with a sibling of the
same type (a file vs another file, or a folder vs another folder in the same
parent).

### Rationale
Matches clarified behavior. Uses the OS's illegal-character rules
(`CharacterSet`/filesystem constraints for macOS) and sibling-scoped uniqueness
to keep the layout unambiguous for libtorrent and the filesystem.

### Alternatives considered
- Auto-renaming with numeric suffixes: rejected by clarification (reject + keep
  original instead).

## Test Harness Limitation (FR-005 / SC-002)

### Decision
End-to-end verification that renamed paths persist on disk is validated
manually via `quickstart.md` scenarios 1, 3, and 4 (task T021).

### Rationale
The unit-test harness (XCTest + `@testable import Canopy`) cannot construct a
live `LTTorrentHandle`, so it cannot exercise the real bridge/libtorrent
`renamed_files` / `rename_file` wiring. The model-level tests in
`Tests/PreAddRenameTests.swift` cover the rename/path-cascade logic in
isolation; the on-disk outcome requires a running app and real torrent.

### Alternatives considered
- Extending the harness to drive a libtorrent session: deferred — significant
  infrastructure (session setup, metadata, network) outside this feature's
  scope.