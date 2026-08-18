# Feature Specification: Rename Before Install

**Created**: 2026-08-17

**Status**: Draft

**Input**: User description: "Add the possibility to rename torrents before putting them to install. Make it possible to rename the folder, any subfolders and subfiles."

## Clarifications

### Session 2026-08-17

- Q: When a user renames a file or folder to a name that already exists among its siblings, what should happen? → A: Reject the change; show an inline error and keep the original name until fixed.
- Q: For a single-file torrent, which already has no wrapping folder on disk, what should the "rename root folder" step do? → A: Disable/hide the root-folder rename for single-file torrents; only file rename applies.

## User Scenarios & Testing

### User Story 1 - Rename the Torrent / Root Folder (Priority: P1)

When a user adds a torrent and reaches the pre-install review screen (the file
selection window shown before the torrent starts downloading), they can rename
the torrent's root folder. The new name replaces the folder name under which
the torrent's files are stored on disk.

**Why this priority**: Renaming the top-level folder is the most common and
impactful rename — users typically want to clean up the folder that wraps all
downloaded content.

**Independent Test**: Can be fully tested by adding any torrent, reaching the
pre-install screen, renaming the root folder, and confirming — then verifying
the downloaded files appear inside a folder with the new name.

**Acceptance Scenarios**:

1. **Given** a user is on the pre-install review screen for a multi-file
   torrent, **When** they rename the root folder from "OldName" to "NewName",
   **Then** the review screen shows the folder and all its contents under
   "NewName".
2. **Given** a user has renamed the root folder, **When** they confirm the
   torrent and it downloads, **Then** the files are stored under the new folder
   name on disk.
3. **Given** a single-file torrent, **When** the user reaches the review screen,
   **Then** the root-folder rename control is hidden/disabled (only the file
   rename applies, since there is no wrapping folder on disk).

---

### User Story 2 - Rename Subfolders (Priority: P2)

On the pre-install review screen, the user can rename any subfolder within the
torrent's file tree. Renaming a subfolder updates its path for all files it
contains.

**Why this priority**: Subfolder renaming is a valuable but less frequent
operation than root-folder renaming; it lets users reorganize nested content.

**Independent Test**: Can be fully tested by adding a torrent whose file tree
contains one or more subfolders, renaming a subfolder on the review screen, and
verifying its children now appear under the new subfolder name.

**Acceptance Scenarios**:

1. **Given** a torrent with a subfolder "Season1" containing several episode
   files, **When** the user renames "Season1" to "S01", **Then** all contained
   files appear under "S01" in the review tree.
2. **Given** the renamed subfolder, **When** the user confirms the torrent,
   **Then** the files are stored under the new subfolder name on disk.

---

### User Story 3 - Rename Individual Files (Priority: P2)

On the pre-install review screen, the user can rename any individual file
within the torrent. Renaming a file changes its file name on disk after
download.

**Why this priority**: File renaming is frequently desired (e.g. correcting
scene release naming); it is independent of folder renaming and equally
valuable.

**Independent Test**: Can be fully tested by adding a torrent, renaming a
single file on the review screen, confirming, and verifying the downloaded file
has the new name on disk.

**Acceptance Scenarios**:

1. **Given** a torrent containing a file "Episode.01.mkv", **When** the user
   renames it to "Episode1.mkv", **Then** the review tree shows the new name.
2. **Given** the renamed file, **When** the user confirms the torrent and it
   downloads, **Then** the file appears on disk with the new name.

---

### Edge Cases

- What happens if two items (files or folders) are renamed to the same name
  within the same parent folder?
- What happens if a user clears a name, leaving it empty?
- What happens if a user enters a name containing path separators (`/`) or
  other illegal filename characters?
- What happens to file/folder ordering in the tree after a rename?
- How is the renamed structure reflected back when the user changes file
  priorities at the same time?

## Requirements

### Functional Requirements

- **FR-001**: The pre-install review screen MUST allow the user to rename the
  torrent's root folder for multi-file torrents.
- **FR-001a**: For single-file torrents, the root-folder rename control MUST be
  hidden/disabled; only the file name is editable.
- **FR-002**: The pre-install review screen MUST allow the user to rename any
  subfolder in the torrent's file tree.
- **FR-003**: The pre-install review screen MUST allow the user to rename any
  individual file in the torrent's file tree.
- **FR-004**: Renaming a folder MUST update the displayed path of every
  contained file and subfolder.
- **FR-005**: When the user confirms the torrent, libtorrent MUST receive the
  renamed file paths and persist them to disk using the new names.
- **FR-006**: The rename control MUST appear only in the pre-install flow
  (before a torrent is added); it MUST NOT rename files of torrents already
  downloading/seeding.
- **FR-007**: The system MUST validate names and reject empty names, names
  containing a `/`, `\`, `:`, or control character, and names that collide with
  a sibling of the same type. On rejection it MUST show an inline error and keep
  the original name until the user provides a valid one.
- **FR-008**: Renaming MUST preserve the user's file priority selections.

### Key Entities

- **PendingTorrent**: The in-memory representation of a torrent before it is
  added. Holds the torrent name (root folder name) and the list of files.
- **PendingFile**: A file in the pre-add list, with a relative `path` (e.g.
  "Folder/Sub/file.mkv"), size, and priority.
- **FileNode**: An editable node in the pre-install review tree. Represents
  either a folder (has children) or a file (has a file index).
- **PreAddViewModel**: Manages the review tree and its synchronization with
  `pending.files` when the user edits names or priorities.

## Success Criteria

### Measurable Outcomes

- **SC-001**: A user can rename the root folder, any subfolder, or any file
  with no more than 3 clicks or keyboard actions per item.
- **SC-002**: After renaming and confirming, the correct folder/file structure
  with the new names appears on disk for 100% of renamed items.
- **SC-003**: Empty, separator-containing, or duplicate names are rejected and
  an inline error is shown in under 1 second.
- **SC-004**: Renaming an item does not alter the user's selected file
  priorities for any other item.
- **SC-005**: The renaming feature applies to the pre-install flow only and does
  not affect already-downloading or seeded torrents.

## Assumptions

- "Before installing" refers to the existing pre-add review screen (the file
  selection window shown after adding a torrent or magnet and before it starts
  downloading payload data).
- Renaming a file or folder changes only how the content is named on disk; it
  does not change the bytes/content of the file.
- For libtorrent, renaming before add is implemented by adjusting the file
  paths passed at add time (the same mechanism that already sends priorities).
- The torrent's root folder name defaults to the torrent name; renaming the root
  folder renames that folder but the feature does not rename the torrent's
  display name in the transfer list.
- Renaming during the pre-install review is an in-memory operation until the
  user confirms; nothing is written to disk before confirmation.
- Editing a name in place is acceptable; no drag-and-drop reordering is in
  scope.
- Rejected name characters are limited to `/`, `\`, `:`, and control
  characters.
- Rename operations are reachable only from the pre-install review flow; they
  do not mutate already-downloading or seeding torrents.