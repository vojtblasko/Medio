---
type: feature
status: active
tags:
  - medio
  - feature
  - search
aliases:
  - Search Experience
  - Library Search
---

# Search

Search spans files, songs, albums, artists, metadata, and lyrics. It relies on the library text index for fast matching and the lyrics repository for lyric text.

## Search Inputs

- `LibrarySearchTextIndex` from [[Library Indexing]].
- Song, album, artist, and file metadata from [[Metadata and Artwork]].
- Batch lyric text from [[Lyrics System]].
- Current library state from [[State Stores]].

## Search Results

Search can surface:

- songs
- albums
- artists
- files/folders
- lyric matches

## Performance Notes

The lyrics repository exposes a batch search capability so the app does not do expensive per-song lyrics association work while filtering thousands of tracks.

## Source

- `Sources/ViewModels.swift`
- `Sources/AppScreens.swift`
- `Sources/AppInfrastructure.swift`
- `Sources/FileLyricsRepository.swift`

