import Combine
@preconcurrency import Foundation
import SwiftUI

// MARK: - Domain models (minimal for view-model wiring)

enum FileBrowserViewStyle: String {
    case icons
    case list
    case desktop

    static let menuCases: [FileBrowserViewStyle] = [.icons, .list, .desktop]

    var title: String {
        switch self {
        case .icons: "Icons"
        case .list: "List"
        case .desktop: "Desktop Style"
        }
    }

    var systemImage: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .desktop: "macwindow"
        }
    }
}

struct MediaItem: Hashable, Identifiable {
    let id: String
    var title: String
    var artist: String?
    var album: String?
    var genre: String? = nil
    var year: String? = nil
    var isVideo: Bool
}

extension Notification.Name {
    static let medioFavoritesDidChange = Notification.Name("MedioFavoritesDidChange")
    static let medioVisualMetadataOverridesDidChange = Notification.Name("MedioVisualMetadataOverridesDidChange")
    static let medioCustomSongColorsDidChange = Notification.Name("MedioCustomSongColorsDidChange")
    static let medioArtistProfileImagesDidChange = Notification.Name("MedioArtistProfileImagesDidChange")
    static let medioArtworkCacheDidChange = Notification.Name("MedioArtworkCacheDidChange")
}

struct PlaybackState: Hashable {
    var isPlaying: Bool = false
    var positionMs: Int = 0
    var durationMs: Int? = nil
    var repeatMode: RepeatMode = .off
    var shuffleEnabled: Bool = false
    var queueIndex: Int? = nil
}

enum RepeatMode: String, Hashable {
    case off
    case one
    case all
}

enum PlaybackAudioLevels {
    static let barCount = 6
    static let resting = Array(repeating: 0.15, count: barCount)
}

struct FileInfo: Hashable, Identifiable, Codable, Sendable {
    /// Absolute path (kept as String for easy persistence & list identity).
    let id: String
    var isDirectory: Bool
    var displayName: String
    var author: String?
    var album: String?
    var durationMs: Int? = nil
    var genre: String? = nil
    var year: String? = nil
    var albumArtist: String? = nil
    var composer: String? = nil
    var trackNumber: String? = nil
    var discNumber: String? = nil
    var contentCreationDate: Date? = nil
    var fileCreationDate: Date? = nil
    var fileModificationDate: Date? = nil
    var fileSizeBytes: Int? = nil
    var typeIdentifier: String? = nil
    var localizedTypeDescription: String? = nil

    enum FileType: String, Sendable {
        case folder = "Folder"
        case music = "Music"
        case lyrics = "Lyrics"
        case video = "Video"
        case unrecognized = "Unrecognized"
    }

    var fileType: FileType {
        if isDirectory {
            return .folder
        }

        let fileExtension = URL(fileURLWithPath: id).pathExtension.lowercased()
        if FileMetadataReader.videoExtensions.contains(fileExtension) {
            return .video
        }

        if FileMetadataReader.audioExtensions.contains(fileExtension) {
            return .music
        }

        let lyricsExtensions = ["lrc", "srt", "ttml", "ttlm", "txt", "xml"]
        if lyricsExtensions.contains(fileExtension) {
            return .lyrics
        }

        guard let typeIdentifier = typeIdentifier else {
            return .unrecognized
        }

        // Check for video types
        if typeIdentifier.hasPrefix("public.video") ||
           typeIdentifier.hasPrefix("public.movie") {
            return .video
        }

        // Check for audio types
        if typeIdentifier.hasPrefix("public.audio") {
            return .music
        }

        // Check for text/lyrics types
        if typeIdentifier.hasPrefix("public.text") ||
           typeIdentifier.hasPrefix("public.plain-text") {
            return .lyrics
        }

        return .unrecognized
    }

    enum CodingKeys: String, CodingKey {
        case id = "path"
        case isDirectory
        case displayName
        case author
        case album
        case durationMs
        case genre
        case year
        case albumArtist
        case composer
        case trackNumber
        case discNumber
        case contentCreationDate
        case fileCreationDate
        case fileModificationDate
        case fileSizeBytes
        case typeIdentifier
        case localizedTypeDescription
    }
}

enum MedioShadowFolder {
    static let favoritesID = "medio://shadow/favorites"
    static let favoritesName = "Favorites"

    static var favorites: FileInfo {
        FileInfo(
            id: favoritesID,
            isDirectory: true,
            displayName: favoritesName,
            author: nil,
            album: nil
        )
    }

    static func isFavorites(_ path: String) -> Bool {
        path == favoritesID
    }
}

enum MedioLastOpenedStore {
    private static let defaultsKey = "medio.lastOpened.v1"

    static func record(_ path: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        for key in PersistedMediaPath.lookupKeys(for: path).dropFirst() { values.removeValue(forKey: key) }
        values[normalized(path)] = date.timeIntervalSince1970
        defaults.set(values, forKey: defaultsKey)
    }

    static func date(for path: String, defaults: UserDefaults = .standard) -> Date? {
        let values = defaults.dictionary(forKey: defaultsKey) as? [String: Double]
        guard let timestamp = PersistedMediaPath.lookupKeys(for: path).compactMap({ values?[$0] }).first else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func normalized(_ path: String) -> String {
        PersistedMediaPath.encode(path)
    }
}

struct ShadowAlbum: Hashable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    var songs: [FileInfo]
    
    var releaseYear: String? {
        songs.compactMap { $0.year }.first
    }

    var totalDurationMs: Int? {
        let durations = songs.compactMap(\.durationMs)
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +)
    }

    var releaseKind: AlbumReleaseKind {
        AlbumReleaseKind.classify(trackCount: songs.count, totalDurationMs: totalDurationMs)
    }
}

struct AlbumTrackSection: Hashable, Identifiable {
    let id: String
    let title: String?
    let songs: [FileInfo]
}

enum AlbumTrackOrdering {
    static func sorted(_ songs: [FileInfo]) -> [FileInfo] {
        songs.sorted(by: areInIncreasingOrder)
    }

