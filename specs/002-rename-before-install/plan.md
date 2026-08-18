# Implementation Plan: Rename Before Install

**Branch**: `002-rename-before-install` | **Date**: 2026-08-17 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-rename-before-install/spec.md`

## Summary

Extend the pre-add review screen (the file-selection window shown before a
torrent starts downloading) so users can rename the torrent's root folder, any
subfolder, or any individual file before confirming. Renamed paths are applied
to libtorrent so downloaded content lands on disk under the new names.

## Technical Context

**Language/Version**: Swift 5.10+, Objective-C++ (bridge only)

**Primary Dependencies**: libtorrent-rasterbar 2.x (via Homebrew), SwiftUI,
Combine, Foundation

**Storage**: Filesystem — renamed paths are applied via libtorrent at add time;
nothing is written to disk before the user confirms. The existing resume-data
directory is unaffected.

**Testing**: XCTest (`swift test`). Follows the existing pattern: pure Swift
view-model/model logic is unit-testable; bridge/libtorrent integration is not
covered by the current harness (the handle is not externally constructible).

**Target Platform**: macOS 14 Sonoma or newer

**Project Type**: Desktop app (macOS native, SwiftUI)

**Performance Goals**: Rename validation responds in under 1 second; renaming
an item does not visibly lag the review screen.

**Constraints**: 
- Engine-UI separation: mutations routed through the engine/bridge serial queue.
- All libtorrent interaction goes through the ObjC++ bridge.
- The rename feature appears only in the pre-add flow.
- No new external dependencies.
- Single-file torrents hide the root-folder rename control (clarified).

**Scale/Scope**: Single-user desktop app. Pre-add file trees are small (thumb to
a few thousand files).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| **I. Native macOS & Swift Conventions** | ✅ PASS | In-place rename follows macOS text-editing conventions |
| **II. Simplicity Over Abstraction** | ✅ PASS | Uses libtorrent's built-in rename mechanisms; no new layers |
| **III. Dependency Discipline** | ✅ PASS | No new dependencies |
| **IV. Preserve Existing Functionality** | ✅ PASS | Renames only occur in pre-add flow; existing downloads unaffected |
| **VI. Input Validation** | ✅ PASS | Name validation rejects empty, separator-containing, and duplicate names |
| **VII. Engine-UI Separation** | ✅ PASS | Rename state lives in ViewModel; bridge applies to libtorrent on confirm |
| **VIII. Architectural Separation** | ✅ PASS | Follows View → ViewModel → Engine → Bridge layering |
| **IX. Test on Behavior Change** | ✅ PASS | Name-validation / rename-path logic unit-tested |
| **X. Build & Test Verification** | ✅ PASS | Must pass `swift test` |
| **XI. Focused Changes** | ✅ PASS | One cohesive feature |
| **XIII. Explicit Destructive Operations** | ✅ PASS | Renaming is not destructive; in-memory until confirm |

**No violations. Gate passes.**

## Project Structure

### Documentation (this feature)

```text
specs/002-rename-before-install/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
├── spec.md              # Feature specification
├── checklists/
│   └── requirements.md  # Quality checklist
└── tasks.md             # Phase 2 output (not created by /speckit.plan)
```

### Source Code (repository root)

```text
Sources/
├── Models/
│   ├── PendingTorrent.swift          # + expanded path storage for renamed files
│   ├── FileNode.swift                # + name editing / rename tracking
│   └── PreAddViewModel.swift         # + rename + validation logic
├── Views/
│   └── PreAddSheet.swift             # + rename UI (inline text fields, root/folder/file)
└── Engine/
    └── Bridge/ObjC/
        ├── include/LibtorrentWrapper.h   # + renamed paths param on add/commit
        └── LibtorrentWrapper.mm          # + populate renamed_files / rename_file

Tests/
└── PreAddRenameTests.swift           # + rename validation + path logic tests
```

**Structure Decision**: Single SwiftPM project. Extends the existing
`PreAddSheet`/`PreAddViewModel`/`FileNode`/`PendingTorrent` code. No new source
modules or files beyond one test file.

## Complexity Tracking

None. No constitution violations to justify.