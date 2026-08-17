# Feature Specification: Sequential Download & Smart Double-Click

**Created**: 2026-08-17

**Status**: Draft

**Input**: User description: "Please add a download in sequential order so that the app prioritizes downloading the file from the first pieces until the last. Also, when double clicking on a downloaded torrents name, dont make it pop up where the file is, rather make it open if its a single file like a mkv or mp4, or make it open the folder if its a folder"

## User Scenarios & Testing

### User Story 1 - Toggle Sequential Download (Priority: P1)

A user downloading a large video file wants to start watching it as soon as
possible. They enable "Download in order" for that torrent, and the app
prioritizes downloading pieces from the beginning of the file towards the end,
so the user can begin playback of the early portion while the rest is still
downloading.

**Why this priority**: Sequential download is the primary ask and directly
affects the download experience for media consumers.

**Independent Test**: Can be fully tested by starting a torrent with sequential
mode enabled, verifying the indicator icon is shown, and verifying that pieces
are requested with a preference for lower-numbered pieces first.

**Acceptance Scenarios**:

1. **Given** a torrent is added to Canopy, **When** the user enables "Download
   in order" for that torrent, **Then** the engine prioritizes lower-numbered
   pieces over higher-numbered pieces during piece selection.
2. **Given** a torrent has sequential mode enabled and partially downloaded,
   **When** the user disables sequential mode, **Then** the engine returns to
   the default piece selection strategy.
3. **Given** sequential mode is active on a torrent, **When** the torrent
   finishes downloading, **Then** sequential mode has no further effect on the
   completed torrent.

---

### User Story 2 - Smart Double-Click on Torrent Name (Priority: P1)

A user who has finished downloading a torrent double-clicks on the torrent name
in the transfer list. If the torrent contains a single file, the app opens that
file with the system default application. If the torrent contains multiple
files, the app opens the containing folder in Finder.

**Why this priority**: This is the second primary ask and directly improves the
post-download user experience.

**Independent Test**: Can be fully tested by double-clicking completed torrents
with single and multi-file structures and verifying the correct system action
occurs.

**Acceptance Scenarios**:

1. **Given** a completed torrent containing a single file (e.g. a movie.mkv),
   **When** the user double-clicks the torrent name, **Then** the file is
   opened with the system's default application for that file type.
2. **Given** a completed torrent containing multiple files in a folder,
   **When** the user double-clicks the torrent name, **Then** Finder opens
   showing the torrent's download folder.
3. **Given** a torrent that is still downloading, **When** the user
   double-clicks the torrent name, **Then** the existing behavior (reveal in
   Finder) is preserved.
4. **Given** a completed single-file torrent whose file type has no registered
   default application, **When** the user double-clicks the torrent name,
   **Then** the containing folder is revealed in Finder.

---

### Edge Cases

- What happens when the torrent has a single file but the file type has no
  default application registered on the system?
- What happens when the torrent's download folder has been moved or deleted
  since the torrent completed?
- How does the user know whether a torrent is single-file or multi-file before
  double-clicking?
- What happens if the user double-clicks on a torrent that has a single file of
  an unknown or unrecognized extension?

## Requirements

### Functional Requirements

- **FR-001**: The app MUST provide a per-torrent "Download in order" control
  that, when enabled, causes the engine to prioritize lower-numbered pieces
  over higher-numbered pieces during piece selection.
- **FR-002**: The "Download in order" control MUST be visible in the torrent's
  context menu or inspector panel.
- **FR-003**: Disabling "Download in order" MUST revert the torrent to the
  default piece selection strategy.
- **FR-004**: Double-clicking the name of a completed single-file torrent MUST
  open that file with the system default application.
- **FR-005**: Double-clicking the name of a completed multi-file torrent MUST
  open the torrent's download folder in Finder.
- **FR-006**: Double-clicking the name of an incomplete (still downloading)
  torrent MUST preserve the current reveal-in-Finder behavior.
- **FR-007**: The state of "Download in order" MUST persist across app
  restarts for each torrent.
- **FR-008**: If opening a single-file completed torrent with the default
  application fails (no registered application), the app MUST fall back to
  revealing the containing folder in Finder.

### Key Entities

- **Torrent**: A download managed by the engine. Contains metadata about piece
  count, file list, and download state. Has a "sequential download" flag.
- **Piece**: A fixed-size chunk of the torrent data. Sequentially numbered
  from 0 to N-1. The engine selects which piece to request next based on the
  active strategy.
- **Torrent File**: A file within a torrent. May be a single file (torrent has
  one file entry) or one of many files (torrent has a directory structure).

## Success Criteria

### Measurable Outcomes

- **SC-001**: Users can enable or disable sequential download on any torrent
  with at most 2 clicks or keyboard actions.
- **SC-002**: When sequential download is enabled, pieces are requested with a
  strong preference for lower-numbered pieces (the engine biases toward
  sequential order rather than rarest-first).
- **SC-003**: Double-clicking a single-file completed torrent opens the file
  in the default application in under 1 second.
- **SC-004**: Double-clicking a multi-file completed torrent reveals the folder
  in Finder in under 1 second.
- **SC-005**: The reveal-in-Finder behavior for incomplete torrents is
  unchanged from the existing behavior.
- **SC-006**: If a single-file torrent has no default application for its file
  type, double-clicking falls back to revealing the folder in Finder.

## Assumptions

- Sequential download is a per-torrent setting, not a global preference.
- The default piece selection strategy is rarest-first (libtorrent default).
- A torrent is considered "completed" when all pieces have been downloaded and
  the data is verified.
- A torrent is "single-file" when the torrent metadata contains exactly one
  file entry; otherwise it is "multi-file".
- Opening a file with the system default application is handled by the
  operating system.
- The existing double-click behavior reveals the torrent's download location in
  Finder; this is unchanged for incomplete torrents.