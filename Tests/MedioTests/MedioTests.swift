import XCTest
import UIKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import WebKit
import SQLite3
import Security
import CryptoKit
import CoreImage
@testable import Medio

private struct StubLyricsRepository: LyricsRepository {
    let lyricsByPath: [String: String]

    func loadLyrics(forMediaPath path: String) async throws -> String? {
        lyricsByPath[path]
    }

    func saveLyrics(_ lrc: String, forMediaPath path: String) async throws {}
    func deleteLyrics(forMediaPath path: String) async throws {}
}

private enum MissingLyricsTestError: Error {
    case unavailable
}

private struct StubAudioSpeechDetector: AudioSpeechDetecting {
    let resultsByPath: [String: Result<Bool, Error>]

    func containsSpeech(in mediaURL: URL) async throws -> Bool {
        try resultsByPath[mediaURL.path, default: .failure(MissingLyricsTestError.unavailable)].get()
    }
}

private struct FailingAudioSpeechDetector: AudioSpeechDetecting {
    func containsSpeech(in mediaURL: URL) async throws -> Bool {
        throw MissingLyricsTestError.unavailable
    }
}

private struct StubMediaLibraryDataSource: MediaLibraryDataSource {
    let cachedItems: [FileInfo]?
    let scannedItems: [FileInfo]

    func loadCachedItems() -> [FileInfo]? {
        cachedItems
    }

    func scanAndCacheItems() async throws -> [FileInfo] {
        scannedItems
    }
}

private final class CountingMediaLibraryDataSource: MediaLibraryDataSource, @unchecked Sendable {
    let cachedItems: [FileInfo]?
    let scannedItems: [FileInfo]
    private(set) var scanCount = 0

    init(cachedItems: [FileInfo]?, scannedItems: [FileInfo]) {
        self.cachedItems = cachedItems
        self.scannedItems = scannedItems
    }

    func loadCachedItems() -> [FileInfo]? {
        cachedItems
    }

    func scanAndCacheItems() async throws -> [FileInfo] {
        scanCount += 1
        return scannedItems
    }
}

private struct ThrowingMediaLibraryDataSource: MediaLibraryDataSource {
    let error: Error

    func loadCachedItems() -> [FileInfo]? {
        nil
    }

    func scanAndCacheItems() async throws -> [FileInfo] {
        throw error
    }
}

private struct DelayedMediaLibraryDataSource: MediaLibraryDataSource {
    let delayNanoseconds: UInt64
    let scannedItems: [FileInfo]

    func loadCachedItems() -> [FileInfo]? { nil }

    func scanAndCacheItems() async throws -> [FileInfo] {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return scannedItems
    }
}

private actor StubListeningHistoryRepository: ListeningHistoryRepository {
    private var sessions: [ListeningSession]

    init(sessions: [ListeningSession]) {
        self.sessions = sessions
    }

    func loadSessions() async throws -> [ListeningSession] {
        sessions
    }

    func appendSession(_ session: ListeningSession) async throws {
        sessions.append(session)
    }

    func clearSessions() async throws {
        sessions.removeAll()
    }

    func storedSessions() -> [ListeningSession] {
        sessions
    }
}

@MainActor
private final class StubNotificationsService: NotificationsService {
    func requestAuthorization() async throws -> Bool { true }
    func scheduleLocal(title: String, body: String, after seconds: TimeInterval) async throws { }
    func cancelAll() async { }
}

private func makeTestImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
        UIColor.systemRed.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
}

@MainActor
final class MissingLyricsScannerTests: XCTestCase {
    func testIncludePolicyListsEveryPlayableFileWithoutLyricsWithoutSpeechAnalysis() async throws {
        let withLyrics = FileInfo(id: "/music/with-lyrics.mp3", isDirectory: false, displayName: "With Lyrics", author: nil, album: nil)
        let missingMusic = FileInfo(id: "/music/instrumental.mp3", isDirectory: false, displayName: "Instrumental", author: nil, album: nil)
        let missingVideo = FileInfo(id: "/music/video.mp4", isDirectory: false, displayName: "Video", author: nil, album: nil)
        let scanner = MissingLyricsScanner(
            lyricsRepository: StubLyricsRepository(lyricsByPath: [withLyrics.id: "Lyrics"]),
            speechDetector: FailingAudioSpeechDetector()
        )

        let report = try await scanner.scan(
            songs: [withLyrics, missingMusic, missingVideo],
            speechlessMusicPolicy: .include
        )

        XCTAssertEqual(report.files.map(\.song.id), [missingMusic.id, missingVideo.id])
        XCTAssertEqual(report.files.map(\.speechAnalysis), [.notRequested, .notRequested])
        XCTAssertEqual(report.speechlessMusicExcludedCount, 0)
        XCTAssertEqual(report.speechAnalysisFailureCount, 0)
    }

    func testExcludePolicyRemovesSpeechlessMusicButKeepsVideos() async throws {
        let vocal = FileInfo(id: "/music/vocal.mp3", isDirectory: false, displayName: "Vocal", author: nil, album: nil)
        let instrumental = FileInfo(id: "/music/instrumental.m4a", isDirectory: false, displayName: "Instrumental", author: nil, album: nil)
        let video = FileInfo(id: "/music/video.mp4", isDirectory: false, displayName: "Video", author: nil, album: nil)
        let detector = StubAudioSpeechDetector(resultsByPath: [
            vocal.id: .success(true),
            instrumental.id: .success(false)
        ])
        let scanner = MissingLyricsScanner(
            lyricsRepository: StubLyricsRepository(lyricsByPath: [:]),
            speechDetector: detector
        )

        let report = try await scanner.scan(
            songs: [vocal, instrumental, video],
            speechlessMusicPolicy: .exclude
        )

        XCTAssertEqual(report.files.map(\.song.id), [vocal.id, video.id])
        XCTAssertEqual(report.files.map(\.speechAnalysis), [.speechDetected, .notRequested])
        XCTAssertEqual(report.speechlessMusicExcludedCount, 1)
        XCTAssertEqual(report.speechAnalysisFailureCount, 0)
    }

    func testExcludePolicyKeepsFilesWhenSpeechAnalysisFails() async throws {
        let song = FileInfo(id: "/music/unreadable.mp3", isDirectory: false, displayName: "Unreadable", author: nil, album: nil)
        let scanner = MissingLyricsScanner(
            lyricsRepository: StubLyricsRepository(lyricsByPath: [:]),
            speechDetector: FailingAudioSpeechDetector()
        )

        let report = try await scanner.scan(
            songs: [song],
            speechlessMusicPolicy: .exclude
        )

        XCTAssertEqual(report.files, [MissingLyricsFile(song: song, speechAnalysis: .analysisUnavailable)])
        XCTAssertEqual(report.speechlessMusicExcludedCount, 0)
        XCTAssertEqual(report.speechAnalysisFailureCount, 1)
    }
}

@MainActor
final class AppRouterTests: XCTestCase {
    func testSheetPresentationAndDismissal() {
        let router = AppRouter()
        XCTAssertNil(router.sheet)
        router.present(.settings)
        XCTAssertEqual(router.sheet, .settings)
        router.dismissSheet()
        XCTAssertNil(router.sheet)

        router.present(.folder(path: "/root"))
        router.present(.folder(path: "/root/child"))

        XCTAssertEqual(router.sheet, .folder(path: "/root"))
        XCTAssertEqual(router.sheetPath, [.folder(path: "/root/child")])
        XCTAssertEqual(router.currentSheetRoute, .folder(path: "/root/child"))

        router.dismissSheet()
        XCTAssertEqual(router.sheet, .folder(path: "/root"))
        XCTAssertTrue(router.sheetPath.isEmpty)

        router.dismissSheet()
        XCTAssertNil(router.sheet)
    }

    func testNowPlayingOpensAboveThePageAndKeepsItsNavigationPath() {
        let router = AppRouter()
        router.push(.folder(path: "/music"))
        router.push(.nowPlaying)
        XCTAssertTrue(router.pushPath.isEmpty)
        XCTAssertEqual(router.sheet, .folder(path: "/music"))
        XCTAssertEqual(router.currentSheetRoute, .nowPlaying)
        router.dismissSheet()
        XCTAssertEqual(router.currentSheetRoute, .folder(path: "/music"))
        router.dismissSheet()
        XCTAssertNil(router.sheet)
    }

    func testPushAndPop() {
        let router = AppRouter()
        XCTAssertTrue(router.pushPath.isEmpty)
        router.push(.createFolder(parentPath: "/tmp"))
        XCTAssertTrue(router.pushPath.isEmpty)
        XCTAssertEqual(router.currentSheetRoute, .createFolder(parentPath: "/tmp"))
        router.dismissSheet()
        XCTAssertNil(router.currentSheetRoute)
    }

    func testReselectHomeTabResetsHomeStackAndRequestsScrollToTop() {
        let router = AppRouter()
        router.push(.createFolder(parentPath: "/tmp"))

        let initialScrollCount = router.homeScrollToTopCounter
        router.reselectHomeTab()

        XCTAssertTrue(router.pushPath.isEmpty)
        XCTAssertEqual(router.homeScrollToTopCounter, initialScrollCount + 1)
    }

    func testReselectHomeTabSelectsHomeWithoutScrollWhenOnAnotherTab() {
        let router = AppRouter()
        router.selectTab(.library)

        let initialScrollCount = router.homeScrollToTopCounter
        router.reselectHomeTab()

        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertEqual(router.homeScrollToTopCounter, initialScrollCount)
    }
}

@MainActor
final class PlaybackAndViewModelTests: XCTestCase {
    private func settleMainActor(_ cycles: Int = 8) async {
        for _ in 0..<cycles {
            await Task.yield()
        }
    }

