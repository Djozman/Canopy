# Implementation Plan: Sequential Download & Smart Double-Click

**Branch**: `001-sequential-download-open-action` | **Date**: 2026-08-17 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-sequential-download-open-action/spec.md`

## Summary

Add a per-torrent "Download in order" toggle that requests pieces from first to
last, and change double-click on a completed torrent name to open the file (if
single-file) or the folder (if multi-file) instead of always revealing in Finder.

## Technical Context

**Language/Version**: Swift 5.10+, Objective-C++ (bridge only)

**Primary Dependencies**: libtorrent-rasterbar 2.x (via Homebrew), SwiftUI,
Combine, Foundation (NSWorkspace)

**Storage**: Filesystem — torrent resume data at
`~/Library/Application Support/Canopy/Resume/`; download data at user-chosen
save path

**Testing**: XCTest (`swift test`)

**Target Platform**: macOS 14 Sonoma or newer

**Project Type**: Desktop app (macOS native, SwiftUI)

**Performance Goals**: Responsive UI during sequential piece requests; file open
or Finder reveal completes in under 1 second

**Constraints**: Engine-UI separation via serial queue + immutable snapshots;
all libtorrent calls must go through the ObjC++ bridge; no new external
dependencies

**Scale/Scope**: Single-user desktop app

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| **I. Native macOS & Swift Conventions** | ✅ PASS | Toggle follows macOS UX patterns; smart double-click uses system file-opening conventions |
| **II. Simplicity Over Abstraction** | ✅ PASS | No new abstractions — extends existing engine/bridge layer |
| **III. Dependency Discipline** | ✅ PASS | No new dependencies — uses NSWorkspace (system framework) and extends existing bridge API |
| **IV. Preserve Existing Functionality** | ✅ PASS | Incomplete torrents preserve existing reveal-in-Finder behavior per spec |
| **VII. Engine-UI Separation** | ✅ PASS | Sequential download toggle routed through engine's serial queue |
| **VIII. Architectural Separation** | ✅ PASS | Follows existing View → ViewModel → Engine → Bridge layering |
| **IX. Test on Behavior Change** | ✅ PASS | Tests required for both features |
| **X. Build & Test Verification** | ✅ PASS | Must pass `swift test` |
| **XI. Focused Changes** | ✅ PASS | Both features in same spec per user request |
| **XIII. Explicit Destructive Operations** | ✅ PASS | Not applicable |

**No violations. Gate passes.**

## Project Structure

### Documentation (this feature)

```text
specs/001-sequential-download-open-action/
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
├── Engine/
│   ├── Bridge/ObjC/
│   │   ├── include/LibtorrentWrapper.h   # + sequentialDownload property
│   │   └── LibtorrentWrapper.mm          # + sequential download getter/setter
│   └── TorrentEngine.swift               # + setSequentialDownload() method
├── Models/
│   └── TorrentStatus                     # + isSequentialDownload field
├── ViewModels/
│   └── TorrentListViewModel.swift        # + sequential download action
├── Views/
│   ├── ContentView.swift                 # + smart double-click logic, + sequential toggle in context menu
│   └── TorrentRowView.swift              # + sequential download indicator icon

Tests/
└── TorrentEngineTests.swift              # + sequential download toggle tests
```

**Structure Decision**: Single SwiftPM project. Both features extend existing
files without creating new source files or modules.

## Complexity Tracking

None. No constitution violations to justify.