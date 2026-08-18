# Data Model: Rename Before Install

## Entity: PendingFile

Currently a `struct` with `id`, `path`, `size`, `priority`. For rename support,
the downstream computed name is derived from `path`. Renaming mutates the
relative `path`.

| Field | Type | Description |
|-------|------|-------------|
| `id` | Int | Stable file index (matches libtorrent `file_index_t`) — never changes across a rename |
| `path` | String | Relative path, e.g. `"Folder/Sub/file.mkv"`. Mutated by renames |
| `size` | Int64 | File size in bytes (unchanged by rename) |
| `priority` | FilePriority | Download priority (unchanged by rename) |

**State transitions** (`path`):
- Original path → new path on a successful rename (file or folder).
- Rejected renames leave `path` unchanged (validation keeps the original).

## Entity: FileNode

Reused for the review tree. Renames update `FileNode.name`. Folder renames
cascade to descendant file paths; file renames update only the leaf node's path.

| Field | Type | Description |
|-------|------|-------------|
| `name` | String | Displayed + on-disk name for this node |
| `fileIndex` | Int? | Present for file leaves; matches `PendingFile.id` |
| `children` | [FileNode]? | Present for folders |
| `priority` | FilePriority | Preserved through rename |

## Entity: PreAddViewModel

| Property | Description |
|----------|-------------|
| `pending` | The `PendingTorrent` being reviewed; mutated on rename |
| `tree` / `treeRoot` | The editable review tree built from `pending.files` |
| `errorMessage` | Inline validation error shown to the user |

**Operations** (new):
- `rename(node: FileNode, to newName: String) -> ValidationResult` — validates,
  then updates the node and cascades to `pending.files` paths.
- `buildRenamedFiles() -> [Int: String]` — resolves the tree back into a
  file-index → new-relative-path map for the bridge.
- `syncFilePriorities()` — existing; must remain consistent after renames.

## Validation Rules (from FR-007 + FR-001a)

| Rule | Behavior |
|------|----------|
| Empty name | Reject; inline error; keep original |
| Contains `/` or OS-illegal char | Reject; inline error; keep original |
| Collides with a same-type sibling in the same parent | Reject; inline error; keep original |
| Single-file torrent root-folder rename | Control hidden; not applicable |

## Persistence / Lifecycle

Renames are in-memory only until the user confirms the torrent. On confirm,
`PreAddViewModel` resolves renamed paths to libtorrent (via the bridge) and the
torrent begins saving with the new layout. No separate persistence store is
added; resume data reflects the renamed layout once download begins.