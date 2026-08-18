# Quickstart: Rename Before Install

## Prerequisites

- macOS 14 Sonoma or newer
- Xcode command-line tools (Swift 5.10+)
- Homebrew: `libtorrent-rasterbar 2.x`, `boost`

## Validation Scenarios

### Scenario 1: Rename the Root Folder (Multi-File)

1. Add a multi-file torrent (⌘N) → review screen
2. Rename the root folder from "Old" to "New"
3. Confirm the torrent and let it download
4. **Verify**: Files land under a folder named "New" on disk

### Scenario 2: Single-File Torrent Has No Root-Folder Rename

1. Add a single-file torrent → review screen
2. **Verify**: The root-folder rename control is hidden/disabled
3. **Verify**: The file name is editable

### Scenario 3: Rename a Subfolder

1. Add a torrent with a subfolder "Season1" → review screen
2. Rename "Season1" → "S01"
3. **Verify**: All its contained files now appear under "S01"
4. Confirm download → **Verify** on-disk layout matches

### Scenario 4: Rename a File

1. Add a torrent with "Episode.01.mkv" → review screen
2. Rename to "Episode1.mkv"
3. Confirm download → **Verify** the file is named "Episode1.mkv" on disk

### Scenario 5: Invalid Names Are Rejected

1. On the review screen, try renaming an item to "" (empty)
2. **Verify**: An inline error appears and the original name is kept
3. Try a name with `/`; try a name that collides with a sibling
4. **Verify**: Each is rejected with an inline error and keeps original

### Scenario 6: Renames Do Not Affect Priorities

1. Set a file to "Skip" and another to "High" on the review screen
2. Rename several files/folders
3. **Verify**: Priorities for all files remain as chosen
4. Confirm → **Verify** skipped files are not downloaded

## Test Commands

```bash
# Build
swift build

# Run tests
swift test

# Release
swift build -c release
```

## Related Artifacts

- [Feature Specification](../spec.md)
- [Data Model](../data-model.md)
- [Contract: Bridge Rename](contracts/bridge-rename.md)
- [Contract: Rename Validation](contracts/rename-validation.md)