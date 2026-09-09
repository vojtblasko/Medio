---
type: feature
status: active
tags:
  - medio
  - feature
  - queue
  - favorites
aliases:
  - Queue
  - Favorites
---

# Queue and Favorites

Queue and Favorites are the app's intent layer: what the user wants to hear next and what they want to keep close.

## Queue Operations

`QueueUseCases` implements:

- set queue
- play next
- add to queue end
- remove from queue
- clear queue
- replace with context queue

Because `PlaybackService` exposes `setQueue`, queue mutations rebuild a new queue and apply it to [[Playback Pipeline]].

## Current Item Preservation

Queue mutations try to preserve the same logical current item when possible. When removing items, the code remembers the current ID, mutates the queue, deduplicates, then finds the new index for that ID or clamps to a valid index.

## Favorites

Favorites are stored separately from the media files and surfaced as a shadow folder plus panels. This keeps favorites useful across [[Home and Library Browsing]], [[Search]], and [[Playback Pipeline]] without changing the user's filesystem.

## Source

- `Sources/QueueUseCases.swift`
- `Sources/UserDefaultsFavoritesRepository.swift`
- `Sources/AppPanels.swift`
- `Sources/Stores.swift`
- `Sources/ViewModels.swift`

