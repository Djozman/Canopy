<!-- Sync Impact Report
  Version change: 1.0.0 → 1.1.0
  Modified principles:
    I. Bridge Isolation → replaced by VII. Engine-UI Separation & VIII. Architectural Separation
    II. Native macOS Interface → folded into I. Native macOS & Swift Conventions
    III. Engine Serialization (NON-NEGOTIABLE) → folded into VII. Engine-UI Separation
    IV. Test-First → replaced by IX. Test on Behavior Change
    V. ABI-Consistent Build → preserved in Technology Stack section
  Added sections: 8 new principles (II, III, IV, V, VI, X, XI, XII, XIII)
  Removed sections: (none)
  Follow-up TODOs: (none)
-->

# Canopy Constitution

## Core Principles

### I. Native macOS & Swift Conventions

Preserve native macOS and Swift conventions. The UI MUST be built with SwiftUI
and native AppKit controls. Cross-platform abstraction layers or non-native
widget sets MUST NOT be used. The interface MUST follow macOS Human Interface
Guidelines and support light/dark mode. Swift idioms, error handling patterns,
and concurrency primitives (async/await, actors) MUST be preferred over
non-native patterns.

Rationale: Canopy is a macOS-native client. Users expect standard keyboard
shortcuts, menu bar behavior, and system integration. Following Swift
conventions reduces cognitive overhead for contributors.

### II. Simplicity Over Abstraction

