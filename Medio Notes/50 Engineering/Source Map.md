---
type: reference
status: active
tags:
  - medio
  - source-map
  - engineering
aliases:
  - Source Index
  - Code Map
---

# Source Map

This index maps source files to concepts in the vault.

## App Shell

- `Sources/MedioApp.swift` -> [[App Architecture]]
- `Sources/RootView.swift` -> [[Navigation and Screens]], [[Dependency Container]]
- `Sources/AppContainer.swift` -> [[Dependency Container]]
- `Sources/AppRouter.swift` -> [[Navigation and Screens]]
- `Sources/AppRoutes.swift` -> [[Navigation and Screens]]

## UI

- `Sources/AppScreens.swift` -> [[Home and Library Browsing]], [[Search]]
- `Sources/AppPanels.swift` -> [[Home and Library Browsing]], [[Queue and Favorites]]
- `Sources/NowPlayingPanel.swift` -> [[Now Playing and System Integration]]
- `Sources/SettingsPanel.swift` -> [[State Stores]], [[Testing and Diagnostics]]
- `Sources/DesignSystem.swift` -> [[Metadata and Artwork]]
- `Sources/EditMetadataView.swift` -> [[Metadata and Artwork]]

## Domain and State

- `Sources/Stores.swift` -> [[State Stores]], [[Playback Pipeline]], [[Library Indexing]]
- `Sources/ViewModels.swift` -> [[Home and Library Browsing]], [[Search]], [[Queue and Favorites]]
- `Sources/BuildLibraryIndexUseCase.swift` -> [[Library Indexing]]
- `Sources/ScanLibraryUseCase.swift` -> [[Library Indexing]]
- `Sources/PlayMediaUseCase.swift` -> [[Playback Pipeline]]
- `Sources/QueueUseCases.swift` -> [[Queue and Favorites]]

## Data and Persistence

- `Sources/MediaLibraryRepository.swift` -> [[Library Indexing]], [[Persistence]]
- `Sources/FileMetadataReader.swift` -> [[Metadata and Artwork]]
- `Sources/FileLyricsRepository.swift` -> [[Lyrics System]], [[Persistence]]
- `Sources/LyricsFileAssociationRepository.swift` -> [[Lyrics System]], [[Persistence]]
- `Sources/UserDefaultsPreferencesRepository.swift` -> [[Persistence]], [[State Stores]]
- `Sources/UserDefaultsFavoritesRepository.swift` -> [[Queue and Favorites]], [[Persistence]]
- `Sources/SQLiteListeningHistoryRepository.swift` -> [[Persistence]], [[Now Playing and System Integration]]

## System Services

- `Sources/AudioPlaybackService.swift` -> [[Playback Pipeline]]
- `Sources/NowPlaying.swift` -> [[Now Playing and System Integration]]
- `Sources/Notifications.swift` -> [[Now Playing and System Integration]]
- `Sources/SystemUI.swift` -> [[Navigation and Screens]]
- `Sources/BatterySaverService.swift` -> [[State Stores]]

## Support

- `Sources/AppInfrastructure.swift` -> [[Persistence]], [[Testing and Diagnostics]]
- `Sources/FileMoveService.swift` -> [[Home and Library Browsing]]
- `Sources/ImportDocumentsUseCase.swift` -> [[Home and Library Browsing]]
- `Tests/MedioTests/MedioTests.swift` -> [[Testing and Diagnostics]]
- `Tests/MedioUITests/MedioUITests.swift` -> [[Testing and Diagnostics]]

