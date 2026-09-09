---
type: guide
status: living
tags:
  - medio
  - obsidian
  - graph
aliases:
  - Graph View
  - Obsidian Graph Guide
---

# Graph View Guide

The vault is organized around hub notes. The best graph view comes from filtering by topic tags and following dense links between the hubs.

## Recommended Filters

- `tag:#architecture` shows the app skeleton: [[App Architecture]], [[Dependency Container]], [[State Stores]], and [[Navigation and Screens]].
- `tag:#domain` shows implementation domains: [[Library Indexing]], [[Playback Pipeline]], [[Lyrics System]], [[Metadata and Artwork]], [[Persistence]].
- `tag:#feature` shows user-facing behavior: [[Home and Library Browsing]], [[Search]], [[Queue and Favorites]].
- `tag:#source-map` shows source reference notes.

## Layout Pattern

Use [[Medio Atlas]] as the central anchor. Then open local graph from:

- [[App Architecture]] for technical topology.
- [[Playback Pipeline]] for runtime behavior.
- [[Library Indexing]] for data derivation.
- [[Lyrics System]] for file association and search behavior.

## Link Hygiene

When adding future notes:

- Link every new note to exactly one hub.
- Link concrete code concepts to [[Source Map]].
- Prefer notes named by stable concepts, not temporary tasks.
- Use `status: draft`, `status: active`, or `status: stable` in frontmatter.

