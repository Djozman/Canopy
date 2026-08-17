# Source layout

Canopy is a native macOS SwiftUI application. Swift Package Manager is the
canonical build system.

- `App/` — lifecycle, file and magnet URL handling
- `Engine/` — main-actor session facade and Objective-C++ libtorrent bridge
- `Models/` — torrent and recursive file-tree models
- `ViewModels/` — filtering, sorting, live file progress, update checks
- `Views/` — three-column macOS interface, add flow, details, and settings
- `Assets.xcassets/` — application icon

The bridge header stays pure Objective-C so Swift can import it. All libtorrent
C++ types remain in `LibtorrentWrapper.mm`. Engine calls are serialized on a
utility queue.
