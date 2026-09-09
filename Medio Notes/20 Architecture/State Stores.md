---
type: architecture
status: active
tags:
  - medio
  - architecture
  - state
aliases:
  - Stores
  - App State
---

# State Stores

The app's observable state lives primarily in `LibraryStore`, `PlaybackStore`, and `SettingsStore`. These stores form the shared state backbone used by view models, screens, and services.

## LibraryStore

Owns the derived library collections:

- all files/folders
- playable songs
- shadow albums
- shadow artists
- favorites and priority slots
- scan progress and storage summaries

Connected notes: [[Library Indexing]], [[Home and Library Browsing]], [[Search]].

## PlaybackStore

Tracks the currently visible playback model:

- current item
- queue
- current index
- play/pause state
- position and duration
- shuffle and repeat

Connected notes: [[Playback Pipeline]], [[Queue and Favorites]], [[Now Playing and System Integration]].

## SettingsStore

Holds user preferences for presentation and playback-adjacent behavior. It is backed by [[Persistence]] through `PreferencesRepository`.

Connected notes: [[Metadata and Artwork]], [[Home and Library Browsing]].

## Source

- `Sources/Stores.swift`
- `Sources/PreferencesRepository.swift`
- `Sources/UserDefaultsPreferencesRepository.swift`

