# Medio

**Your files. A proper listening experience.**

Medio is a local-first audio and video player for iPhone, built with SwiftUI and AVFoundation. Browse your own folders, discover albums and artists from file metadata, and listen with lyrics, favorites, and a persistent listening history.

## What you can do

- **Browse your way.** Home offers list, icon, and desktop-style views, sorting, adjustable icon sizes, and up to ten priority slots. Pin folders or use a priority slot as an image-only card with the same size and a matching rectangular crop. Native sort menus show the selected direction; choose the same sort again to reverse it.
- **Organize your files.** Import through the system Files picker, create folders, select and move items, and drag files between folders. Medio exposes its Documents folder in Files.
- **Explore your library.** Browse songs, albums, and artists derived from local metadata. Cached indexing speeds up startup and avoids rebuilding the entire library for every view.
- **Control playback.** Play audio and video, seek, manage the queue, shuffle, repeat a track or queue, and use favorites. Earlier entries are dimmed only inside the queue; repeat indicators show whether the current song or the whole queue loops. Removing or moving another queue entry keeps the current song and playback position. Audio supports background playback, Lock Screen controls, and system remote commands; video can open fullscreen.
- **Read and manage lyrics.** Display local lyrics, associate lyric files with tracks, organize managed lyrics, and find songs missing lyrics. Optional on-device speech detection helps distinguish instrumental tracks during scanning.
- **Customize presentation.** Edit display metadata, artwork, and colors, and choose images from Photos or Files. Small browsing thumbnails fill their square frames, while the larger Now Playing cover keeps its original proportions. Choose which songs, albums, and artists show the audio spectrum under **Settings → Playback Indicators**. Visual overrides are stored by Medio separately from embedded media tags.
- **Search across your collection.** Find files, songs, albums, artists, metadata, and lyric text from the Search tab.
- **Keep a listening history.** Local SQLite storage records playback activity for listening statistics and Medio ReCapped.

English, Czech, German, and French are included. Medio follows the device’s preferred supported language, with English as the fallback. **Settings → Language → App Language** opens iOS app settings for a per-app language choice. File names, music metadata, and lyrics retain their original language.

The interface uses native Liquid Glass on iOS 26, with compatible styling on earlier supported versions. Settings, Queue, Now Playing, and detail pages open full screen above the four main tabs. Album headers load the original embedded artwork independently of the smaller thumbnail cache.

## Get started

1. Build and launch Medio using the instructions below.
2. Open **Home → … → Import Files**, or add media to Medio's folder in the Files app.
3. Browse folders in Home, or use Library to browse the indexed songs, albums, and artists.
4. Tap a track to start playback and open Now Playing for playback controls and lyrics.
5. Configure priority folders, separate Home/priority Favorites switches, online access, and other preferences in **Home → … → Settings**. Long-press a priority card to change its folder or make it an image card.

Medio recognizes common audio extensions such as MP3, M4A, AAC, WAV, AIFF, FLAC, and ALAC, as well as video extensions including MP4, M4V, and MOV. Recognition in the browser does not guarantee decoding: playback depends on AVFoundation support for the file's actual codec and container, and protected files may not play.

## Local storage and optional internet access

Your media, managed lyrics, settings, favorites, artwork overrides, and listening history live in the app's local storage. Medio does not require a streaming account to browse or play local media.

The **App Can Connect to the Internet** setting controls optional network features. When enabled, artist-picture lookup can use MusicBrainz and Wikimedia sources and checks image-license metadata. Disabling internet access stops those lookups; the app explains when downloaded artist pictures will be removed. One switch controls artist lookup, image/license lookup, and image downloads together. Each process remains listed with its own persistent usage counter. Counters start when this version is first opened and measure sent/received HTTP bytes, excluding cache hits and connection overhead; they can be reset in Settings. Files providers may handle their own downloads when you import a file.

For future app-owned network features, add an `OnlineFeature` case and route requests through `OnlineAccessStore.data(for:feature:using:)`. Settings automatically lists registered processes and counters under the same master switch. External Safari pages and system Files providers are outside this gate.

Storage, interaction, and internet diagnostics can be enabled separately in Settings for troubleshooting. **Crash Report & Bugs Manager → Report a Bug on GitHub** opens a new issue in this repository; diagnostics are only included if you choose to copy them into your report.

## Share audio through Safari

1. Connect the host iPhone and listening devices to the same trusted Wi-Fi network.
2. In **Settings → Share Audio**, enable **Share with Other Headphones or Speakers**.
3. On each new listening device, follow **Set Up Encryption**. Download the host's public certificate using its setup QR code, verify its SHA-256 fingerprint against the host, install the profile, and explicitly enable certificate trust in iOS Settings. [Apple explains manual certificate trust](https://support.apple.com/102390). Trust only a host you control; a root certificate grants trust to certificates that host signs. Remove the profile when no longer needed.
4. Scan the **join QR code** to open the HTTPS player and fill in the session code, then tap **Listen**. Alternatively, enter the HTTPS address and code manually. Pair each receiving device with its own headphones or speaker.
5. Play local media in Medio. Listeners follow track changes, seeking, and play/pause. If Safari pauses playback, tap **Listen** again.
6. Turn sharing off to end the session. Leaving Medio also ends it. Keep the host app open; automatic locking is disabled only while sharing is active.