    static func sections(for songs: [FileInfo]) -> [AlbumTrackSection] {
        let sortedSongs = sorted(songs)
        guard sortedSongs.contains(where: { discKey(for: $0).hasDisc }) else {
            return [AlbumTrackSection(id: "music-files", title: nil, songs: sortedSongs)]
        }

        var sections: [AlbumTrackSection] = []
        var currentKey: DiscKey?
        var currentSongs: [FileInfo] = []

        for song in sortedSongs {
            let key = discKey(for: song)
            if let currentKey, currentKey != key {
                sections.append(section(for: currentKey, songs: currentSongs))
                currentSongs.removeAll()
            }
            currentKey = key
            currentSongs.append(song)
        }

        if let currentKey, !currentSongs.isEmpty {
            sections.append(section(for: currentKey, songs: currentSongs))
        }

        if sections.count == 1, let onlySection = sections.first {
            return [AlbumTrackSection(id: onlySection.id, title: "Tracks", songs: onlySection.songs)]
        }
        return sections
    }

    private static func areInIncreasingOrder(_ lhs: FileInfo, _ rhs: FileInfo) -> Bool {
        let lhsDisc = discKey(for: lhs)
        let rhsDisc = discKey(for: rhs)
        if let discOrder = compareDiscs(lhsDisc, rhsDisc) {
            return discOrder
        }

        let lhsTrack = ordinal(in: lhs.trackNumber)
        let rhsTrack = ordinal(in: rhs.trackNumber)
        switch (lhsTrack, rhsTrack) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return nameComesBefore(lhs, rhs)
        }
    }

    private static func compareDiscs(_ lhs: DiscKey, _ rhs: DiscKey) -> Bool? {
        if lhs.hasDisc != rhs.hasDisc {
            return lhs.hasDisc
        }

        switch (lhs.ordinal, rhs.ordinal) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if let lhsRaw = lhs.raw, let rhsRaw = rhs.raw, lhsRaw != rhsRaw {
            return lhsRaw.localizedStandardCompare(rhsRaw) == .orderedAscending
        }
        return nil
    }

    private static func nameComesBefore(_ lhs: FileInfo, _ rhs: FileInfo) -> Bool {
        let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    private static func section(for key: DiscKey, songs: [FileInfo]) -> AlbumTrackSection {
        AlbumTrackSection(id: key.id, title: key.title, songs: songs)
    }

    private static func discKey(for song: FileInfo) -> DiscKey {
        guard let raw = rawOrdinalComponent(song.discNumber) else {
            return DiscKey(raw: nil, ordinal: nil)
        }
        let ordinal = ordinal(in: raw)
        return DiscKey(raw: ordinal.map(String.init) ?? raw, ordinal: ordinal)
    }

    private static func rawOrdinalComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let first = value.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? value
        return first.isEmpty ? nil : first
    }

    private static func ordinal(in value: String?) -> Int? {
        guard let raw = rawOrdinalComponent(value),
              let match = raw.range(of: #"\d+"#, options: .regularExpression) else {
            return nil
        }
        return Int(raw[match])
    }

    private struct DiscKey: Hashable {
        let raw: String?
        let ordinal: Int?

        var hasDisc: Bool {
            raw != nil
        }

        var id: String {
            guard let raw else { return "disc-none" }
            if let ordinal { return "disc-\(ordinal)" }
            return "disc-\(raw.lowercased())"
        }

        var title: String? {
            guard let raw else { return "Other Tracks" }
            if let ordinal { return "Disc \(ordinal)" }
            return "Disc \(raw)"
        }
    }
}

enum AlbumReleaseKind: String, Hashable {
    case single = "Single"
    case ep = "EP"
    case album = "Album"

    private static let thirtyMinutesMs = 30 * 60 * 1000

    static func classify(trackCount: Int, totalDurationMs: Int?) -> AlbumReleaseKind {
        if trackCount > 0, trackCount <= 3 {
            return .single
        }
        if let totalDurationMs, totalDurationMs < thirtyMinutesMs {
            return .single
        }
        if (4...6).contains(trackCount) {
            return .ep
        }
        return .album
    }
}

struct ShadowArtist: Hashable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    var songs: [FileInfo]
}

struct LibraryStorageScanSummary: Equatable, Sendable {
    let documentsPath: String
    let scannedItemCount: Int
    let visibleHomeItemCount: Int
    let mediaItemCount: Int
    let refreshedAt: Date
}

// MARK: - Stores

@MainActor
final class LibraryStore: ObservableObject {
    @Published var isLoading: Bool = false
    @Published private(set) var loadingProgress: LibraryScanProgress?
    @Published var allItems: [FileInfo] = []
    @Published var homeItems: [FileInfo] = []
    @Published var librarySongs: [FileInfo] = []
    @Published var albums: [ShadowAlbum] = []
    @Published var artists: [ShadowArtist] = []
    @Published var favorites: Set<String> = [] // paths
    @Published var favoriteAddedDates: [String: Date] = [:]
    @Published private(set) var lastStorageScanSummary: LibraryStorageScanSummary?
    @Published private(set) var lastStorageScanError: String?
    @Published private(set) var loadedCachedSnapshotOnLaunch: Bool = false

    private var didStart: Bool = false
    private var refreshGeneration: UInt64 = 0
    private var favoritesObserver: NSObjectProtocol? = nil
    private var metadataOverridesObserver: NSObjectProtocol? = nil

