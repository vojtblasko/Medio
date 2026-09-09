---
type: home
status: living
tags:
  - medio
  - map
  - obsidian-hub
aliases:
  - Medio Notes
  - Medio Vault
---

# Medio Notes

This vault is a graph-first map of [[Medio Product Brief|Medio]], the iOS media library app in this workspace.

## Start Here

- [[Medio Atlas]] is the main map of the vault.
- [[Graph View Guide]] explains how to make the graph useful.
- [[App Architecture]] shows how the app is wired.
- [[Source Map]] links concepts back to Swift source files.

## Core Loops

```mermaid
flowchart LR
  Files["User media files"] --> Library["Library Indexing"]
  Library --> Browse["Home and Library Browsing"]
  Browse --> Queue["Queue and Favorites"]
  Queue --> Playback["Playback Pipeline"]
  Playback --> NowPlaying["Now Playing and System Integration"]
  Lyrics["Lyrics System"] --> Search["Search"]
  Metadata["Metadata and Artwork"] --> Browse
  Persistence["Persistence"] --> Library
  Persistence --> Playback
```

## Graph Hubs

- [[App Architecture]]
- [[Library Indexing]]
- [[Playback Pipeline]]
- [[Lyrics System]]
- [[Metadata and Artwork]]
- [[Navigation and Screens]]
- [[State Stores]]
- [[Persistence]]

