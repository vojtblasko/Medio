import Foundation
@preconcurrency import Combine
import AVFoundation
import UniformTypeIdentifiers
import UIKit

enum PlaybackContext {
    case explicit(files: [FileInfo])
    case folder(path: String)
    case album(name: String)
    case artist(name: String)
}

protocol FavoritesRepository: Sendable {
    func loadFavorites() async throws -> Set<String>
    func loadFavoriteAddedDates() async throws -> [String: Date]
    func setFavorite(_ path: String, isFavorite: Bool) async throws -> Set<String>
}

extension FavoritesRepository {
    func loadFavoriteAddedDates() async throws -> [String: Date] { [:] }
}

struct VisualMetadataOverride: Codable, Hashable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var coverArtworkPath: String?
    var folderColorRgba: UInt32?

    var isEmpty: Bool {
        title == nil
            && artist == nil
            && album == nil
            && genre == nil
            && year == nil
            && coverArtworkPath == nil
            && folderColorRgba == nil
    }
}

protocol VisualMetadataOverridesRepository {
    func loadOverride(forMediaPath path: String) -> VisualMetadataOverride?
    func saveOverride(_ override: VisualMetadataOverride, forMediaPath path: String)
}

final class UserDefaultsVisualMetadataOverridesRepository: VisualMetadataOverridesRepository, @unchecked Sendable {
    static let shared = UserDefaultsVisualMetadataOverridesRepository()
    private let key = "medio_visual_metadata_overrides_v1"
    private let defaults: UserDefaults
    private let cacheLock = NSLock()
    private var cachedOverrides: [String: VisualMetadataOverride]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadOverride(forMediaPath path: String) -> VisualMetadataOverride? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let all = loadAllLocked()
        return PersistedMediaPath.lookupKeys(for: path).compactMap { all[$0] }.first
    }

    func saveOverride(_ override: VisualMetadataOverride, forMediaPath path: String) {
        cacheLock.lock()
        var all = loadAllLocked()
        let storageKey = PersistedMediaPath.encode(path)
        for legacyKey in PersistedMediaPath.lookupKeys(for: path) where legacyKey != storageKey {
            all.removeValue(forKey: legacyKey)
        }
        if override.isEmpty {
            all.removeValue(forKey: storageKey)
        } else {
            all[storageKey] = override
        }
        do {
            let data = try JSONEncoder().encode(all)
            defaults.set(data, forKey: key)
            cachedOverrides = all
        } catch {
            AppLog.persistence.error("Visual metadata overrides could not be encoded: \(error.localizedDescription, privacy: .public)")
        }
        cacheLock.unlock()
        NotificationCenter.default.post(name: .medioVisualMetadataOverridesDidChange, object: self, userInfo: ["path": path])
    }

    private func loadAllLocked() -> [String: VisualMetadataOverride] {
        if let cachedOverrides { return cachedOverrides }
        guard let data = defaults.data(forKey: key) else {
            cachedOverrides = [:]
            return [:]
        }
        do {
            let decoded = try JSONDecoder().decode([String: VisualMetadataOverride].self, from: data)
            cachedOverrides = decoded
            return decoded
        } catch {
            AppLog.persistence.error("Visual metadata overrides were corrupt and have been reset: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: key)
            cachedOverrides = [:]
            return [:]
        }
    }
}