    init() {
        // no superclass to call; ObservableObject is a protocol
        // Observe favorites changes to keep in-memory favorites consistent.
        favoritesObserver = NotificationCenter.default.addObserver(forName: .medioFavoritesDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            if let arr = note.userInfo?["favorites"] as? [String] {
                let timestamps = note.userInfo?["addedDates"] as? [String: Double]
                Task { @MainActor in
                    self.favorites = Set(arr)
                    if let timestamps {
                        self.favoriteAddedDates = timestamps.mapValues(Date.init(timeIntervalSince1970:))
                    }
                }
            }
        }
        metadataOverridesObserver = NotificationCenter.default.addObserver(forName: .medioVisualMetadataOverridesDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.allItems.isEmpty else { return }
                let items = self.allItems
                let index = await Task.detached(priority: .utility) {
                    BuildLibraryIndexUseCase().execute(items)
                }.value
                guard self.allItems == items else { return }
                self.apply(index)
            }
        }
    }

    deinit {
        if let obs = favoritesObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = metadataOverridesObserver { NotificationCenter.default.removeObserver(obs) }
    }

    /// Launch load:
    /// - apply cached index immediately (if any)
    /// - record the cached snapshot timestamp so UI can show when it was saved
    /// - scan only when there is no cache; RootView follows cached launches with a refresh
    func loadOnLaunch(
        dataSource: MediaLibraryDataSource,
        scanUseCase: ScanLibraryUseCase
    ) async {
        guard !didStart else { return }
        didStart = true
        loadedCachedSnapshotOnLaunch = false

        let indexer = BuildLibraryIndexUseCase()
        let cached = await Task.detached(priority: .userInitiated) {
            dataSource.loadCachedItems()
        }.value

        if let cached {
            let cachedIndex = await Task.detached(priority: .userInitiated) {
                indexer.execute(cached)
            }.value
            let cachedDate = await Task.detached(priority: .utility) {
                dataSource.cachedSnapshotDate()
            }.value

            loadedCachedSnapshotOnLaunch = true
            apply(cachedIndex)
            recordStorageScanSummary(
                for: cachedIndex,
                refreshedAt: cachedDate ?? Date()
            )
            preloadArtwork(for: cachedIndex.songs)
            return
        }

        beginLoading()
        defer { endLoading() }

        do {
            let fresh = try await scanUseCase.execute(progress: loadingProgressHandler())
            apply(fresh)
            recordStorageScanSummary(for: fresh)
            preloadArtwork(for: fresh.songs)
        } catch {
            lastStorageScanError = error.localizedDescription
        }
    }

    func refresh(scanUseCase: ScanLibraryUseCase) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        beginLoading()
        defer {
            if generation == refreshGeneration { endLoading() }
        }
        do {
            var previousArtworkFingerprints: [String: String] = [:]
            for song in librarySongs {
                previousArtworkFingerprints[song.id] = artworkFingerprint(for: song)
            }
            let fresh = try await scanUseCase.execute(progress: loadingProgressHandler(for: generation))
            guard generation == refreshGeneration else { return }
            loadedCachedSnapshotOnLaunch = false
            apply(fresh)
            recordStorageScanSummary(for: fresh)
            retryArtworkForNewOrChangedSongs(in: fresh.songs, previousArtworkFingerprints: previousArtworkFingerprints)
        } catch {
            guard generation == refreshGeneration else { return }
            lastStorageScanError = error.localizedDescription
            AppLog.library.error("Library refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginLoading() {
        isLoading = true
        loadingProgress = LibraryScanProgress(
            phase: .preparing,
            completedItemCount: 0,
            totalItemCount: nil
        )
    }

    private func endLoading() {
        loadingProgress = nil
        isLoading = false
    }

    private func loadingProgressHandler(for generation: UInt64? = nil) -> LibraryScanProgressHandler {
        { [weak self] progress in
            if let generation, self?.refreshGeneration != generation { return }
            self?.loadingProgress = progress
        }
    }

    private func recordStorageScanSummary(
        for index: (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist]),
        refreshedAt: Date = Date()
    ) {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .standardizedFileURL
            .path ?? ""
        let scannedStorageItemCount: Int
        let scannedStorageSongCount: Int
        if documentsPath.isEmpty {
            scannedStorageItemCount = index.items.count
            scannedStorageSongCount = index.songs.count
        } else {
            scannedStorageItemCount = index.items.filter { item in
                let path = URL(fileURLWithPath: item.id).standardizedFileURL.path
                return path.hasPrefix(documentsPath + "/")
            }.count
            scannedStorageSongCount = index.songs.filter { item in
                let path = URL(fileURLWithPath: item.id).standardizedFileURL.path
                return path.hasPrefix(documentsPath + "/")
            }.count
        }
        lastStorageScanError = nil
        lastStorageScanSummary = LibraryStorageScanSummary(
            documentsPath: documentsPath,
            scannedItemCount: scannedStorageItemCount,
            visibleHomeItemCount: homeItems.count,
            mediaItemCount: scannedStorageSongCount,
            refreshedAt: refreshedAt
        )
    }

    private func preloadArtwork(for songs: [FileInfo]) {
        // Visible rows request their own artwork. A small warm-up avoids decoding dozens of
        // off-screen audio files at launch while still making the first screen feel immediate.
        ArtworkCache.shared.preload(Array(songs.lazy.map(\.id).prefix(8)))
    }

    private func retryArtworkForNewOrChangedSongs(in songs: [FileInfo], previousArtworkFingerprints: [String: String]) {
        let retrySongIDs = songs.compactMap { song -> String? in
            let fingerprint = artworkFingerprint(for: song)
            guard previousArtworkFingerprints[song.id] != fingerprint else { return nil }
            return song.id
        }
        guard !retrySongIDs.isEmpty else {
            preloadArtwork(for: songs)
            return
        }
        ArtworkCache.shared.invalidate(retrySongIDs)
        preloadArtwork(for: songs)
    }

    private func artworkFingerprint(for song: FileInfo) -> String {
        let modifiedAt = song.fileModificationDate?.timeIntervalSince1970 ?? -1
        let fileSize = song.fileSizeBytes ?? -1
        return "\(modifiedAt)|\(fileSize)"
    }

    private func apply(_ index: (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist])) {
        if allItems != index.items {
            allItems = index.items
        }

        let nextHomeItems: [FileInfo]
        // Filter homeItems to only show root-level items (direct children of Documents)
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL.path else {
            publishDerivedLibraryViews(
                homeItems: index.items,
                songs: index.songs,
                albums: index.albums,
                artists: index.artists
            )
            return
        }
        nextHomeItems = index.items.filter { item in
            let standardizedPath = URL(fileURLWithPath: item.id).standardizedFileURL.path
            guard standardizedPath.hasPrefix(documentsPath + "/") else { return false }

            let relativePath = String(standardizedPath.dropFirst(documentsPath.count))
            // Root-level items have no additional "/" after the initial one
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 1 else { return false }

            let lowerName = components[0].lowercased()
            return lowerName != "users" && lowerName != "add music files here.txt"
        }
        publishDerivedLibraryViews(
            homeItems: nextHomeItems,
            songs: index.songs,
            albums: index.albums,
            artists: index.artists
        )
    }

    private func publishDerivedLibraryViews(
        homeItems nextHomeItems: [FileInfo],
        songs nextSongs: [FileInfo],
        albums nextAlbums: [ShadowAlbum],
        artists nextArtists: [ShadowArtist]
    ) {
        if homeItems != nextHomeItems {
            homeItems = nextHomeItems
        }
        if librarySongs != nextSongs {
            librarySongs = nextSongs
            ArtworkCache.shared.updateFolderPreviews(for: nextSongs)
        }
        if albums != nextAlbums {
            albums = nextAlbums
        }
        if artists != nextArtists {
            artists = nextArtists
        }
    }

    // MARK: - Favorites

    func loadFavoritesOnLaunch(favoritesRepository: FavoritesRepository) async {
        do {
            favorites = try await favoritesRepository.loadFavorites()
            favoriteAddedDates = try await favoritesRepository.loadFavoriteAddedDates()
        } catch {
            favorites = []
            favoriteAddedDates = [:]
            AppLog.persistence.error("Favorites could not be loaded: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setFavorite(_ path: String, isFavorite: Bool, favoritesRepository: FavoritesRepository) async {
        do {
            favorites = try await favoritesRepository.setFavorite(path, isFavorite: isFavorite)
            favoriteAddedDates = try await favoritesRepository.loadFavoriteAddedDates()
        } catch {
            AppLog.persistence.error("Favorite change could not be persisted: \(error.localizedDescription, privacy: .public)")
            // Best-effort: keep local value if persistence fails.
            if isFavorite {
                favorites.insert(path)
                favoriteAddedDates[path] = favoriteAddedDates[path] ?? Date()
            } else {
                favorites.remove(path)
                favoriteAddedDates.removeValue(forKey: path)
            }
        }
    }

    func toggleFavorite(_ path: String, favoritesRepository: FavoritesRepository) async {
        await setFavorite(path, isFavorite: !favorites.contains(path), favoritesRepository: favoritesRepository)
    }

    func isFavorite(_ path: String) -> Bool {
        favorites.contains(path)
    }
}

@MainActor
final class PlaybackStore: ObservableObject {
    @Published var nowPlaying: MediaItem? = nil
    @Published var queue: [MediaItem] = []
    @Published var isPlaying: Bool = false
    @Published var audioLevels: [Double] = PlaybackAudioLevels.resting
    private(set) var positionMs: Int = 0
    private(set) var durationMs: Int? = nil
    @Published var currentIndex: Int? = nil

    /// Back-compat for existing view models.
    @Published var playback: PlaybackState = PlaybackState()

    private var playbackCancellable: AnyCancellable?

    func connect(playbackService: PlaybackService) {
        guard let publishing = playbackService as? PlaybackServicePublishing else { return }
        playbackCancellable?.cancel()

        // Subscribe to playback service updates; the player is the single progress clock.
        playbackCancellable = publishing.playbackUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }
                self.apply(update)
            }
    }

    private func apply(_ update: PlaybackUpdate) {
        // Apply update atomically and defensively so UI never sees a partial state.

        // Build visible queue from update (authoritative)
        var visibleQueue = update.queue
        if visibleQueue.isEmpty, (update.isPlaying || isPlaying), !queue.isEmpty {
            // AVQueuePlayer can emit transient empty snapshots while active.
            // Keep the last valid queue to prevent UI from dropping to empty state.
            visibleQueue = queue
        }

        // Determine canonical index: prefer update.queueIndex if valid, otherwise try to locate update.item inside queue
        var canonicalIndex: Int? = nil
        if let idx = update.queueIndex, idx >= 0, idx < visibleQueue.count {
            canonicalIndex = idx
        } else if let item = update.item {
            canonicalIndex = visibleQueue.firstIndex(where: { $0.id == item.id })
        }

        // Keep the currently displayed item stable across transient updates that may omit
        // item/index while the queue is being rebuilt by AVQueuePlayer internals.
        if canonicalIndex == nil, !visibleQueue.isEmpty {
            if let current = nowPlaying,
               let idx = visibleQueue.firstIndex(where: { $0.id == current.id }) {
                canonicalIndex = idx
            } else if let currentIndex, currentIndex >= 0, currentIndex < visibleQueue.count {
                canonicalIndex = currentIndex
            } else {
                canonicalIndex = 0
            }
        }

        // Determine nowPlaying: prefer explicit update.item (fresh metadata), otherwise derive from queue+index
        var canonicalNowPlaying: MediaItem? = nil
        if let item = update.item {
            canonicalNowPlaying = item
            // The service-provided index is authoritative in the normal progress-update path.
            // Search the full queue only when that index is absent or inconsistent.
            if canonicalIndex.map({ visibleQueue[$0].id != item.id }) ?? true,
               let idx = visibleQueue.firstIndex(where: { $0.id == item.id }) {
                canonicalIndex = idx
            }
        } else if let idx = canonicalIndex, idx >= 0, idx < visibleQueue.count {
            canonicalNowPlaying = visibleQueue[idx]
        } else {
            canonicalNowPlaying = nil
        }

        if canonicalNowPlaying == nil, (update.isPlaying || isPlaying), let existing = nowPlaying {
            canonicalNowPlaying = existing
            if canonicalIndex == nil {
                canonicalIndex = visibleQueue.firstIndex(where: { $0.id == existing.id }) ?? currentIndex
            }
        }

        // Commit all values together on main thread (we're already on main due to receive(on:))
        if queue != visibleQueue { queue = visibleQueue }
        if currentIndex != canonicalIndex { currentIndex = canonicalIndex }
        if nowPlaying != canonicalNowPlaying { nowPlaying = canonicalNowPlaying }
        if isPlaying != update.isPlaying { isPlaying = update.isPlaying }
        let nextAudioLevels = update.isPlaying ? update.audioLevels : PlaybackAudioLevels.resting
        if audioLevels != nextAudioLevels { audioLevels = nextAudioLevels }
        if durationMs != update.durationMs { durationMs = update.durationMs }

        // Position handling: accept update.positionMs as the authoritative player snapshot.
        if positionMs != update.positionMs { positionMs = update.positionMs }

        // Mirror into backward-compatible `playback` struct
        let nextPlayback = PlaybackState(
            isPlaying: update.isPlaying,
            positionMs: update.positionMs,
            durationMs: update.durationMs,
            repeatMode: update.repeatMode,
            shuffleEnabled: update.shuffleEnabled,
            queueIndex: canonicalIndex
        )
        if playback != nextPlayback { playback = nextPlayback }
    }
}

