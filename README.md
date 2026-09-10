# Medio

**Your files. A proper listening experience.**

Medio is a local-first audio and video player for iPhone and iPad, built with SwiftUI and AVFoundation. Browse your own folders, discover albums and artists from file metadata, and listen with lyrics, favorites, and a persistent listening history.

## What you can do

- **Browse your way.** Home offers list, icon, and desktop-style views, sorting, adjustable icon sizes, and up to ten priority slots. Pin folders or use a priority slot as an image-only card.
- **Organize your files.** Import through the system Files picker, create folders, select and move items, and drag files between folders. Medio exposes its Documents folder in Files.
- **Explore your library.** Browse songs, albums, and artists derived from local metadata. Cached indexing speeds up startup and avoids rebuilding the entire library for every view.
- **Control playback.** Play audio and video, seek, manage the queue, shuffle, repeat a track or queue, and use favorites. Audio supports background playback, Lock Screen controls, and system remote commands; video can open fullscreen.
- **Read and manage lyrics.** Display local lyrics, associate lyric files with tracks, organize managed lyrics, and find songs missing lyrics. Optional on-device speech detection helps distinguish instrumental tracks during scanning.
- **Customize presentation.** Edit display metadata, artwork, and colors, and choose images from Photos or Files. Visual overrides are stored by Medio separately from embedded media tags.
- **Search across your collection.** Find files, songs, albums, artists, metadata, and lyric text from the Search tab.
- **Keep a listening history.** Local SQLite storage records playback activity for listening statistics and Medio ReCapped.

The interface uses native Liquid Glass on iOS 26, with compatible styling on earlier supported versions.

## Get started

1. Build and launch Medio using the instructions below.
2. Open **Home → … → Import Files**, or add media to Medio's folder in the Files app.
3. Browse folders in Home, or use Library to browse the indexed songs, albums, and artists.
4. Tap a track to start playback and open Now Playing for playback controls and lyrics.
5. Configure priority folders, online access, and other preferences in **Home → … → Settings**. Long-press a priority card to change its folder or make it an image card.

Medio recognizes common audio extensions such as MP3, M4A, AAC, WAV, AIFF, FLAC, and ALAC, as well as video extensions including MP4, M4V, and MOV. Recognition in the browser does not guarantee decoding: playback depends on AVFoundation support for the file's actual codec and container, and protected files may not play.

## Local storage and optional internet access

Your media, managed lyrics, settings, favorites, artwork overrides, and listening history live in the app's local storage. Medio does not require a streaming account to browse or play local media.

The **App Can Connect to the Internet** setting controls optional network features. When enabled, artist-picture lookup can use MusicBrainz and Wikimedia sources and checks image-license metadata. Disabling internet access stops those lookups; the app explains when downloaded artist pictures will be removed. Files providers may handle their own downloads when you import a file.

Storage, interaction, and internet diagnostics can be enabled separately in Settings for troubleshooting.

## Build and run

- **Deployment target:** iOS / iPadOS 15.5 or later.
- **Development tools:** Xcode with an iOS 26 or newer SDK, and Swift 6.
- **Project:** `Medio.xcodeproj`; scheme: `Medio`.

Open the project in Xcode, select the Medio scheme and a simulator, then run. For a physical device, configure your own signing team in the app target's Signing & Capabilities settings.

```sh
xcodebuild build \
  -project Medio.xcodeproj \
  -scheme Medio \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

## Tests

`Medio.xctestplan` includes unit and UI tests. Choose an installed simulator in Xcode, or replace the simulator name below with one from `xcrun simctl list devices available`:

```sh
xcodebuild test \
  -project Medio.xcodeproj \
  -scheme Medio \
  -testPlan Medio \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Unit tests cover playback and queues, library indexing and filtering, persistence, file operations, lyrics, artwork, and system-picker coordination. UI tests exercise browsing, folder workflows, menus, playback screens, and priority-card behavior. The UI suite uses fixture media and resets its app data, so run it on a dedicated simulator.

GitHub Actions builds the app and runs both test targets using the [iOS CI workflow](.github/workflows/ci.yml).

## Project map

| Location | Purpose |
| --- | --- |
| `Sources/MedioApp.swift`, `RootView.swift`, `AppRouter.swift` | App entry, navigation, and presentation |
| `Sources/AppScreens.swift`, `AppPanels.swift`, `NowPlayingPanel.swift` | Browsing and playback screens |
| `Sources/DesignSystem.swift` | Shared artwork, controls, visualizers, and styling |
| `Sources/AppContainer.swift`, `Stores.swift`, `ViewModels.swift` | Dependencies and observable application state |
| `Sources/AudioPlaybackService.swift`, `NowPlaying.swift` | AVFoundation playback and system integration |
| `Sources/MediaLibraryRepository.swift`, `BuildLibraryIndexUseCase.swift` | File scanning, caching, and library indexing |
| `Sources/FileLyricsRepository.swift`, `MissingLyricsService.swift` | Local lyrics and missing-lyrics detection |
| `Sources/SQLiteListeningHistoryRepository.swift` | Persistent listening history |
| `Tests/MedioTests`, `Tests/MedioUITests` | Unit and UI tests |
| `Resources` | App assets and configuration |

For a fuller product and architecture overview, start with the [Medio Atlas](Medio%20Notes/00%20Atlas/Medio%20Atlas.md).