enum VisualArtworkOverrideStore {
    static func saveArtwork(_ data: Data) throws -> String {
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "VisualArtworkOverrideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a valid image."])
        }
        let prepared = prepare(image)
        guard let output = prepared.jpegData(compressionQuality: 0.88) else {
            throw NSError(domain: "VisualArtworkOverrideStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not save image."])
        }
        let folder = try artworkFolder()
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try output.write(to: url, options: .atomic)
        return url.path
    }

    static func image(at path: String?) -> UIImage? {
        guard let path else { return nil }
        return UIImage(contentsOfFile: path)
    }

    private static func artworkFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent("Medio/Artwork Overrides", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func prepare(_ image: UIImage) -> UIImage {
        let maxSide: CGFloat = 900
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

protocol CustomSongColorsRepository {
    func loadColors(forMediaPath path: String) -> [UIColor]?
    func saveColors(_ colors: [UIColor], forMediaPath path: String)
}

final class UserDefaultsCustomSongColorsRepository: CustomSongColorsRepository, @unchecked Sendable {
    static let shared = UserDefaultsCustomSongColorsRepository()
    private let key = "medio_custom_song_colors_v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadColors(forMediaPath path: String) -> [UIColor]? {
        let all = loadAll()
        guard let tokens = PersistedMediaPath.lookupKeys(for: path).compactMap({ all[$0] }).first else { return nil }
        return tokens.map { UIColor(hexRGBA: $0) }
    }

    func saveColors(_ colors: [UIColor], forMediaPath path: String) {
        var all = loadAll()
        let storageKey = PersistedMediaPath.encode(path)
        for legacyKey in PersistedMediaPath.lookupKeys(for: path) where legacyKey != storageKey {
            all.removeValue(forKey: legacyKey)
        }
        all[storageKey] = colors.map(\.rgbaToken)
        do {
            let data = try JSONEncoder().encode(all)
            defaults.set(data, forKey: key)
        } catch {
            AppLog.persistence.error("Custom song colors could not be encoded: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: .medioCustomSongColorsDidChange, object: self, userInfo: ["path": path])
    }

    private func loadAll() -> [String: [UInt32]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: [UInt32]].self, from: data)
        } catch {
            AppLog.persistence.error("Custom song colors were corrupt and have been reset: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: key)
            return [:]
        }
    }
}

extension UIColor {
    convenience init(hexRGBA: UInt32) {
        let red = CGFloat((hexRGBA >> 24) & 0xFF) / 255.0
        let green = CGFloat((hexRGBA >> 16) & 0xFF) / 255.0
        let blue = CGFloat((hexRGBA >> 8) & 0xFF) / 255.0
        let alpha = CGFloat(hexRGBA & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    var rgbaToken: UInt32 {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (UInt32(red * 255) << 24) | (UInt32(green * 255) << 16) | (UInt32(blue * 255) << 8) | UInt32(alpha * 255)
    }
}

// MARK: - Private extensions

private extension String {
    var medioSearchNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum SearchMatch {
    static func file(_ item: FileInfo, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return LibrarySearchTextIndex.shared.fileMatches(id: item.id, query: query)
            || [item.displayName, item.author ?? "", item.album ?? ""]
                .contains { $0.lowercased().contains(query) }
    }

    static func album(_ album: ShadowAlbum, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return LibrarySearchTextIndex.shared.albumMatches(name: album.name, query: query)
            || album.name.lowercased().contains(query)
            || album.songs.contains { file($0, query: query) }
    }

    static func artist(_ artist: ShadowArtist, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return LibrarySearchTextIndex.shared.artistMatches(name: artist.name, query: query)
            || artist.name.lowercased().contains(query)
            || artist.songs.contains { file($0, query: query) }
    }
}

// MARK: - Base helpers

@MainActor
class ScreenViewModel: ObservableObject {
    @Published var errorMessage: String? = nil

    private var scheduledUpdateKeys: Set<String> = []

    func scheduleCoalescedUpdate(
        key: String = "default",
        _ update: @escaping @MainActor () -> Void
    ) {
        guard scheduledUpdateKeys.insert(key).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduledUpdateKeys.remove(key)
            update()
        }
    }
}

/// Long-lived app coordinator living in SwiftUI as a view model.
/// Subscribes to playback changes and schedules lightweight notifications.
@MainActor
final class PlaybackEventsViewModel: ScreenViewModel {
    private let playbackStore: PlaybackStore
    private let libraryStore: LibraryStore
    private let notificationsService: NotificationsService
    private let listeningHistoryRepository: ListeningHistoryRepository
    private let settingsStore: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var lastNotifiedMediaID: String? = nil
    private var activeListeningSession: ListeningSessionDraft? = nil
    private var medioReCappedEnabled: Bool = true
    private var historyWriteTask: Task<Void, Never>?

    private struct ListeningSessionDraft {
        var item: MediaItem
        var libraryItem: FileInfo?
        var startedAt: Date
        var lastUpdateAt: Date
        var lastPositionMs: Int
        var maxPositionMs: Int
        var listenedMs: Int
        var durationMs: Int?
    }

    init(
        playbackStore: PlaybackStore,
        libraryStore: LibraryStore,
        notificationsService: NotificationsService,
        listeningHistoryRepository: ListeningHistoryRepository,
        settingsStore: SettingsStore
    ) {
        self.playbackStore = playbackStore
        self.libraryStore = libraryStore
        self.notificationsService = notificationsService
        self.listeningHistoryRepository = listeningHistoryRepository
        self.settingsStore = settingsStore
        self.medioReCappedEnabled = settingsStore.medioReCappedEnabled
        super.init()

        Publishers.CombineLatest(playbackStore.$nowPlaying, playbackStore.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item, isPlaying in
                guard let self else { return }
                guard isPlaying, let item else { return }
                guard self.lastNotifiedMediaID != item.id else { return }
                self.lastNotifiedMediaID = item.id
                Task {
                    do {
                        try await self.notificationsService.scheduleLocal(
                            title: "Now playing",
                            body: [item.title, item.artist].compactMap { $0 }.joined(separator: " — "),
                            after: 1
                        )
                    } catch {
                        AppLog.persistence.error("Now Playing notification could not be scheduled: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(playbackStore.$nowPlaying, playbackStore.$playback)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item, playback in
                self?.trackListening(item: item, playback: playback)
            }
            .store(in: &cancellables)

        settingsStore.$medioReCappedEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                self.medioReCappedEnabled = isEnabled
                if !isEnabled {
                    self.discardActiveListeningSession()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if medioReCappedEnabled {
            let session = activeListeningSession
            let repository = listeningHistoryRepository
            if let session, let finalized = Self.finalizedSession(from: session, endedAt: Date()) {
                let previous = historyWriteTask
                Task {
                    if let previous { await previous.value }
                    do {
                        try await repository.appendSession(finalized)
                    } catch {
                        AppLog.persistence.error("Final listening session could not be saved: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    private func trackListening(item: MediaItem?, playback: PlaybackState) {
        let now = Date()
        guard medioReCappedEnabled else {
            discardActiveListeningSession()
            return
        }
        guard playback.isPlaying, let item else {
            finalizeActiveListeningSession(endedAt: now)
            return
        }

        if activeListeningSession?.item.id != item.id {
            finalizeActiveListeningSession(endedAt: now)
            activeListeningSession = ListeningSessionDraft(
                item: item,
                libraryItem: libraryStore.librarySongs.first(where: { $0.id == item.id }),
                startedAt: now,
                lastUpdateAt: now,
                lastPositionMs: playback.positionMs,
                maxPositionMs: playback.positionMs,
                listenedMs: 0,
                durationMs: playback.durationMs
            )
            return
        }

        guard var session = activeListeningSession else { return }
        let positionDelta = playback.positionMs - session.lastPositionMs
        let wallClockDelta = Int(max(0, now.timeIntervalSince(session.lastUpdateAt)) * 1000)
        let listenedDelta: Int
        if positionDelta >= 0, positionDelta <= 5_000 {
            listenedDelta = positionDelta
        } else {
            listenedDelta = min(wallClockDelta, 5_000)
        }
        session.listenedMs += max(0, listenedDelta)
        session.lastPositionMs = playback.positionMs
        session.maxPositionMs = max(session.maxPositionMs, playback.positionMs)
        session.lastUpdateAt = now
        session.durationMs = playback.durationMs ?? session.durationMs
        if session.libraryItem == nil {
            session.libraryItem = libraryStore.librarySongs.first(where: { $0.id == item.id })
        }
        activeListeningSession = session
    }

    private func finalizeActiveListeningSession(endedAt: Date) {
        guard let session = activeListeningSession else { return }
        activeListeningSession = nil
        guard let finalized = Self.finalizedSession(from: session, endedAt: endedAt) else { return }
        let repository = listeningHistoryRepository
        let previous = historyWriteTask
        historyWriteTask = Task {
            if let previous { await previous.value }
            do {
                try await repository.appendSession(finalized)
            } catch {
                AppLog.persistence.error("Listening session could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flushListeningHistory() async {
        if medioReCappedEnabled {
            finalizeActiveListeningSession(endedAt: Date())
        }
        await historyWriteTask?.value
    }

    private func discardActiveListeningSession() {
        activeListeningSession = nil
    }

    nonisolated private static func finalizedSession(from draft: ListeningSessionDraft, endedAt: Date) -> ListeningSession? {
        let listenedMs = max(draft.listenedMs, 0)
        let duration = draft.durationMs ?? draft.libraryItem?.durationMs
        let completed: Bool
        if let duration, duration > 0 {
            completed = draft.maxPositionMs >= max(0, duration - 5_000) || listenedMs >= Int(Double(duration) * 0.8)
        } else {
            completed = false
        }
        return ListeningSession(
            id: UUID(),
            mediaID: draft.item.id,
            title: draft.item.title,
            artist: draft.item.artist ?? draft.libraryItem?.author,
            album: draft.item.album ?? draft.libraryItem?.album,
            genre: draft.item.genre ?? draft.libraryItem?.genre,
            year: draft.item.year ?? draft.libraryItem?.year,
            startedAt: draft.startedAt,
            endedAt: endedAt,
            listenedMs: listenedMs,
            durationMs: duration,
            completed: completed
        )
    }
}

// MARK: - Tabs

struct HomePrioritySlot: Hashable, Identifiable {
    enum Content: Hashable {
        case favorites
        case folder(FileInfo, storageSlot: Int)
        case empty(storageSlot: Int)
    }

    let content: Content

    var id: String {
        switch content {
        case .favorites:
            return MedioShadowFolder.favoritesID
        case .folder(let item, let storageSlot):
            return "priority:\(storageSlot):\(item.id)"
        case .empty(let storageSlot):
            return "priority-empty:\(storageSlot)"
        }
    }

    var searchText: String {
        switch content {
        case .favorites:
            return MedioShadowFolder.favoritesName
        case .folder(let item, _):
            return [item.displayName, item.id.appRelativeDisplayPath].joined(separator: " ")
        case .empty(let storageSlot):
            return "priority folder \(storageSlot + 2) choose folder"
        }
    }
}

@MainActor
final class HomeViewModel: ScreenViewModel {
    @Published var query: String = ""
    @Published private(set) var prioritySlots: [HomePrioritySlot] = []
    @Published private(set) var filteredItems: [FileInfo] = []

    private let libraryStore: LibraryStore
    private let playbackService: PlaybackService
    private let settingsStore: SettingsStore
    private let playMediaUseCase: PlayMediaUseCase
    private var cancellables: Set<AnyCancellable> = []

    init(libraryStore: LibraryStore, playbackService: PlaybackService, settingsStore: SettingsStore, playMediaUseCase: PlayMediaUseCase = PlayMediaUseCase()) {
        self.libraryStore = libraryStore
        self.playbackService = playbackService
        self.settingsStore = settingsStore
        self.playMediaUseCase = playMediaUseCase
        super.init()
        libraryStore.$homeItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        libraryStore.$allItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        libraryStore.$favorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        $query
            .map(\.medioSearchNormalized)
            .removeDuplicates()
            .debounce(for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        Publishers.CombineLatest4(
            settingsStore.$homeSortBy,
            settingsStore.$homeSortAscending,
            settingsStore.$priorityFoldersCount,
            settingsStore.$priorityFolderPaths
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        settingsStore.$favoritesPriorityFolderEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        settingsStore.$favoritesHomeFolderEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        settingsStore.$primaryPriorityFolderPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        settingsStore.$prioritySlotArtworkPaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        settingsStore.$prioritySlotImageOnlyKeys
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        recompute()
    }

    convenience init(libraryStore: LibraryStore, playbackService: PlaybackService) {
        self.init(
            libraryStore: libraryStore,
            playbackService: playbackService,
            settingsStore: SettingsStore()
        )
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func recompute() {
        let q = query.medioSearchNormalized
        let rawPrioritySlots = makePrioritySlots()
        prioritySlots = q.isEmpty
            ? rawPrioritySlots
            : rawPrioritySlots.filter { $0.searchText.medioSearchNormalized.contains(q) }

        let pinnedFolderPaths = Set(rawPrioritySlots.compactMap { slot -> String? in
            if case .folder(let item, _) = slot.content { return item.id }
            return nil
        })
        let regularItems = homeItemsIncludingFavoritesShadow()
            .filter { !pinnedFolderPaths.contains($0.id) }
        filteredItems = sortedHomeItems(regularItems.filter { SearchMatch.file($0, query: q) })
    }

    private func scheduleRecompute() {
        scheduleCoalescedUpdate(key: "home.recompute") { [weak self] in
            self?.recompute()
        }
    }

    private func sortedHomeItems(_ items: [FileInfo]) -> [FileInfo] {
        FileSortOrdering.sorted(
            items,
            by: settingsStore.homeSortBy,
            ascending: settingsStore.homeSortAscending
        )
    }

    func play(_ item: FileInfo) async {
        guard !item.isDirectory else { return }
        await playMediaUseCase.execute(
            selected: item,
            context: .explicit(files: libraryStore.librarySongs),
            libraryStore: libraryStore,
            playbackService: playbackService
        )
    }

    private func homeItemsIncludingFavoritesShadow() -> [FileInfo] {
        var items = libraryStore.homeItems
        if settingsStore.favoritesHomeFolderEnabled,
           !(settingsStore.priorityFoldersCount > 0 && settingsStore.favoritesPriorityFolderEnabled),
           !libraryStore.favorites.isEmpty {
            items.append(MedioShadowFolder.favorites)
        }
        return items
    }

    private func makePrioritySlots() -> [HomePrioritySlot] {
        guard settingsStore.priorityFoldersCount > 0 else { return [] }
        var slots: [HomePrioritySlot]
        if settingsStore.favoritesPriorityFolderEnabled {
            slots = [HomePrioritySlot(content: .favorites)]
        } else if let path = settingsStore.priorityFolderPath(at: -1),
                  let folder = folderInfo(for: path) {
            slots = [HomePrioritySlot(content: .folder(folder, storageSlot: -1))]
        } else {
            slots = [HomePrioritySlot(content: .empty(storageSlot: -1))]
        }
        let storedSlotCount = max(0, settingsStore.priorityFoldersCount - 1)
        for storageSlot in 0..<storedSlotCount {
            if let path = settingsStore.priorityFolderPath(at: storageSlot),
               let folder = folderInfo(for: path) {
                slots.append(HomePrioritySlot(content: .folder(folder, storageSlot: storageSlot)))
            } else {
                slots.append(HomePrioritySlot(content: .empty(storageSlot: storageSlot)))
            }
        }
        return slots
    }

    private func folderInfo(for path: String) -> FileInfo? {
        guard let resolvedPath = resolvedPriorityFolderPath(for: path) else { return nil }
        if let item = libraryStore.allItems.first(where: { $0.id == resolvedPath && $0.isDirectory }) {
            return item
        }
        if let item = libraryStore.homeItems.first(where: { $0.id == resolvedPath && $0.isDirectory }) {
            return item
        }
        let name = URL(fileURLWithPath: resolvedPath).lastPathComponent
        guard !name.isEmpty else { return nil }
        return FileInfo(id: resolvedPath, isDirectory: true, displayName: name, author: nil, album: nil)
    }

    private func resolvedPriorityFolderPath(for path: String) -> String? {
        let standardizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard !standardizedPath.isEmpty else { return nil }

        if let documentsPath = AppFileRoot.documentsPath,
           standardizedPath == documentsPath {
            return singleDirectChildFolderPath(of: standardizedPath)
        }

        if let exact = knownDirectoryPath(matching: standardizedPath) {
            return shouldCollapsePriorityWrapper(path: exact)
                ? collapsedSingleChildFolderPath(from: exact)
                : exact
        }

        if let byName = uniqueKnownDirectoryPath(named: URL(fileURLWithPath: standardizedPath).lastPathComponent) {
            return shouldCollapsePriorityWrapper(path: byName)
                ? collapsedSingleChildFolderPath(from: byName)
                : byName
        }

        if let recovered = singleDirectChildFolderPath(of: standardizedPath) {
            return collapsedSingleChildFolderPath(from: recovered)
        }

        return nil
    }

    private func shouldCollapsePriorityWrapper(path: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        if let documentsPath = AppFileRoot.documentsPath, standardizedPath == documentsPath {
            return true
        }
        return URL(fileURLWithPath: standardizedPath).lastPathComponent.localizedCaseInsensitiveCompare("Data") == .orderedSame
    }

    private func knownDirectoryPath(matching path: String) -> String? {
        let candidates = libraryStore.allItems + libraryStore.homeItems
        return candidates.first { item in
            item.isDirectory && URL(fileURLWithPath: item.id, isDirectory: true).standardizedFileURL.path == path
        }?.id
    }

    private func uniqueKnownDirectoryPath(named name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = (libraryStore.allItems + libraryStore.homeItems)
            .filter { item in
                item.isDirectory
                    && item.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }
            .map(\.id)
        let unique = Array(Set(candidates))
        return unique.count == 1 ? unique[0] : nil
    }

    private func collapsedSingleChildFolderPath(from path: String) -> String {
        var current = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        var seen: Set<String> = [current]
        while let next = singleDirectChildFolderPath(of: current), seen.insert(next).inserted {
            current = next
        }
        return current
    }

    private func singleDirectChildFolderPath(of parentPath: String) -> String? {
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL.path
        let childFolders = libraryStore.allItems.filter { item in
            guard item.isDirectory else { return false }
            let childURL = URL(fileURLWithPath: item.id, isDirectory: true).standardizedFileURL
            return childURL.deletingLastPathComponent().path == parent
        }
        guard childFolders.count == 1 else { return nil }

        let directFiles = libraryStore.allItems.filter { item in
            guard !item.isDirectory else { return false }
            let fileURL = URL(fileURLWithPath: item.id, isDirectory: false).standardizedFileURL
            return fileURL.deletingLastPathComponent().path == parent
        }
        guard directFiles.isEmpty else { return nil }
        return childFolders[0].id
    }
}

@MainActor
final class LibraryViewModel: ScreenViewModel {
    @Published var query: String = ""
    @Published private(set) var filteredAlbums: [ShadowAlbum] = []
    @Published private(set) var filteredArtists: [ShadowArtist] = []
    @Published private(set) var filteredSongs: [FileInfo] = []

    private let libraryStore: LibraryStore
    private let playbackService: PlaybackService
    private let settingsStore: SettingsStore
    private let playMediaUseCase: PlayMediaUseCase
    private var recomputeTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        libraryStore: LibraryStore,
        playbackService: PlaybackService,
        settingsStore: SettingsStore? = nil,
        playMediaUseCase: PlayMediaUseCase = PlayMediaUseCase()
    ) {
        self.libraryStore = libraryStore
        self.playbackService = playbackService
        self.settingsStore = settingsStore ?? SettingsStore()
        self.playMediaUseCase = playMediaUseCase
        super.init()
        Publishers.CombineLatest3(libraryStore.$albums, libraryStore.$artists, libraryStore.$librarySongs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        $query
            .map(\.medioSearchNormalized)
            .removeDuplicates()
            .debounce(for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        Publishers.CombineLatest(self.settingsStore.$homeSortBy, self.settingsStore.$homeSortAscending)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        self.settingsStore.$showUnknownArtists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        self.settingsStore.$showUnknownAlbums
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        recompute()
    }

    deinit {
        recomputeTask?.cancel()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func recompute() {
        let q = query.medioSearchNormalized
        let albums = libraryStore.albums
        let artists = libraryStore.artists
        let songs = libraryStore.librarySongs
        let sort = settingsStore.homeSortBy
        let ascending = settingsStore.homeSortAscending
        let showUnknownArtists = settingsStore.showUnknownArtists
        let showUnknownAlbums = settingsStore.showUnknownAlbums
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let albums = Self.sortedCollections(
                    albums.filter {
                        (showUnknownAlbums || !isUnknownAlbumName($0.name)) && SearchMatch.album($0, query: q)
                    },
                    sort: sort,
                    ascending: ascending,
                    name: { $0.name },
                    songs: { $0.songs },
                    kind: { $0.releaseKind.rawValue }
                )
                let artists = Self.sortedCollections(
                    artists.filter {
                        (showUnknownArtists || !isUnknownArtistName($0.name)) && SearchMatch.artist($0, query: q)
                    },
                    sort: sort,
                    ascending: ascending,
                    name: { $0.name },
                    songs: { $0.songs },
                    kind: { _ in "Artist" }
                )
                let songs = FileSortOrdering.sorted(
                    songs.filter { !$0.isDirectory && SearchMatch.file($0, query: q) },
                    by: sort,
                    ascending: ascending
                )
                return (albums, artists, songs)
            }.value
            guard !Task.isCancelled, let self, self.query.medioSearchNormalized == q else { return }
            self.filteredAlbums = result.0
            self.filteredArtists = result.1
            self.filteredSongs = result.2
        }
    }

    private func scheduleRecompute() {
        scheduleCoalescedUpdate(key: "library.recompute") { [weak self] in
            self?.recompute()
        }
    }

    nonisolated private static func sortedCollections<T: Sendable>(
        _ values: [T],
        sort: HomeSortBy,
        ascending: Bool,
        name: @Sendable (T) -> String,
        songs: @Sendable (T) -> [FileInfo],
        kind: @Sendable (T) -> String
    ) -> [T] {
        guard sort != .added else {
            return ascending ? values : Array(values.reversed())
        }

        let ordered = values.sorted { lhs, rhs in
            let lhsName = name(lhs)
            let rhsName = name(rhs)
            let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            let nameBefore = nameComparison == .orderedAscending

            switch sort {
            case .added:
                return false
            case .name:
                return nameBefore
            case .kind:
                let comparison = kind(lhs).localizedCaseInsensitiveCompare(kind(rhs))
                return comparison == .orderedSame ? nameBefore : comparison == .orderedAscending
            case .dateModified:
                let lhsDate = songs(lhs).map(FileSortOrdering.dateModified(for:)).max() ?? .distantPast
                let rhsDate = songs(rhs).map(FileSortOrdering.dateModified(for:)).max() ?? .distantPast
                return lhsDate == rhsDate ? nameBefore : lhsDate < rhsDate
            case .releaseDate:
                let lhsDate = songs(lhs).map(FileSortOrdering.releaseDate(for:)).max() ?? .distantPast
                let rhsDate = songs(rhs).map(FileSortOrdering.releaseDate(for:)).max() ?? .distantPast
                return lhsDate == rhsDate ? nameBefore : lhsDate < rhsDate
            case .size:
                let lhsSize = songs(lhs).reduce(0) { $0 + ($1.fileSizeBytes ?? 0) }
                let rhsSize = songs(rhs).reduce(0) { $0 + ($1.fileSizeBytes ?? 0) }
                return lhsSize == rhsSize ? nameBefore : lhsSize < rhsSize
            }
        }
        return ascending ? ordered : Array(ordered.reversed())
    }

    func playSong(_ song: FileInfo) async {
        guard !song.isDirectory else { return }
        await playMediaUseCase.execute(
            selected: song,
            context: .explicit(files: libraryStore.librarySongs),
            libraryStore: libraryStore,
            playbackService: playbackService
        )
    }
}

@MainActor
final class SearchSongsViewModel: ScreenViewModel {
    @Published var query: String = ""
    @Published private(set) var filteredArtists: [ShadowArtist] = []
    @Published private(set) var filteredAlbums: [ShadowAlbum] = []
    @Published private(set) var filteredSongs: [FileInfo] = []
    @Published private(set) var lyricMatches: [String: LyricSearchMatch] = [:]

    private let libraryStore: LibraryStore
    private let playbackService: PlaybackService
    private let lyricsRepository: LyricsRepository?
    private let settingsStore: SettingsStore?
    private let playMediaUseCase: PlayMediaUseCase
    private var loadedLyricIDs: Set<String> = []
    private var lyricTextCache: [String: String] = [:]
    private var lyricLineIndex: [String: [LyricSearchLine]] = [:]
    private var searchFilterTask: Task<Void, Never>?
    private var songFilterTask: Task<Void, Never>?
    private var lyricSearchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        libraryStore: LibraryStore,
        playbackService: PlaybackService,
        lyricsRepository: LyricsRepository? = nil,
        settingsStore: SettingsStore? = nil,
        playMediaUseCase: PlayMediaUseCase = PlayMediaUseCase()
    ) {
        self.libraryStore = libraryStore
        self.playbackService = playbackService
        self.lyricsRepository = lyricsRepository
        self.settingsStore = settingsStore
        self.playMediaUseCase = playMediaUseCase
        super.init()
        Publishers.CombineLatest3(libraryStore.$albums, libraryStore.$artists, libraryStore.$librarySongs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        $query
            .map(\.medioSearchNormalized)
            .removeDuplicates()
            .debounce(for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        settingsStore?.$showUnknownArtists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        settingsStore?.$showUnknownAlbums
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        recompute()
    }

    deinit {
        searchFilterTask?.cancel()
        songFilterTask?.cancel()
        lyricSearchTask?.cancel()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func recompute() {
        let q = query.medioSearchNormalized
        let artists = libraryStore.artists
        let albums = libraryStore.albums
        let songs = libraryStore.librarySongs
        let currentLyricMatches = lyricMatches
        let showUnknownArtists = settingsStore?.showUnknownArtists ?? true
        let showUnknownAlbums = settingsStore?.showUnknownAlbums ?? true
        searchFilterTask?.cancel()
        searchFilterTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let artists = artists.filter { artist in
                    (showUnknownArtists || !isUnknownArtistName(artist.name))
                        && SearchMatch.artist(artist, query: q)
                }
                let albums = albums.filter { album in
                    (showUnknownAlbums || !isUnknownAlbumName(album.name))
                        && SearchMatch.album(album, query: q)
                }
                let songs = songs.filter { song in
                    guard !song.isDirectory else { return false }
                    return q.isEmpty
                        || SearchMatch.file(song, query: q)
                        || currentLyricMatches[song.id]?.query == q
                }
                return (artists, albums, songs)
            }.value
            guard !Task.isCancelled, let self, self.query.medioSearchNormalized == q else { return }
            self.filteredArtists = result.0
            self.filteredAlbums = result.1
            self.filteredSongs = result.2
        }
        if q.isEmpty {
            lyricSearchTask?.cancel()
            lyricMatches = [:]
            return
        }
        refreshLyricMatches(query: q)
    }

    private func scheduleRecompute() {
        scheduleCoalescedUpdate(key: "search.recompute") { [weak self] in
            self?.recompute()
        }
    }

    func playSong(_ song: FileInfo) async {
        guard !song.isDirectory else { return }
        await playMediaUseCase.execute(
            selected: song,
            context: .explicit(files: libraryStore.librarySongs),
            libraryStore: libraryStore,
            playbackService: playbackService
        )
    }

    private func recomputeFilteredSongs(query q: String) {
        let songs = libraryStore.librarySongs
        let matches = lyricMatches
        songFilterTask?.cancel()
        songFilterTask = Task { [weak self] in
            let filtered = await Task.detached(priority: .userInitiated) {
                songs.filter { song in
                    guard !song.isDirectory else { return false }
                    return SearchMatch.file(song, query: q) || matches[song.id]?.query == q
                }
            }.value
            guard !Task.isCancelled, let self, self.query.medioSearchNormalized == q else { return }
            self.filteredSongs = filtered
        }
    }

    private func refreshLyricMatches(query q: String) {
        lyricSearchTask?.cancel()
        guard let lyricsRepository else { return }
        let librarySongs = libraryStore.librarySongs
        let existingIndex = lyricLineIndex
        let loadedIDs = loadedLyricIDs

        lyricSearchTask = Task { [weak self] in
            let initial = await Task.detached(priority: .utility) {
                let songs = librarySongs.filter { !$0.isDirectory }
                return (
                    Self.makeLyricMatches(query: q, songs: songs, index: existingIndex),
                    songs.filter { !loadedIDs.contains($0.id) },
                    songs
                )
            }.value
            guard !Task.isCancelled, let self, self.query.medioSearchNormalized == q else { return }
            if initial.0 != self.lyricMatches {
                self.lyricMatches = initial.0
                self.recomputeFilteredSongs(query: q)
            }
            let missingSongs = initial.1
            let songs = initial.2
            guard !missingSongs.isEmpty else { return }

            if let batchRepository = lyricsRepository as? LyricsSearchRepository {
                let paths = missingSongs.map(\.id)
                let loadedLyrics: [String: String]
                do {
                    loadedLyrics = try await batchRepository.loadLyricsForSearch(forMediaPaths: paths)
                } catch {
                    AppLog.persistence.error("Lyrics search batch could not be loaded: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let loadedIndex = await Task.detached(priority: .utility) {
                    Self.makeLyricLineIndex(loadedLyrics)
                }.value
                guard !Task.isCancelled else { return }
                self.loadedLyricIDs.formUnion(paths)
                self.lyricTextCache.merge(loadedLyrics) { _, new in new }
                self.lyricLineIndex.merge(loadedIndex) { _, new in new }
                guard self.query.medioSearchNormalized == q else { return }
                let index = self.lyricLineIndex
                self.lyricMatches = await Task.detached(priority: .utility) {
                    Self.makeLyricMatches(query: q, songs: songs, index: index)
                }.value
                self.recomputeFilteredSongs(query: q)
                return
            }

            var loadedIDs: Set<String> = []
            var loadedLyrics: [String: String] = [:]
            var failedLoads = 0

            for song in missingSongs {
                guard !Task.isCancelled else { return }
                let lyrics: String?
                do {
                    lyrics = try await lyricsRepository.loadLyrics(forMediaPath: song.id)
                } catch {
                    failedLoads += 1
                    continue
                }
                guard !Task.isCancelled else { return }
                loadedIDs.insert(song.id)
                if let lyrics {
                    loadedLyrics[song.id] = lyrics
                }
            }

            let loadedIndex = await Task.detached(priority: .utility) {
                Self.makeLyricLineIndex(loadedLyrics)
            }.value

            guard !Task.isCancelled else { return }
            if failedLoads > 0 {
                AppLog.persistence.error("Lyrics search skipped \(failedLoads) unreadable file(s).")
            }
            self.loadedLyricIDs.formUnion(loadedIDs)
            self.lyricTextCache.merge(loadedLyrics) { _, new in new }
            self.lyricLineIndex.merge(loadedIndex) { _, new in new }
            guard self.query.medioSearchNormalized == q else { return }
            let index = self.lyricLineIndex
            self.lyricMatches = await Task.detached(priority: .utility) {
                Self.makeLyricMatches(query: q, songs: songs, index: index)
            }.value
            self.recomputeFilteredSongs(query: q)
        }
    }

    nonisolated private static func makeLyricMatches(
        query q: String,
        songs: [FileInfo],
        index: [String: [LyricSearchLine]]
    ) -> [String: LyricSearchMatch] {
        guard !q.isEmpty else { return [:] }
        var matches: [String: LyricSearchMatch] = [:]
        for song in songs {
            guard let lines = index[song.id],
                  let line = lines.first(where: { $0.normalized.contains(q) }) else { continue }
            matches[song.id] = LyricSearchMatch(query: q, line: line.display)
        }
        return matches
    }

    private struct LyricSearchLine: Sendable {
        let normalized: String
        let display: String
    }

    nonisolated private static func makeLyricLineIndex(_ lyricsByPath: [String: String]) -> [String: [LyricSearchLine]] {
        lyricsByPath.mapValues { lyrics in
            lyrics.components(separatedBy: .newlines).compactMap { rawLine in
                let cleaned = cleanLyricSearchLine(rawLine)
                guard !cleaned.isEmpty else { return nil }
                return LyricSearchLine(normalized: cleaned.medioSearchNormalized, display: cleaned)
            }
        }
    }

    nonisolated private static func firstMatchingLyricLine(in lyrics: String, query q: String) -> String? {
        for rawLine in lyrics.components(separatedBy: .newlines) {
            let cleaned = cleanLyricSearchLine(rawLine)
            guard !cleaned.isEmpty else { continue }
            if cleaned.medioSearchNormalized.contains(q) {
                return cleaned
            }
        }
        return nil
    }

    nonisolated private static func cleanLyricSearchLine(_ line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(
            of: #"\[[^\]]*\]"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^\d+\s*$"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\d{1,2}:\d{2}[:.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}[:.,]\d{1,3}"#,
            with: "",
            options: .regularExpression
        )
        return result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LyricSearchMatch: Equatable, Sendable {
    let query: String
    let line: String
}

@MainActor
final class PlaygroundViewModel: ScreenViewModel {
    @Published private(set) var favoriteCount: Int = 0
    @Published private(set) var queueCount: Int = 0
    @Published private(set) var albumCount: Int = 0
    @Published private(set) var artistCount: Int = 0

    private let libraryStore: LibraryStore
    private let playbackStore: PlaybackStore
    private var cancellables: Set<AnyCancellable> = []

    init(libraryStore: LibraryStore, playbackStore: PlaybackStore) {
        self.libraryStore = libraryStore
        self.playbackStore = playbackStore
        super.init()
        Publishers.CombineLatest4(
            libraryStore.$favorites.map(\.count),
            playbackStore.$queue.map(\.count),
            libraryStore.$albums.map(\.count),
            libraryStore.$artists.map(\.count)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] fav, queue, albums, artists in
            self?.favoriteCount = fav
            self?.queueCount = queue
            self?.albumCount = albums
            self?.artistCount = artists
        }
        .store(in: &cancellables)
        refreshCounts()
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func refreshCounts() {
        favoriteCount = libraryStore.favorites.count
        queueCount = playbackStore.queue.count
        albumCount = libraryStore.albums.count
        artistCount = libraryStore.artists.count
    }
}

@MainActor
final class FavoritesViewModel: ScreenViewModel {
    @Published var query: String = ""
    @Published private(set) var allFavorites: [FileInfo] = []
    @Published private(set) var filtered: [FileInfo] = []

    private let libraryStore: LibraryStore
    private let playbackService: PlaybackService
    private let settingsStore: SettingsStore
    private let playMediaUseCase: PlayMediaUseCase
    private var cancellables: Set<AnyCancellable> = []

    init(
        libraryStore: LibraryStore,
        playbackService: PlaybackService,
        settingsStore: SettingsStore? = nil,
        playMediaUseCase: PlayMediaUseCase = PlayMediaUseCase()
    ) {
        self.libraryStore = libraryStore
        self.playbackService = playbackService
        self.settingsStore = settingsStore ?? SettingsStore()
        self.playMediaUseCase = playMediaUseCase
        super.init()
        Publishers.CombineLatest3(
            libraryStore.$favorites,
            libraryStore.$librarySongs,
            libraryStore.$favoriteAddedDates
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.syncFromStore() }
            .store(in: &cancellables)
        $query
            .map(\.medioSearchNormalized)
            .removeDuplicates()
            .debounce(for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        Publishers.CombineLatest(self.settingsStore.$favoritesSortBy, self.settingsStore.$favoritesSortAscending)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.recompute() }
            .store(in: &cancellables)
        syncFromStore()
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func syncFromStore() {
        let favoriteSet = libraryStore.favorites
        allFavorites = libraryStore.librarySongs.filter { favoriteSet.contains($0.id) }
        recompute()
    }

    func recompute() {
        let q = query.medioSearchNormalized
        let matches = allFavorites.filter { SearchMatch.file($0, query: q) }
        let sorted = matches.sorted { lhs, rhs in
            let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            let nameBefore = nameComparison == .orderedSame ? lhs.id < rhs.id : nameComparison == .orderedAscending
            switch settingsStore.favoritesSortBy {
            case .dateAdded:
                let lhsDate = libraryStore.favoriteAddedDates[lhs.id] ?? FileSortOrdering.dateModified(for: lhs)
                let rhsDate = libraryStore.favoriteAddedDates[rhs.id] ?? FileSortOrdering.dateModified(for: rhs)
                return lhsDate == rhsDate ? nameBefore : lhsDate < rhsDate
            case .name:
                return nameBefore
            case .dateModified:
                let lhsDate = FileSortOrdering.dateModified(for: lhs)
                let rhsDate = FileSortOrdering.dateModified(for: rhs)
                return lhsDate == rhsDate ? nameBefore : lhsDate < rhsDate
            case .releaseDate:
                let lhsDate = FileSortOrdering.releaseDate(for: lhs)
                let rhsDate = FileSortOrdering.releaseDate(for: rhs)
                return lhsDate == rhsDate ? nameBefore : lhsDate < rhsDate
            case .size:
                let lhsSize = lhs.fileSizeBytes ?? 0
                let rhsSize = rhs.fileSizeBytes ?? 0
                return lhsSize == rhsSize ? nameBefore : lhsSize < rhsSize
            }
        }
        filtered = settingsStore.favoritesSortAscending ? sorted : Array(sorted.reversed())
    }

    func play(_ item: FileInfo) async {
        await playMediaUseCase.execute(
            selected: item,
            context: .explicit(files: allFavorites),
            libraryStore: libraryStore,
            playbackService: playbackService
        )
    }
}

@MainActor
final class QueueViewModel: ScreenViewModel {
    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var currentIndex: Int? = nil
    @Published private(set) var nowPlaying: MediaItem? = nil
    @Published private(set) var playback: PlaybackState = PlaybackState()

    private let playbackStore: PlaybackStore
    private let playbackService: PlaybackService
    private let lyricsRepository: LyricsRepository?
    private var cancellables: Set<AnyCancellable> = []

    init(playbackStore: PlaybackStore, playbackService: PlaybackService, lyricsRepository: LyricsRepository? = nil) {
        self.playbackStore = playbackStore
        self.playbackService = playbackService
        self.lyricsRepository = lyricsRepository
        super.init()

        Publishers.CombineLatest3(playbackStore.$queue, playbackStore.$currentIndex, playbackStore.$nowPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queue, index, item in
                self?.queue = queue
                self?.currentIndex = index
                self?.nowPlaying = item
            }
            .store(in: &cancellables)

        playbackStore.$playback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playback in
                self?.playback = playback
            }
            .store(in: &cancellables)

        syncFromStore()
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func syncFromStore() {
        queue = playbackStore.queue
        currentIndex = playbackStore.currentIndex ?? playbackStore.playback.queueIndex
        nowPlaying = playbackStore.nowPlaying
        playback = playbackStore.playback
    }

    func play(at index: Int) async {
        guard index >= 0, index < queue.count else { return }
        await playbackService.updateQueue(queue, currentIndex: index, preservingCurrentItem: false)
        await playbackService.play()
        syncFromStore()
    }

    func remove(at offsets: IndexSet) async {
        syncFromStore()
        let retained = queue.indices.filter { !offsets.contains($0) }
        guard retained.count != queue.count else { return }
        let oldIndex = currentIndex ?? 0
        let newIndex = retained.firstIndex(of: oldIndex)
            ?? retained.firstIndex(where: { $0 > oldIndex })
            ?? max(retained.count - 1, 0)
        await playbackService.updateQueue(retained.map { queue[$0] }, currentIndex: newIndex,
                                          preservingCurrentItem: retained.contains(oldIndex))
        syncFromStore()
    }

    func move(from offsets: IndexSet, to destination: Int) async {
        syncFromStore()
        let moved = queue.indices.filter { offsets.contains($0) }
        guard !moved.isEmpty else { return }
        var order = queue.indices.filter { !offsets.contains($0) }
        let insertionIndex = min(max(destination - moved.filter { $0 < destination }.count, 0), order.count)
        order.insert(contentsOf: moved, at: insertionIndex)
        let newIndex = order.firstIndex(of: currentIndex ?? 0) ?? 0
        await playbackService.updateQueue(order.map { queue[$0] }, currentIndex: newIndex,
                                          preservingCurrentItem: true)
        syncFromStore()
    }

    func clear() async {
        await playbackService.setQueue([], startAt: 0)
        syncFromStore()
    }
}

@MainActor
final class SettingsViewModel: ScreenViewModel {
    @Published var lyricsEnabled: Bool {
        didSet { autosave() }
    }
    @Published var priorityFoldersCount: Int {
        didSet { autosave() }
    }
    @Published var homeSortBy: HomeSortBy {
        didSet { autosave() }
    }
    @Published var homeSortAscending: Bool {
        didSet { autosave() }
    }
    @Published var nowPlayingBackgroundMode: NowPlayingBackgroundMode {
        didSet { autosave() }
    }
    @Published var appCanConnectToInternet: Bool {
        didSet { autosave() }
    }
    @Published var medioReCappedEnabled: Bool {
        didSet { autosave() }
    }
    @Published var showUnknownArtists: Bool {
        didSet { autosave() }
    }
    @Published var showUnknownAlbums: Bool {
        didSet { autosave() }
    }

    private let settingsStore: SettingsStore
    private var isSyncingFromStore = false

    init(settingsStore: SettingsStore, preferencesRepository: PreferencesRepository? = nil) {
        self.settingsStore = settingsStore
        self.lyricsEnabled = settingsStore.lyricsEnabled
        self.priorityFoldersCount = settingsStore.priorityFoldersCount
        self.homeSortBy = settingsStore.homeSortBy
        self.homeSortAscending = settingsStore.homeSortAscending
        self.nowPlayingBackgroundMode = settingsStore.nowPlayingBackgroundMode
        self.appCanConnectToInternet = settingsStore.appCanConnectToInternet
        self.medioReCappedEnabled = settingsStore.medioReCappedEnabled
        self.showUnknownArtists = settingsStore.showUnknownArtists
        self.showUnknownAlbums = settingsStore.showUnknownAlbums
        super.init()
    }

    private func autosave() {
        guard !isSyncingFromStore else { return }
        apply()
    }

    func apply() {
        settingsStore.lyricsEnabled = lyricsEnabled
        settingsStore.priorityFoldersCount = priorityFoldersCount
        settingsStore.homeSortBy = homeSortBy
        settingsStore.homeSortAscending = homeSortAscending
        settingsStore.nowPlayingBackgroundMode = nowPlayingBackgroundMode
        settingsStore.appCanConnectToInternet = appCanConnectToInternet
        settingsStore.medioReCappedEnabled = medioReCappedEnabled
        settingsStore.showUnknownArtists = showUnknownArtists
        settingsStore.showUnknownAlbums = showUnknownAlbums

    }

    func resetFromStore() {
        isSyncingFromStore = true
        lyricsEnabled = settingsStore.lyricsEnabled
        priorityFoldersCount = settingsStore.priorityFoldersCount
        homeSortBy = settingsStore.homeSortBy
        homeSortAscending = settingsStore.homeSortAscending
        nowPlayingBackgroundMode = settingsStore.nowPlayingBackgroundMode
        appCanConnectToInternet = settingsStore.appCanConnectToInternet
        medioReCappedEnabled = settingsStore.medioReCappedEnabled
        showUnknownArtists = settingsStore.showUnknownArtists
        showUnknownAlbums = settingsStore.showUnknownAlbums
        isSyncingFromStore = false
    }
}

@MainActor
final class FolderViewModel: ScreenViewModel {
    let path: String
    @Published var query: String = ""
    @Published private(set) var items: [FileInfo] = []
    @Published private(set) var filtered: [FileInfo] = []

    var libraryStore: LibraryStore
    var playbackService: PlaybackService
    var playMediaUseCase: PlayMediaUseCase
    var favoritesRepository: FavoritesRepository?
    private let settingsStore: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(
        path: String,
        libraryStore: LibraryStore,
        playbackService: PlaybackService,
        favoritesRepository: FavoritesRepository? = nil,
        settingsStore: SettingsStore? = nil,
        playMediaUseCase: PlayMediaUseCase = PlayMediaUseCase()
    ) {
        self.path = path
        self.libraryStore = libraryStore
        self.playbackService = playbackService
        self.favoritesRepository = favoritesRepository
        self.settingsStore = settingsStore ?? SettingsStore()
        self.playMediaUseCase = playMediaUseCase
        super.init()
        libraryStore.$allItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
        $query
            .map(\.medioSearchNormalized)
            .removeDuplicates()
            .debounce(for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        Publishers.CombineLatest(self.settingsStore.$homeSortBy, self.settingsStore.$homeSortAscending)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.recompute() }
            .store(in: &cancellables)
        load()
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func load() {
        let pathWithSlash = path.hasSuffix("/") ? path : path + "/"
        items = libraryStore.allItems.filter { item in
            guard item.id.hasPrefix(pathWithSlash) else { return false }
            let suffix = String(item.id.dropFirst(pathWithSlash.count))
            return !suffix.contains("/")
        }
        recompute()
    }

    func recompute() {
        let q = query.medioSearchNormalized
        filtered = FileSortOrdering.sorted(
            items.filter { SearchMatch.file($0, query: q) },
            by: settingsStore.homeSortBy,
            ascending: settingsStore.homeSortAscending
        )
    }

    func refresh(scanUseCase: ScanLibraryUseCase) async {
        await libraryStore.refresh(scanUseCase: scanUseCase)
        load()
    }

    func play(_ item: FileInfo) async {
        guard !item.isDirectory else { return }
        await playMediaUseCase.execute(
            selected: item,
            context: .folder(path: path),
            libraryStore: libraryStore,
            playbackService: playbackService
        )
    }

    func toggleFavorite(_ item: FileInfo) async {
        guard let repo = favoritesRepository else { return }
        await libraryStore.toggleFavorite(item.id, favoritesRepository: repo)
    }
}

@MainActor
struct AlbumMetadataSummary: Equatable {
    let songCountInAlbumFolders: Int
    let totalTracks: String
    let genre: String
    let discNumbers: String
    let lyricsIncluded: String
    let credits: String
    let subtitleArtist: String
    let subtitleYear: String

    static let empty = AlbumMetadataSummary(
        songCountInAlbumFolders: 0,
        totalTracks: "NA",
        genre: "NA",
        discNumbers: "NA",
        lyricsIncluded: "N",
        credits: "Album artist: NA • Author: NA • Writer: NA",
        subtitleArtist: "Unknown Artist",
        subtitleYear: "NA"
    )

    static func loading(songCountInAlbumFolders: Int) -> AlbumMetadataSummary {
        AlbumMetadataSummary(
            songCountInAlbumFolders: songCountInAlbumFolders,
            totalTracks: "NA",
            genre: "NA",
            discNumbers: "NA",
            lyricsIncluded: "N",
            credits: "Album artist: NA • Author: NA • Writer: NA",
            subtitleArtist: "Unknown Artist",
            subtitleYear: "NA"
        )
    }

    nonisolated static func make(songs: [FileInfo], songCountInAlbumFolders: Int) async -> AlbumMetadataSummary {
        let tags = await AlbumTagReader.readTags(for: songs)
        let overrides = songs.map { UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: $0.id) }
        let genres = zip(songs, overrides).map { song, override in override?.genre ?? song.genre ?? tags[song.id]?.genre }
        let years = overrides.map { $0?.year }.merging(songs.map { $0.year ?? tags[$0.id]?.year })
        let albumArtists = songs.map { $0.albumArtist ?? tags[$0.id]?.albumArtist }
        let authors = songs.map { tags[$0.id]?.author ?? $0.author }
        let writers = songs.map { $0.composer ?? tags[$0.id]?.writer }
        let hasLyrics = tags.values.contains { $0.hasLyrics }
        let subtitleArtist = uniqueOrNA(songs.map { tags[$0.id]?.albumArtist ?? $0.author })
        let subtitleYear = uniqueOrNA(years)

        return AlbumMetadataSummary(
            songCountInAlbumFolders: songCountInAlbumFolders,
            totalTracks: "NA",
            genre: uniqueOrNA(genres),
            discNumbers: uniqueOrNA(tags.map { $0.value.discNumber }),
            lyricsIncluded: hasLyrics ? "Y" : "N",
            credits: "Album artist: \(uniqueOrNA(albumArtists)) • Author: \(uniqueOrNA(authors)) • Writer: \(uniqueOrNA(writers))",
            subtitleArtist: subtitleArtist,
            subtitleYear: subtitleYear
        )
    }

    private nonisolated static func uniqueOrNA(_ values: [String?]) -> String {
        var seen: Set<String> = []
        var unique: [String] = []
        for raw in values {
            guard let value = raw?.nilIfEmpty else { continue }
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(value)
        }
        return unique.isEmpty ? "NA" : unique.joined(separator: ", ")
    }
}

private struct AlbumTagInfo {
    var genre: String?
    var year: String?
    var discNumber: String?
    var albumArtist: String?
    var author: String?
    var writer: String?
    var hasLyrics: Bool = false
}

private enum AlbumTagReader {
    static func readTags(for songs: [FileInfo]) async -> [String: AlbumTagInfo] {
        await Task.detached(priority: .utility) {
            var result: [String: AlbumTagInfo] = [:]
            for song in songs where !Task.isCancelled {
                result[song.id] = await readTag(for: song.id)
            }
            return result
        }.value
    }

    private static func readTag(for path: String) async -> AlbumTagInfo {
        let url = URL(fileURLWithPath: path)
        var info = AlbumTagInfo()
        do {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.metadata)
            let commonMetadata = try await asset.load(.commonMetadata)
            for item in metadata + commonMetadata {
                let rawKey = item.commonKey?.rawValue
                    ?? item.identifier?.rawValue
                    ?? item.key.map { String(describing: $0) }
                    ?? ""
                let key = rawKey.lowercased()
                let value = (try? await item.load(.stringValue))?.nilIfEmpty
                if key.contains("genre") {
                    info.genre = info.genre ?? value
                } else if key.contains("year") || key.contains("date") {
                    info.year = info.year ?? normalizedYear(value)
                } else if key.contains("disc") || key.contains("disk") {
                    info.discNumber = info.discNumber ?? value
                } else if key.contains("albumartist") || key.contains("album artist") || key.contains("album_artist") {
                    info.albumArtist = info.albumArtist ?? value
                } else if key.contains("author") {
                    info.author = info.author ?? value
                } else if key.contains("writer") || key.contains("composer") {
                    info.writer = info.writer ?? value
                } else if key.contains("lyric") || key.contains("uslt") || key.contains("syncedlyrics") {
                    info.hasLyrics = info.hasLyrics || value != nil
                }
            }
        } catch {}
        return info
    }

    private static func normalizedYear(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        if let match = value.range(of: #"^\d{4}"#, options: .regularExpression) {
            return String(value[match])
        }
        return value
    }
}

private extension Array where Element == String? {
    func merging(_ other: [String?]) -> [String?] {
        self + other
    }
}

private func isUnknownArtistName(_ name: String) -> Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare("Unknown Artist") == .orderedSame
}

private func isUnknownAlbumName(_ name: String) -> Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare("Unknown Album") == .orderedSame
}

@MainActor
private func shouldShowUnknownArtist(_ artist: ShadowArtist, settingsStore: SettingsStore) -> Bool {
    settingsStore.showUnknownArtists || !isUnknownArtistName(artist.name)
}

@MainActor
private func shouldShowUnknownAlbum(_ album: ShadowAlbum, settingsStore: SettingsStore) -> Bool {
    settingsStore.showUnknownAlbums || !isUnknownAlbumName(album.name)
}

@MainActor
final class AlbumViewModel: ScreenViewModel {
    let name: String
    let artistName: String?
    @Published var query: String = ""
    @Published private(set) var songs: [FileInfo] = []
    @Published private(set) var filtered: [FileInfo] = []
    @Published private(set) var metadata: AlbumMetadataSummary = .empty

    private let libraryStore: LibraryStore
    private let playbackService: PlaybackService
    private let playMediaUseCase: PlayMediaUseCase
    private var cancellables: Set<AnyCancellable> = []
    private var metadataTask: Task<Void, Never>?
    private var metadataGeneration: Int = 0

    init(
        name: String,
        artistName: String? = nil,
        libraryStore: LibraryStore,
        playbackService: PlaybackService,
        playMediaUseCase: PlayMediaUseCase = PlayMediaUseCase()
    ) {
        self.name = name
        self.artistName = artistName
        self.libraryStore = libraryStore
        self.playbackService = playbackService
        self.playMediaUseCase = playMediaUseCase
        super.init()
        libraryStore.$albums
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
        libraryStore.$artists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
        $query
            .map(\.medioSearchNormalized)
            .removeDuplicates()
            .debounce(for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        load()
    }

    deinit {
        metadataTask?.cancel()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func load() {
        let nextSongs = AlbumTrackOrdering.sorted(albumSongs())
        let nextSongCountInAlbumFolders = songCountInAlbumFolders(for: nextSongs)
        guard nextSongs != songs || metadata.songCountInAlbumFolders != nextSongCountInAlbumFolders else {
            recompute()
            return
        }

        songs = nextSongs
        let loadingMetadata = AlbumMetadataSummary.loading(songCountInAlbumFolders: nextSongCountInAlbumFolders)
        if metadata != loadingMetadata {
            metadata = loadingMetadata
        }
        loadMetadata()
        recompute()
    }

    func recompute() {
        let q = query.medioSearchNormalized
        filtered = songs.filter { SearchMatch.file($0, query: q) }
    }

    func play(_ song: FileInfo) async {
        await playMediaUseCase.execute(
            selected: song,
            context: artistName == nil ? .album(name: name) : .explicit(files: songs),
            libraryStore: libraryStore,
            playbackService: playbackService
        )
    }

    private func albumSongs() -> [FileInfo] {
        if let artistName {
            let artistSongs = libraryStore.artists.first(where: { $0.name == artistName })?.songs ?? []
            return artistSongs.filter { (($0.album?.nilIfEmpty) ?? "Unknown Album") == name }
        }
        return libraryStore.albums.first(where: { $0.name == name })?.songs ?? []
    }

    private func loadMetadata() {
        metadataGeneration += 1
        let generation = metadataGeneration
        let currentSongs = songs
        let folderSongCount = songCountInAlbumFolders(for: currentSongs)
        metadataTask?.cancel()
        metadataTask = Task {
            let summary = await AlbumMetadataSummary.make(
                songs: currentSongs,
                songCountInAlbumFolders: folderSongCount
            )
            guard !Task.isCancelled, generation == metadataGeneration else { return }
            metadata = summary
        }
    }

    private func songCountInAlbumFolders(for songs: [FileInfo]) -> Int {
        let folderPaths = Set(songs.map { URL(fileURLWithPath: $0.id).deletingLastPathComponent().path })
        guard !folderPaths.isEmpty else { return 0 }
        let songsInFolders = libraryStore.librarySongs.filter { song in
            folderPaths.contains(URL(fileURLWithPath: song.id).deletingLastPathComponent().path)
        }
        return max(songs.count, songsInFolders.count)
    }
}

@MainActor
final class ArtistViewModel: ScreenViewModel {
    let name: String
    @Published var query: String = ""
    @Published private(set) var songs: [FileInfo] = []
    @Published private(set) var filtered: [FileInfo] = []
    @Published private(set) var mostPlayedSongs: [FileInfo] = []
    @Published private(set) var filteredMostPlayedSongs: [FileInfo] = []
    @Published private(set) var albums: [ShadowAlbum] = []
    @Published private(set) var filteredAlbums: [ShadowAlbum] = []
    @Published private(set) var artistImage: UIImage?

    private let libraryStore: LibraryStore
    private let playbackService: PlaybackService
    private let playMediaUseCase: PlayMediaUseCase
    private let listeningHistoryRepository: ListeningHistoryRepository
    private let settingsStore: SettingsStore?
    private let artistImageLoader: ArtistProfileImageLoader
    private var cancellables: Set<AnyCancellable> = []
    private var artistImageTask: Task<Void, Never>?
    private var listeningHistoryTask: Task<Void, Never>?
    private var listenedMsBySongID: [String: Int] = [:]
    private static let mostPlayedSongLimit = 5

    init(
        name: String,
        libraryStore: LibraryStore,
        playbackService: PlaybackService,
        settingsStore: SettingsStore? = nil,
        listeningHistoryRepository: ListeningHistoryRepository = SQLiteListeningHistoryRepository(),
        artistProfileRepository: ArtistProfileRepository = UserDefaultsArtistProfileRepository.shared,
        onlineArtistImageRepository: OnlineArtistImageRepository = WikimediaPublicDomainArtistImageRepository.shared,
        playMediaUseCase: PlayMediaUseCase = PlayMediaUseCase()
    ) {
        self.name = name
        self.libraryStore = libraryStore
        self.playbackService = playbackService
        self.playMediaUseCase = playMediaUseCase
        self.listeningHistoryRepository = listeningHistoryRepository
        self.settingsStore = settingsStore
        self.artistImageLoader = ArtistProfileImageLoader(
            profileRepository: artistProfileRepository,
            onlineRepository: onlineArtistImageRepository
        )
        super.init()
        libraryStore.$artists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
        $query
            .map(\.medioSearchNormalized)
            .removeDuplicates()
            .debounce(for: DispatchQueue.SchedulerTimeType.Stride.milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        settingsStore?.$appCanConnectToInternet
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                if isEnabled {
                    self?.loadArtistImage()
                } else {
                    self?.artistImageTask?.cancel()
                }
            }
            .store(in: &cancellables)
        settingsStore?.$showUnknownAlbums
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .medioArtistProfileImagesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let changedArtist = notification.userInfo?["artist"] as? String else {
                    self.loadArtistImage()
                    return
                }
                let changedKey = notification.userInfo?["artistKey"] as? String
                    ?? UserDefaultsArtistProfileRepository.storageKey(for: changedArtist)
                if changedKey == UserDefaultsArtistProfileRepository.storageKey(for: self.name) {
                    self.loadArtistImage()
                }
            }
            .store(in: &cancellables)
        load()
        listeningHistoryTask = Task { await refreshListeningHistory() }
        loadArtistImage()
    }

    deinit {
        artistImageTask?.cancel()
        listeningHistoryTask?.cancel()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func load() {
        let nextSongs = libraryStore.artists.first(where: { $0.name == name })?.songs ?? []
        let nextAlbums = Self.groupAlbums(from: nextSongs)
            .sorted { album1, album2 in
                let year1 = album1.songs.compactMap(\.year).first ?? ""
                let year2 = album2.songs.compactMap(\.year).first ?? ""
                return year1 < year2
            }
        guard nextSongs != songs || nextAlbums != albums else {
            recompute()
            return
        }

        songs = nextSongs
        albums = nextAlbums
        recompute()
    }

    func recompute() {
        let q = query.medioSearchNormalized
        filtered = songs.filter { SearchMatch.file($0, query: q) }
        mostPlayedSongs = Self.mostPlayedSongs(
            from: songs,
            listenedMsBySongID: listenedMsBySongID
        )
        filteredMostPlayedSongs = mostPlayedSongs.filter { SearchMatch.file($0, query: q) }
        filteredAlbums = albums.filter { album in
            let shouldShowUnknown = settingsStore.map { shouldShowUnknownAlbum(album, settingsStore: $0) } ?? true
            guard shouldShowUnknown else { return false }
            guard !q.isEmpty else { return true }
            return album.name.lowercased().contains(q) || album.songs.contains { SearchMatch.file($0, query: q) }
        }
    }

    func refreshListeningHistory() async {
        let sessions: [ListeningSession]
        do {
            sessions = try await listeningHistoryRepository.loadSessions()
        } catch {
            errorMessage = "Listening history could not be loaded."
            AppLog.persistence.error("Listening history could not be loaded: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }
        listenedMsBySongID = sessions.reduce(into: [:]) { totals, session in
            guard session.listenedMs > 0 else { return }
            totals[session.mediaID, default: 0] += session.listenedMs
        }
        recompute()
    }

    func play(_ song: FileInfo) async {
        await playMediaUseCase.execute(
            selected: song,
            context: .artist(name: name),
            libraryStore: libraryStore,
            playbackService: playbackService
        )
    }

    private func loadArtistImage() {
        let canFetchOnline = settingsStore?.appCanConnectToInternet == true
        artistImageTask?.cancel()
        let artistName = name
        let loader = artistImageLoader
        artistImageTask = Task { [weak self] in
            let image = await loader.image(for: artistName, canFetchOnline: canFetchOnline)
            guard !Task.isCancelled, let self else { return }
            self.artistImage = image
        }
    }

    private static func groupAlbums(from songs: [FileInfo]) -> [ShadowAlbum] {
        let grouped = Dictionary(grouping: songs, by: { ($0.album?.nilIfEmpty) ?? "Unknown Album" })
        return grouped
            .map { name, songs in
                ShadowAlbum(
                    name: name,
                    songs: AlbumTrackOrdering.sorted(songs)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func mostPlayedSongs(
        from songs: [FileInfo],
        listenedMsBySongID: [String: Int]
    ) -> [FileInfo] {
        Array(
            songs
                .filter { (listenedMsBySongID[$0.id] ?? 0) > 0 }
                .sorted { lhs, rhs in
                    let lhsMs = listenedMsBySongID[lhs.id] ?? 0
                    let rhsMs = listenedMsBySongID[rhs.id] ?? 0
                    if lhsMs != rhsMs { return lhsMs > rhsMs }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                .prefix(mostPlayedSongLimit)
        )
    }
}

@MainActor
final class CreateFolderViewModel: ScreenViewModel {
    @Published var name: String = ""
    let parentPath: String?

    init(parentPath: String?) {
        self.parentPath = parentPath
        super.init()
    }

    func create() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Folder name cannot be empty."
            return
        }
        guard AppFilePathPolicy.isValidLeafName(trimmedName) else {
            errorMessage = AppFilePolicyError.invalidName.localizedDescription
            return
        }
        name = trimmedName
        errorMessage = nil
    }
}

@MainActor
final class VideoFullscreenViewModel: ScreenViewModel {
    let mediaID: String
    init(mediaID: String) {
        self.mediaID = mediaID
        super.init()
    }
}