extension PlaybackStore {
    var queueIndexForControls: Int? {
        if let currentIndex, currentIndex >= 0, currentIndex < queue.count {
            return currentIndex
        }
        if let index = playback.queueIndex, index >= 0, index < queue.count {
            return index
        }
        if let nowPlaying {
            return queue.firstIndex { $0.id == nowPlaying.id }
        }
        return nil
    }

    var canSkipToPreviousQueueItem: Bool {
        guard let index = queueIndexForControls else { return false }
        return index > 0
    }

    var canSkipToNextQueueItem: Bool {
        guard let index = queueIndexForControls else { return false }
        return index + 1 < queue.count
    }
}

enum NowPlayingBackgroundMode: Int, Hashable, CaseIterable {
    case dynamic = 0
    case albumThemed = 1
    case custom = 2
}

enum HomeSortBy: Int, Hashable, CaseIterable {
    case added = 0
    case name = 1
    case kind = 2
    case dateModified = 3
    case size = 4
    case releaseDate = 5

    static let menuCases: [HomeSortBy] = [.name, .kind, .dateModified, .releaseDate, .size]

    var title: String {
        switch self {
        case .added: return "Added"
        case .name: return "Name"
        case .kind: return "Kind"
        case .dateModified: return "Date Modified"
        case .releaseDate: return "Release Date"
        case .size: return "Size"
        }
    }

