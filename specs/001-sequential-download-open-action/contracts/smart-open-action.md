# Contract: Smart Open Action

**Layer**: SwiftUI Views → macOS system (NSWorkspace)

## Function Signature

```swift
/// Returns the URL to open for a completed torrent:
/// - Single-file torrent → the file itself
/// - Multi-file (folder) torrent → the torrent's own folder
///   (savePath + top-level path component of the file layout)
/// Returns nil only for incomplete torrents, so the handler falls back to
/// the generic save path (reveal-in-Finder).
func bestFileToOpen(_ torrent: TorrentStatus) -> URL?
```

## Behavior

| Torrent State | File Count | Result |
|---------------|-----------|--------|
| Incomplete | Any | `nil` (fallback: reveal savePath in Finder) |
| Complete | 1 | URL to that file |
| Complete | >1 | URL to the torrent's own folder (`savePath` + root folder name) |

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
    let saveURL = URL(fileURLWithPath: torrent.savePath)
    if let url = bestFileToOpen(torrent), NSWorkspace.shared.open(url) {
        return
    }
    // nil (incomplete) or open failure (no default app): reveal savePath.
    NSWorkspace.shared.open(saveURL)
}
```