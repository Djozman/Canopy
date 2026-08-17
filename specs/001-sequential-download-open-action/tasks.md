---

description: "Task list for Sequential Download and Smart Double-Click features"

---

# Tasks: Sequential Download & Smart Double-Click

**Input**: Design documents from `specs/001-sequential-download-open-action/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Tests are included per constitution requirement (IX. Test on Behavior Change) and spec success criteria.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single project**: `Sources/`, `Tests/` at repository root

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [X] T001 Verify project builds and tests pass before starting (`swift build && swift test`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

No foundational tasks — both user stories are independent and share no blocking prerequisites. US1 changes the bridge/engine/data-model; US2 changes only the `ContentView.swift` double-click handler. They touch different files.

---

## Phase 3: User Story 1 - Toggle Sequential Download (Priority: P1) 🎯 MVP

**Goal**: Users can enable "Download in order" per torrent, causing the engine to prioritize lower-numbered pieces over higher-numbered pieces during piece selection (libtorrent `sequential_download` flag).

**Independent Test**: Add a torrent, enable "Download in order" via the context menu, verify the indicator icon appears in the name cell, and verify lower-numbered pieces are prioritized during piece selection. Disable to revert to default; verify state persists across restart.

### Tests for User Story 1

> **NOTE**: Write these tests FIRST, ensure they FAIL before implementation.

- [X] T002 [P] [US1] Add unit test that `TorrentStatus.isSequentialDownload` correctly reflects the handle's `sequentialDownload` flag in `Tests/TorrentEngineTests.swift`
- [X] T003 [P] [US1] Add unit test for `TorrentEngine.setSequentialDownload(_:enabled:)` that it dispatches the flag change to the torrent handle in `Tests/TorrentEngineTests.swift`

### Implementation for User Story 1

- [X] T004 [P] [US1] Add `@property (nonatomic, assign) BOOL sequentialDownload;` to `LTTorrentHandle` in `Sources/Engine/Bridge/ObjC/include/LibtorrentWrapper.h`
- [X] T005 [P] [US1] Implement `sequentialDownload` getter in `Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm` reading `(_cachedStatus.flags & lt::torrent_flags::sequential_download)` (mirror the existing `paused` getter at line ~168)
- [X] T006 [P] [US1] Implement `setSequentialDownload:` setter in `Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm` calling `_handle.set_flags(...)`/`_handle.unset_flags(...)` for `lt::torrent_flags::sequential_download`
- [X] T007 [P] [US1] Add `public let isSequentialDownload: Bool` field to `TorrentStatus` struct in `Sources/Engine/TorrentEngine.swift`
- [X] T008 [P] [US1] Update `TorrentStatus.init(from:)` in `Sources/Engine/TorrentEngine.swift` to populate `isSequentialDownload` from `h.sequentialDownload`
- [X] T009 [US1] Add `setSequentialDownload(_:enabled:)` method to `TorrentEngine` in `Sources/Engine/TorrentEngine.swift` (guard handle, dispatch to serial queue)
- [X] T010 [US1] Add "Download in Order" toggle to `selectedTorrentContextMenu` in `Sources/Views/ContentView.swift` calling `engine.setSequentialDownload(torrent, enabled: !torrent.isSequentialDownload)`
- [X] T011 [US1] Add sequential download indicator to `TorrentNameCell` in `Sources/Views/TorrentRowView.swift` shown when `torrent.isSequentialDownload` is true

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently.

---

## Phase 4: User Story 2 - Smart Double-Click on Torrent Name (Priority: P1)

**Goal**: Double-clicking a completed single-file torrent opens that file with the default application; double-clicking a completed multi-file torrent or an incomplete torrent opens/ reveals the download folder in Finder; falls back to revealing the folder if opening a single file fails.

**Independent Test**: Download a single-file torrent to completion, double-click the name, verify the file opens in the default application. Download a multi-file torrent, double-click, verify the folder opens in Finder. Double-click an incomplete torrent and verify reveal-in-Finder is preserved. Test a single-file torrent with no registered default app and verify fallback to the folder.

### Tests for User Story 2

> **NOTE**: Write these tests FIRST, ensure they FAIL before implementation.

- [X] T012 [P] [US2] Add unit test for the `bestFileToOpen` helper covering single-file completed (returns file URL), multi-file completed (returns nil), and incomplete torrents (returns nil) in `Tests/TorrentEngineTests.swift`

### Implementation for User Story 2

- [X] T013 [US2] Implement `bestFileToOpen(torrent:engine:)` helper in `Sources/Views/ContentView.swift` (single-file completed → return URL of that file; multi-file or incomplete → return nil)
- [X] T014 [US2] Replace the double-click handler in `ContentView.swift` (TorrentNameCell `onOpen` closure, ~line 174) to call `bestFileToOpen` — if it returns a URL, open with `NSWorkspace.shared.open(fileURL)` and fall back to `NSWorkspace.shared.open(savePath)` when open returns `false`; if nil, open `savePath` in Finder

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T015 [P] Run `swift build` and verify no warnings (constitution X)
- [X] T016 [P] Run `swift test` and verify all tests pass (constitution X)
- [ ] T017 Run quickstart.md validation scenarios (scenarios 1-6) — manual GUI verification: requires running the app, adding real torrents, and double-clicking. Verified via code-path analysis of all 6 scenarios (see completion report); persistence of the sequential flag confirmed in libtorrent resume data. Final human GUI run still recommended.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — verify baseline
- **Phase 2 (Foundational)**: None — both stories share no blocking prereqs
- **US1 (Phase 3)**: Can start immediately after Phase 1
- **US2 (Phase 4)**: Can start immediately after Phase 1
- **Polish (Phase 5)**: Depends on US1 and US2 being complete

### User Story Dependencies

- **User Story 1 (P1)**: No dependencies on other stories. Internal order: bridge header (T004), bridge getter/setter (T005, T006), data-model field + init (T007, T008), engine method (T009, depends on T005-T008), UI (T010, T011).
- **User Story 2 (P1)**: No dependencies on other stories. Internal order: helper (T013), double-click handler (T014). Note: `T013`/`T014` modify `ContentView.swift` which US1 also touches (`T010`, context menu); coordinate US1 and US2 edits to `ContentView.swift` to avoid conflicts.

### Within Each User Story

- Tests (T002/T003, T012) MUST be written and FAIL before implementation
- Bridge before engine before data-model before UI
- Story complete before moving to polish

### Parallel Opportunities

- T002 and T003 (US1 tests) can run in parallel
- T004, T005, T006 (bridge header + getter + setter) can run in parallel
- T007 and T008 (data-model field + init) can run in parallel
- T002-T011 (US1) and T012-T014 (US2) can run in parallel except for shared file `ContentView.swift` (T010 vs T013/T014) — sequence these to avoid same-file conflicts
- All tests across stories can run in parallel

---

## Parallel Example: User Story 1

```bash
# Launch all bridge changes together:
Task: "Add sequentialDownload property to LTTorrentHandle in Sources/Engine/Bridge/ObjC/include/LibtorrentWrapper.h"
Task: "Implement sequentialDownload getter in Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm"
Task: "Implement setSequentialDownload: setter in Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm"