    var systemImage: String {
        switch self {
        case .added: return "plus"
        case .name: return "textformat"
        case .kind: return "square.grid.2x2"
        case .dateModified: return "calendar.badge.clock"
        case .releaseDate: return "calendar"
        case .size: return "internaldrive"
        }
    }

}

enum FileSortOrdering {
    static func sorted(_ items: [FileInfo], by sort: HomeSortBy, ascending: Bool) -> [FileInfo] {
        guard sort != .added else {
            return ascending ? items : Array(items.reversed())
        }

        if sort == .releaseDate {
            return items.sorted { lhs, rhs in
                let lhsGroup = releaseDateGroup(for: lhs)
                let rhsGroup = releaseDateGroup(for: rhs)
                if lhsGroup != rhsGroup {
                    return lhsGroup < rhsGroup
                }

                let lhsDate = releaseDate(for: lhs)
                let rhsDate = releaseDate(for: rhs)
                if lhsDate != rhsDate {
                    return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
                }
                return nameComesBefore(lhs, rhs)
            }
        }

        let sorted = items.sorted { lhs, rhs in
            let orderedBefore: Bool
            switch sort {
            case .added:
                orderedBefore = false
            case .name:
                orderedBefore = nameComesBefore(lhs, rhs)
            case .kind:
                let lhsKind = lhs.localizedTypeDescription ?? lhs.fileType.rawValue
                let rhsKind = rhs.localizedTypeDescription ?? rhs.fileType.rawValue
                let comparison = lhsKind.localizedCaseInsensitiveCompare(rhsKind)
                orderedBefore = comparison == .orderedSame
                    ? nameComesBefore(lhs, rhs)
                    : comparison == .orderedAscending
            case .dateModified:
                let lhsDate = dateModified(for: lhs)
                let rhsDate = dateModified(for: rhs)
                orderedBefore = lhsDate == rhsDate ? nameComesBefore(lhs, rhs) : lhsDate < rhsDate
            case .releaseDate:
                let lhsDate = releaseDate(for: lhs)
                let rhsDate = releaseDate(for: rhs)
                orderedBefore = lhsDate == rhsDate ? nameComesBefore(lhs, rhs) : lhsDate < rhsDate
            case .size:
                let lhsSize = lhs.fileSizeBytes ?? 0
                let rhsSize = rhs.fileSizeBytes ?? 0
                orderedBefore = lhsSize == rhsSize ? nameComesBefore(lhs, rhs) : lhsSize < rhsSize
            }
            return orderedBefore
        }
        return ascending ? sorted : Array(sorted.reversed())
    }

    static func dateModified(for item: FileInfo) -> Date {
        item.fileModificationDate ?? item.contentCreationDate ?? item.fileCreationDate ?? .distantPast
    }

    static func releaseDate(for item: FileInfo) -> Date {
        if let contentCreationDate = item.contentCreationDate {
            return contentCreationDate
        }
        if let year = item.year.flatMap(Int.init),
           let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1)) {
            return date
        }
        return item.fileCreationDate ?? item.fileModificationDate ?? .distantPast
    }

    private static func releaseDateGroup(for item: FileInfo) -> Int {
        if item.isDirectory { return 0 }
        if item.fileType == .music || item.fileType == .video { return 1 }
        return 2
    }

    private static func nameComesBefore(_ lhs: FileInfo, _ rhs: FileInfo) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}

enum FavoritesSortBy: Int, Hashable, CaseIterable {
    case dateAdded = 0
    case name = 1
    case dateModified = 2
    case releaseDate = 3
    case size = 4

    static let menuCases: [FavoritesSortBy] = [.dateAdded, .name, .dateModified, .releaseDate, .size]

    var title: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .releaseDate: return "Release Date"
        case .size: return "Size"
        }
    }

    var systemImage: String {
        switch self {
        case .dateAdded: return "list.number"
        case .name: return "textformat"
        case .dateModified: return "calendar.badge.clock"
        case .releaseDate: return "calendar"
        case .size: return "internaldrive"
        }
    }
}

/// Codable-safe color placeholder (keeps the type stable for later persistence).
struct ColorToken: Hashable {
    var rgba: UInt32
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum DefaultsKey {
        static let priorityFoldersCount = "medio.settings.priorityFoldersCount"
        static let priorityFolderPaths = "medio.settings.priorityFolderPaths"
        static let prioritySlotArtworkPaths = "medio.settings.prioritySlotArtworkPaths"
        static let prioritySlotImageOnlyKeys = "medio.settings.prioritySlotImageOnlyKeys"
        static let favoritesHomeFolderEnabled = "medio.settings.favoritesHomeFolderEnabled"
        static let primaryPriorityFolderPath = "medio.settings.primaryPriorityFolderPath"
        static let appCanConnectToInternet = "medio.settings.appCanConnectToInternet"
        static let medioReCappedEnabled = "medio.settings.medioReCappedEnabled"
        static let favoritesSortBy = "medio.settings.favoritesSortBy"
        static let favoritesSortAscending = "medio.settings.favoritesSortAscending"
        static let showUnknownArtists = "medio.settings.showUnknownArtists"
        static let showUnknownAlbums = "medio.settings.showUnknownAlbums"
    }

