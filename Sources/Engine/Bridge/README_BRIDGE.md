# libtorrent C Bridge — Setup Guide

## What this folder contains

| File | Purpose |
|---|---|
| `libtorrent_bridge.h` | Public C API — imported by Swift via the bridging header |
| `libtorrent_bridge.cpp` | C++ implementation — translates C calls → libtorrent C++ API |
| `QBridgingHeader.h` | Xcode Objective-C Bridging Header — just `#include`s the `.h` above |

---

## Step 1 — Install libtorrent via Homebrew

```bash
brew install libtorrent-rasterbar
```

Verify:
```bash
pkg-config --cflags --libs libtorrent-rasterbar
```

---

## Step 2 — Xcode project settings

In **Build Settings** of your app target:

| Setting | Value |
|---|---|
| Header Search Paths | `$(shell brew --prefix libtorrent-rasterbar)/include` |
| Library Search Paths | `$(shell brew --prefix libtorrent-rasterbar)/lib` |
| Other Linker Flags | `-ltorrent-rasterbar -lc++` |
| Swift Compiler — Obj-C Bridging Header | `Sources/Engine/Bridge/QBridgingHeader.h` |
| C++ Language Dialect | `C++17` |

---

## Step 3 — Add files to target

Add **both** of the following to your Xcode target's "Compile Sources":
- `libtorrent_bridge.cpp`
- All `.swift` files

Do **not** add `libtorrent_bridge.h` or `QBridgingHeader.h` to Compile Sources — they are header files only.

---

## Step 4 — Swap mock data for real engine

In `TorrentListViewModel.swift`, replace:
```swift
@Published var torrents: [TorrentStatus] = TorrentStatus.mockList
```
with:
```swift
@Published var torrents: [TorrentStatus] = []
private var cancellables = Set<AnyCancellable>()

init(engine: TorrentEngine) {
    engine.$torrents
        .receive(on: RunLoop.main)
        .assign(to: &$torrents)
    engine.startPolling()
}
```

And inject `TorrentEngine` from `qBittorrentApp.swift`:
```swift
@StateObject private var engine = TorrentEngine()
// pass into ContentView / ViewModel as needed
```

---

## Architecture diagram

```
libtorrent C++ (brew)
        │
        │  C++ API calls
        ▼
libtorrent_bridge.cpp   ← C++ only, not imported by Swift
        │
        │  plain C function calls (extern "C")
        ▼
libtorrent_bridge.h     ← C header, safe for Swift
        │
        │  via QBridgingHeader.h
        ▼
TorrentEngine.swift     ← Swift wrapper, owns session lifetime
        │
        │  @Published torrents: [TorrentStatus]
        ▼
TorrentListViewModel    ← SwiftUI ViewModel
        │
        ▼
SwiftUI Views
```

---

## Notes on memory ownership

- `lt_session_create()` returns a heap-allocated `lt::session*` cast to `void*`.  
  You **must** call `lt_session_destroy()` exactly once (on app quit).
- Torrent handles returned by `lt_torrent_add_*` are heap-allocated `lt::torrent_handle*`.  
  They are freed inside `lt_torrent_remove()`. Do **not** free them yourself.
- Handles passed to `lt_status_callback` and `lt_alert_callback` are **temporary** —  
  they are freed after the callback returns. Copy what you need before returning.
