# Contract: Smart Open Action

**Layer**: SwiftUI Views → macOS system (NSWorkspace)

## Function Signature

```swift
/// Determines the best file to open for a completed single-file torrent.
/// Returns nil if the torrent is incomplete or multi-file (fall back to
/// reveal-in-Finder).
func bestFileToOpen(
    torrent: TorrentStatus, engine: TorrentEngine
) -> URL?
```

## Behavior

| Torrent State | File Count | Result |
|---------------|-----------|--------|
| Incomplete | Any | `nil` (reveal savePath in Finder) |
| Complete | 1 | URL to that file |
| Complete | >1 | `nil` (reveal savePath in Finder) |

## NSWorkspace Usage

```swift
// Open a file with default application
NSWorkspace.shared.open(fileURL)

// Show a folder in Finder
NSWorkspace.shared.open(folderURL)

// Show a folder in Finder and select it (existing reveal behavior)
NSWorkspace.shared.activateFileViewerSelecting([folderURL])
```

## Double-Click Handler (ContentView.swift)

```swift
TorrentNameCell(torrent: torrent) {
    if let fileURL = bestFileToOpen(torrent: torrent, engine: engine) {
        NSWorkspace.shared.open(fileURL)
    } else {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: torrent.savePath)
        )
    }
}
```