    private let defaults: UserDefaults
    private let preferencesRepository: PreferencesRepository
    private var persistenceTask: Task<Void, Never>?

    @Published var accentColor: ColorToken = ColorToken(rgba: 0x000000FF) {
        didSet { persistUnifiedSettings() }
    }
    @Published var nowPlayingBackgroundMode: NowPlayingBackgroundMode = .dynamic {
        didSet { persistUnifiedSettings() }
    }
    @Published var nowPlayingCustomBackgroundColor: ColorToken = ColorToken(rgba: 0x000000FF) {
        didSet { persistUnifiedSettings() }
    }
    @Published var nowPlayingAlbumColorIndex: Int = 0 {
        didSet {
            let clamped = min(3, max(0, nowPlayingAlbumColorIndex))
            if nowPlayingAlbumColorIndex != clamped {
                nowPlayingAlbumColorIndex = clamped
                return
            }
            persistUnifiedSettings()
        }
    }

    @Published var priorityFoldersCount: Int = 4 {
        didSet {
            let clamped = min(10, max(0, priorityFoldersCount))
            if priorityFoldersCount != clamped {
                priorityFoldersCount = clamped
                return
            }
            normalizePrioritySlots()
            savePrioritySettings()
        }
    }
    @Published var priorityFolderPaths: [String?] = [] {
        didSet {
            normalizePrioritySlots()
            savePrioritySettings()
        }
    }
    @Published var prioritySlotArtworkPaths: [String: String] = [:] {
        didSet {
            normalizePrioritySlots()
            savePrioritySettings()
        }
    }
    @Published var prioritySlotImageOnlyKeys: Set<String> = [] {
        didSet {
            normalizePrioritySlots()
            savePrioritySettings()
        }
    }
    @Published var favoritesHomeFolderEnabled = true {
        didSet { savePrioritySettings() }
    }
    @Published var primaryPriorityFolderPath: String? {
        didSet { savePrioritySettings() }
    }
    @Published var homeSortBy: HomeSortBy = .added {
        didSet { persistUnifiedSettings() }
    }
    @Published var homeSortAscending: Bool = true {
        didSet { persistUnifiedSettings() }
    }
    @Published var favoritesSortBy: FavoritesSortBy = .dateAdded {
        didSet { saveFavoritesSortSettings() }
    }
    @Published var favoritesSortAscending: Bool = false {
        didSet { saveFavoritesSortSettings() }
    }
    @Published var lyricsEnabled: Bool = true {
        didSet { persistUnifiedSettings() }
    }
    @Published var nowPlayingShowsTotalDuration: Bool = false {
        didSet { persistUnifiedSettings() }
    }
    @Published var showUnknownArtists: Bool = true {
        didSet { saveLibraryCategoryVisibilitySettings() }
    }
    @Published var showUnknownAlbums: Bool = true {
        didSet { saveLibraryCategoryVisibilitySettings() }
    }
    /// Global gate for every network connection. Any internet-using feature must check this before starting URLSession work.
    @Published var appCanConnectToInternet: Bool = false {
        didSet {
            saveInternetAccessSetting()
        }
    }
    @Published var medioReCappedEnabled: Bool = true {
        didSet { saveMedioReCappedSetting() }
    }

    func selectSort(_ sort: HomeSortBy) {
        if homeSortBy == sort {
            homeSortAscending.toggle()
        } else {
            homeSortBy = sort
            homeSortAscending = true
        }
    }

    func selectFavoritesSort(_ sort: FavoritesSortBy) {
        if favoritesSortBy == sort {
            favoritesSortAscending.toggle()
        } else {
            favoritesSortBy = sort
            favoritesSortAscending = sort != .dateAdded
        }
    }

    private var isNormalizingPrioritySlots = false
    private var isLoadingPrioritySettings = false