# Launch data-model changes together:
Task: "Add isSequentialDownload field to TorrentStatus struct in Sources/Engine/TorrentEngine.swift"
Task: "Update TorrentStatus.init(from:) in Sources/Engine/TorrentEngine.swift"
```

## Parallel Example: User Story 2

```bash
# T013 and T014 are sequential (same file ContentView.swift).
# T012 (test) can be written in parallel with T013-T014 implementation.
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 3: User Story 1 (Sequential Download)
3. **STOP and VALIDATE**: Test User Story 1 independently
4. Deploy/demo if ready

### Incremental Delivery

1. Phase 1 → Foundation ready
2. Add User Story 1 (Sequential Download) → Test independently (MVP!)
3. Add User Story 2 (Smart Double-Click) → Test independently
4. Each story adds value without breaking prior stories

### Parallel Team Strategy

With multiple developers:

1. Developer A: User Story 1 (T002-T011)
2. Developer B: User Story 2 (T012-T014)
3. Both stories can proceed in parallel since they touch different files
4. Only `ContentView.swift` is shared (context menu in T010, double-click handler in T013/T014) — sequence these or use a single developer for that file

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Verify tests fail before implementing
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Avoid: vague tasks, same file conflicts, cross-story dependencies that break independence
- 17 tasks total: 1 setup, 10 US1 (T002-T011), 3 US2 (T012-T014), 3 polish (T015-T017)