---
type: product
status: active
tags:
  - medio
  - product
  - feature
aliases:
  - Medio
  - Product Brief
---

# Medio Product Brief

Medio is an iOS media library for people who manage their own local audio and video files. It behaves more like a private music shelf than a streaming client: the user's files, lyrics, favorites, metadata choices, and listening history are first-class.

## Product Thesis

Give a local library the polish of a modern music app without hiding the filesystem. The user should be able to browse by folders, albums, artists, favorites, and search while still understanding where files live.

## Core Experiences

- [[Home and Library Browsing]]: fast entry into folders, albums, artists, favorites, and priority slots.
- [[Playback Pipeline]]: select media, build the context queue, play, seek, skip, shuffle, and repeat.
- [[Lyrics System]]: read and associate local lyric files, search lyric text, and identify songs missing lyrics.
- [[Metadata and Artwork]]: extract embedded metadata and let users override visual presentation.
- [[Now Playing and System Integration]]: keep lock screen, remote commands, notifications, and playback state aligned.

## Design Priorities

- Local-first reliability over network dependency.
- Fast library startup using cached indexes.
- Respect for real folder organization.
- Beautiful presentation through artwork, colors, profiles, and metadata overrides.
- Clear recovery paths when files, lyrics, or cache data are missing.

## Product Risks

- Large libraries make scan performance, caching, and search indexing critical. See [[Library Indexing]].
- Queue rebuilding can surprise users if current item preservation is wrong. See [[Queue and Favorites]].
- Metadata and artist identity heuristics need careful user override paths. See [[Metadata and Artwork]].

