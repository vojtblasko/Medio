---
type: domain
status: active
tags:
  - medio
  - domain
  - metadata
  - artwork
aliases:
  - Metadata
  - Artwork
  - Visual Metadata
---

# Metadata and Artwork

Medio combines embedded file metadata, user overrides, generated display models, custom colors, folder artwork, and artist profile images.

## Metadata Sources

- Embedded AVFoundation metadata through [[Library Indexing]].
- User visual overrides stored by `UserDefaultsVisualMetadataOverridesRepository`.
- Custom song colors stored by `UserDefaultsCustomSongColorsRepository`.
- Artist profile images fetched and cached through `ArtistProfileRepository` implementations.
- Artwork override images saved to Application Support.

## File Metadata

`FileMetadataReader` extracts:

- title
- artist
- album
- genre
- year/date
- album artist
- composer
- track and disc numbers
- duration
- file type and filesystem dates

## Visual Overrides

Visual overrides can change display title, artist, album, genre, year, cover artwork path, and folder color without mutating the original media file.

## Artist Images

Artist image lookup has explicit policy layers:

- identity policy
- public-domain license policy
- MusicBrainz/Wikimedia lookup
- rate limiting and fetch gating

This is connected to [[Now Playing and System Integration]], [[Home and Library Browsing]], and [[Persistence]].

## Source

- `Sources/FileMetadataReader.swift`
- `Sources/ViewModels.swift`
- `Sources/EditMetadataView.swift`
- `Sources/ArtistProfileRepository.swift`
- `Sources/DesignSystem.swift`