Prefer simple, maintainable solutions over unnecessary abstractions. Layers,
protocols, generics, or design patterns MUST NOT be introduced unless they
solve a concrete, demonstrated problem. YAGNI (You Ain't Gonna Need It)
applies to all architectural decisions.

Rationale: Each abstraction layer adds maintenance cost, indirection, and
cognitive load. The simplest solution that meets the requirements is the
correct default.

### III. Dependency Discipline

Do not introduce dependencies unless there is a clear benefit. Every external
dependency (Swift Package, Homebrew library, system framework) MUST be
justified relative to the cost of maintaining it. Vendored code SHOULD be
preferred over dependencies that add build complexity.

Rationale: Dependencies are a source of version conflicts, supply-chain risk,
build failures, and maintenance burden. The project already relies on
libtorrent-rasterbar, Boost, and OpenSSL; new dependencies must meet a high
bar.

### IV. Preserve Existing Functionality

Preserve existing Canopy functionality unless a specification explicitly
changes it. Features, behaviors, and data flows that are currently working
MUST NOT be inadvertently altered or removed during refactoring or feature
implementation.

Rationale: Silent regressions erode user trust. Changes to existing behavior
require a deliberate decision documented in a specification.

### V. Secrets & Credentials Protection

Never expose, hardcode, or commit secrets, credentials, API keys, or private
user data. All sensitive values MUST be loaded from the system keychain,
environment variables, or configuration files excluded from version control.
Secrets MUST NOT appear in logs, error messages, or debug output.

Rationale: Hardcoded secrets in source code are a leading cause of credential
leaks. The git history preserves every commit, making removal after the fact
insufficient.

### VI. Input Validation

Validate untrusted input at security boundaries. All data received from
network peers, magnet links, `.torrent` files, user preferences, and file
system paths MUST be validated before use. Validation MUST reject malformed,
oversized, or unexpected input rather than attempting to sanitize it.

Rationale: BitTorrent clients process data from untrusted peers. Invalid or
malicious input at any boundary can lead to crashes, data corruption, or
exploitation.

### VII. Engine-UI Separation

Keep torrent/network operations isolated from UI concerns. All session
mutations MUST be performed on the engine's serial queue. Torrent state MUST
be published as immutable snapshots on the main actor. Views MUST NOT call
libtorrent session methods directly. Swift code MUST never import or reference
C++ types directly; all C++ interaction MUST go through the ObjC++ bridge.

Rationale: libtorrent session methods are not thread-safe. Serializing
operations through a dedicated queue and publishing only immutable snapshots
eliminates data races. The C++/Swift boundary prevents namespace and ABI
mismatches.

### VIII. Architectural Separation

Maintain clear separation between Views, ViewModels, Models, and Engine code.
Each layer MUST have a defined responsibility and MUST NOT reach into another
layer's domain. ViewModels own presentation logic and state; Models represent
immutable data; the Engine owns all libtorrent interaction.

Rationale: Clear layer boundaries make the codebase navigable, testable, and
resistant to architectural drift. The documented architecture diagram in the
README must be kept accurate.

### IX. Test on Behavior Change

Add or update tests when changing behavior. Any change that alters observable
behavior MUST include tests that cover the new or modified code paths. Tests
MUST be written before the implementation code is merged. The test suite MUST
pass before any PR is merged.

Rationale: Tests are the primary safety net against regressions in a
multi-layer Swift/ObjC++/C++ codebase. Changes without tests risk silent
breakage.

### X. Build & Test Verification

Build and test the project after meaningful implementation changes. All
changes MUST compile without warnings and pass `swift test` before being
committed or merged. CI (GitHub Actions) MUST also pass on macOS 14 and
macOS 15 runners.

Rationale: A green build and test suite is the prerequisite for all
integration. CI catches platform-specific issues that local builds may miss.

### XI. Focused Changes

Do not make unrelated refactors while implementing a feature. Each PR or
commit SHOULD address a single concern. Refactoring, formatting changes, or
style fixes MUST be done in separate commits or PRs from behavior changes.

Rationale: Unrelated changes make reviews harder, increase the risk of
regressions, and obscure the intent of the feature implementation.

### XII. Privacy & Least Privilege

Favor privacy-preserving behavior and least-privilege access. The application
MUST only access the minimum data required for its function. Network activity,
file access, and system resource usage MUST be scoped to the explicit
operation the user initiated. Anonymous mode in libtorrent SHOULD be
respected where applicable.

Rationale: BitTorrent traffic inherently reveals network information.
Minimizing data collection, access, and disclosure reduces harm from
compromise or misuse.

### XIII. Explicit Destructive Operations

Any destructive or irreversible operation MUST be explicitly specified.
Removing a torrent MUST NOT delete user data unless the user has explicitly
chosen "Remove torrent + data". Destructive actions MUST require a distinct
user action (not a hidden default) and SHOULD present a confirmation where
ambiguity exists.

Rationale: Users trust the application with their data. Accidental data loss
from implicit destructive behavior is irrecoverable and breaks trust.

## Technology Stack

- **Language**: Swift 5.10+, Objective-C++ (bridge only)
- **Platform**: macOS 14 Sonoma or newer
- **Dependencies**: libtorrent-rasterbar 2.x, Boost (current Homebrew release),
  OpenSSL 3 (via Homebrew)
- **Build System**: SwiftPM with pkg-config integration. The build MUST consume
  the installed `libtorrent-rasterbar.pc` file to determine compiler and linker
  flags. Hard-coded ABI flags MUST NOT be used.
- **CI/CD**: GitHub Actions on macOS 14 and macOS 15 runners
- **Distribution**: Ad-hoc signed ZIP and DMG via `package_release.sh`

## Development Workflow

- **Branch strategy**: `main` is the integration branch. Feature branches MUST
  be based on `main` and merged via PR.
- **PR requirements**: Every PR MUST include a description of changes, pass
  `swift test`, and verify no new warnings. Bridge changes MUST include
  integration tests.
- **Release process**: Releases are tag-driven. Push a `vMAJOR.MINOR.PATCH`
  tag to trigger the release workflow, which builds, bundles runtime libraries,
  packages ZIP and DMG, and publishes SHA-256 checksums.
- **Bundle scripts**: `build_app.sh` produces an ad-hoc signed app bundle.
  `package_release.sh` produces distributable packages with bundled Homebrew
  libraries. Both MUST be kept in sync with the SwiftPM target list.

## Governance

This constitution defines the non-negotiable principles and constraints of the
Canopy project. It supersedes ad-hoc practices and informal conventions.

- **Amendments**: Proposals to amend the constitution MUST be submitted as a
  PR that modifies `.specify/memory/constitution.md`. The PR description MUST
  include the rationale, the affected section, and the version impact.
- **Versioning**: Constitution versions follow semantic versioning:
  - MAJOR: backward-incompatible governance or principle changes.
  - MINOR: new principles or materially expanded guidance.
  - PATCH: clarifications, wording refinements, or typo fixes.
- **Compliance review**: Every PR MUST be reviewed for constitution compliance
  before merging. Reviewers MUST verify that the change does not violate any
  principle or constraint.
- **Deviation policy**: Any deviation from a constitutional principle MUST be
  documented in the PR description with a justification. Persistent deviations
  require a constitution amendment.

**Version**: 1.1.0 | **Ratified**: 2026-08-17 | **Last Amended**: 2026-08-17