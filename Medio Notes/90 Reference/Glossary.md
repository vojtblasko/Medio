---
type: reference
status: active
tags:
  - medio
  - reference
aliases:
  - Glossary
---

# Glossary

## AppContainer

The composition root that constructs stores, repositories, services, and startup helpers. See [[Dependency Container]].

## FileInfo

The main file/folder domain model. Used by [[Library Indexing]], [[Home and Library Browsing]], [[Search]], and [[Playback Pipeline]].

## MediaItem

The playback-facing item model passed into `PlaybackService`. See [[Playback Pipeline]].

## ShadowAlbum

A derived album grouping built from library songs. See [[Library Indexing]].

## ShadowArtist

A derived artist grouping built from song metadata and artist-name splitting rules. See [[Library Indexing]].

## Shadow Folder

A virtual folder that behaves like a folder in the UI without existing as a real filesystem folder. Favorites use this model. See [[Queue and Favorites]].

## Visual Metadata Override

User-provided display metadata stored separately from media files. See [[Metadata and Artwork]].

## Stable Identity

A normalized persisted path representation created by `PersistedMediaPath` and `AppFilePathPolicy`. See [[Persistence]].

