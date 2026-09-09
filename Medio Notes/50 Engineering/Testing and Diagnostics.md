---
type: engineering
status: active
tags:
  - medio
  - engineering
  - testing
  - diagnostics
aliases:
  - Testing
  - Diagnostics
---

# Testing and Diagnostics

The project includes UI-test switches, in-memory services, fixture libraries, diagnostics recording, logging, and performance signposts.

## Test Runtime

`AppRuntime` reads launch arguments:

- `-medioUITestMode`
- `-medioUITestReset`
- `-medioInitialTab`
- `-medioInitialRoute`
- `-medioInitialPath`
- `-medioStartFirstPlayable`
- `-medioUITestLongLibrary`

These feed [[Dependency Container]] and [[Navigation and Screens]].

## Fixtures

UI test mode creates predictable Documents contents:

- `Example Folder`
- `Song One.mp3`
- `Song Two.mp3`
- `Example Video.mp4`
- optional long fixture tracks

## Observability

- `AppLog` defines logging categories for files, library, persistence, and playback.
- `AppPerformance` exposes an `OSSignposter` for library refresh and indexing intervals.
- `DiagnosticsCenter` records interactions and diagnostic entries for settings/debug panels.

## Connected Notes

- [[App Architecture]]
- [[Library Indexing]]
- [[Playback Pipeline]]
- [[Persistence]]

## Source

- `Sources/AppInfrastructure.swift`
- `Sources/SettingsPanel.swift`
- `Tests/MedioTests/MedioTests.swift`
- `Tests/MedioUITests/MedioUITests.swift`

