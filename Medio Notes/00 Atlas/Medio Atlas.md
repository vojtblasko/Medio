---
type: moc
status: living
tags:
  - medio
  - map
  - architecture
aliases:
  - Project Atlas
  - Medio Atlas
---

# Medio Atlas

Medio is a local-first media library and player. The app scans the user's Documents folder, derives a browsable music/video library, supports lyrics and metadata overrides, and drives playback through a queue-based AVFoundation service.

## Product

- [[Medio Product Brief]] captures the product shape, audience, and core value.
- [[Home and Library Browsing]] describes the primary browsing experience.
- [[Search]] covers song, album, artist, file, and lyrics discovery.
- [[Queue and Favorites]] covers intentional listening flows.

## Architecture

- [[App Architecture]] is the system overview.
- [[Dependency Container]] explains service and repository wiring.
- [[State Stores]] explains `LibraryStore`, `PlaybackStore`, and `SettingsStore`.
- [[Navigation and Screens]] maps tabs, sheets, pushes, and screen composition.

## Domains

- [[Library Indexing]] turns filesystem entries into songs, albums, and artists.
- [[Playback Pipeline]] maps selection into queues and AVQueuePlayer state.
- [[Lyrics System]] handles stored, associated, searched, and missing lyrics.
- [[Metadata and Artwork]] handles file metadata, visual overrides, colors, and artist images.
- [[Persistence]] shows where settings, favorites, history, lyrics, and cache live.
- [[Now Playing and System Integration]] connects playback to OS surfaces.

## Engineering

- [[Source Map]] is the source-file index.
- [[Testing and Diagnostics]] tracks test modes, fixtures, diagnostics, and observability.
- [[Glossary]] defines recurring project terms.

## High-Value Graph Paths

- [[Medio Product Brief]] -> [[Home and Library Browsing]] -> [[Library Indexing]] -> [[Metadata and Artwork]]
- [[Medio Product Brief]] -> [[Queue and Favorites]] -> [[Playback Pipeline]] -> [[Now Playing and System Integration]]
- [[Search]] -> [[Lyrics System]] -> [[Persistence]]
- [[App Architecture]] -> [[Dependency Container]] -> [[State Stores]]