    init(
        defaults: UserDefaults = .standard,
        preferencesRepository: PreferencesRepository? = nil
    ) {
        self.defaults = defaults
        self.preferencesRepository = preferencesRepository
            ?? UserDefaultsPreferencesRepository(storage: SettingsDefaultsStorage(defaults))
        isLoadingPrioritySettings = true
        let persistedSnapshot: SettingsSnapshot?
        do {
            persistedSnapshot = try SettingsPersistence.load(from: defaults)
        } catch {
            AppLog.persistence.error("Stored settings could not be decoded: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: SettingsPersistence.key)
            persistedSnapshot = nil
        }
        if let snapshot = persistedSnapshot {
            snapshot.apply(to: self)
        } else if defaults.object(forKey: DefaultsKey.priorityFoldersCount) != nil {
            priorityFoldersCount = defaults.integer(forKey: DefaultsKey.priorityFoldersCount)
            if let paths = defaults.array(forKey: DefaultsKey.priorityFolderPaths) as? [String] {
                priorityFolderPaths = paths.map { $0.isEmpty ? nil : $0 }
            }
            if let paths = defaults.dictionary(forKey: DefaultsKey.prioritySlotArtworkPaths) as? [String: String] {
                prioritySlotArtworkPaths = paths
            }
            if let keys = defaults.stringArray(forKey: DefaultsKey.prioritySlotImageOnlyKeys) {
                prioritySlotImageOnlyKeys = Set(keys)
            }
            if defaults.object(forKey: DefaultsKey.favoritesHomeFolderEnabled) != nil {
                favoritesHomeFolderEnabled = defaults.bool(forKey: DefaultsKey.favoritesHomeFolderEnabled)
            }
            primaryPriorityFolderPath = defaults.string(forKey: DefaultsKey.primaryPriorityFolderPath)?.nilIfEmpty
            if defaults.object(forKey: DefaultsKey.appCanConnectToInternet) != nil {
                appCanConnectToInternet = defaults.bool(forKey: DefaultsKey.appCanConnectToInternet)
            }
            if defaults.object(forKey: DefaultsKey.medioReCappedEnabled) != nil {
                medioReCappedEnabled = defaults.bool(forKey: DefaultsKey.medioReCappedEnabled)
            }
            if defaults.object(forKey: DefaultsKey.showUnknownArtists) != nil {
                showUnknownArtists = defaults.bool(forKey: DefaultsKey.showUnknownArtists)
            }
            if defaults.object(forKey: DefaultsKey.showUnknownAlbums) != nil {
                showUnknownAlbums = defaults.bool(forKey: DefaultsKey.showUnknownAlbums)
            }
            if defaults.object(forKey: DefaultsKey.favoritesSortBy) != nil {
                favoritesSortBy = FavoritesSortBy(rawValue: defaults.integer(forKey: DefaultsKey.favoritesSortBy)) ?? .dateAdded
            }
            if defaults.object(forKey: DefaultsKey.favoritesSortAscending) != nil {
                favoritesSortAscending = defaults.bool(forKey: DefaultsKey.favoritesSortAscending)
            }
        }
        isLoadingPrioritySettings = false
        normalizePrioritySlots()
        persistUnifiedSettings()
    }

    func priorityFolderPath(at slot: Int) -> String? {
        if slot == -1 { return primaryPriorityFolderPath }
        guard slot >= 0, slot < priorityFolderPaths.count else { return nil }
        return priorityFolderPaths[slot]
    }

    func assignPriorityFolder(_ path: String, to slot: Int) {
        guard slot >= -1 else { return }
        let requiredVisibleSlots = slot == -1 ? 1 : slot + 2
        if requiredVisibleSlots > priorityFoldersCount {
            priorityFoldersCount = requiredVisibleSlots
        }
        if slot == -1 {
            primaryPriorityFolderPath = path
            savePrioritySettings()
            return
        }
        normalizePrioritySlots()
        var updatedPaths = priorityFolderPaths
        guard slot < updatedPaths.count else { return }
        updatedPaths[slot] = path
        priorityFolderPaths = updatedPaths
        savePrioritySettings(paths: updatedPaths)
    }

    func clearPriorityFolder(at slot: Int) {
        guard slot >= -1 else { return }
        if slot == -1 {
            primaryPriorityFolderPath = nil
            savePrioritySettings()
            return
        }
        normalizePrioritySlots()
        guard slot < priorityFolderPaths.count else { return }
        var updatedPaths = priorityFolderPaths
        updatedPaths[slot] = nil
        priorityFolderPaths = updatedPaths
        savePrioritySettings(paths: updatedPaths)
    }

    func prioritySlotArtworkPath(at slot: Int) -> String? {
        guard let key = prioritySlotKey(for: slot) else { return nil }
        return prioritySlotArtworkPaths[key]
    }

    func setPrioritySlotArtworkPath(_ path: String?, at slot: Int) {
        guard let key = prioritySlotKey(for: slot) else { return }
        normalizePrioritySlots()
        var updated = prioritySlotArtworkPaths
        if let path, !path.isEmpty {
            updated[key] = path
        } else {
            updated.removeValue(forKey: key)
        }
        prioritySlotArtworkPaths = updated
        savePrioritySettings(artworkPaths: updated)
    }

    func isPrioritySlotImageOnly(_ slot: Int) -> Bool {
        guard let key = prioritySlotKey(for: slot) else { return false }
        return prioritySlotImageOnlyKeys.contains(key) && prioritySlotArtworkPaths[key] != nil
    }

    func setPrioritySlotImageOnly(_ isImageOnly: Bool, at slot: Int) {
        guard let key = prioritySlotKey(for: slot) else { return }
        var updated = prioritySlotImageOnlyKeys
        if isImageOnly {
            updated.insert(key)
        } else {
            updated.remove(key)
        }
        prioritySlotImageOnlyKeys = updated
        savePrioritySettings(imageOnlyKeys: updated)
    }

    func resetPrioritySlot(at slot: Int) {
        clearPriorityFolder(at: slot)
        setPrioritySlotArtworkPath(nil, at: slot)
        setPrioritySlotImageOnly(false, at: slot)
    }

    func removePriorityFolder(at slot: Int) {
        guard slot >= 0, slot < priorityFolderPaths.count else { return }
        normalizePrioritySlots()
        var updatedPaths = priorityFolderPaths
        updatedPaths.remove(at: slot)
        let updatedCount = max(0, priorityFoldersCount - 1)
        priorityFolderPaths = updatedPaths
        priorityFoldersCount = updatedCount
        savePrioritySettings(count: updatedCount, paths: updatedPaths)
    }

    private func normalizePrioritySlots() {
        guard !isNormalizingPrioritySlots else { return }
        isNormalizingPrioritySlots = true
        if priorityFoldersCount < 0 {
            priorityFoldersCount = 0
        } else if priorityFoldersCount > 10 {
            priorityFoldersCount = 10
        }
        let storedSlotCount = max(0, priorityFoldersCount - 1)
        if priorityFolderPaths.count < storedSlotCount {
            priorityFolderPaths.append(contentsOf: Array(repeating: nil, count: storedSlotCount - priorityFolderPaths.count))
        } else if priorityFolderPaths.count > storedSlotCount {
            priorityFolderPaths = Array(priorityFolderPaths.prefix(storedSlotCount))
        }
        let validKeys = Set((0..<storedSlotCount).map { "\($0)" }).union(["primary"])
        let filteredArtworkPaths = prioritySlotArtworkPaths.filter { validKeys.contains($0.key) }
        if filteredArtworkPaths.count != prioritySlotArtworkPaths.count {
            prioritySlotArtworkPaths = filteredArtworkPaths
        }
        let filteredImageOnlyKeys = prioritySlotImageOnlyKeys.intersection(validKeys)
        if filteredImageOnlyKeys != prioritySlotImageOnlyKeys {
            prioritySlotImageOnlyKeys = filteredImageOnlyKeys
        }
        isNormalizingPrioritySlots = false
    }

    private func prioritySlotKey(for slot: Int) -> String? {
        if slot == -1 { return "primary" }
        return slot >= 0 ? "\(slot)" : nil
    }

    private func savePrioritySettings(
        count: Int? = nil,
        paths: [String?]? = nil,
        artworkPaths: [String: String]? = nil,
        imageOnlyKeys: Set<String>? = nil
    ) {
        guard !isNormalizingPrioritySlots, !isLoadingPrioritySettings else { return }
        persistUnifiedSettings()
    }

    private func saveInternetAccessSetting() {
        guard !isLoadingPrioritySettings else { return }
        persistUnifiedSettings()
    }

    private func saveMedioReCappedSetting() {
        guard !isLoadingPrioritySettings else { return }
        persistUnifiedSettings()
    }

    private func saveLibraryCategoryVisibilitySettings() {
        guard !isLoadingPrioritySettings else { return }
        persistUnifiedSettings()
    }

    private func saveFavoritesSortSettings() {
        guard !isLoadingPrioritySettings else { return }
        persistUnifiedSettings()
    }

    private func persistUnifiedSettings() {
        guard !isLoadingPrioritySettings else { return }
        let snapshot = SettingsSnapshot.fromStore(self)
        let repository = preferencesRepository
        persistenceTask?.cancel()
        persistenceTask = Task {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                try Task.checkCancellation()
                try await repository.saveSettings(snapshot)
            } catch is CancellationError {
                return
            } catch {
                AppLog.persistence.error("Settings could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flushPersistence() async {
        persistenceTask?.cancel()
        persistenceTask = nil
        do {
            try await preferencesRepository.saveSettings(SettingsSnapshot.fromStore(self))
        } catch {
            AppLog.persistence.error("Settings could not be flushed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Service / repository protocols (separation of concerns)

// Note: LibraryRepository and FavoritesRepository defined in ViewModels.swift

@MainActor
protocol PlaybackService {
    func setQueue(_ items: [MediaItem], startAt index: Int) async
    func play() async
    func pause() async
    func seek(toMs: Int) async
    func skipNext() async
    func skipPrevious() async
    func toggleShuffle() async
    func cycleRepeatMode() async
}

/// Optional capability: a playback service that emits updates for UI/state stores.
@MainActor
protocol PlaybackServicePublishing {
    var playbackUpdates: AnyPublisher<PlaybackUpdate, Never> { get }
}

struct PlaybackUpdate: Equatable {
    var item: MediaItem?
    var queue: [MediaItem]
    var isPlaying: Bool
    var positionMs: Int
    var durationMs: Int?
    var queueIndex: Int?
    var repeatMode: RepeatMode
    var shuffleEnabled: Bool
    var audioLevels: [Double] = PlaybackAudioLevels.resting
}

// MARK: - In-memory implementations (so everything runs)

struct InMemoryLibraryRepository: LibraryRepository {
    func loadLibrary() async throws -> (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist]) {
        // Minimal fixture data to exercise navigation + MVVM wiring.
        let folder = FileInfo(id: "/example/folder", isDirectory: true, displayName: "Example Folder", author: nil, album: nil)
        let song1 = FileInfo(id: "/example/folder/song1.mp3", isDirectory: false, displayName: "Song One", author: "Example Artist", album: "Example Album")
        let song2 = FileInfo(id: "/example/folder/song2.mp3", isDirectory: false, displayName: "Song Two", author: "Example Artist", album: "Example Album")
        let items = [folder, song1, song2]
        let songs = [song1, song2]
        let albums = [ShadowAlbum(name: "Example Album", songs: songs)]
        let artists = [ShadowArtist(name: "Example Artist", songs: songs)]
        return (items, songs, albums, artists)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class InMemoryFavoritesRepository: FavoritesRepository {
    private var favorites: Set<String> = []
    private var addedDates: [String: Date] = [:]

    func loadFavorites() async throws -> Set<String> { favorites }
    func loadFavoriteAddedDates() async throws -> [String: Date] { addedDates }

    func setFavorite(_ path: String, isFavorite: Bool) async throws -> Set<String> {
        if isFavorite {
            favorites.insert(path)
            addedDates[path] = addedDates[path] ?? Date()
        } else {
            favorites.remove(path)
            addedDates.removeValue(forKey: path)
        }
        NotificationCenter.default.post(
            name: .medioFavoritesDidChange,
            object: self,
            userInfo: [
                "favorites": Array(favorites).sorted(),
                "addedDates": addedDates.mapValues(\.timeIntervalSince1970)
            ]
        )
        return favorites
    }
}

@MainActor
final class InMemoryPlaybackService: PlaybackService {
    private let store: PlaybackStore

    init(store: PlaybackStore) {
        self.store = store
    }

    func setQueue(_ items: [MediaItem], startAt index: Int) async {
        store.queue = items
        let safeIndex = min(max(index, 0), max(items.count - 1, 0))
        store.playback.queueIndex = items.isEmpty ? nil : safeIndex
        store.nowPlaying = items.isEmpty ? nil : items[safeIndex]
        store.isPlaying = false
        store.audioLevels = PlaybackAudioLevels.resting
        store.playback.positionMs = 0
        store.playback.durationMs = 180_000
    }

    func play() async {
        store.isPlaying = true
        store.playback.isPlaying = true
        store.audioLevels = [0.36, 0.72, 0.52, 0.88, 0.44, 0.64]
    }

    func pause() async {
        store.isPlaying = false
        store.playback.isPlaying = false
        store.audioLevels = PlaybackAudioLevels.resting
    }

    func seek(toMs: Int) async {
        store.playback.positionMs = max(0, toMs)
    }

    func skipNext() async {
        guard !store.queue.isEmpty else { return }
        if store.playback.repeatMode == .one {
            store.playback.positionMs = 0
            return
        }
        let next = ((store.playback.queueIndex ?? 0) + 1) % store.queue.count
        store.playback.queueIndex = next
        store.nowPlaying = store.queue[next]
        store.playback.positionMs = 0
    }

    func skipPrevious() async {
        guard !store.queue.isEmpty else { return }
        let cur = store.playback.queueIndex ?? 0
        let prev = (cur - 1 + store.queue.count) % store.queue.count
        store.playback.queueIndex = prev
        store.nowPlaying = store.queue[prev]
        store.playback.positionMs = 0
    }

    func toggleShuffle() async {
        store.playback.shuffleEnabled.toggle()
    }

    func cycleRepeatMode() async {
        switch store.playback.repeatMode {
        case .off: store.playback.repeatMode = .one
        case .one: store.playback.repeatMode = .all
        case .all: store.playback.repeatMode = .off
        }
    }
}