Audio, access codes, and playback state travel over TLS-protected HTTPS. A per-install certificate authority is stored in this device's Keychain; each session gets a short-lived certificate for its Wi-Fi address, a fresh access code, and an access token. The only plaintext HTTP endpoint serves the **public certificate**; it cannot serve audio, join requests, or playback metadata. The join code is in the QR link's fragment, which is removed after the page reads it. It is never sent in the initial page request. Keep the QR and join link private.

Sharing is local and independent of the internet switch. Its session counter includes application-level traffic for the player and certificate download, excluding TLS/network overhead. There is no cloud relay, third-party script, or analytics. Only the current eligible file is served; clients cannot browse the library or filesystem. Authorized listeners receive playable audio, so HTTPS does not prevent them from retaining a copy.

**Reduce Audio Bandwidth** optionally prepares a temporary stereo AAC copy at 96 kbps. This is lossy compression, not decompression, and can reduce transfer size for high-bitrate sources; an already smaller source is not guaranteed to shrink. Preparation adds startup delay and uses processing power. Videos always send only their audio track (256 kbps AAC normally, 96 kbps with this option); their pictures remain on the host. Original files are never edited. Copies use iOS file protection and are removed when released. Available common metadata is carried into the copy.

The receiver adjusts small timing differences gradually and seeks for larger differences. Wi-Fi, browser buffering, and Bluetooth delay still prevent guaranteed simultaneous headphone playback. Guest networks with device isolation may block sharing. Unprotected local MP3, M4A, AAC, WAV, AIFF, and FLAC files are candidates for direct playback; the browser must support the actual codec. Videos need an AVFoundation-readable audio track. Protected media, other apps' sound, and system audio capture are unsupported. Certificate onboarding and timing across physical phones still require device testing.

For the Czech/EU copyright assessment and the limits of personal copying, see [Audio sharing and copyright](docs/audio-sharing-copyright.md). Share only material for which you have the required rights; local Wi-Fi, encryption, and compression do not provide permission.

Medio requests local-network permission for this feature, following [Apple’s local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). The receiving browser requires a user tap to begin audible playback, as described in [Apple’s HTML audio guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/Using_HTML5_Audio_Video/AudioandVideoTagBasics/AudioandVideoTagBasics.html).

## Build and run

- **Deployment target:** iOS 15.5 or later.
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
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS="$PWD/Tests/Simulator.entitlements"
```

Simulator tests use local ad-hoc signing with test-only entitlements so Keychain and HTTPS tests run without an Apple signing certificate. Never apply `Tests/Simulator.entitlements` to device distribution builds.

Unit tests cover encrypted connections, certificate trust, QR joining, audio-only conversion, playback and queues, library indexing and filtering, persistence, file operations, lyrics, artwork, and system-picker coordination. UI tests exercise browsing, folder workflows, menus, playback screens, and priority-card behavior. The UI suite uses fixture media and resets its app data, so run it on a dedicated simulator.

GitHub Actions builds the app and runs both test targets using the [iOS CI workflow](.github/workflows/ci.yml).

## Project map

| Location | Purpose |
| --- | --- |
| `Sources/MedioApp.swift`, `RootView.swift`, `AppRouter.swift` | App entry, navigation, and presentation |
| `Sources/AppScreens.swift`, `AppPanels.swift`, `NowPlayingPanel.swift` | Browsing and playback screens |
| `Sources/DesignSystem.swift` | Shared artwork, controls, visualizers, and styling |
| `Sources/AppContainer.swift`, `Stores.swift`, `ViewModels.swift` | Dependencies and observable application state |
| `Sources/AudioPlaybackService.swift`, `NowPlaying.swift` | AVFoundation playback and system integration |
| `Sources/LocalAudioSharing.swift`, `SharingReceiverPage.swift`, `SharingSecurity.swift`, `SharingAudioPreparation.swift` | HTTPS sharing, QR joining, certificate identities, and audio-only conversion |
| `Resources/Localizable.xcstrings`, `InfoPlist.xcstrings` | English, Czech, German, and French interface and permission text |
| `Sources/MediaLibraryRepository.swift`, `BuildLibraryIndexUseCase.swift` | File scanning, caching, and library indexing |
| `Sources/FileLyricsRepository.swift`, `MissingLyricsService.swift` | Local lyrics and missing-lyrics detection |
| `Sources/SQLiteListeningHistoryRepository.swift` | Persistent listening history |
| `Tests/MedioTests`, `Tests/MedioUITests` | Unit and UI tests |
| `Resources` | App assets and configuration |

For a fuller product and architecture overview, start with the [Medio Atlas](Medio%20Notes/00%20Atlas/Medio%20Atlas.md).
