# libtorrent bridge

`ClibtorrentBridge` is a Swift Package Manager target that isolates
libtorrent-rasterbar behind a pure Objective-C API.

## Design

- `include/LibtorrentWrapper.h` is Swift-importable and contains no C++ types.
- `LibtorrentWrapper.mm` owns the `libtorrent::session`, torrent handles,
  alerts, settings, metadata fetch, and resume data.
- `TorrentEngine.swift` serializes bridge calls on one utility queue and
  publishes immutable `TorrentStatus` snapshots on the main actor.

## Important invariants

1. Metadata-only magnets use `upload_mode`, not `paused`; a paused magnet cannot
   announce and therefore cannot fetch metadata.
2. Download destinations are created before adding or committing a torrent.
3. Cancelled metadata handles are removed from the session.
4. Removing a torrent without deleting data uses no delete flags.
5. Resume data is written atomically and supports both v1 and v2 hashes.
6. The Objective-C wrapper never exposes libtorrent-owned pointers to Swift.

## Dependencies

```bash
brew install libtorrent-rasterbar boost
```

Homebrew locations are selected by `Package.swift` for Apple Silicon and Intel
Macs.
