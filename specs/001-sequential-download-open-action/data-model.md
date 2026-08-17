# Data Model: Sequential Download & Smart Double-Click

## Entity: TorrentStatus

| Field | Type | Description | Feature |
|-------|------|-------------|---------|
| `id` | String | Unique torrent identifier (info hash) | Both |
| `name` | String | Torrent display name | Both |
| `savePath` | String | Absolute path to download directory | Both |
| `isSequentialDownload` | Bool | Whether sequential download is enabled | Sequential |
| `fileCount` | Int | Number of files in the torrent | Smart double-click |
| `isComplete` | Bool | Whether all pieces have been downloaded | Smart double-click |

**State transitions** (`isSequentialDownload`):
- `false` → `true`: User enables sequential mode via context menu/toggle
- `true` → `false`: User disables sequential mode via context menu/toggle
- No automatic transitions — persists across app restarts

## Entity: LTTorrentHandle (ObjC Bridge)

| Property | Type | Description |
|----------|------|-------------|
| `sequentialDownload` | BOOL (read/write) | libtorrent sequential download flag |

**Bridge mapping**:
- Getter: `_handle.flags() & lt::torrent_flags::sequential_download`
- Setter (YES): `_handle.set_flags(lt::torrent_flags::sequential_download)`
- Setter (NO): `_handle.unset_flags(lt::torrent_flags::sequential_download)`

## Smart Open Decision Logic

```
if torrent is incomplete:
    → open savePath in Finder (existing behavior)

if torrent has exactly 1 file:
    path = savePath + "/" + single file name
    → attempt NSWorkspace.shared.open(path)
    if open fails (no default application):
        → open savePath in Finder

if torrent has multiple files:
    → open savePath in Finder
```

## Persistence

Sequential download state is persisted via libtorrent's resume data mechanism.
When resume data is saved (on shutdown or periodic snapshot), the
`sequential_download` flag is included in the torrent flags. On load, the flag
is restored automatically by libtorrent. No additional persistence layer is
needed.