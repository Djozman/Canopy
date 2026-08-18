---

description: "Task list for Rename Before Install feature"

---

# Tasks: Rename Before Install

**Input**: Design documents from `specs/002-rename-before-install/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Tests are included per constitution requirement (IX. Test on Behavior Change) and spec success criteria. The pure Swift validation/path logic is unit-testable; bridge/libtorrent integration is not covered by the existing harness.

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

- [X] T002 [P] Add `renameValidation` (empty / illegal-character / duplicate-sibling checks) to `PreAddViewModel` as a model-level helper in `Sources/Models/PreAddViewModel.swift`
- [X] T003 [P] Add `buildRenamedFiles()` to `PreAddViewModel` that returns `[Int: String]` (file index → new relative path) and syncs paths into `pending.files`; called once on confirm in `Sources/Models/PreAddViewModel.swift`
- [X] T004 Add `rename(node: FileNode, to newName: String)` to `PreAddViewModel` that validates, updates the node name, and cascades path changes to `pending.files` in `Sources/Models/PreAddViewModel.swift`
- [X] T005 Extend bridge `addTorrentFile:` to accept a `renamedFiles` path array and populate `add_torrent_params::renamed_files` in `Sources/Engine/Bridge/ObjC/include/LibtorrentWrapper.h` and `Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm`
- [X] T006 Extend bridge `commitMagnet:` to accept a `renamedFiles` path array and call `torrent_handle::rename_file(...)` per renamed file before resuming in `Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm`

**Checkpoint**: Foundation ready - rename validation, path-cascade, and bridge rename plumbing are in place.

---

## Phase 3: User Story 1 - Rename the Root Folder (Priority: P1) 🎯 MVP

**Goal**: Users can rename the torrent's root folder for a multi-file torrent on the pre-install screen; single-file torrents hide the control.

**Independent Test**: Add a multi-file torrent, rename the root folder on the review screen, confirm, and verify the files land under the new folder on disk. Add a single-file torrent and verify the root-folder rename control is hidden.

### Tests for User Story 1

> **NOTE**: Write these tests FIRST, ensure they FAIL before implementation.

- [X] T007 [P] [US1] Add unit test that renaming the root folder rewrites the top-level path component of every contained file in `Tests/PreAddRenameTests.swift`
- [X] T008 [P] [US1] Add unit test that the root-folder rename is rejected/hidden for single-file torrents in `Tests/PreAddRenameTests.swift`

### Implementation for User Story 1

- [X] T009 [US1] Add root-folder rename UI (editable text field) to `PreAddSheet.swift`, shown only when the torrent has more than one file
- [X] T010 [US1] Wire the root-folder rename to `PreAddViewModel.rename(node:to:)` and surface inline errors in `Sources/Views/PreAddSheet.swift`
- [X] T011 [US1] Resolve the renamed root folder into `pending.files` paths (via `buildRenamedFiles()` on confirm) and pass the resulting `renamedFiles` array through `TorrentEngine.confirm(_:)` in `Sources/Views/PreAddSheet.swift` and `Sources/Engine/TorrentEngine.swift`

**Checkpoint**: User Story 1 (root-folder rename) is fully functional and independently testable.

---

## Phase 4: User Story 2 - Rename Subfolders (Priority: P2)

**Goal**: Users can rename any subfolder; all contained files and subfolders inherit the new folder component in their paths.

**Independent Test**: Add a torrent with a subfolder, rename the subfolder on the review screen, confirm, and verify on-disk layout reflects the new subfolder name.

### Tests for User Story 2

> **NOTE**: Write these tests FIRST, ensure they FAIL before implementation.

- [X] T012 [P] [US2] Add unit test that renaming a subfolder rewrites the corresponding path component for all descendant files in `Tests/PreAddRenameTests.swift`

### Implementation for User Story 2

- [X] T013 [US2] Add subfolder rename UI (editable text field per folder row) to the file tree in `Sources/Views/PreAddSheet.swift`
- [X] T014 [US2] Wire subfolder rename to the same `PreAddViewModel.rename(node:to:)` path cascade (reuses T004), surfacing inline errors in `Sources/Views/PreAddSheet.swift`

**Checkpoint**: User Stories 1 and 2 (root + subfolder rename) both work.

---

## Phase 5: User Story 3 - Rename Individual Files (Priority: P2)

**Goal**: Users can rename any individual file on the review screen; the file name on disk reflects the change.

**Independent Test**: Add a torrent, rename a single file on the review screen, confirm, and verify the downloaded file has the new name.

### Tests for User Story 3

> **NOTE**: Write these tests FIRST, ensure they FAIL before implementation.

- [X] T015 [P] [US3] Add unit test that renaming a file updates only the leaf node's path (last path component) in `Tests/PreAddRenameTests.swift`

### Implementation for User Story 3

- [X] T016 [US3] Add per-file rename UI (editable text field per file leaf row) to the file tree in `Sources/Views/PreAddSheet.swift`
- [X] T017 [US3] Wire file rename to `PreAddViewModel.rename(node:to:)` and ensure `buildRenamedFiles()` maps the new file path by its stable `fileIndex` in `Sources/Models/PreAddViewModel.swift`

**Checkpoint**: All user stories (root folder, subfolders, files) work independently.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T018 [P] Verify file priorities are preserved after renames by asserting `syncFilePriorities()` is unaffected in `Tests/PreAddRenameTests.swift`
- [X] T019 [P] Run `swift build` and verify no warnings (constitution X)
- [X] T020 [P] Run `swift test` and verify all tests pass (constitution X)
- [ ] T021 Run quickstart.md validation scenarios (scenarios 1-6); GUI steps require human QA. Automated coverage provided by T002-T020 (build + 6 rename unit tests); final human GUI run still recommended.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — verify baseline
- **Phase 2 (Foundational)**: Depends on Phase 1 — BLOCKS all user stories (T002-T006)
- **US1 (Phase 3)**: Depends on Phase 2
- **US2 (Phase 4)**: Depends on Phase 2, specially on T004 (shared cascade) and US1's T011 pattern
- **US3 (Phase 5)**: Depends on Phase 2, especially T003 (`buildRenamedFiles`) and T004
- **Polish (Phase 6)**: Depends on all user stories being complete

### User Story Dependencies

- **US1 (P1)**: Root-folder rename — needs the rename core (T004) and bridge plumbing (T005/T006)
- **US2 (P2)**: Subfolder rename — reuses the same core; independent of US1 UI
- **US3 (P2)**: File rename — needs `buildRenamedFiles()` (T003) + core (T004)

### Within Each User Story

- Tests MUST be written and FAIL before implementation
- Core/model logic before UI wiring before engine integration
- Story complete before moving to polish

### Parallel Opportunities

- T002, T003, T004, T005, T006 (all Phase 2 foundational) can run in parallel (different concerns/files)
- T007/T008 (US1 tests) can run in parallel with T009-T011 (US1 impl)
- US1, US2, US3 UI tasks touch the same file (`PreAddSheet.swift`) — sequence them to avoid conflicts
- Tests across stories can run in parallel

---

## Parallel Example: Phase 2 (Foundational)

```bash
# Launch all foundational tasks together (different files/concerns):
Task: "Add renameValidation helper to PreAddViewModel in Sources/Models/PreAddViewModel.swift"
Task: "Add buildRenamedFiles() to PreAddViewModel in Sources/Models/PreAddViewModel.swift"
Task: "Add rename(node:to:) to PreAddViewModel in Sources/Models/PreAddViewModel.swift"
Task: "Extend bridge addTorrentFile: in Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm"
Task: "Extend bridge commitMagnet: in Sources/Engine/Bridge/ObjC/LibtorrentWrapper.mm"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (root-folder rename)
4. **STOP and VALIDATE**: Test User Story 1 independently
5. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 (root-folder rename) → Test independently (MVP!)
3. Add User Story 2 (subfolder rename) → Test independently
4. Add User Story 3 (file rename) → Test independently
5. Each story adds value without breaking prior stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together (T002-T006)
2. Once Foundational is done:
   - Developer A: User Story 1 (T009-T011)
   - Developer B: User Story 2 (T013-T014)
   - Developer C: User Story 3 (T016-T017)
3. Note: all UI tasks edit `PreAddSheet.swift`; coordinate or use a single developer for that file

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Verify tests fail before implementing
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Avoid: vague tasks, same file conflicts, cross-story dependencies that break independence
- 21 tasks total: 1 setup, 5 foundational, 5 US1 (T007-T011), 3 US2 (T012-T014), 3 US3 (T015-T017), 4 polish (T018-T021)