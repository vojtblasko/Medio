---
type: domain
status: active
tags:
  - medio
  - domain
  - lyrics
aliases:
  - Lyrics
  - Lyric Files
---

# Lyrics System

The lyrics system manages local lyric text, associated external lyric files, search indexing, missing-lyrics scanning, and organized lyrics storage.

## Lookup Order

```mermaid
flowchart TB
  Request["loadLyrics(mediaPath)"] --> Migration["Migrate managed storage if needed"]
  Migration --> Associated["Associated lyrics file"]
  Associated -->|missing| Managed["Managed Lyrics directory candidates"]
  Managed -->|missing| Tags["Auto-associate by LRC tags"]
  Tags -->|no tag match| Filename["Exact filename/title/artist match"]
  Filename -->|no match| None["nil"]
```

## Storage Model

- Managed lyrics live under the app's Documents `Lyrics/` folder.
- Associations are stored through `LyricsFileAssociationRepository`.
- Search uses batch loading to avoid per-song metadata work across large libraries.
- Supported text decoding includes UTF-8, UTF-16 variants, and ISO Latin 1.

## Missing Lyrics

`MissingLyricsScanner` can identify songs without lyrics and optionally use speech detection to avoid flagging instrumental tracks. This connects lyrics quality to [[Search]] and library hygiene.

## Connected Notes

- [[Search]]
- [[Persistence]]
- [[Metadata and Artwork]]
- [[Testing and Diagnostics]]

## Source

- `Sources/LyricsRepository.swift`
- `Sources/FileLyricsRepository.swift`
- `Sources/LyricsFileAssociationRepository.swift`
- `Sources/LyricsOrganizationService.swift`
- `Sources/MissingLyricsService.swift`