    private func waitForLyrics(in vm: NowPlayingViewModel, maxCycles: Int = 120) async {
        for _ in 0..<maxCycles {
            if !vm.lyricsLines.isEmpty { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testInMemoryPlaybackServiceSetsQueueAndPlays() async {
        let store = PlaybackStore()
        let service = InMemoryPlaybackService(store: store)
        let items = [
            MediaItem(id: "a.mp3", title: "A", artist: "X", album: nil, isVideo: false),
            MediaItem(id: "b.mp3", title: "B", artist: "Y", album: nil, isVideo: false),
        ]

        await service.setQueue(items, startAt: 1)
        XCTAssertEqual(store.queue, items)
        XCTAssertEqual(store.nowPlaying?.id, "b.mp3")
        XCTAssertEqual(store.playback.queueIndex, 1)

        await service.play()
        XCTAssertTrue(store.playback.isPlaying)
    }

    func testAudioPlaybackServiceBuffersOnlySmallWindowForLargeQueue() async {
        let service = AudioPlaybackService()
        let items = (0..<3_000).map { index in
            MediaItem(
                id: "/tmp/medio-large-queue/song-\(index).mp3",
                title: "Song \(index)",
                artist: "Artist",
                album: "Album",
                isVideo: false
            )
        }
        var latestUpdate: PlaybackUpdate?
        let cancellable = service.playbackUpdates.sink { latestUpdate = $0 }

        await service.setQueue(items, startAt: 0)

        XCTAssertEqual(latestUpdate?.queue.count, 3_000)
        XCTAssertEqual(latestUpdate?.item?.id, items[0].id)
        XCTAssertLessThanOrEqual(service.bufferedPlayerItemCount, 3)

        await service.skipNext()

        XCTAssertEqual(latestUpdate?.queue.count, 3_000)
        XCTAssertEqual(latestUpdate?.item?.id, items[1].id)
        XCTAssertLessThanOrEqual(service.bufferedPlayerItemCount, 3)
        withExtendedLifetime(cancellable) {}
    }

    func testAudioPlaybackServiceCanToggleShuffleWithEmptyQueue() async {
        let service = AudioPlaybackService()
        var latestUpdate: PlaybackUpdate?
        let cancellable = service.playbackUpdates.sink { latestUpdate = $0 }

        await service.setQueue([], startAt: 0)
        await service.toggleShuffle()

        XCTAssertTrue(latestUpdate?.shuffleEnabled == true)
        XCTAssertTrue(latestUpdate?.queue.isEmpty == true)
        XCTAssertNil(latestUpdate?.item)
        withExtendedLifetime(cancellable) {}
    }

    func testAudioPlaybackServiceShufflePreservesDuplicateQueueEntry() async {
        let service = AudioPlaybackService()
        let items = [
            MediaItem(id: "/tmp/duplicate.mp3", title: "First", artist: nil, album: nil, isVideo: false),
            MediaItem(id: "/tmp/duplicate.mp3", title: "Second", artist: nil, album: nil, isVideo: false),
            MediaItem(id: "/tmp/other.mp3", title: "Other", artist: nil, album: nil, isVideo: false)
        ]
        var latestUpdate: PlaybackUpdate?
        let cancellable = service.playbackUpdates.sink { latestUpdate = $0 }

        await service.setQueue(items, startAt: 1)
        await service.toggleShuffle()

        XCTAssertEqual(latestUpdate?.item?.title, "Second")
        withExtendedLifetime(cancellable) {}
    }

    func testAudioPlaybackServiceReappliesShuffleWhenQueueIsReplaced() async {
        let service = AudioPlaybackService()
        var latestUpdate: PlaybackUpdate?
        let cancellable = service.playbackUpdates.sink { latestUpdate = $0 }
        await service.toggleShuffle()
        let items = (0..<8).map {
            MediaItem(id: "/tmp/\($0).mp3", title: "Song \($0)", artist: nil, album: nil, isVideo: false)
        }

        await service.setQueue(items, startAt: 6)

        XCTAssertTrue(latestUpdate?.shuffleEnabled == true)
        XCTAssertEqual(latestUpdate?.item?.id, items[6].id)
        XCTAssertEqual(Set(latestUpdate?.queue.map(\.id) ?? []), Set(items.map(\.id)))
        withExtendedLifetime(cancellable) {}
    }

    func testInMemoryPlaybackServiceSkipNextRestartsSameTrackInRepeatOne() async {
        let store = PlaybackStore()
        let service = InMemoryPlaybackService(store: store)
        let items = [
            MediaItem(id: "a.mp3", title: "A", artist: "X", album: nil, isVideo: false),
            MediaItem(id: "b.mp3", title: "B", artist: "Y", album: nil, isVideo: false),
        ]

        await service.setQueue(items, startAt: 0)
        await service.cycleRepeatMode() // .off -> .one
        store.playback.positionMs = 42_000

        await service.skipNext()

        XCTAssertEqual(store.playback.queueIndex, 0)
        XCTAssertEqual(store.nowPlaying?.id, "a.mp3")
        XCTAssertEqual(store.playback.positionMs, 0)
    }

    func testListeningHistoryFlushPersistsActiveSession() async {
        let suiteName = "MedioTests.historyFlush.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playbackStore = PlaybackStore()
        let history = StubListeningHistoryRepository(sessions: [])
        let settings = SettingsStore(defaults: defaults)
        let viewModel = PlaybackEventsViewModel(
            playbackStore: playbackStore,
            libraryStore: LibraryStore(),
            notificationsService: StubNotificationsService(),
            listeningHistoryRepository: history,
            settingsStore: settings
        )
        let item = MediaItem(id: "/music/background.mp3", title: "Background", artist: "Artist", album: "Album", isVideo: false)

        playbackStore.nowPlaying = item
        playbackStore.playback = PlaybackState(isPlaying: true, positionMs: 0, durationMs: 30_000)
        await settleMainActor()
        playbackStore.playback.positionMs = 2_500
        await settleMainActor()

        await viewModel.flushListeningHistory()

        let sessions = await history.storedSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.mediaID, item.id)
        XCTAssertEqual(sessions.first?.listenedMs, 2_500)
    }

    func testPlaybackStoreReportsQueueBoundariesForMiniPlayerSwipes() {
        let store = PlaybackStore()
        let items = [
            MediaItem(id: "a.mp3", title: "A", artist: "X", album: nil, isVideo: false),
            MediaItem(id: "b.mp3", title: "B", artist: "Y", album: nil, isVideo: false),
        ]
        store.queue = items
        store.nowPlaying = items[0]
        store.currentIndex = 0
        store.playback.queueIndex = 0

        XCTAssertFalse(store.canSkipToPreviousQueueItem)
        XCTAssertTrue(store.canSkipToNextQueueItem)

        store.nowPlaying = items[1]
        store.currentIndex = 1
        store.playback.queueIndex = 1

        XCTAssertTrue(store.canSkipToPreviousQueueItem)
        XCTAssertFalse(store.canSkipToNextQueueItem)
    }

    func testFavoritesViewModelPlayStartsPlayback() async {
        let libraryStore = LibraryStore()
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)

        let song = FileInfo(id: "/song1.mp3", isDirectory: false, displayName: "Song 1", author: "Artist", album: "Album")
        libraryStore.librarySongs = [song]
        libraryStore.favorites = [song.id]

        let vm = FavoritesViewModel(libraryStore: libraryStore, playbackService: playbackService)
        vm.syncFromStore()
        XCTAssertEqual(vm.filtered.count, 1)

        await vm.play(song)
        XCTAssertEqual(playbackStore.nowPlaying?.id, song.id)
        XCTAssertTrue(playbackStore.playback.isPlaying)
    }

    func testFavoritesViewModelUsesIndependentSortSettings() {
        let suiteName = "MedioTests.favoriteSort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        settings.favoritesSortBy = .name
        settings.favoritesSortAscending = true

        let libraryStore = LibraryStore()
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let zed = FileInfo(id: "/zed.mp3", isDirectory: false, displayName: "Zed", author: nil, album: nil)
        let alpha = FileInfo(id: "/alpha.mp3", isDirectory: false, displayName: "Alpha", author: nil, album: nil)
        libraryStore.librarySongs = [zed, alpha]
        libraryStore.favorites = [zed.id, alpha.id]

        let vm = FavoritesViewModel(
            libraryStore: libraryStore,
            playbackService: playbackService,
            settingsStore: settings
        )

        XCTAssertEqual(vm.filtered.map(\.displayName), ["Alpha", "Zed"])
        settings.favoritesSortAscending = false
        vm.recompute()
        XCTAssertEqual(vm.filtered.map(\.displayName), ["Zed", "Alpha"])
    }

    func testFavoritesDefaultsToNewestFavoriteFirst() {
        let suiteName = "MedioTests.favoriteAddedSort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        let libraryStore = LibraryStore()
        let playbackService = InMemoryPlaybackService(store: PlaybackStore())
        let older = FileInfo(id: "/older.mp3", isDirectory: false, displayName: "Older", author: nil, album: nil)
        let newer = FileInfo(id: "/newer.mp3", isDirectory: false, displayName: "Newer", author: nil, album: nil)
        libraryStore.librarySongs = [older, newer]
        libraryStore.favorites = [older.id, newer.id]
        libraryStore.favoriteAddedDates = [
            older.id: Date(timeIntervalSince1970: 100),
            newer.id: Date(timeIntervalSince1970: 200)
        ]

        let vm = FavoritesViewModel(
            libraryStore: libraryStore,
            playbackService: playbackService,
            settingsStore: settings
        )

        XCTAssertEqual(settings.favoritesSortBy, .dateAdded)
        XCTAssertFalse(settings.favoritesSortAscending)
        XCTAssertEqual(vm.filtered.map(\.id), [newer.id, older.id])
    }

    func testLastOpenedStoreTracksMedioFolderOpenDate() {
        let suiteName = "MedioTests.lastOpened.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let openedAt = Date(timeIntervalSince1970: 1_750_000_000)

        MedioLastOpenedStore.record("/tmp/Folder/../Folder", at: openedAt, defaults: defaults)

        let recordedAt = MedioLastOpenedStore.date(for: "/tmp/Folder", defaults: defaults)
        XCTAssertNotNil(recordedAt)
        XCTAssertEqual(
            recordedAt?.timeIntervalSince1970 ?? 0,
            openedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testDesktopPositionsPersistExactPointsPerFolder() {
        let suiteName = "MedioTests.desktopPositions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let firstPoint = CGPoint(x: 83.25, y: 211.75)
        let secondPoint = CGPoint(x: 276.5, y: 94.125)

        MedioDesktopPositionStore.set(
            ["/Documents/First.mp3": firstPoint],
            in: "/Documents",
            defaults: defaults
        )
        MedioDesktopPositionStore.set(
            ["/Documents/Folder/Second.mp3": secondPoint],
            in: "/Documents/Folder",
            defaults: defaults
        )

        XCTAssertEqual(
            MedioDesktopPositionStore.positions(in: "/Documents", defaults: defaults)["/Documents/First.mp3"],
            firstPoint
        )
        XCTAssertEqual(
            MedioDesktopPositionStore.positions(in: "/Documents/Folder", defaults: defaults)["/Documents/Folder/Second.mp3"],
            secondPoint
        )
        XCTAssertNil(
            MedioDesktopPositionStore.positions(in: "/Documents", defaults: defaults)["/Documents/Folder/Second.mp3"]
        )
    }

    func testDesktopPositionRemovalOnlyAffectsSourceFolder() {
        let suiteName = "MedioTests.desktopPositionRemoval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let itemPath = "/Documents/Folder/Song.mp3"

        MedioDesktopPositionStore.set([itemPath: CGPoint(x: 40, y: 80)], in: "/Documents", defaults: defaults)
        MedioDesktopPositionStore.set([itemPath: CGPoint(x: 140, y: 180)], in: "/Documents/Folder", defaults: defaults)
        MedioDesktopPositionStore.remove(itemPaths: [itemPath], from: "/Documents/Folder", defaults: defaults)

        XCTAssertNotNil(MedioDesktopPositionStore.positions(in: "/Documents", defaults: defaults)[itemPath])
        XCTAssertNil(MedioDesktopPositionStore.positions(in: "/Documents/Folder", defaults: defaults)[itemPath])
    }

    func testQueueViewModelNativeReorderPreservesCurrentTrack() async {
        let store = PlaybackStore()
        let service = InMemoryPlaybackService(store: store)
        let items = [
            MediaItem(id: "a.mp3", title: "A", artist: nil, album: nil, isVideo: false),
            MediaItem(id: "b.mp3", title: "B", artist: nil, album: nil, isVideo: false),
            MediaItem(id: "c.mp3", title: "C", artist: nil, album: nil, isVideo: false)
        ]
        await service.setQueue(items, startAt: 1)
        let vm = QueueViewModel(playbackStore: store, playbackService: service)

        await vm.move(from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(vm.queue.map(\.id), ["b.mp3", "c.mp3", "a.mp3"])
        XCTAssertEqual(vm.nowPlaying?.id, "b.mp3")
        XCTAssertEqual(vm.currentIndex, 0)
    }

    func testQueueDeletionPreservesOccurrencePositionAndPlayState() async {
        let store = PlaybackStore()
        let service = InMemoryPlaybackService(store: store)
        let tracks = (0..<6).map { MediaItem(id: "\($0 % 3).mp3", title: "Occurrence \($0)", isVideo: false) }
        await service.setQueue(tracks, startAt: 4)
        await service.play()
        await service.seek(toMs: 42_000)
        let vm = QueueViewModel(playbackStore: store, playbackService: service)
        await vm.remove(at: IndexSet([0, 1]))
        XCTAssertEqual(vm.nowPlaying, tracks[4])
        XCTAssertEqual(vm.currentIndex, 2)
        XCTAssertEqual(store.playback.positionMs, 42_000)
        XCTAssertTrue(store.isPlaying)
        await vm.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(vm.nowPlaying, tracks[4])
        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertEqual(store.playback.positionMs, 42_000)
        await service.pause()
        await vm.remove(at: IndexSet(integer: 3))
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.playback.positionMs, 42_000)
    }

    func testRemovingCurrentQueueEntryChoosesNextSurvivorThenClears() async {
        let store = PlaybackStore()
        let service = InMemoryPlaybackService(store: store)
        let tracks = (0..<6).map { MediaItem(id: "\($0).mp3", title: "\($0)", isVideo: false) }
        await service.setQueue(tracks, startAt: 3)
        await service.play()
        await service.seek(toMs: 42_000)
        let vm = QueueViewModel(playbackStore: store, playbackService: service)
        await vm.remove(at: IndexSet([0, 3, 4]))
        XCTAssertEqual(vm.nowPlaying, tracks[5])
        XCTAssertEqual(vm.currentIndex, 2)
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.playback.positionMs, 0)
        await vm.remove(at: IndexSet(integersIn: 0..<3))
        XCTAssertTrue(vm.queue.isEmpty)
        XCTAssertNil(vm.nowPlaying)
        XCTAssertFalse(store.isPlaying)
    }

    func testAudioQueueEditRetainsAVPlayerItemAndDoesNotReshuffle() async throws {
        let service = AudioPlaybackService()
        var latest: PlaybackUpdate?
        let observation = service.playbackUpdates.sink { latest = $0 }
        let tracks = (0..<8).map { MediaItem(id: "/tmp/queue-edit-\($0).mp3", title: "\($0)", isVideo: false) }
        await service.setQueue(tracks, startAt: 4)
        let active = try XCTUnwrap(service.videoPlayer.currentItem)
        let edited = Array(tracks.dropFirst(2))
        await service.updateQueue(edited, currentIndex: 2, preservingCurrentItem: true)
        XCTAssertTrue(active === service.videoPlayer.currentItem)
        XCTAssertEqual(latest?.item, tracks[4])
        XCTAssertEqual(latest?.queueIndex, 2)
        await service.toggleShuffle()
        let shuffled = try XCTUnwrap(latest?.queue)
        let index = try XCTUnwrap(latest?.queueIndex)
        let shuffledActive = service.videoPlayer.currentItem
        await service.updateQueue(shuffled, currentIndex: index, preservingCurrentItem: true)
        XCTAssertEqual(latest?.queue, shuffled)
        XCTAssertTrue(latest?.shuffleEnabled == true)
        XCTAssertTrue(shuffledActive === service.videoPlayer.currentItem)
        await service.toggleShuffle()
        XCTAssertEqual(latest?.queue, edited, "Shuffle Off must retain the pre-shuffle order after edits")
        XCTAssertEqual(latest?.item, tracks[4])
        XCTAssertLessThanOrEqual(service.bufferedPlayerItemCount, 3)
        await service.updateQueue([], currentIndex: 0, preservingCurrentItem: false)
        XCTAssertNil(latest?.item)
        XCTAssertTrue(latest?.queue.isEmpty == true)
        XCTAssertFalse(latest?.isPlaying == true)
        withExtendedLifetime(observation) {}
    }

    func testPastQueueTracksExcludeCurrentAndUpcomingDuplicates() async {
        let store = PlaybackStore()
        let service = InMemoryPlaybackService(store: store)
        let tracks = ["a", "b", "a", "c"].map { MediaItem(id: $0, title: $0, isVideo: false) }
        await service.setQueue(tracks, startAt: 2)
        XCTAssertEqual(store.pastQueueItemIDs, ["b"])
        await service.skipNext()
        XCTAssertEqual(store.pastQueueItemIDs, ["a", "b"])
    }

    func testNowPlayingViewModelReflectsStore() async {
        let store = PlaybackStore()
        let service = InMemoryPlaybackService(store: store)
        await service.setQueue([MediaItem(id: "t.mp3", title: "T", artist: nil, album: nil, isVideo: false)], startAt: 0)

        let vm = NowPlayingViewModel(playbackStore: store, playbackService: service)
        vm.syncFromStore()
        XCTAssertEqual(vm.item?.id, "t.mp3")
        XCTAssertFalse(vm.playback.isPlaying)

        await vm.playPause()
        vm.syncFromStore()
        XCTAssertTrue(vm.playback.isPlaying)
    }

    func testNowPlayingViewModelParsesSRTWithStartAndEndProgress() async {
        let store = PlaybackStore()
        let item = MediaItem(id: "srt.mp3", title: "SRT Song", artist: "Artist", album: nil, isVideo: false)
        store.queue = [item]
        store.currentIndex = 0
        store.nowPlaying = item
        store.playback = PlaybackState(
            isPlaying: true,
            positionMs: 2_000,
            durationMs: 6_000,
            repeatMode: .off,
            shuffleEnabled: false,
            queueIndex: 0
        )

        let lyrics = """
        1
        00:00:01,000 --> 00:00:03,000
        Line one

        2
        00:00:03,000 --> 00:00:05,000
        Line two
        """
        let repo = StubLyricsRepository(lyricsByPath: [item.id: lyrics])
        let service = InMemoryPlaybackService(store: store)
        let vm = NowPlayingViewModel(playbackStore: store, playbackService: service, lyricsRepository: repo)

        vm.syncFromStore()
        await waitForLyrics(in: vm)
        await settleMainActor()

        XCTAssertEqual(vm.lyricsLines, ["Line one", "Line two"])
        XCTAssertEqual(vm.timestampForLyricLine(0), 1_000)
        XCTAssertEqual(vm.activeLyricLineIndex, 0)
        XCTAssertEqual(Double(vm.lyricProgressForLine(0)), 0.5, accuracy: 0.08)

        store.playback.positionMs = 4_500
        await settleMainActor()

        XCTAssertEqual(vm.activeLyricLineIndex, 1)
        XCTAssertEqual(Double(vm.lyricProgressForLine(1)), 0.75, accuracy: 0.08)
    }

    func testNowPlayingViewModelParsesEditedSRTWithoutReliableCueNumbers() async {
        let store = PlaybackStore()
        let item = MediaItem(id: "edited-srt.mp3", title: "Edited SRT Song", artist: "Artist", album: nil, isVideo: false)
        store.queue = [item]
        store.currentIndex = 0
        store.nowPlaying = item
        store.playback = PlaybackState(
            isPlaying: true,
            positionMs: 27_000,
            durationMs: 40_000,
            repeatMode: .off,
            shuffleEnabled: false,
            queueIndex: 0
        )

        let lyrics = """
        5
        00:00:26,521 --> 00:00:31,740
        Evil is a relay spot when the one
        who's burned turns to pass the torch.
        00:00:31,740 --> 00:00:35,000 align:start position:0%
        Next line
        """
        let repo = StubLyricsRepository(lyricsByPath: [item.id: lyrics])
        let service = InMemoryPlaybackService(store: store)
        let vm = NowPlayingViewModel(playbackStore: store, playbackService: service, lyricsRepository: repo)

        vm.syncFromStore()
        await waitForLyrics(in: vm)
        await settleMainActor()

        XCTAssertEqual(vm.lyricsLines, [
            "Evil is a relay spot when the one who's burned turns to pass the torch.",
            "Next line",
        ])
        XCTAssertEqual(vm.timestampForLyricLine(0), 26_521)
        XCTAssertEqual(vm.timestampForLyricLine(1), 31_740)
        XCTAssertEqual(vm.activeLyricLineIndex, 0)

        store.playback.positionMs = 32_000
        await settleMainActor()

        XCTAssertEqual(vm.activeLyricLineIndex, 1)
    }

    func testNowPlayingViewModelParsesTTMLWithoutInferringOpenEndedProgress() async {
        let store = PlaybackStore()
        let item = MediaItem(id: "ttml.mp3", title: "TTML Song", artist: "Artist", album: nil, isVideo: false)
        store.queue = [item]
        store.currentIndex = 0
        store.nowPlaying = item
        store.playback = PlaybackState(
            isPlaying: true,
            positionMs: 1_500,
            durationMs: 7_000,
            repeatMode: .off,
            shuffleEnabled: false,
            queueIndex: 0
        )

        let lyrics = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body>
            <div>
              <p begin="00:00:01.000" end="00:00:03.000">First line</p>
              <p begin="00:00:04.000">Second line</p>
            </div>
          </body>
        </tt>
        """
        let repo = StubLyricsRepository(lyricsByPath: [item.id: lyrics])
        let service = InMemoryPlaybackService(store: store)
        let vm = NowPlayingViewModel(playbackStore: store, playbackService: service, lyricsRepository: repo)

        vm.syncFromStore()
        await waitForLyrics(in: vm)
        await settleMainActor()

        XCTAssertEqual(vm.lyricsLines, ["First line", "Second line"])
        XCTAssertEqual(vm.timestampForLyricLine(1), 4_000)
        XCTAssertTrue(vm.lyricLineHasExplicitEnd(0))
        XCTAssertFalse(vm.lyricLineHasExplicitEnd(1))
        XCTAssertEqual(vm.activeLyricLineIndex, 0)
        XCTAssertEqual(Double(vm.lyricProgressForLine(0)), 0.25, accuracy: 0.08)

        store.playback.positionMs = 5_000
        await settleMainActor()

        XCTAssertEqual(vm.activeLyricLineIndex, 1)
        XCTAssertEqual(Double(vm.lyricProgressForLine(1)), 0, accuracy: 0.001)
    }

    func testNowPlayingViewModelParsesStartOnlyLRCWithNextTimestampProgressInference() async {
        let store = PlaybackStore()
        let item = MediaItem(id: "start-only.mp3", title: "Start Only Song", artist: "Artist", album: nil, isVideo: false)
        store.queue = [item]
        store.currentIndex = 0
        store.nowPlaying = item
        store.playback = PlaybackState(
            isPlaying: true,
            positionMs: 2_500,
            durationMs: 6_000,
            repeatMode: .off,
            shuffleEnabled: false,
            queueIndex: 0
        )

        let lyrics = """
        [00:01.000]First line
        [00:02.000]Second line
        [00:04.000]Third line
        """
        let repo = StubLyricsRepository(lyricsByPath: [item.id: lyrics])
        let service = InMemoryPlaybackService(store: store)
        let vm = NowPlayingViewModel(playbackStore: store, playbackService: service, lyricsRepository: repo)

        vm.syncFromStore()
        await waitForLyrics(in: vm)
        await settleMainActor()

        XCTAssertEqual(vm.lyricsLines, ["First line", "Second line", "Third line"])
        XCTAssertEqual(vm.timestampForLyricLine(0), 1_000)
        XCTAssertEqual(vm.timestampForLyricLine(1), 2_000)
        XCTAssertFalse(vm.lyricLineHasExplicitEnd(0))
        XCTAssertFalse(vm.lyricLineHasExplicitEnd(1))
        XCTAssertFalse(vm.lyricLineHasExplicitEnd(2))
        XCTAssertEqual(vm.activeLyricLineIndex, 1)
        XCTAssertEqual(Double(vm.lyricProgressForLine(1)), 0.25, accuracy: 0.08)

        store.playback.positionMs = 4_200
        await settleMainActor()

        XCTAssertEqual(vm.activeLyricLineIndex, 2)
        XCTAssertEqual(Double(vm.lyricProgressForLine(2)), 0, accuracy: 0.001)
    }

    func testNowPlayingViewModelStartsLongPauseAfterInferredLyricEnd() async {
        let store = PlaybackStore()
        let item = MediaItem(id: "pause.mp3", title: "Pause Song", artist: "Artist", album: nil, isVideo: false)
        store.queue = [item]
        store.currentIndex = 0
        store.nowPlaying = item
        store.playback = PlaybackState(
            isPlaying: true,
            positionMs: 12_000,
            durationMs: 60_000,
            repeatMode: .off,
            shuffleEnabled: false,
            queueIndex: 0
        )

        let lyrics = """
        [00:01.000]First line
        [00:12.000]Second line
        [00:32.000]Third line
        [00:45.000]Fourth line
        """
        let repo = StubLyricsRepository(lyricsByPath: [item.id: lyrics])
        let service = InMemoryPlaybackService(store: store)
        let vm = NowPlayingViewModel(playbackStore: store, playbackService: service, lyricsRepository: repo)

        vm.syncFromStore()
        await waitForLyrics(in: vm)
        await settleMainActor()

        XCTAssertEqual(vm.lyricsLines, ["First line", "Second line", "⟪pause:16000⟫", "Third line", "Fourth line"])
        XCTAssertEqual(vm.activeLyricLineIndex, 1)

        store.playback.positionMs = 17_000
        await settleMainActor()

        XCTAssertEqual(vm.activeLyricLineIndex, 2)
        XCTAssertEqual(Double(vm.lyricProgressForLine(2)), 0.0625, accuracy: 0.02)
    }

    func testNowPlayingViewModelDetectsUntimedLines() async {
        let store = PlaybackStore()
        let item = MediaItem(id: "mixed.mp3", title: "Mixed", artist: "Artist", album: nil, isVideo: false)
        store.queue = [item]
        store.currentIndex = 0
        store.nowPlaying = item
        store.playback = PlaybackState(
            isPlaying: true,
            positionMs: 1_500,
            durationMs: 5_000,
            repeatMode: .off,
            shuffleEnabled: false,
            queueIndex: 0
        )

        let lyrics = """
        Plain line without time
        [00:01.00]Timed line
        """
        let repo = StubLyricsRepository(lyricsByPath: [item.id: lyrics])
        let service = InMemoryPlaybackService(store: store)
        let vm = NowPlayingViewModel(playbackStore: store, playbackService: service, lyricsRepository: repo)

        vm.syncFromStore()
        await waitForLyrics(in: vm)
        await settleMainActor()

        XCTAssertEqual(vm.lyricsLines, ["Plain line without time", "Timed line"])
        XCTAssertNil(vm.timestampForLyricLine(0))
        XCTAssertEqual(vm.timestampForLyricLine(1), 1_000)
    }

    func testDesktopPositionsScaleWithCanvasSize() {
        let suiteName = "MedioTests.desktopScaling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MedioDesktopPositionStore.set(
            ["/Documents/Song.mp3": CGPoint(x: 330, y: 240)],
            in: "/Documents",
            canvasSize: CGSize(width: 390, height: 600),
            defaults: defaults
        )
        let restored = MedioDesktopPositionStore.positions(
            in: "/Documents",
            canvasSize: CGSize(width: 780, height: 900),
            defaults: defaults
        )["/Documents/Song.mp3"]

        let restoredPoint = try? XCTUnwrap(restored)
        XCTAssertEqual(restoredPoint?.x ?? 0, 660, accuracy: 0.001)
        XCTAssertEqual(restoredPoint?.y ?? 0, 360, accuracy: 0.001)
    }
}

@MainActor
final class LibraryAndFilteringTests: XCTestCase {
    func testInMemoryLibraryRepositoryProvidesFixtures() async throws {
        let repo = InMemoryLibraryRepository()
        let loaded = try await repo.loadLibrary()
        XCTAssertTrue(loaded.items.contains(where: { $0.displayName == "Example Folder" && $0.isDirectory }))
        XCTAssertEqual(loaded.songs.count, 2)
        XCTAssertEqual(loaded.albums.first?.name, "Example Album")
        XCTAssertEqual(loaded.artists.first?.name, "Example Artist")
    }

    func testHomeViewModelFiltersHomeItemsByQuery() {
        let suiteName = "MedioTests.homeFilter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore()
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        store.homeItems = [
            FileInfo(id: "/a", isDirectory: false, displayName: "Alpha", author: nil, album: nil),
            FileInfo(id: "/b", isDirectory: false, displayName: "Beta", author: nil, album: nil),
        ]
        let vm = HomeViewModel(
            libraryStore: store,
            playbackService: playbackService,
            settingsStore: SettingsStore(defaults: defaults)
        )
        XCTAssertEqual(vm.filteredItems.map(\.displayName), ["Alpha", "Beta"])

        vm.query = "alp"
        vm.recompute()
        XCTAssertEqual(vm.filteredItems.map(\.displayName), ["Alpha"])
    }

    func testHomeViewModelShowsFavoriteShadowFolderWhenPriorityDisabled() {
        let suiteName = "MedioTests.homePriorityDisabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = LibraryStore()
        let settings = SettingsStore(defaults: defaults)
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let song = FileInfo(id: "/music/song.mp3", isDirectory: false, displayName: "Song", author: nil, album: nil)
        store.homeItems = [
            FileInfo(id: "/music", isDirectory: true, displayName: "Music", author: nil, album: nil)
        ]
        store.librarySongs = [song]
        store.favorites = [song.id]
        settings.priorityFoldersCount = 0

        let vm = HomeViewModel(libraryStore: store, playbackService: playbackService, settingsStore: settings)
        XCTAssertTrue(vm.prioritySlots.isEmpty)
        XCTAssertEqual(vm.filteredItems.map(\.displayName), ["Music", "Favorites"])
    }

    func testHomeViewModelHidesFavoriteShadowFolderWhenFavoritesHomeFolderIsRemoved() {
        let suiteName = "MedioTests.homeFavoritesRemoved.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = LibraryStore()
        let settings = SettingsStore(defaults: defaults)
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let song = FileInfo(id: "/music/song.mp3", isDirectory: false, displayName: "Song", author: nil, album: nil)
        store.homeItems = [
            FileInfo(id: "/music", isDirectory: true, displayName: "Music", author: nil, album: nil)
        ]
        store.librarySongs = [song]
        store.favorites = [song.id]
        settings.priorityFoldersCount = 0
        settings.favoritesHomeFolderEnabled = false

        let vm = HomeViewModel(libraryStore: store, playbackService: playbackService, settingsStore: settings)

        XCTAssertEqual(vm.filteredItems.map(\.displayName), ["Music"])
        XCTAssertFalse(vm.filteredItems.contains { MedioShadowFolder.isFavorites($0.id) })
    }

    func testUnpinningFavoritesUnlocksPrimaryPrioritySlot() {
        let suiteName = "MedioTests.primaryPriority.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = LibraryStore()
        let settings = SettingsStore(defaults: defaults)
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let folder = FileInfo(id: "/music", isDirectory: true, displayName: "Music", author: nil, album: nil)
        store.homeItems = [folder]
        store.allItems = [folder]
        settings.favoritesPriorityFolderEnabled = false
        settings.priorityFoldersCount = 2
        settings.assignPriorityFolder(folder.id, to: -1)

        let vm = HomeViewModel(libraryStore: store, playbackService: playbackService, settingsStore: settings)

        guard case .folder(let primary, let storageSlot) = vm.prioritySlots.first?.content else {
            XCTFail("Priority 1 should become a normal folder.")
            return
        }
        XCTAssertEqual(primary.id, folder.id)
        XCTAssertEqual(storageSlot, -1)
    }

    func testHomeViewModelPinsFavoritesAndAssignedPriorityFolders() {
        let suiteName = "MedioTests.homePriorityPins.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = LibraryStore()
        let settings = SettingsStore(defaults: defaults)
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let folder = FileInfo(id: "/music", isDirectory: true, displayName: "Music", author: nil, album: nil)
        store.homeItems = [folder]
        store.allItems = [folder]
        settings.priorityFoldersCount = 2
        settings.assignPriorityFolder(folder.id, to: 0)

        let vm = HomeViewModel(libraryStore: store, playbackService: playbackService, settingsStore: settings)
        XCTAssertEqual(vm.prioritySlots.count, 2)
        if case .favorites = vm.prioritySlots[0].content {
            XCTAssertTrue(true)
        } else {
            XCTFail("First priority slot should be Favorites.")
        }
        if case .folder(let pinnedFolder, let slot) = vm.prioritySlots[1].content {
            XCTAssertEqual(pinnedFolder.id, folder.id)
            XCTAssertEqual(slot, 0)
        } else {
            XCTFail("Second priority slot should be the assigned folder.")
        }
        XCTAssertTrue(vm.filteredItems.isEmpty)
    }

    func testHomeViewModelResolvesPriorityDataWrapperToSingleChildFolder() {
        let suiteName = "MedioTests.homePriorityDataWrapper.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = LibraryStore()
        let settings = SettingsStore(defaults: defaults)
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let wrapper = FileInfo(id: "/tmp/Data", isDirectory: true, displayName: "Data", author: nil, album: nil)
        let actualFolder = FileInfo(id: "/tmp/Data/Music", isDirectory: true, displayName: "Music", author: nil, album: nil)
        store.homeItems = [wrapper]
        store.allItems = [wrapper, actualFolder]
        settings.priorityFoldersCount = 2
        settings.assignPriorityFolder(wrapper.id, to: 0)

        let vm = HomeViewModel(libraryStore: store, playbackService: playbackService, settingsStore: settings)

        XCTAssertEqual(vm.prioritySlots.count, 2)
        if case .folder(let folder, let slot) = vm.prioritySlots[1].content {
            XCTAssertEqual(folder.id, actualFolder.id)
            XCTAssertEqual(folder.displayName, actualFolder.displayName)
            XCTAssertEqual(slot, 0)
        } else {
            XCTFail("Second priority slot should resolve to the single child folder.")
        }
    }

    func testLibraryViewModelFiltersAlbumsAndArtists() async {
        let store = LibraryStore()
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let song = FileInfo(id: "/s.mp3", isDirectory: false, displayName: "Song", author: "Artist", album: "Album")
        store.albums = [ShadowAlbum(name: "Rock", songs: [song]), ShadowAlbum(name: "Jazz", songs: [song])]
        store.artists = [ShadowArtist(name: "Alice", songs: [song]), ShadowArtist(name: "Bob", songs: [song])]
        store.librarySongs = [song]

        let vm = LibraryViewModel(libraryStore: store, playbackService: playbackService)
        for _ in 0..<100 where vm.filteredAlbums.count != 2 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(vm.filteredAlbums.count, 2)
        XCTAssertEqual(vm.filteredArtists.count, 2)

        vm.query = "ja"
        vm.recompute()
        for _ in 0..<100 where vm.filteredAlbums.map(\.name) != ["Jazz"] {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(vm.filteredAlbums.map(\.name), ["Jazz"])
        XCTAssertTrue(vm.filteredArtists.isEmpty)
    }

    func testFileSortOrderingSupportsModifiedDateReleaseDateAndSize() {
        let olderLarge = FileInfo(
            id: "/older.mp3",
            isDirectory: false,
            displayName: "Older",
            author: nil,
            album: nil,
            contentCreationDate: Date(timeIntervalSince1970: 400),
            fileModificationDate: Date(timeIntervalSince1970: 100),
            fileSizeBytes: 2_000
        )
        let newerSmall = FileInfo(
            id: "/newer.mp3",
            isDirectory: false,
            displayName: "Newer",
            author: nil,
            album: nil,
            contentCreationDate: Date(timeIntervalSince1970: 300),
            fileModificationDate: Date(timeIntervalSince1970: 200),
            fileSizeBytes: 500
        )

        XCTAssertEqual(
            FileSortOrdering.sorted([olderLarge, newerSmall], by: .dateModified, ascending: false).map(\.id),
            [newerSmall.id, olderLarge.id]
        )
        XCTAssertEqual(
            FileSortOrdering.sorted([olderLarge, newerSmall], by: .releaseDate, ascending: false).map(\.id),
            [olderLarge.id, newerSmall.id]
        )
        XCTAssertEqual(
            FileSortOrdering.sorted([olderLarge, newerSmall], by: .size, ascending: false).map(\.id),
            [olderLarge.id, newerSmall.id]
        )
    }

    func testReleaseDateSortKeepsFoldersThenMediaThenOtherFiles() {
        let folder = FileInfo(
            id: "/folder",
            isDirectory: true,
            displayName: "Folder",
            author: nil,
            album: nil,
            contentCreationDate: Date(timeIntervalSince1970: 100)
        )
        let olderSong = FileInfo(
            id: "/older.mp3",
            isDirectory: false,
            displayName: "Older Song",
            author: nil,
            album: nil,
            contentCreationDate: Date(timeIntervalSince1970: 200)
        )
        let newerVideo = FileInfo(
            id: "/newer.mp4",
            isDirectory: false,
            displayName: "Newer Video",
            author: nil,
            album: nil,
            contentCreationDate: Date(timeIntervalSince1970: 300)
        )
        let document = FileInfo(
            id: "/document.txt",
            isDirectory: false,
            displayName: "Document",
            author: nil,
            album: nil,
            contentCreationDate: Date(timeIntervalSince1970: 400)
        )

        XCTAssertEqual(
            FileSortOrdering.sorted(
                [document, olderSong, folder, newerVideo],
                by: .releaseDate,
                ascending: false
            ).map(\.id),
            [folder.id, newerVideo.id, olderSong.id, document.id]
        )
    }

    func testLibraryViewModelUsesSharedSortSetting() async {
        let store = LibraryStore()
        let settings = SettingsStore()
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let small = FileInfo(
            id: "/small.mp3",
            isDirectory: false,
            displayName: "Small",
            author: "Artist",
            album: "Album",
            fileSizeBytes: 100
        )
        let large = FileInfo(
            id: "/large.mp3",
            isDirectory: false,
            displayName: "Large",
            author: "Artist",
            album: "Album",
            fileSizeBytes: 2_000
        )
        store.librarySongs = [small, large]
        settings.homeSortBy = .size
        settings.homeSortAscending = false

        let vm = LibraryViewModel(
            libraryStore: store,
            playbackService: playbackService,
            settingsStore: settings
        )
        for _ in 0..<100 where vm.filteredSongs.count != 2 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(vm.filteredSongs.map(\.id), [large.id, small.id])
    }

    func testSearchViewModelFindsArtistsAlbumsAndSongs() async {
        let store = LibraryStore()
        let playbackStore = PlaybackStore()
        let playbackService = InMemoryPlaybackService(store: playbackStore)
        let song = FileInfo(
            id: "/fiona/apple.mp3",
            isDirectory: false,
            displayName: "Criminal",
            author: "Fiona Apple",
            album: "Tidal"
        )
        store.artists = [
            ShadowArtist(name: "Fiona Apple", songs: [song]),
            ShadowArtist(name: "bar italia", songs: [])
        ]
        store.albums = [
            ShadowAlbum(name: "Tidal", songs: [song]),
            ShadowAlbum(name: "Tracey Denim", songs: [])
        ]
        store.librarySongs = [song]

        let vm = SearchSongsViewModel(libraryStore: store, playbackService: playbackService)
        vm.query = "fiona"
        vm.recompute()
        for _ in 0..<100 where vm.filteredSongs.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(vm.filteredArtists.map(\.name), ["Fiona Apple"])
        XCTAssertEqual(vm.filteredAlbums.map(\.name), ["Tidal"])
        XCTAssertEqual(vm.filteredSongs.map(\.displayName), ["Criminal"])
    }

    func testSandboxRelativeDisplayPathStartsAtSandboxRoot() {
        let sandboxRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let nestedPath = sandboxRoot.appendingPathComponent("Documents/Music/Album", isDirectory: true).path

        XCTAssertEqual(NSHomeDirectory().sandboxRelativeDisplayPath, "/")
        XCTAssertEqual(nestedPath.sandboxRelativeDisplayPath, "/Documents/Music/Album")
        XCTAssertEqual("/outside/the/sandbox".sandboxRelativeDisplayPath, "/")
    }

    func testAlbumReleaseKindClassification() {
        XCTAssertEqual(AlbumReleaseKind.classify(trackCount: 1, totalDurationMs: 35 * 60 * 1000), .single)
        XCTAssertEqual(AlbumReleaseKind.classify(trackCount: 8, totalDurationMs: 24 * 60 * 1000), .single)
        XCTAssertEqual(AlbumReleaseKind.classify(trackCount: 4, totalDurationMs: 40 * 60 * 1000), .ep)
        XCTAssertEqual(AlbumReleaseKind.classify(trackCount: 9, totalDurationMs: 45 * 60 * 1000), .album)
    }

    func testAlbumTracksSortByDiscThenTrackNumberWithAlphabeticalFallback() {
        func song(_ name: String, path: String, track: String? = nil, disc: String? = nil) -> FileInfo {
            FileInfo(
                id: path,
                isDirectory: false,
                displayName: name,
                author: "Artist",
                album: "Album",
                trackNumber: track,
                discNumber: disc
            )
        }

        let shuffled = [
            song("Zeta Demo", path: "/album/zeta.mp3"),
            song("Second", path: "/album/second.mp3", track: "2", disc: "1"),
            song("Disc Two Opener", path: "/album/disc-two-opener.mp3", track: "1", disc: "2"),
            song("Alpha Demo", path: "/album/alpha.mp3"),
            song("Disc One Bonus", path: "/album/disc-one-bonus.mp3", disc: "1"),
            song("Opener", path: "/album/opener.mp3", track: "1", disc: "1"),
        ]

        let album = BuildLibraryIndexUseCase().execute(shuffled).albums.first

        XCTAssertEqual(album?.songs.map(\.displayName), [
            "Opener",
            "Second",
            "Disc One Bonus",
            "Disc Two Opener",
            "Alpha Demo",
            "Zeta Demo",
        ])
    }

    func testLibraryIndexBuildsThreeThousandRootSongs() {
        let songs = (0..<3_000).map { index in
            FileInfo(
                id: "/Documents/Song \(index).mp3",
                isDirectory: false,
                displayName: "Song \(index)",
                author: "Artist \(index % 100)",
                album: "Album \(index % 250)",
                durationMs: 180_000,
                fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                fileSizeBytes: 4_000_000,
                typeIdentifier: "public.mp3"
            )
        }

        let index = BuildLibraryIndexUseCase().execute(songs)

        XCTAssertEqual(index.songs.count, 3_000)
        XCTAssertEqual(index.albums.count, 250)
        XCTAssertEqual(index.artists.count, 100)
    }

    func testAlbumTrackSectionsSeparateDiscsWhenDiscMetadataExists() {
        let discOne = FileInfo(
            id: "/album/one.mp3",
            isDirectory: false,
            displayName: "One",
            author: "Artist",
            album: "Album",
            trackNumber: "1",
            discNumber: "1"
        )
        let discTwo = FileInfo(
            id: "/album/two.mp3",
            isDirectory: false,
            displayName: "Two",
            author: "Artist",
            album: "Album",
            trackNumber: "1",
            discNumber: "2"
        )
        let other = FileInfo(id: "/album/other.mp3", isDirectory: false, displayName: "Other", author: "Artist", album: "Album")

        let sections = AlbumTrackOrdering.sections(for: [discTwo, other, discOne])

        XCTAssertEqual(sections.map(\.title), ["Disc 1", "Disc 2", "Other Tracks"])
        XCTAssertEqual(sections.map { $0.songs.map(\.displayName) }, [["One"], ["Two"], ["Other"]])
    }

    func testAlbumTrackSectionsUseTracksForOnlyKnownDisc() {
        let first = FileInfo(
            id: "/album/one.mp3",
            isDirectory: false,
            displayName: "One",
            author: "Artist",
            album: "Album",
            trackNumber: "1",
            discNumber: "1"
        )
        let second = FileInfo(
            id: "/album/two.mp3",
            isDirectory: false,
            displayName: "Two",
            author: "Artist",
            album: "Album",
            trackNumber: "2",
            discNumber: "1"
        )

        let sections = AlbumTrackOrdering.sections(for: [second, first])

        XCTAssertEqual(sections.map(\.title), ["Tracks"])
        XCTAssertEqual(sections.first?.songs.map(\.displayName), ["One", "Two"])
    }

    func testAlbumPlaybackQueueUsesAlbumTrackOrdering() {
        let first = FileInfo(
            id: "/album/first.mp3",
            isDirectory: false,
            displayName: "Zed First",
            author: "Artist",
            album: "Album",
            trackNumber: "1"
        )
        let second = FileInfo(
            id: "/album/second.mp3",
            isDirectory: false,
            displayName: "Alpha Second",
            author: "Artist",
            album: "Album",
            trackNumber: "2"
        )
        let store = LibraryStore()
        store.albums = [ShadowAlbum(name: "Album", songs: [second, first])]

        let built = BuildPlaybackQueueUseCase().execute(
            selected: second,
            context: .album(name: "Album"),
            libraryStore: store
        )

        XCTAssertEqual(built.queue.map(\.title), ["Zed First", "Alpha Second"])
        XCTAssertEqual(built.startIndex, 1)
    }

    func testVideoFormatsAreClassifiedAsSupportedVideoMedia() {
        let extensions = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "vob", "mpg"]

        for ext in extensions {
            let path = "/library/video.\(ext)"
            let item = FileInfo(id: path, isDirectory: false, displayName: "Video", author: nil, album: nil)

            XCTAssertTrue(
                FileMetadataReader.isSupportedMediaFile(url: URL(fileURLWithPath: path), typeIdentifier: nil),
                "\(ext) should be indexed as media"
            )
            XCTAssertEqual(item.fileType, .video, "\(ext) should be classified as video")
        }
    }

    func testPlaybackQueueMarksVideoFormatsAsVideo() {
        let store = LibraryStore()
        let video = FileInfo(id: "/library/live.webm", isDirectory: false, displayName: "Live", author: "Artist", album: "Videos")
        let song = FileInfo(id: "/library/song.mp3", isDirectory: false, displayName: "Song", author: "Artist", album: "Album")
        store.librarySongs = [video, song]

        let built = BuildPlaybackQueueUseCase().execute(
            selected: video,
            context: .explicit(files: store.librarySongs),
            libraryStore: store
        )

        XCTAssertEqual(built.queue.map { $0.id }, [video.id, song.id])
        XCTAssertEqual(built.queue.first?.isVideo, true)
        XCTAssertEqual(built.queue.last?.isVideo, false)
    }

    func testSharedArtistsStayGroupedOnlyWhenTheyHaveTheSameSongs() {
        let first = FileInfo(id: "/music/paper.mp3", isDirectory: false, displayName: "Paper Planes", author: "Peter & Katya", album: "Duo")
        let second = FileInfo(id: "/music/tomodorio.mp3", isDirectory: false, displayName: "Tomodorio", author: "Peter & Katya", album: "Duo")
        let solo = FileInfo(id: "/music/solo.mp3", isDirectory: false, displayName: "Solo", author: "Peter", album: "Solo")

        let duoOnly = BuildLibraryIndexUseCase().execute([first, second])
        XCTAssertEqual(duoOnly.artists.map(\.name), ["Peter & Katya"])
        XCTAssertEqual(duoOnly.artists.first?.songs.map(\.displayName).sorted(), ["Paper Planes", "Tomodorio"])

        let withSolo = BuildLibraryIndexUseCase().execute([first, second, solo])
        XCTAssertEqual(withSolo.artists.map(\.name).sorted(), ["Katya", "Peter"])
        XCTAssertEqual(withSolo.artists.first(where: { $0.name == "Peter" })?.songs.count, 3)
        XCTAssertEqual(withSolo.artists.first(where: { $0.name == "Katya" })?.songs.count, 2)
    }

    func testFolderViewModelLoadsSongsUnderPath() {
        let store = LibraryStore()
        store.allItems = [
            FileInfo(id: "/root/folder", isDirectory: true, displayName: "Folder", author: nil, album: nil),
            FileInfo(id: "/root/folder/a.mp3", isDirectory: false, displayName: "A", author: nil, album: nil),
            FileInfo(id: "/root/other/b.mp3", isDirectory: false, displayName: "B", author: nil, album: nil),
        ]
        let playback = PlaybackStore()
        let service = InMemoryPlaybackService(store: playback)

        let vm = FolderViewModel(path: "/root/folder", libraryStore: store, playbackService: service)
        vm.load()
        XCTAssertEqual(vm.items.map(\.id), ["/root/folder/a.mp3"])
    }

    func testFolderViewModelUsesSharedSortSettingsForFilesAndFolders() {
        let suiteName = "MedioTests.folderSort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults)
        settings.homeSortBy = .name
        settings.homeSortAscending = true

        let store = LibraryStore()
        store.allItems = [
            FileInfo(id: "/root/folder/Zed.mov", isDirectory: false, displayName: "Zed", author: nil, album: nil),
            FileInfo(id: "/root/folder/Alpha.txt", isDirectory: false, displayName: "Alpha", author: nil, album: nil),
            FileInfo(id: "/root/folder/Middle", isDirectory: true, displayName: "Middle", author: nil, album: nil)
        ]
        let playback = PlaybackStore()
        let service = InMemoryPlaybackService(store: playback)

        let vm = FolderViewModel(
            path: "/root/folder",
            libraryStore: store,
            playbackService: service,
            settingsStore: settings
        )

        XCTAssertEqual(vm.filtered.map(\.displayName), ["Alpha", "Middle", "Zed"])
        settings.homeSortAscending = false
        vm.recompute()
        XCTAssertEqual(vm.filtered.map(\.displayName), ["Zed", "Middle", "Alpha"])
    }

    func testHomeViewModelKeepsRootVideosAndGenericFilesVisible() {
        let store = LibraryStore()
        let video = FileInfo(id: "/root/clip.mov", isDirectory: false, displayName: "Clip", author: nil, album: nil)
        let document = FileInfo(id: "/root/notes.pdf", isDirectory: false, displayName: "Notes", author: nil, album: nil)
        store.homeItems = [video, document]
        let playback = PlaybackStore()
        let service = InMemoryPlaybackService(store: playback)

        let vm = HomeViewModel(libraryStore: store, playbackService: service)

        XCTAssertEqual(Set(vm.filteredItems.map(\.id)), Set([video.id, document.id]))
        XCTAssertEqual(video.fileType, .video)
        XCTAssertEqual(document.fileType, .unrecognized)
    }

    func testAlbumAndArtistViewModelsBuildQueuesInOrder() async {
        let store = LibraryStore()
        let s1 = FileInfo(id: "/a.mp3", isDirectory: false, displayName: "A", author: "Artist", album: "Album")
        let s2 = FileInfo(id: "/b.mp3", isDirectory: false, displayName: "B", author: "Artist", album: "Album")
        store.albums = [ShadowAlbum(name: "Album", songs: [s1, s2])]
        store.artists = [ShadowArtist(name: "Artist", songs: [s1, s2])]

        let playback = PlaybackStore()
        let service = InMemoryPlaybackService(store: playback)

        let albumVM = AlbumViewModel(name: "Album", libraryStore: store, playbackService: service)
        await albumVM.play(s2)
        XCTAssertEqual(playback.queue.map(\.title), ["A", "B"])
        XCTAssertEqual(playback.nowPlaying?.id, "/b.mp3")

        let artistVM = ArtistViewModel(name: "Artist", libraryStore: store, playbackService: service)
        await artistVM.play(s1)
        XCTAssertEqual(playback.nowPlaying?.id, "/a.mp3")
    }

    func testArtistScopedAlbumViewModelBuildsQueueFromThatArtistOnly() async {
        let store = LibraryStore()
        let artistAFirst = FileInfo(id: "/a/one.mp3", isDirectory: false, displayName: "A One", author: "Artist A", album: "Greatest Hits")
        let artistASecond = FileInfo(id: "/a/two.mp3", isDirectory: false, displayName: "A Two", author: "Artist A", album: "Greatest Hits")
        let artistB = FileInfo(id: "/b/one.mp3", isDirectory: false, displayName: "B One", author: "Artist B", album: "Greatest Hits")
        store.albums = [ShadowAlbum(name: "Greatest Hits", songs: [artistAFirst, artistASecond, artistB])]
        store.artists = [
            ShadowArtist(name: "Artist A", songs: [artistAFirst, artistASecond]),
            ShadowArtist(name: "Artist B", songs: [artistB])
        ]

        let playback = PlaybackStore()
        let service = InMemoryPlaybackService(store: playback)
        let vm = AlbumViewModel(
            name: "Greatest Hits",
            artistName: "Artist A",
            libraryStore: store,
            playbackService: service
        )

        XCTAssertEqual(vm.songs.map(\.id), [artistAFirst.id, artistASecond.id])

        await vm.play(artistASecond)

        XCTAssertEqual(playback.queue.map(\.id), [artistAFirst.id, artistASecond.id])
        XCTAssertEqual(playback.nowPlaying?.id, artistASecond.id)
    }

    func testArtistViewModelBuildsMostPlayedSongsFromListeningHistory() async {
        let store = LibraryStore()
        let s1 = FileInfo(id: "/a.mp3", isDirectory: false, displayName: "Alpha", author: "Artist", album: "Album")
        let s2 = FileInfo(id: "/b.mp3", isDirectory: false, displayName: "Beta", author: "Artist", album: "Album")
        let s3 = FileInfo(id: "/c.mp3", isDirectory: false, displayName: "Gamma", author: "Artist", album: "Album")
        store.artists = [ShadowArtist(name: "Artist", songs: [s1, s2, s3])]

        let sessions = [
            ListeningSession(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                mediaID: s1.id,
                title: s1.displayName,
                artist: s1.author,
                album: s1.album,
                genre: nil,
                year: nil,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_060),
                listenedMs: 60_000,
                durationMs: nil,
                completed: false
            ),
            ListeningSession(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                mediaID: s2.id,
                title: s2.displayName,
                artist: s2.author,
                album: s2.album,
                genre: nil,
                year: nil,
                startedAt: Date(timeIntervalSince1970: 1_100),
                endedAt: Date(timeIntervalSince1970: 1_220),
                listenedMs: 120_000,
                durationMs: nil,
                completed: false
            )
        ]

        let vm = ArtistViewModel(
            name: "Artist",
            libraryStore: store,
            playbackService: InMemoryPlaybackService(store: PlaybackStore()),
            listeningHistoryRepository: StubListeningHistoryRepository(sessions: sessions)
        )

        await vm.refreshListeningHistory()

        XCTAssertEqual(vm.mostPlayedSongs.map { $0.id }, [s2.id, s1.id])
        XCTAssertEqual(vm.filteredMostPlayedSongs.map { $0.id }, [s2.id, s1.id])
    }

    func testLibraryStoreLoadOnLaunchHidesUsersFolderAndMarkerFile() async {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            XCTFail("Missing documents directory.")
            return
        }

        let visibleFolder = FileInfo(
            id: documentsURL.appendingPathComponent("Albums", isDirectory: true).path,
            isDirectory: true,
            displayName: "Albums",
            author: nil,
            album: nil
        )
        let hiddenUsersFolder = FileInfo(
            id: documentsURL.appendingPathComponent("Users", isDirectory: true).path,
            isDirectory: true,
            displayName: "Users",
            author: nil,
            album: nil
        )
        let hiddenMarkerFile = FileInfo(
            id: documentsURL.appendingPathComponent("Add music files here.txt", isDirectory: false).path,
            isDirectory: false,
            displayName: "Add music files here.txt",
            author: nil,
            album: nil
        )
        let outsideDocuments = FileInfo(
            id: "/Users",
            isDirectory: true,
            displayName: "Users",
            author: nil,
            album: nil
        )

        let dataSource = StubMediaLibraryDataSource(
            cachedItems: nil,
            scannedItems: [visibleFolder, hiddenUsersFolder, hiddenMarkerFile, outsideDocuments]
        )
        let store = LibraryStore()
        await store.loadOnLaunch(
            dataSource: dataSource,
            scanUseCase: ScanLibraryUseCase(dataSource: dataSource)
        )

        XCTAssertEqual(store.homeItems.map(\.displayName), ["Albums"])
    }

    func testLibraryStoreLoadOnLaunchUsesCacheWithoutScanning() async {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            XCTFail("Missing documents directory.")
            return
        }

        let cachedSong = FileInfo(
            id: documentsURL.appendingPathComponent("Cached Song.mp3", isDirectory: false).path,
            isDirectory: false,
            displayName: "Cached Song",
            author: "Cached Artist",
            album: nil
        )
        let scannedSong = FileInfo(
            id: documentsURL.appendingPathComponent("Scanned Song.mp3", isDirectory: false).path,
            isDirectory: false,
            displayName: "Scanned Song",
            author: "Scanned Artist",
            album: nil
        )
        let dataSource = CountingMediaLibraryDataSource(
            cachedItems: [cachedSong],
            scannedItems: [scannedSong]
        )
        let store = LibraryStore()

        await store.loadOnLaunch(
            dataSource: dataSource,
            scanUseCase: ScanLibraryUseCase(dataSource: dataSource)
        )

        XCTAssertEqual(store.homeItems.map(\.displayName), ["Cached Song"])
        XCTAssertEqual(dataSource.scanCount, 0)
    }

    func testLibraryStoreRefreshRecordsStorageScanSummary() async {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            XCTFail("Missing documents directory.")
            return
        }

        let visibleFolder = FileInfo(
            id: documentsURL.appendingPathComponent("Albums", isDirectory: true).path,
            isDirectory: true,
            displayName: "Albums",
            author: nil,
            album: nil
        )
        let visibleSong = FileInfo(
            id: documentsURL.appendingPathComponent("Song.mp3", isDirectory: false).path,
            isDirectory: false,
            displayName: "Song",
            author: "Artist",
            album: "Album"
        )
        let outsideDocuments = FileInfo(
            id: "/tmp/Outside.mp3",
            isDirectory: false,
            displayName: "Outside",
            author: "Artist",
            album: "Album"
        )

        let dataSource = StubMediaLibraryDataSource(
            cachedItems: nil,
            scannedItems: [visibleFolder, visibleSong, outsideDocuments]
        )
        let store = LibraryStore()

        await store.refresh(scanUseCase: ScanLibraryUseCase(dataSource: dataSource))

        XCTAssertEqual(store.homeItems.map(\.displayName), ["Albums", "Song"])
        XCTAssertEqual(store.lastStorageScanSummary?.documentsPath, documentsURL.standardizedFileURL.path)
        XCTAssertEqual(store.lastStorageScanSummary?.scannedItemCount, 2)
        XCTAssertEqual(store.lastStorageScanSummary?.visibleHomeItemCount, 2)
        XCTAssertEqual(store.lastStorageScanSummary?.mediaItemCount, 1)
        XCTAssertNil(store.lastStorageScanError)
    }

    func testLibraryStoreRefreshRecordsStorageScanError() async {
        let dataSource = ThrowingMediaLibraryDataSource(
            error: NSError(domain: "MedioTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Scan failed."])
        )
        let store = LibraryStore()

        await store.refresh(scanUseCase: ScanLibraryUseCase(dataSource: dataSource))

        XCTAssertEqual(store.lastStorageScanError, "Scan failed.")
        XCTAssertNil(store.lastStorageScanSummary)
    }

    func testLibraryStoreDoesNotPublishAnOlderOverlappingRefresh() async throws {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            XCTFail("Missing documents directory.")
            return
        }
        let oldItem = FileInfo(
            id: documentsURL.appendingPathComponent("Old.txt").path,
            isDirectory: false,
            displayName: "Old",
            author: nil,
            album: nil
        )
        let newItem = FileInfo(
            id: documentsURL.appendingPathComponent("New.txt").path,
            isDirectory: false,
            displayName: "New",
            author: nil,
            album: nil
        )
        let store = LibraryStore()
        let slow = ScanLibraryUseCase(dataSource: DelayedMediaLibraryDataSource(
            delayNanoseconds: 120_000_000,
            scannedItems: [oldItem]
        ))
        let fast = ScanLibraryUseCase(dataSource: DelayedMediaLibraryDataSource(
            delayNanoseconds: 5_000_000,
            scannedItems: [newItem]
        ))

        let first = Task { await store.refresh(scanUseCase: slow) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = Task { await store.refresh(scanUseCase: fast) }
        await first.value
        await second.value

        XCTAssertEqual(store.homeItems.map(\.displayName), ["New"])
        XCTAssertFalse(store.isLoading)
    }

    func testFilesystemScanIncludesTextFilesInDocuments() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MedioTests.textScan.\(UUID().uuidString)", isDirectory: true)
        let documentsURL = root.appendingPathComponent("Documents", isDirectory: true)
        let cacheURL = root.appendingPathComponent("Caches/library.json", isDirectory: false)
        let textFile = documentsURL.appendingPathComponent("Visible.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: textFile)

        let scanned = try await DefaultMediaLibraryRepository(
            fileManager: fileManager,
            documentsURL: documentsURL,
            cacheURL: cacheURL
        ).scanAndCacheItems()

        XCTAssertTrue(scanned.contains { $0.id == textFile.path && !$0.isDirectory })
    }

    func testFilesystemScanIncludesNestedFilesInDocuments() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MedioTests.nestedScan.\(UUID().uuidString)", isDirectory: true)
        let documentsURL = root.appendingPathComponent("Documents", isDirectory: true)
        let cacheURL = root.appendingPathComponent("Caches/library.json", isDirectory: false)
        let folder = documentsURL.appendingPathComponent("Nested", isDirectory: true)
        let nestedFile = folder.appendingPathComponent("Visible.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nestedFile)

        let scanned = try await DefaultMediaLibraryRepository(
            fileManager: fileManager,
            documentsURL: documentsURL,
            cacheURL: cacheURL
        ).scanAndCacheItems()

        XCTAssertTrue(scanned.contains { $0.id == folder.path && $0.isDirectory })
        XCTAssertTrue(scanned.contains { $0.id == nestedFile.path && !$0.isDirectory })
    }

    func testCorruptLibraryCacheIsQuarantinedAndRebuilt() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MedioTests.libraryCache.\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let cache = root.appendingPathComponent("Caches/medio-library-cache.v4.json", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: cache)
        let visible = documents.appendingPathComponent("Visible.txt")
        try Data("visible".utf8).write(to: visible)

        let repository = DefaultMediaLibraryRepository(
            fileManager: fileManager,
            documentsURL: documents,
            cacheURL: cache
        )
        XCTAssertNil(repository.loadCachedItems())
        XCTAssertFalse(fileManager.fileExists(atPath: cache.path))
        let quarantined = try fileManager.contentsOfDirectory(atPath: cache.deletingLastPathComponent().path)
        XCTAssertTrue(quarantined.contains { $0.hasPrefix("medio-library-cache.corrupt.") })

        let scanned = try await repository.scanAndCacheItems()
        XCTAssertTrue(scanned.contains { $0.id == visible.path })
        XCTAssertTrue(fileManager.fileExists(atPath: cache.path))
        XCTAssertEqual(repository.loadCachedItems()?.map(\.id), scanned.map(\.id))
    }
}

@MainActor
final class SettingsAndValidationTests: XCTestCase {
    func testDiagnosticsCollectorsDefaultOffAndOnlyRecordAfterOptIn() {
        let suiteName = "MedioTests.diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let diagnostics = DiagnosticsCenter(defaults: defaults)
        XCTAssertFalse(diagnostics.storageEnabled)
        XCTAssertFalse(diagnostics.internetEnabled)
        XCTAssertFalse(diagnostics.interactionEnabled)

        diagnostics.appendInternet("ignored")
        XCTAssertTrue(diagnostics.internetEntries.isEmpty)

        diagnostics.internetEnabled = true
        diagnostics.appendInternet("recorded")

        let reloaded = DiagnosticsCenter(defaults: defaults)
        XCTAssertTrue(reloaded.internetEnabled)
        XCTAssertEqual(reloaded.internetEntries.map(\.message), ["recorded"])
        XCTAssertFalse(reloaded.storageEnabled)
        XCTAssertFalse(reloaded.interactionEnabled)
    }

    func testFileBrowserIconSizingClampsAndBuildsGridWidths() {
        XCTAssertEqual(FileBrowserIconSizing.clamped(20), 46)
        XCTAssertEqual(FileBrowserIconSizing.clamped(52), 52)
        XCTAssertEqual(FileBrowserIconSizing.clamped(100), 84)
        XCTAssertEqual(FileBrowserIconSizing.gridMinimum(for: 52), 60)
        XCTAssertEqual(FileBrowserIconSizing.gridMaximum(for: 52), 72)
    }

    func testSelectingSortStartsAscendingThenTogglesDirection() {
        let suiteName = "MedioTests.sortSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.homeSortBy = .dateModified
        store.homeSortAscending = false

        store.selectSort(.kind)
        XCTAssertEqual(store.homeSortBy, .kind)
        XCTAssertTrue(store.homeSortAscending)

        store.selectSort(.kind)
        XCTAssertFalse(store.homeSortAscending)

        store.selectSort(.size)
        XCTAssertEqual(store.homeSortBy, .size)
        XCTAssertTrue(store.homeSortAscending)
    }

    func testSettingsViewModelAutoSavesChangesToStore() {
        let store = SettingsStore()
        store.lyricsEnabled = true
        store.priorityFoldersCount = 4
        store.homeSortAscending = true
        store.appCanConnectToInternet = false
        store.medioReCappedEnabled = true

        let vm = SettingsViewModel(settingsStore: store)
        vm.lyricsEnabled = false
        vm.priorityFoldersCount = 7
        vm.homeSortAscending = false
        vm.appCanConnectToInternet = true
        vm.medioReCappedEnabled = false

        XCTAssertFalse(store.lyricsEnabled)
        XCTAssertEqual(store.priorityFoldersCount, 7)
        XCTAssertFalse(store.homeSortAscending)
        XCTAssertTrue(store.appCanConnectToInternet)
        XCTAssertFalse(store.medioReCappedEnabled)
    }

    func testVersionedSettingsRepositoryRoundTripsCompleteSnapshot() async throws {
        let suiteName = "MedioTests.settingsSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var snapshot = SettingsSnapshot.defaults
        snapshot.accentColorRgba = 0x11223344
        snapshot.nowPlayingBackgroundModeRaw = 2
        snapshot.nowPlayingCustomBackgroundColorRgba = 0x55667788
        snapshot.nowPlayingAlbumColorIndex = 3
        snapshot.nowPlayingShowsTotalDuration = true
        snapshot.priorityFoldersCount = 4
        snapshot.homeSortByRaw = HomeSortBy.size.rawValue
        snapshot.homeSortAscending = false
        snapshot.lyricsEnabled = false
        snapshot.appCanConnectToInternet = true
        snapshot.medioReCappedEnabled = false
        snapshot.showUnknownArtists = false
        snapshot.showUnknownAlbums = false
        snapshot.priorityFolderPaths = ["medio://documents/Music", nil]
        snapshot.prioritySlotArtworkPaths = ["0": "medio://documents/Covers/music.jpg"]
        snapshot.prioritySlotImageOnlyKeys = ["0"]
        snapshot.favoritesHomeFolderEnabled = false
        snapshot.primaryPriorityFolderPath = "medio://documents/Primary"
        snapshot.favoritesSortByRaw = FavoritesSortBy.name.rawValue
        snapshot.favoritesSortAscending = true

        let repository = UserDefaultsPreferencesRepository(storage: SettingsDefaultsStorage(defaults))
        try await repository.saveSettings(snapshot)

        let reloadedSnapshot = try await repository.loadSettings()
        XCTAssertEqual(reloadedSnapshot, snapshot)
        XCTAssertNil(defaults.object(forKey: SettingsPersistence.legacyKey))
    }

    func testCorruptSettingsRecoverToDefaults() async throws {
        let suiteName = "MedioTests.settingsCorrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("corrupt".utf8), forKey: SettingsPersistence.key)

        let repository = UserDefaultsPreferencesRepository(storage: SettingsDefaultsStorage(defaults))
        let recoveredSnapshot = try await repository.loadSettings()
        XCTAssertEqual(recoveredSnapshot, .defaults)
        XCTAssertNil(defaults.object(forKey: SettingsPersistence.key))
    }

    func testPriorityFolderSlotsPersistAndRemove() async {
        let suiteName = "MedioTests.prioritySlots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = SettingsStore(defaults: defaults)
        store.assignPriorityFolder("/docs/Music", to: 0)
        store.assignPriorityFolder("/docs/Podcasts", to: 1)
        await store.flushPersistence()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.priorityFolderPath(at: 0), "/docs/Music")
        XCTAssertEqual(reloaded.priorityFolderPath(at: 1), "/docs/Podcasts")

        reloaded.removePriorityFolder(at: 0)
        XCTAssertEqual(reloaded.priorityFoldersCount, 3)
        XCTAssertEqual(reloaded.priorityFolderPath(at: 0), "/docs/Podcasts")
    }

    func testPriorityImageOnlyAndPrimaryFolderSettingsPersist() async {
        let suiteName = "MedioTests.priorityImageOnly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = SettingsStore(defaults: defaults)
        store.favoritesHomeFolderEnabled = false
        store.priorityFoldersCount = 2
        store.assignPriorityFolder("/docs/Primary", to: -1)
        store.setPrioritySlotArtworkPath("/art/primary.jpg", at: -1)
        store.setPrioritySlotImageOnly(true, at: -1)
        await store.flushPersistence()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.favoritesHomeFolderEnabled)
        XCTAssertEqual(reloaded.priorityFolderPath(at: -1), "/docs/Primary")
        XCTAssertEqual(reloaded.prioritySlotArtworkPath(at: -1), "/art/primary.jpg")
        XCTAssertTrue(reloaded.isPrioritySlotImageOnly(-1))
    }

    func testMedioReCappedExporterWritesTextReports() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MedioTests.medio-recapped.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let songPath = documents
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Midnight Run.mp3", isDirectory: false)
            .path
        let song = FileInfo(
            id: songPath,
            isDirectory: false,
            displayName: "Midnight Run",
            author: "Example Artist",
            album: "Night Drive",
            durationMs: 180_000,
            genre: "Synthpop",
            year: "2026"
        )
        let store = LibraryStore()
        store.librarySongs = [song]
        store.albums = [ShadowAlbum(name: "Night Drive", songs: [song])]
        store.artists = [ShadowArtist(name: "Example Artist", songs: [song])]
        store.favorites = [song.id]

        let session = ListeningSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            mediaID: song.id,
            title: song.displayName,
            artist: song.author,
            album: song.album,
            genre: song.genre,
            year: song.year,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            listenedMs: 120_000,
            durationMs: song.durationMs,
            completed: false
        )
        let exporter = MedioReCappedReportExporter(
            historyRepository: StubListeningHistoryRepository(sessions: [session]),
            outputRoot: tempRoot
        )

        let directory = try await exporter.export(
            libraryStore: store,
            generatedAt: Date(timeIntervalSince1970: 1_200)
        )
        let filenames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))

        XCTAssertEqual(filenames, [
            "library-snapshot.txt",
            "raw-listening-log.txt",
            "summary.txt",
            "top-albums.txt",
            "top-artists.txt",
            "top-genres.txt",
            "top-songs.txt",
        ])

        let summary = try String(contentsOf: directory.appendingPathComponent("summary.txt"))
        XCTAssertTrue(summary.contains("Medio ReCapped"))
        XCTAssertTrue(summary.contains("Total listening time: 2m 0s"))
        XCTAssertTrue(summary.contains("Top song: Midnight Run - Example Artist"))

        let rawLog = try String(contentsOf: directory.appendingPathComponent("raw-listening-log.txt"))
        XCTAssertTrue(rawLog.contains("Genre: Synthpop"))
        XCTAssertTrue(rawLog.contains("Path: Music/Midnight Run.mp3"))
    }

    func testSQLiteListeningHistoryNormalizesTracksAndStoresEveryPlay() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedioTests.sqlite-history.\(UUID().uuidString)", isDirectory: true)
        let databaseURL = tempRoot.appendingPathComponent("recapped.sqlite3")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repository = SQLiteListeningHistoryRepository(
            databaseURL: databaseURL,
            legacyFileURL: tempRoot.appendingPathComponent("legacy.json")
        )
        let first = ListeningSession(
            id: UUID(),
            mediaID: "/music/repeat.mp3",
            title: "Repeat",
            artist: "One Artist",
            album: nil,
            genre: nil,
            year: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_010),
            listenedMs: 10_000,
            durationMs: 180_000,
            completed: false
        )
        let skipped = ListeningSession(
            id: UUID(),
            mediaID: first.mediaID,
            title: first.title,
            artist: first.artist,
            album: nil,
            genre: nil,
            year: nil,
            startedAt: Date(timeIntervalSince1970: 2_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            listenedMs: 0,
            durationMs: first.durationMs,
            completed: false
        )

        try await repository.appendSession(first)
        try await repository.appendSession(skipped)

        let sessions = try await repository.loadSessions()
        XCTAssertEqual(sessions.map(\.listenedMs), [10_000, 0])
        XCTAssertEqual(try sqliteCount("tracks", at: databaseURL), 1)
        XCTAssertEqual(try sqliteCount("play_history", at: databaseURL), 2)
        XCTAssertEqual(try sqliteUserTables(at: databaseURL), ["play_history", "tracks"])
    }

    func testSQLiteListeningHistoryMigratesLegacyJSON() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedioTests.sqlite-migration.\(UUID().uuidString)", isDirectory: true)
        let databaseURL = tempRoot.appendingPathComponent("recapped.sqlite3")
        let legacyURL = tempRoot.appendingPathComponent("medio-listening-history.v1.json")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let session = ListeningSession(
            id: UUID(),
            mediaID: "/music/legacy.mp3",
            title: "Legacy",
            artist: "Archive",
            album: "Old Album",
            genre: "Rock",
            year: "2025",
            startedAt: Date(timeIntervalSince1970: 3_000),
            endedAt: Date(timeIntervalSince1970: 3_090),
            listenedMs: 90_000,
            durationMs: 100_000,
            completed: true
        )
        try JSONEncoder().encode([session]).write(to: legacyURL)

        let repository = SQLiteListeningHistoryRepository(
            databaseURL: databaseURL,
            legacyFileURL: legacyURL
        )
        let migrated = try await repository.loadSessions()

        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.mediaID, session.mediaID)
        XCTAssertEqual(migrated.first?.listenedMs, session.listenedMs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testCreateFolderValidationRejectsEmptyName() async {
        let vm = CreateFolderViewModel(parentPath: "/tmp")
        vm.name = "   "
        await vm.create()
        XCTAssertEqual(vm.errorMessage, "Folder name cannot be empty.")
    }

    func testCreateFolderValidationRejectsPathComponents() async {
        let vm = CreateFolderViewModel(parentPath: "/tmp")
        for invalidName in ["..", ".", "../Outside", "Music/Live", "/Absolute"] {
            vm.name = invalidName
            await vm.create()
            XCTAssertNotNil(vm.errorMessage, "Expected \(invalidName) to be rejected")
        }
    }
}

private func sqliteCount(_ table: String, at databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw NSError(domain: "MedioTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw NSError(domain: "MedioTests.SQLite", code: 2)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "MedioTests.SQLite", code: 3)
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func sqliteUserTables(at databaseURL: URL) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw NSError(domain: "MedioTests.SQLite", code: 4)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw NSError(domain: "MedioTests.SQLite", code: 5)
    }
    defer { sqlite3_finalize(statement) }

    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let value = sqlite3_column_text(statement, 0) {
            names.append(String(cString: value))
        }
    }
    return names
}

final class FileMoveServiceTests: XCTestCase {
    func testPathPolicyRejectsTraversalAndSymlinkEscape() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.pathPolicy.\(UUID().uuidString)", isDirectory: true)
        let outside = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.pathPolicy.outside.\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlink = root.appendingPathComponent("Outside Link")
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let policy = AppFilePathPolicy(rootURL: root, fileManager: fileManager)
        XCTAssertThrowsError(try policy.destination(in: root, named: "../Outside", isDirectory: true))
        XCTAssertThrowsError(try policy.destination(in: root, named: "Music/Live", isDirectory: true))
        XCTAssertThrowsError(try policy.validatedDirectory(outside))
        XCTAssertThrowsError(try policy.validatedDirectory(symlink))
    }

    func testStableIdentitySurvivesDocumentsRootChange() throws {
        let firstRoot = URL(fileURLWithPath: "/old/container/Documents", isDirectory: true)
        let secondRoot = URL(fileURLWithPath: "/new/container/Documents", isDirectory: true)
        let identity = AppFilePathPolicy(rootURL: firstRoot).stableIdentity(
            for: firstRoot.appendingPathComponent("Albums/Song.mp3")
        )

        XCTAssertEqual(identity, "medio://documents/Albums/Song.mp3")
        XCTAssertEqual(
            AppFilePathPolicy(rootURL: secondRoot).url(forStableIdentity: identity)?.path,
            "/new/container/Documents/Albums/Song.mp3"
        )
    }

    func testFailedReplacementPreservesExistingDestination() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.atomicReplace.\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("Song.mp3")
        let missingSource = root.appendingPathComponent("Missing.mp3")
        try Data("existing".utf8).write(to: destination)

        do {
            try await AppFileMutationCoordinator.shared.copyReplacingItem(at: missingSource, to: destination)
            XCTFail("Expected replacement to fail")
        } catch {
            XCTAssertEqual(try String(contentsOf: destination), "existing")
        }
    }

    func testNativeDropLocationPrefersFolderUnderPointerAndFallsBackToCurrentFolder() {
        let frames = [
            "/Documents/Albums": CGRect(x: 20, y: 100, width: 300, height: 60),
            "/Documents/Albums/Live": CGRect(x: 40, y: 110, width: 120, height: 40)
        ]

        XCTAssertEqual(
            nativeDropDestination(
                at: CGPoint(x: 80, y: 130),
                folderFrames: frames,
                defaultPath: "/Documents"
            ),
            "/Documents/Albums/Live"
        )
        XCTAssertEqual(
            nativeDropDestination(
                at: CGPoint(x: 10, y: 10),
                folderFrames: frames,
                defaultPath: "/Documents"
            ),
            "/Documents"
        )
    }

    func testDropFallbackCanKeepCurrentFolderOrTargetHome() {
        XCTAssertEqual(
            nativeDropDefaultDestination(
                isInternalMove: true,
                defaultPath: "/Documents/Albums",
                internalMovePath: "/Documents/Albums"
            ),
            "/Documents/Albums"
        )
        XCTAssertEqual(
            nativeDropDefaultDestination(
                isInternalMove: false,
                defaultPath: "/Documents/Albums",
                internalMovePath: "/Documents"
            ),
            "/Documents/Albums"
        )
        XCTAssertEqual(
            nativeDropDefaultDestination(
                isInternalMove: true,
                defaultPath: "/Documents",
                internalMovePath: "/Documents"
            ),
            "/Documents"
        )
    }

    func testRootDropPayloadAcceptsAppleFilesFileURLs() {
        XCTAssertTrue(medioRootDropPayloadTypeIdentifiers.contains(UTType.fileURL.identifier))
        XCTAssertTrue(medioRootDropPayloadTypeIdentifiers.contains(medioInternalMovePayloadTypeIdentifier))
        XCTAssertTrue(medioInternalMovePayloadType.conforms(to: .json))
    }

    func testNativeProviderDropPipelineMovesFileIntoFolder() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MedioDropPipeline.\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceFile = sourceFolder.appendingPathComponent("Dragged.txt")
        try Data("drop-content".utf8).write(to: sourceFile)
        let item = FileInfo(
            id: sourceFile.path,
            isDirectory: false,
            displayName: sourceFile.lastPathComponent,
            author: nil,
            album: nil
        )
        let provider = makeMoveItemProvider(items: [item])
        let moved = expectation(description: "Native provider moved into folder")
        let moveService = FileMoveService(fileManager: fileManager, rootURL: root)
        let destinationPath = destinationFolder.path

        XCTAssertTrue(loadMovePaths(from: [provider]) { paths in
            Task {
                do {
                    _ = try await moveService.move(
                        paths: paths,
                        toFolder: destinationPath
                    )
                } catch {
                    XCTFail("Drop pipeline failed: \(error)")
                }
                moved.fulfill()
            }
        })

        await fulfillment(of: [moved], timeout: 2)
        XCTAssertFalse(fileManager.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: destinationFolder.appendingPathComponent("Dragged.txt").path
        ))
    }

    func testNativeDragProviderPreservesMetadataAndVendsFileContent() throws {
        let fileManager = FileManager.default
        let sourceFile = fileManager.temporaryDirectory
            .appendingPathComponent("MedioDrag.\(UUID().uuidString).mp3")
        try Data("drag-content".utf8).write(to: sourceFile)
        defer { try? fileManager.removeItem(at: sourceFile) }

        let item = FileInfo(
            id: sourceFile.path,
            isDirectory: false,
            displayName: "Test Song",
            author: "Test Artist",
            album: "Test Album",
            durationMs: 42_000,
            genre: "Test Genre"
        )
        let provider = makeMoveItemProvider(items: [item])

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(medioInternalMovePayloadTypeIdentifier))
        let audioType = try XCTUnwrap(UTType(filenameExtension: "mp3"))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(audioType.identifier))

        let metadataLoaded = expectation(description: "Internal drag metadata loaded")
        provider.loadDataRepresentation(forTypeIdentifier: medioInternalMovePayloadTypeIdentifier) { data, error in
            XCTAssertNil(error)
            do {
                let payload = try JSONDecoder().decode(MedioDragPayload.self, from: XCTUnwrap(data))
                XCTAssertEqual(payload, MedioDragPayload(items: [item]))
            } catch {
                XCTFail("Could not decode drag payload: \(error)")
            }
            metadataLoaded.fulfill()
        }

        let fileLoaded = expectation(description: "External file representation loaded")
        provider.loadFileRepresentation(forTypeIdentifier: audioType.identifier) { url, error in
            XCTAssertNil(error)
            do {
                let url = try XCTUnwrap(url)
                XCTAssertEqual(try String(contentsOf: url), "drag-content")
            } catch {
                XCTFail("Could not load dragged file: \(error)")
            }
            fileLoaded.fulfill()
        }

        wait(for: [metadataLoaded, fileLoaded], timeout: 2)
    }

    func testNativeDragProviderVendsFolders() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("MedioDragFolder.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let item = FileInfo(
            id: folder.path,
            isDirectory: true,
            displayName: "Dragged Folder",
            author: nil,
            album: nil
        )
        let provider = makeMoveItemProvider(items: [item])

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(medioInternalMovePayloadTypeIdentifier))
    }

    func testMovePlacesFileInsideDestinationFolder() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.fileMove.\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let sourceFile = sourceFolder.appendingPathComponent("Song.mp3", isDirectory: false)
        try Data("song".utf8).write(to: sourceFile)

        let moved = try await FileMoveService(fileManager: fileManager, rootURL: root).move(paths: [sourceFile.path], toFolder: destinationFolder.path)

        XCTAssertEqual(moved.map(\.lastPathComponent), ["Song.mp3"])
        XCTAssertFalse(fileManager.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationFolder.appendingPathComponent("Song.mp3").path))
    }

    func testMoveBatchReportsPartialFailurePerFile() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.moveBatch.\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let validSource = root.appendingPathComponent("valid.txt")
        let missingSource = root.appendingPathComponent("missing.txt")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("valid".utf8).write(to: validSource)
        defer { try? fileManager.removeItem(at: root) }

        let result = try await FileMoveService(fileManager: fileManager, rootURL: root).moveBatch(
            paths: [validSource.path, missingSource.path],
            toFolder: destination.path
        )

        XCTAssertEqual(result.completed.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.source, missingSource)
    }

    func testImportFilesCopiesDroppedFileWithUniqueName() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.fileImport.\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("External", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let sourceFile = sourceFolder.appendingPathComponent("Song.mp3", isDirectory: false)
        let existingDestinationFile = destinationFolder.appendingPathComponent("Song.mp3", isDirectory: false)
        try Data("incoming".utf8).write(to: sourceFile)
        try Data("existing".utf8).write(to: existingDestinationFile)

        let imported = try await FileMoveService(fileManager: fileManager, rootURL: root).importFiles(at: [sourceFile], toFolder: destinationFolder.path)

        XCTAssertEqual(imported.map(\.lastPathComponent), ["Song 2.mp3"])
        XCTAssertTrue(fileManager.fileExists(atPath: sourceFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: existingDestinationFile.path))
        XCTAssertEqual(
            try String(contentsOf: destinationFolder.appendingPathComponent("Song 2.mp3")),
            "incoming"
        )
    }

    func testMoveRejectsDestinationOutsideConfiguredRoot() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.moveRoot.\(UUID().uuidString)", isDirectory: true)
        let outside = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.moveOutside.\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Song.mp3")
        try Data("song".utf8).write(to: source)

        let service = FileMoveService(fileManager: fileManager, rootURL: root)
        XCTAssertFalse(service.canMove(source.path, toFolder: outside.path))
        do {
            _ = try await service.move(paths: [source.path], toFolder: outside.path)
            XCTFail("Expected an outside destination to be rejected")
        } catch {
            XCTAssertEqual(error as? AppFilePolicyError, .outsideDocuments)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }

    func testImportDocumentsUseCaseCopiesPickedMediaIntoDocuments() async throws {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            XCTFail("Missing documents directory.")
            return
        }
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.documentImport.\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceFile = root.appendingPathComponent("Picked \(UUID().uuidString).mp3", isDirectory: false)
        try Data("picked".utf8).write(to: sourceFile)

        let imported = try await ImportDocumentsUseCase(fileManager: fileManager).execute(urls: [sourceFile])
        defer {
            for url in imported {
                try? fileManager.removeItem(at: url)
            }
        }

        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(imported[0].standardizedFileURL.path.hasPrefix(documentsURL.standardizedFileURL.path + "/"))
        XCTAssertEqual(imported[0].lastPathComponent, sourceFile.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: imported[0]), "picked")
    }

    func testImportDocumentsUseCaseCopiesIntoRequestedFolder() async throws {
        let fileManager = FileManager.default
        let sourceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MedioImportSource.\(UUID().uuidString)", isDirectory: true)
        let source = sourceRoot.appendingPathComponent("Nested Import.txt")
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destination = documents.appendingPathComponent("Import Destination \(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: sourceRoot)
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: source)

        let imported = try await ImportDocumentsUseCase(fileManager: fileManager).execute(
            urls: [source],
            destinationDirectory: destination
        )

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.deletingLastPathComponent().standardizedFileURL, destination.standardizedFileURL)
        XCTAssertTrue(fileManager.fileExists(atPath: imported[0].path))
    }

    func testImportDocumentsUseCaseImportsSameGenericFileAgainWithUniqueName() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MedioTests.documentImport.\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceFile = root.appendingPathComponent("Note \(UUID().uuidString).txt", isDirectory: false)
        try Data("note".utf8).write(to: sourceFile)

        let useCase = ImportDocumentsUseCase(fileManager: fileManager)
        let firstImport = try await useCase.execute(urls: [sourceFile])
        let secondImport = try await useCase.execute(urls: [sourceFile])
        defer {
            for url in firstImport + secondImport {
                try? fileManager.removeItem(at: url)
            }
        }

        XCTAssertEqual(firstImport.count, 1)
        XCTAssertEqual(secondImport.count, 1)
        XCTAssertNotEqual(firstImport[0].path, secondImport[0].path)
        XCTAssertTrue(secondImport[0].lastPathComponent.hasPrefix(sourceFile.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(try String(contentsOf: secondImport[0]), "note")
    }
}

final class LyricsAssociationPersistenceTests: XCTestCase {
    func testLyricsAssociationPersistsAcrossRepositoryReinit() async throws {
        let suiteName = "MedioTests.lyricsAssociations.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("lyrics-associations.json", isDirectory: false)

        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let mediaPath = "/tmp/Library/My Song.mp3"
        let lyricsPath = "/tmp/Lyrics/My Song.lrc"

        let firstRepository = UserDefaultsLyricsFileAssociationRepository(defaults: defaults, storageURL: storageURL)
        try await firstRepository.setAssociatedLyricsFile(lyricsPath, forMediaPath: mediaPath)

        let reloadedRepository = UserDefaultsLyricsFileAssociationRepository(defaults: defaults, storageURL: storageURL)
        XCTAssertEqual(
            reloadedRepository.getAssociatedLyricsFile(forMediaPath: mediaPath),
            URL(fileURLWithPath: lyricsPath).standardizedFileURL.path
        )
    }

    func testLyricsAssociationUsesCanonicalMediaPathLookup() async throws {
        let suiteName = "MedioTests.lyricsAssociations.canonical.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("lyrics-associations.json", isDirectory: false)

        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let canonicalMediaPath = "/tmp/Media/Song.mp3"
        let variantMediaPath = "/tmp/Media/../Media/Song.mp3"
        let lyricsPath = "/tmp/Lyrics/./Song.lrc"

        let repository = UserDefaultsLyricsFileAssociationRepository(defaults: defaults, storageURL: storageURL)
        try await repository.setAssociatedLyricsFile(lyricsPath, forMediaPath: variantMediaPath)

        XCTAssertEqual(
            repository.getAssociatedLyricsFile(forMediaPath: canonicalMediaPath),
            URL(fileURLWithPath: lyricsPath).standardizedFileURL.path
        )
    }
}

@MainActor
final class ArtistProfileRepositoryTests: XCTestCase {
    func testRepositoryLooksUpArtistImagesWithNormalizedNames() {
        let suiteName = "MedioTests.artistProfiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedioTests.artistProfiles.\(UUID().uuidString)", isDirectory: true)
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        let repository = UserDefaultsArtistProfileRepository(defaults: defaults, cacheDirectory: cacheDirectory)
        repository.setImage(makeTestImage(), for: "  Björk  ")

        XCTAssertNotNil(repository.getImage(for: "bjork"))
        XCTAssertNotNil(repository.getImage(for: "BJÖRK"))
        XCTAssertEqual(repository.cachedImageCount(), 1)
    }

    func testRepositoryMigratesLegacyImageDictionaryToDisk() throws {
        let suiteName = "MedioTests.artistProfilesMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedioTests.artistProfilesMigration.\(UUID().uuidString)", isDirectory: true)
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let imageData = try XCTUnwrap(makeTestImage().pngData())
        defaults.set(try JSONEncoder().encode(["Legacy Artist": imageData]), forKey: "medio_artist_profiles")

        let repository = UserDefaultsArtistProfileRepository(defaults: defaults, cacheDirectory: cacheDirectory)

        XCTAssertNotNil(repository.getImage(for: "legacy artist"))
        XCTAssertEqual(repository.cachedImageCount(), 1)
        XCTAssertNil(defaults.object(forKey: "medio_artist_profiles"))
    }

    func testArtistIdentityPolicyRequiresMatchingArtistName() {
        XCTAssertTrue(ArtistIdentityPolicy.namesMatch("The Cure", candidateName: "Cure"))
        XCTAssertTrue(ArtistIdentityPolicy.namesMatch("Björk", candidateName: "Bjork"))
        XCTAssertFalse(ArtistIdentityPolicy.namesMatch("Queen", candidateName: "Queen Latifah"))
        XCTAssertFalse(ArtistIdentityPolicy.namesMatch("Tyler", candidateName: "Tyler, The Creator"))
    }

    func testArtistIdentityPolicyRequiresMusicArtistDescription() {
        XCTAssertTrue(ArtistIdentityPolicy.textLooksLikeMusicArtist("British rock band"))
        XCTAssertTrue(ArtistIdentityPolicy.textLooksLikeMusicArtist("American singer-songwriter and record producer"))
        XCTAssertFalse(ArtistIdentityPolicy.textLooksLikeMusicArtist("American actor and film director"))
        XCTAssertFalse(ArtistIdentityPolicy.textLooksLikeMusicArtist("American film producer"))
        XCTAssertFalse(ArtistIdentityPolicy.textLooksLikeMusicArtist("disbanded settlement in Ontario, Canada"))
        XCTAssertFalse(ArtistIdentityPolicy.textLooksLikeMusicArtist("city in Ontario, Canada"))
    }

    func testInternetAccessSettingPersistsAcrossStoreReinit() async {
        let suiteName = "MedioTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = SettingsStore(defaults: defaults)
        firstStore.appCanConnectToInternet = true
        await firstStore.flushPersistence()

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloadedStore.appCanConnectToInternet)
    }

    func testMedioReCappedSettingPersistsAcrossStoreReinit() async {
        let suiteName = "MedioTests.settings.recapped.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = SettingsStore(defaults: defaults)
        firstStore.medioReCappedEnabled = false
        await firstStore.flushPersistence()

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.medioReCappedEnabled)
    }

    func testArtistImageLicensePolicyAllowsCommonsFreeLicenses() {
        XCTAssertTrue(ArtistImageLicensePolicy.allows(
            licenseText: "Creative Commons Attribution-Share Alike 4.0",
            licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/",
            shortName: "CC BY-SA 4.0"
        ))
        XCTAssertTrue(ArtistImageLicensePolicy.allows(
            licenseText: "Creative Commons Attribution 2.0",
            licenseURL: "https://creativecommons.org/licenses/by/2.0/",
            shortName: "CC BY 2.0"
        ))
        XCTAssertTrue(ArtistImageLicensePolicy.allows(
            licenseText: "This work has been released into the public domain.",
            licenseURL: "https://creativecommons.org/publicdomain/mark/1.0/",
            shortName: "Public domain"
        ))
    }

    func testArtistImageLicensePolicyRejectsRestrictedLicenses() {
        XCTAssertFalse(ArtistImageLicensePolicy.allows(
            licenseText: "Creative Commons Attribution-NonCommercial 4.0",
            licenseURL: "https://creativecommons.org/licenses/by-nc/4.0/",
            shortName: "CC BY-NC 4.0"
        ))
        XCTAssertFalse(ArtistImageLicensePolicy.allows(
            licenseText: "Creative Commons Attribution-NoDerivatives 4.0",
            licenseURL: "https://creativecommons.org/licenses/by-nd/4.0/",
            shortName: "CC BY-ND 4.0"
        ))
        XCTAssertFalse(ArtistImageLicensePolicy.allows(
            licenseText: "Fair use promotional photo",
            shortName: "Fair use"
        ))
    }
}

final class LyricsFilenameExactMatcherTests: XCTestCase {
    func testMatchesTitleAndArtistWithStrictContent() {
        XCTAssertTrue(
            LyricsFilenameExactMatcher.matchesExactly(
                lyricsFilenameBase: "My Song - Drak",
                songTitle: "My Song",
                songArtist: "Drak"
            )
        )
    }

    func testRejectsNearMissAuthorMismatch() {
        XCTAssertFalse(
            LyricsFilenameExactMatcher.matchesExactly(
                lyricsFilenameBase: "My Song - Drake",
                songTitle: "My Song",
                songArtist: "Drak"
            )
        )

        XCTAssertFalse(
            LyricsFilenameExactMatcher.matchesExactly(
                lyricsFilenameBase: "My Song - Drak",
                songTitle: "My Song",
                songArtist: "Drake"
            )
        )
    }

    func testMatchesArtistTitleOrderToo() {
        XCTAssertTrue(
            LyricsFilenameExactMatcher.matchesExactly(
                lyricsFilenameBase: "Drak - My Song",
                songTitle: "My Song",
                songArtist: "Drak"
            )
        )
    }
}

final class PerformanceBaselineTests: XCTestCase {
    func testLibraryIndexClockAndMemoryBaseline() {
        let songs = (0..<3_000).map { index in
            FileInfo(
                id: "/performance/album-\(index / 12)/track-\(index).mp3",
                isDirectory: false,
                displayName: "Track \(index)",
                author: "Artist \(index % 80)",
                album: "Album \(index / 12)"
            )
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = BuildLibraryIndexUseCase().execute(songs, useCache: false)
            XCTAssertEqual(result.songs.count, songs.count)
        }
    }

    func testIndexedSearchLatencyBaseline() {
        let songs = (0..<3_000).map { index in
            FileInfo(
                id: "/performance/search-\(index).mp3",
                isDirectory: false,
                displayName: "Midnight Track \(index)",
                author: "Artist \(index % 50)",
                album: "Collection \(index % 100)"
            )
        }
        _ = BuildLibraryIndexUseCase().execute(songs, useCache: false)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let matches = songs.reduce(into: 0) { count, song in
                if LibrarySearchTextIndex.shared.fileMatches(id: song.id, query: "midnight") {
                    count += 1
                }
            }
            XCTAssertEqual(matches, songs.count)
        }
    }
}

final class AudioSpectrumAnalyzerTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func tone(_ frequency: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<AudioSpectrumAnalyzer.sampleCount).map {
            Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate))
        }
    }

    func testEachTonePeaksInItsOwnFrequencyBand() {
        let analyzer = AudioSpectrumAnalyzer()
        for (expectedBand, frequency) in [60.0, 160, 400, 1_000, 2_500, 6_300, 15_000].enumerated() {
            let levels = analyzer.levels(channels: [tone(frequency)], sampleRate: sampleRate)
            XCTAssertEqual(levels.count, 7)
            XCTAssertEqual(levels.indices.max(by: { levels[$0] < levels[$1] }), expectedBand, "\(frequency) Hz")
            XCTAssertGreaterThan(levels[expectedBand], 0.8)
        }
    }

    func testSimultaneousBassAndTrebleRemainSeparate() {
        let bass = tone(60)
        let treble = tone(15_000)
        let mixed = zip(bass, treble).map { $0 + $1 }
        let levels = AudioSpectrumAnalyzer().levels(channels: [mixed], sampleRate: sampleRate)
        XCTAssertGreaterThan(levels[0], 0.8)
        XCTAssertGreaterThan(levels[6], 0.8)
        XCTAssertLessThan(levels[3], 0.25)
    }

    func testSilenceAndAmplitude() {
        let analyzer = AudioSpectrumAnalyzer()
        let silence = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
        XCTAssertEqual(analyzer.levels(channels: [silence], sampleRate: sampleRate), PlaybackAudioLevels.resting)
        let quiet = analyzer.levels(channels: [tone(1_000, amplitude: 0.01)], sampleRate: sampleRate)
        let loud = analyzer.levels(channels: [tone(1_000, amplitude: 0.5)], sampleRate: sampleRate)
        XCTAssertGreaterThan(loud[3], quiet[3] + 0.3)
    }

    func testOppositePhaseStereoDoesNotCancelSpectrum() {
        let samples = tone(1_000)
        let analyzer = AudioSpectrumAnalyzer()
        let mono = analyzer.levels(channels: [samples], sampleRate: sampleRate)
        let stereo = analyzer.levels(channels: [samples, samples.map { -$0 }], sampleRate: sampleRate)
        for index in mono.indices {
            XCTAssertEqual(mono[index], stereo[index], accuracy: 0.001)
        }
    }

    func testFileSpectrumFollowsSeekPositionAndStopsAtEnd() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeChangingTone(to: url)
        let reader = AudioSpectrumReader()
        let bass = await reader.levels(for: url.path, atMs: 200)
        let treble = await reader.levels(for: url.path, atMs: 1_200)
        let end = await reader.levels(for: url.path, atMs: 2_100)
        XCTAssertGreaterThan(bass[0], 0.8)
        XCTAssertLessThan(bass[6], 0.25)
        XCTAssertGreaterThan(treble[6], 0.8)
        XCTAssertLessThan(treble[0], 0.25)
        XCTAssertEqual(end, PlaybackAudioLevels.resting)
    }

    private func writeChangingTone(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 2)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            let frequency = Double(index) < sampleRate ? 60.0 : 15_000.0
            samples[index] = Float(0.5 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

@MainActor
final class SystemUIPresenterTests: XCTestCase {
    func testResultArrivesAfterDismissalAndNextPickerCanOpen() async throws {
        let presenter = SystemUIPresenter()
        let service = MedioPhotoPickingService(presenter: presenter)
        let first = Task { try await service.pickImage() }
        await Task.yield()
        XCTAssertNotNil(presenter.sheet)
        let data = Data([1, 2, 3])
        presenter.complete(.success(.image(data)))
        XCTAssertNil(presenter.sheet)
        presenter.didDismiss()
        let result = try await first.value
        XCTAssertEqual(result, data)

        let second = Task { try await service.pickImage() }
        await Task.yield()
        XCTAssertNotNil(presenter.sheet)
        presenter.dismiss()
        presenter.didDismiss()
        presenter.didDismiss() // SwiftUI must not resume a continuation twice.
        do {
            _ = try await second.value
            XCTFail("Dismissing the picker should cancel the request")
        } catch {
            XCTAssertTrue(error is SystemUIError)
        }
    }

    func testPhotoLoadingSurvivesDismissalUntilProviderCompletes() async throws {
        let presenter = SystemUIPresenter()
        let service = MedioPhotoPickingService(presenter: presenter)
        let request = Task { try await service.pickImage() }
        await Task.yield()
        presenter.beginLoadingSelection()
        presenter.didDismiss()
        // Let the queued cancellation fallback run while a photo is still loading.
        try await Task.sleep(nanoseconds: 50_000_000)
        presenter.complete(.success(.image(Data([4, 5, 6]))))
        let result = try await request.value
        XCTAssertEqual(result, Data([4, 5, 6]))
    }

    func testDocumentSelectionDeliveredJustAfterDismissalIsNotCancelled() async throws {
        let presenter = SystemUIPresenter()
        let service = MedioDocumentPickingService(presenter: presenter)
        let request = Task { try await service.pickFile(contentTypes: [.image], allowsMultipleSelection: false) }
        await Task.yield()
        let url = URL(fileURLWithPath: "/tmp/selected-cover.png")
        presenter.didDismiss()
        presenter.complete(.success(.documents([url])))
        let result = try await request.value
        XCTAssertEqual(result, [url])
        let next = Task { try await service.pickFile(contentTypes: [.image], allowsMultipleSelection: false) }
        await Task.yield()
        presenter.complete(.success(.documents([url])))
        presenter.didDismiss()
        let nextResult = try await next.value
        XCTAssertEqual(nextResult, [url], "The previous dismissal must not cancel a new request")
    }

    func testConcurrentPickerRequestIsRejectedWithoutLosingFirstRequest() async throws {
        let presenter = SystemUIPresenter()
        let service = MedioPhotoPickingService(presenter: presenter)
        let first = Task { try await service.pickImage() }
        await Task.yield()
        do {
            _ = try await service.pickImage()
            XCTFail("A second request should not overwrite the active continuation")
        } catch SystemUIError.presentationUnavailable {
            // Expected.
        }
        presenter.complete(.success(.image(Data([7]))))
        presenter.didDismiss()
        let result = try await first.value
        XCTAssertEqual(result, Data([7]))
    }
}

@MainActor
final class MediaArtworkRenderingTests: XCTestCase {
    @available(iOS 16.0, *)
    private func pixels<V: View>(of view: V, width: Int, height: Int) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height)))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    func testRectangularEmbeddedArtKeepsOriginalResolutionAndSharpSquareThumbnails() async throws {
        let cache = ArtworkCache.shared
        cache.setLowPowerMode(false)
        for size in [CGSize(width: 2048, height: 1024), CGSize(width: 1024, height: 2048)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            let png = try XCTUnwrap(image.pngData())
            var block = Data()
            func appendWord(_ number: UInt32) {
                var value = number.bigEndian
                withUnsafeBytes(of: &value) { block.append(contentsOf: $0) }
            }
            // A self-contained FLAC picture metadata fixture; no copyrighted media.
            appendWord(3); appendWord(9); block.append(Data("image/png".utf8)); appendWord(0)
            appendWord(UInt32(size.width)); appendWord(UInt32(size.height)); appendWord(24); appendWord(0)
            appendWord(UInt32(png.count)); block.append(png)
            var file = Data("fLaC".utf8)
            file.append(contentsOf: [0x86, UInt8((block.count >> 16) & 255), UInt8((block.count >> 8) & 255), UInt8(block.count & 255)])
            file.append(block)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
            try file.write(to: url)
            defer { try? FileManager.default.removeItem(at: url); cache.invalidate([url.path]) }
            let extracted = await ArtworkCache.extractArtwork(for: url.path)
            let original = try XCTUnwrap(extracted)
            XCTAssertEqual(original.size, size, "Album headers must receive the original pixels")
            var thumbnail = cache.image(for: url.path)
            let deadline = Date().addingTimeInterval(5)
            while thumbnail == nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
                thumbnail = cache.image(for: url.path)
            }
            let preview = try XCTUnwrap(thumbnail)
            XCTAssertGreaterThanOrEqual(min(preview.size.width, preview.size.height), 512,
                "The cropped square needs enough pixels even when the source is rectangular")
            XCTAssertEqual(preview.size.width / preview.size.height, size.width / size.height, accuracy: 0.001)
        }
    }

    func testPortraitLandscapeAndSquareCoversKeepTheirProportions() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("ImageRenderer requires iOS 16") }
        for size in [CGSize(width: 240, height: 120), CGSize(width: 120, height: 240), CGSize(width: 120, height: 120)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let bytes = try pixels(of: MediaCoverArtwork(image: image), width: 200, height: 200)
            var minX = 200, minY = 200, maxX = 0, maxY = 0
            for y in 0..<200 {
                for x in 0..<200 where bytes[(y * 200 + x) * 4 + 3] > 128 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            XCTAssertLessThan(minX, maxX)
            XCTAssertEqual(Double(maxX - minX + 1) / Double(maxY - minY + 1), Double(size.width / size.height), accuracy: 0.03)
        }
    }

    func testSmallCoversFillEveryCornerForPortraitAndLandscapeImages() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("ImageRenderer requires iOS 16") }
        for size in [CGSize(width: 240, height: 80), CGSize(width: 80, height: 240)] {
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            let bytes = try pixels(of: MediaCoverArtwork(image: image, contentMode: .fill).clipped(), width: 100, height: 100)
            for (x, y) in [(1, 1), (98, 1), (1, 98), (98, 98)] {
                XCTAssertGreaterThan(bytes[(y * 100 + x) * 4], 240)
                XCTAssertGreaterThan(bytes[(y * 100 + x) * 4 + 3], 240)
            }
        }
    }

    func testPriorityCropMatchesAdaptiveCardAndNeverExposesEmptyEdges() {
        for compact in [false, true] {
            for width: CGFloat in [320, 390, 768, 1024] {
                let ratio = HomePriorityLayoutMetrics.cardAspectRatio(contentWidth: width, compact: compact)
                XCTAssertGreaterThan(ratio, 1)
                let viewport = CGSize(width: 300, height: 300 / ratio)
                for source in [CGSize(width: 90, height: 240), CGSize(width: 360, height: 90), CGSize(width: 100, height: 100)] {
                    for zoom: CGFloat in [1, 2, 5] {
                        let rect = CoverCropGeometry.imageRect(source: source, viewport: viewport, zoom: zoom,
                                                              offset: CGSize(width: 10_000, height: -10_000))
                        XCTAssertLessThanOrEqual(rect.minX, 0.001)
                        XCTAssertLessThanOrEqual(rect.minY, 0.001)
                        XCTAssertGreaterThanOrEqual(rect.maxX, viewport.width - 0.001)
                        XCTAssertGreaterThanOrEqual(rect.maxY, viewport.height - 0.001)
                        XCTAssertEqual(rect.width / rect.height, source.width / source.height, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testSevenSpectrumBarsAreMirroredAroundTheirCentre() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("ImageRenderer requires iOS 16") }
        let view = NowPlayingAudioVisualizer(
            isPlaying: true, levels: [0.2, 0.4, 0.8, 1, 0.7, 0.5, 0.3],
            color: .red, size: CGSize(width: 140, height: 100)
        )
        let bytes = try pixels(of: view, width: 140, height: 100)
        func filled(_ x: Int, _ y: Int) -> Bool { bytes[(y * 140 + x) * 4 + 3] > 128 }
        var barCount = 0
        var previous = false
        for x in 0..<140 {
            let current = filled(x, 50)
            if current && !previous { barCount += 1 }
            previous = current
            for y in 0..<50 {
                XCTAssertEqual(filled(x, y), filled(x, 99 - y), "Bar must grow equally upward and downward")
            }
        }
        XCTAssertEqual(barCount, 7)
    }
}

@MainActor
final class BrowsingPreferencesRegressionTests: XCTestCase {
    func testFavoritesPreferencesPersistIndependentlyAndMigrateLegacySnapshots() async throws {
        let name = "MedioTests.favoriteFlags.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.favoritesHomeFolderEnabled = true
        settings.favoritesPriorityFolderEnabled = false
        await settings.flushPersistence()
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.favoritesHomeFolderEnabled)
        XCTAssertFalse(reloaded.favoritesPriorityFolderEnabled)
        let encoded = try JSONEncoder().encode(SettingsSnapshot.fromStore(settings))
        var legacyValues = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyValues.removeValue(forKey: "favoritesPriorityFolderEnabled")
        legacyValues["favoritesHomeFolderEnabled"] = false
        let legacy = try JSONDecoder().decode(SettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: legacyValues))
        XCTAssertFalse(legacy.favoritesPriorityFolderEnabled)
    }

    func testNativeSortMenuTracksSelectionAndDirectionWithoutLosingViewIcon() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "MedioTests.menu.\(UUID())")!)
        settings.selectSort(.name)
        func menu() -> UIMenu {
            BrowserOptionsMenu.sorts(HomeSortBy.menuCases, selected: settings.homeSortBy,
                ascending: settings.homeSortAscending, title: { $0.title }, select: settings.selectSort)
        }
        let selected = menu().children.compactMap { $0 as? UIAction }.filter { $0.state == .on }
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.title, "Name")
        XCTAssertEqual(selected.first?.subtitle, "Ascending")
        settings.selectSort(.name)
        XCTAssertEqual(menu().children.compactMap { $0 as? UIAction }.first { $0.state == .on }?.subtitle, "Descending")
        let views = BrowserOptionsMenu.views(selected: .icons) { _ in }
        let icons = views.children.first as? UIAction
        XCTAssertEqual(icons?.state, .on)
        XCTAssertNotNil(icons?.image)
    }

    func testSingleInternetGateMigratesOldSwitchesAndKeepsUsageByProcess() {
        let name = "MedioTests.online.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["imageDownloads"], forKey: "medio.online.disabledFeatures")
        let store = OnlineAccessStore(defaults: defaults)
        XCTAssertTrue(OnlineFeature.allCases.allSatisfy { !store.allows($0) })
        store.masterEnabled = true
        XCTAssertTrue(OnlineFeature.allCases.allSatisfy { store.allows($0) })
        XCTAssertNil(defaults.object(forKey: "medio.online.disabledFeatures"))
        store.record(bytes: 1234, for: .artistLookup)
        store.record(bytes: 4321, for: .imageMetadata)
        let restored = OnlineAccessStore(defaults: defaults)
        XCTAssertEqual(restored.transferredBytes[OnlineFeature.artistLookup.rawValue], 1234)
        XCTAssertEqual(restored.transferredBytes[OnlineFeature.imageMetadata.rawValue], 4321)
        XCTAssertFalse(restored.allows(.imageDownloads))
        restored.resetUsage()
        XCTAssertTrue(restored.transferredBytes.isEmpty)
        XCTAssertFalse(restored.allows(.imageDownloads))
    }
}

private final class ArtistRequestProbe: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedURLs: [URL] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; recordedURLs = [] }
    static func urls() -> [URL] { lock.lock(); defer { lock.unlock() }; return recordedURLs }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.recordedURLs.append(url); Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"artists\":[],\"search\":[],\"query\":{\"pages\":{}}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class OnlineRequestGateTests: XCTestCase {
    func testDisabledFeaturesNeverStartNetworkRequests() async {
        let originalPermission = OnlineAccessStore.shared.masterEnabled
        OnlineAccessStore.shared.masterEnabled = true
        defer { OnlineAccessStore.shared.masterEnabled = originalPermission }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistRequestProbe.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ArtistRequestProbe.reset() }
        ArtistRequestProbe.reset()
        let blocked = WikimediaPublicDomainArtistImageRepository(session: session, requestAllowed: { _ in false })
        _ = await blocked.fetchImage(for: "Test Artist")
        XCTAssertTrue(ArtistRequestProbe.urls().isEmpty)
        let selective = WikimediaPublicDomainArtistImageRepository(session: session, requestAllowed: { $0 == .artistLookup })
        _ = await selective.fetchImage(for: "Test Artist")
        XCTAssertFalse(ArtistRequestProbe.urls().isEmpty)
        XCTAssertTrue(ArtistRequestProbe.urls().allSatisfy { $0.host == "musicbrainz.org" })
        OnlineAccessStore.shared.masterEnabled = false
        ArtistRequestProbe.reset()
        do {
            _ = try await OnlineAccessStore.shared.data(for: URLRequest(url: URL(string: "https://musicbrainz.org/")!), feature: .artistLookup, using: session)
            XCTFail("The master switch must prevent even direct requests through the shared gate")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertTrue(ArtistRequestProbe.urls().isEmpty)
    }
}

final class LocalAudioSharingTests: XCTestCase {
    func testSafariByteRanges() {
        XCTAssertEqual(AudioByteRange.parse(nil, size: 100), AudioByteRange(start: 0, end: 99))
        XCTAssertEqual(AudioByteRange.parse("bytes=0-1", size: 100), AudioByteRange(start: 0, end: 1))
        XCTAssertEqual(AudioByteRange.parse("bytes=25-", size: 100), AudioByteRange(start: 25, end: 99))
        XCTAssertEqual(AudioByteRange.parse("bytes=-20", size: 100), AudioByteRange(start: 80, end: 99))
        XCTAssertEqual(AudioByteRange.parse("bytes=20-999", size: 100), AudioByteRange(start: 20, end: 99))
        for value in ["bytes=100-", "bytes=3-2", "bytes=-0", "bytes=0-1,4-5", "bytes=hello", "items=0-1", "bytes=99999999999999999999-"] {
            XCTAssertNil(AudioByteRange.parse(value, size: 100), value)
        }
        XCTAssertNil(AudioByteRange.parse(nil, size: 0))
    }

    func testRequestParserRejectsSmugglingAndOversizedBodies() {
        for header in ["GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2", "POST /join HTTP/1.1\r\nContent-Length: 513", "POST /join HTTP/1.1\r\nTransfer-Encoding: chunked", "POST /join HTTP/1.1\r\nContent-Length: -1", "POST /join HTTP/1.1\r\nContent-Length: nope", "bad"] {
            XCTAssertNil(LocalAudioHTTPRequest(header: Data(header.utf8)), header)
        }
        let request = LocalAudioHTTPRequest(header: Data("GET /state HTTP/1.1\r\nAuthorization: Bearer abc\r\nHost: localhost".utf8))
        XCTAssertEqual(request?.headers["authorization"], "Bearer abc")
        XCTAssertEqual(request?.contentLength, 0)
    }

    func testOnlyRegularFilesInsideDocumentsAreEligible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let allowed = documents.appendingPathComponent("track.mp3")
        let outside = root.appendingPathComponent("secret.mp3")
        try Data([1, 2]).write(to: allowed)
        try Data([3, 4]).write(to: outside)
        let link = documents.appendingPathComponent("escape.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNotNil(SharedAudioTrack.validatedURL(path: allowed.path, documents: documents))
        XCTAssertNil(SharedAudioTrack.validatedURL(path: outside.path, documents: documents))
        XCTAssertNil(SharedAudioTrack.validatedURL(path: documents.path, documents: documents))
        XCTAssertNil(SharedAudioTrack.validatedURL(path: link.path, documents: documents))
    }

    func testHTTPAuthenticationRangesTrackChangesAndShutdown() async throws {
        let port = expectation(description: "Listener starts")
        let portBox = SharingTestPort()
        let server = LocalAudioHTTPServer(code: "123456", page: "receiver", restrictToWiFi: false) { event in
            if case .ready(let number) = event { portBox.set(number); port.fulfill() }
        }
        server.start()
        defer { server.stop() }
        await fulfillment(of: [port], timeout: 30)
        let base = try XCTUnwrap(portBox.get()).description
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET", body: String? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(base)\(path)")!)
            request.httpMethod = method; request.httpBody = body.map { Data($0.utf8) }; request.timeoutInterval = 15
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let root = try await request("/")
        XCTAssertEqual(root.0, Data("receiver".utf8))
        XCTAssertEqual(root.1.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let denied = try await request("/state")
        XCTAssertEqual(denied.1.statusCode, 403)
        let wrong = try await request("/join", method: "POST", body: "000000")
        XCTAssertEqual(wrong.1.statusCode, 403)
        let joined = try await request("/join", method: "POST", body: "123456")
        let token = try XCTUnwrap((JSONSerialization.jsonObject(with: joined.0) as? [String: String])?["token"])
        let auth = ["Authorization": "Bearer " + token]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(0..<100).write(to: file)
        let track = SharedAudioTrack(id: "first", url: file, mimeType: "audio/mpeg", size: 100)
        server.update(track: track, state: SharedAudioState(track: "first", title: "A <title>", position: 12.5, playing: true))
        let state = try await request("/state", headers: auth)
        let movingPosition = try JSONDecoder().decode(SharedAudioState.self, from: state.0).position
        XCTAssertGreaterThanOrEqual(movingPosition, 12.5)
        XCTAssertLessThan(movingPosition, 15.5)
        let partial = try await request("/audio/first?token=\(token)", headers: ["Range": "bytes=8-15"])
        XCTAssertEqual(partial.1.statusCode, 206)
        XCTAssertEqual(partial.0, Data(8..<16))
        XCTAssertEqual(partial.1.value(forHTTPHeaderField: "Content-Range"), "bytes 8-15/100")
        let head = try await request("/audio/first", method: "HEAD", headers: auth)
        XCTAssertTrue(head.0.isEmpty)
        XCTAssertEqual(head.1.value(forHTTPHeaderField: "Content-Length"), "100")
        let invalid = try await request("/audio/first?token=\(token)", headers: ["Range": "bytes=1000-"])
        XCTAssertEqual(invalid.1.statusCode, 416)
        let traversal = try await request("/audio/..%2Fsecret?token=\(token)")
        XCTAssertEqual(traversal.1.statusCode, 404)
        server.update(track: nil, state: SharedAudioState())
        let revokedTrack = try await request("/audio/first", headers: auth)
        XCTAssertEqual(revokedTrack.1.statusCode, 404)
        server.stop()
        do { _ = try await request("/state", headers: auth); XCTFail("Stopped session must not respond") } catch { }
    }

    func testFourLanguagesAreBundledAndHaveRealTranslations() throws {
        let expected = ["en": "Home", "cs": "Domů", "de": "Start", "fr": "Accueil"]
        for (language, home) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Home", value: nil, table: nil), home)
            for key in ["Settings", "Share Audio", "Ascending", "Descending", "App Language"] {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(value, "MISSING", "\(language): \(key)")
                if language != "en" { XCTAssertNotEqual(value, key, "\(language): \(key)") }
            }
            XCTAssertNotEqual(bundle.localizedString(forKey: "NSLocalNetworkUsageDescription", value: "MISSING", table: "InfoPlist"), "MISSING")
        }
    }
}

private final class SharingTestPort: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16?
    func set(_ value: UInt16) { lock.lock(); defer { lock.unlock() }; port = value }
    func get() -> UInt16? { lock.lock(); defer { lock.unlock() }; return port }
}

// Exercise the actual receiver JavaScript against the native HTTP server in WebKit.
// Autoplay policy is disabled only in this test; the production page requires Listen.
@MainActor
final class AudioSharingReceiverTests: XCTestCase {
    func testSharingAddressSupportsBothIPFamilies() {
        XCTAssertEqual(LocalAudioSharing.listenerURL(host: "192.168.1.2", port: 8080)?.absoluteString, "http://192.168.1.2:8080")
        XCTAssertEqual(LocalAudioSharing.listenerURL(host: "fd00::1234", port: 8080)?.absoluteString, "http://[fd00::1234]:8080")
    }

    func testBrowserReceivesAudioFollowsPauseAndStopsWithHost() async throws {
        let port = expectation(description: "Browser test server starts")
        let box = SharingTestPort()
        let server = LocalAudioHTTPServer(code: "654321", page: SharingReceiverPage.html, restrictToWiFi: false) { event in
            if case .ready(let value) = event { box.set(value); port.fulfill() }
        }
        server.start()
        defer { server.stop() }
        await fulfillment(of: [port], timeout: 30)
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let file = documents.appendingPathComponent("receiver-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        // Thirty seconds of silence leaves room for cold WebKit startup while
        // the host clock advances. PCM mono, 8 kHz / 16-bit; no external media.
        var wav = Data()
        func ascii(_ value: String) { wav.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        func dword(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        ascii("RIFF"); dword(480036); ascii("WAVEfmt "); dword(16); word(1); word(1)
        dword(8000); dword(16000); word(2); word(16); ascii("data"); dword(480000)
        wav.append(Data(repeating: 0, count: 480000)); try wav.write(to: file)
        let item = MediaItem(id: file.path, title: "Receiver <test>", artist: "Local", isVideo: false)
        let prepared = await SharedAudioTrack.prepare(item: item)
        let track = try XCTUnwrap(prepared)
        server.update(track: track, state: SharedAudioState(track: track.id, title: item.title, position: 0, playing: true))
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        window?.addSubview(web)
        defer { web.removeFromSuperview(); web.stopLoading() }
        let serverPort = try XCTUnwrap(box.get(), "Loopback listener did not become ready")
        let loaded = expectation(description: "Receiver page loads")
        let delegate = SharingNavigationDelegate(loaded: loaded)
        web.navigationDelegate = delegate
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(serverPort)/#code=654321")!))
        await fulfillment(of: [loaded], timeout: 30)
        try await waitFor(web, expression: "location.hash === ''")
        try await waitFor(web, expression: "!document.getElementById('player').hidden && document.getElementById('audio').src.includes('/audio/')")
        try await evaluate(web, script: "document.getElementById('audio').muted=true;document.getElementById('listen').click();true")
        try await waitFor(web, expression: "!document.getElementById('audio').paused && document.getElementById('audio').currentTime > 0", timeout: 60)
        try await waitFor(web, expression: "document.getElementById('title').textContent === 'Receiver <test>' && !document.querySelector('#title test')")
        // Moving to another queue entry keeps following without leaving a stale Listen button.
        let nextTrack = SharedAudioTrack(id: UUID().uuidString, url: track.url, mimeType: track.mimeType, size: track.size)
        server.update(track: nextTrack, state: SharedAudioState(track: nextTrack.id, title: "Next song", position: 0, playing: true))
        try await waitFor(web, expression: "document.getElementById('title').textContent === 'Next song' && !audio.paused && audio.currentTime > 0 && document.getElementById('listen').hidden", timeout: 60)
        server.update(track: nextTrack, state: SharedAudioState(track: nextTrack.id, title: "Next song", position: 1, playing: false))
        try await waitFor(web, expression: "document.getElementById('audio').paused && document.getElementById('listen').hidden")
        server.stop()
        try await waitFor(web, expression: "document.getElementById('player').hidden", timeout: 20)
    }

    @discardableResult
    private func evaluate(_ web: WKWebView, script: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? Bool ?? false) }
            }
        }
    }

    private func waitFor(_ web: WKWebView, expression: String, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await evaluate(web, script: expression) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let diagnostic = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            web.evaluateJavaScript("JSON.stringify({status:document.getElementById('status').textContent,ready:audio.readyState,network:audio.networkState,paused:audio.paused,time:audio.currentTime,error:audio.error?.message})") { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String ?? "No browser state") }
            }
        }
        throw NSError(domain: "AudioSharingReceiverTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Receiver condition timed out: \(expression). \(diagnostic)"])

    }
}

@MainActor
private final class SharingNavigationDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

@MainActor
final class SharingSecurityTests: XCTestCase {
    func testCertificateIdentityTrustAndHostValidation() throws {
        let account = "MedioTests.tls.\(UUID().uuidString)"
        defer { removeRoot(account) }
        let first = try SharingTLSIdentity.make(host: "127.0.0.1", keychainAccount: account)
        let next = try SharingTLSIdentity.make(host: "192.168.1.10", keychainAccount: account)
        XCTAssertEqual(first.rootCertificate, next.rootCertificate, "Setup is reused across sharing sessions and Wi-Fi addresses")
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, first.rootCertificate as CFData))
        XCTAssertTrue(trust(first.certificate, root: root, host: "127.0.0.1"))
        XCTAssertFalse(trust(first.certificate, root: root, host: "192.168.1.10"))
        XCTAssertTrue(trust(next.certificate, root: root, host: "192.168.1.10"))
    }

    func testHTTPSRejectsUntrustedClientsAndServesWithPinnedRoot() async throws {
        let account = "MedioTests.tls.\(UUID().uuidString)"
        defer { removeRoot(account) }
        let identity = try SharingTLSIdentity.make(host: "127.0.0.1", keychainAccount: account)
        let ready = expectation(description: "TLS listener starts")
        let box = SharingTestPort()
        let server = LocalAudioHTTPServer(code: "123456", page: "encrypted receiver", restrictToWiFi: false, tlsIdentity: identity) { event in
            if case .ready(let port) = event { box.set(port); ready.fulfill() }
        }
        server.start()
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 30)
        let url = URL(string: "https://127.0.0.1:\(try XCTUnwrap(box.get()))/")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let untrusted = URLSession(configuration: config)
        defer { untrusted.invalidateAndCancel() }
        do {
            _ = try await untrusted.data(from: url)
            XCTFail("Untrusted TLS certificates must be rejected")
        } catch { XCTAssertTrue((error as NSError).domain == NSURLErrorDomain) }
        let trusted = URLSession(configuration: config, delegate: SharingTestTrustDelegate(root: identity.rootCertificate), delegateQueue: nil)
        defer { trusted.invalidateAndCancel() }
        let (data, response) = try await trusted.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "encrypted receiver")
    }

    func testPublicCertificateEndpointCannotExposeAudioOrJoin() async throws {
        let ready = expectation(description: "Certificate listener starts")
        let box = SharingTestPort()
        let server = LocalAudioHTTPServer(code: "123456", page: "must not be served", restrictToWiFi: false, certificateDownload: Data([1,2,3])) { event in
            if case .ready(let port) = event { box.set(port); ready.fulfill() }
        }
        server.start()
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 30)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for path in ["/", "/state", "/audio/test", "/join"] {
            let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(try XCTUnwrap(box.get()))\(path)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(try XCTUnwrap(box.get()))/certificate.cer")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data([1,2,3]))
    }

    func testJoinQRCodeRoundTripsAndKeepsCodeOutOfRequestURL() throws {
        let url = URL(string: "https://192.168.1.42:4443/#code=123456")!
        let image = try XCTUnwrap(SharingQRCode.image(for: url))
        let input = try XCTUnwrap(CIImage(image: image)).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let result = try XCTUnwrap(detector.features(in: input).first as? CIQRCodeFeature)
        XCTAssertEqual(result.messageString, url.absoluteString)
        XCTAssertNil(url.query)
        XCTAssertEqual(url.fragment, "code=123456")
    }

    private func trust(_ leaf: SecCertificate, root: SecCertificate, host: String) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private func removeRoot(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "Medio Local Audio TLS", kSecAttrAccount: account] as CFDictionary)
    }
}

private final class SharingTestTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let root: Data
    init(root: Data) { self.root = root }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let root = SecCertificateCreateWithData(nil, root as CFData) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor
final class SharingAudioPreparationTests: XCTestCase {
    func testCompressionReducesPCMSizePreservesSourceAndCleansUpCopy() async throws {
        let source = try makeTone()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let output = try await SharingAudioPreparation.makeAudioCopy(from: source, compact: true)
        var owner: SharedTemporaryAudio? = SharedTemporaryAudio(url: output)
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(audio.count, 1)
        XCTAssertTrue(video.isEmpty)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.1)
        XCTAssertLessThan(try Data(contentsOf: output).count, original.count / 3)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(owner?.url, output)
        owner = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testVideoSharingExtractsOnlyAudioInBothQualityModes() async throws {
        let tone = try makeTone()
        let silentVideo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let source = documents.appendingPathComponent(UUID().uuidString + ".mov")
        defer { for url in [tone, silentVideo, source] { try? FileManager.default.removeItem(at: url) } }
        let writer = try AVAssetWriter(outputURL: silentVideo, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for second in 0..<3 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        for (url, type) in [(tone, AVMediaType.audio), (silentVideo, AVMediaType.video)] {
            let sourceAsset = AVURLAsset(url: url)
            let tracks = try await sourceAsset.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.first)
            let destination = try XCTUnwrap(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try withExtendedLifetime(sourceAsset) {
                try destination.insertTimeRange(range, of: track, at: .zero)
            }
        }
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        export.outputURL = source
        export.outputFileType = .mov
        await export.export()
        XCTAssertEqual(export.status, .completed)
        let original = try Data(contentsOf: source)
        for compact in [false, true] {
            let prepared = await SharedAudioTrack.prepare(item: MediaItem(id: source.path, title: "Generated test video", isVideo: true), compact: compact)
            let shared = try XCTUnwrap(prepared)
            XCTAssertNotEqual(shared.url, source)
            XCTAssertEqual(shared.mimeType, "audio/mp4")
            let asset = AVURLAsset(url: shared.url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertTrue(videos.isEmpty)
            XCTAssertEqual(audios.count, 1)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testCancelledPreparationDoesNotChangeSource() async throws {
        let source = try makeTone()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let task = Task { try await SharingAudioPreparation.makeAudioCopy(from: source, compact: true) }
        task.cancel()
        do {
            let output = try await task.value
            try? FileManager.default.removeItem(at: output)
            XCTFail("Cancelled conversion must not publish an output")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func makeTone() throws -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for frame in 0..<Int(buffer.frameLength) { samples[frame] = Float(0.4 * sin(2 * .pi * 440 * Double(frame) / 44_100)) }
        }
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
        return source
    }
}
