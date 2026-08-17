# Quickstart: Sequential Download & Smart Double-Click

## Prerequisites

- macOS 14 Sonoma or newer
- Xcode command-line tools (Swift 5.10+)
- Homebrew: `libtorrent-rasterbar 2.x`, `boost`
- Canopy project cloned and buildable (`swift build`)

## Validation Scenarios

### Scenario 1: Sequential Download Toggle

1. **Setup**: Build and run Canopy from source
2. **Add a torrent**: Press `⌘N` and add a magnet link or `.torrent` file
3. **Enable sequential download**: Right-click the torrent → select "Download in
   Order" from the context menu
4. **Verify**: The torrent row shows a sequential download indicator icon
5. **Verify in logs**: Lower-numbered pieces are prioritized over higher-numbered pieces
6. **Disable**: Right-click again → deselect "Download in Order"
7. **Verify**: The indicator icon disappears; piece selection returns to default

**Expected**: User can toggle sequential download with at most 2 clicks.
Toggling is responsive (no UI freeze).

### Scenario 2: Smart Double-Click — Single File

1. **Setup**: Download a single-file torrent (e.g., `movie.mkv`) to completion
2. **Double-click**: Double-click the torrent name in the transfer list
3. **Verify**: The file opens in the system default application for `.mkv`
   (e.g., QuickTime Player, VLC, IINA)

### Scenario 3: Smart Double-Click — Multi-File Folder

1. **Setup**: Download a multi-file torrent (e.g., a TV episode with `.mkv` +
   `.srt` + `.jpg` files) to completion
2. **Double-click**: Double-click the torrent name in the transfer list
3. **Verify**: The torrent's download folder opens in Finder

### Scenario 4: Double-Click During Download (Preserved Behavior)

1. **Setup**: Start downloading a torrent (any size)
2. **Double-click**: Double-click the torrent name while it is still
   downloading
3. **Verify**: The download folder opens in Finder (existing behavior,
   unchanged)

### Scenario 5: Single-File Fallback on No Default Application

1. **Setup**: Download a single-file torrent with an uncommon extension (e.g.,
   `.xyz`) that has no default application on the system
2. **Double-click**: Double-click the torrent name in the transfer list
3. **Verify**: The containing folder opens in Finder (fallback behavior)

### Scenario 6: Persistence Across Restart

1. **Setup**: Enable "Download in Order" on a torrent
2. **Restart**: Quit and relaunch Canopy
3. **Verify**: The torrent still has sequential download enabled
   (indicator icon visible, toggle state maintained)

## Test Commands

```bash
# Build
swift build

# Run tests
swift test

# Build release
swift build -c release
```

## Related Artifacts

- [Feature Specification](../spec.md)
- [Data Model](../data-model.md)
- [Contracts: Bridge Sequential Download](contracts/bridge-sequential-download.md)
- [Contracts: Smart Open Action](contracts/smart-open-action.md)