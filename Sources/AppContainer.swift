import SwiftUI

protocol LibraryRepository: Sendable {}

/// Dependency container for the SwiftUI app.
@MainActor
final class AppContainer: ObservableObject {
    let libraryStore: LibraryStore
    let playbackStore: PlaybackStore
    let settingsStore: SettingsStore

    let mediaLibraryRepository: MediaLibraryRepository
    let libraryRepository: LibraryRepository
    let preferencesRepository: PreferencesRepository
    let favoritesRepository: FavoritesRepository
    let listeningHistoryRepository: ListeningHistoryRepository
    let lyricsRepository: LyricsRepository
    let lyricsFileAssociationRepository: LyricsFileAssociationRepository
    let visualMetadataOverridesRepository: VisualMetadataOverridesRepository
    let customSongColorsRepository: CustomSongColorsRepository
    let audioSharing: LocalAudioSharing
    let playbackService: PlaybackService

    let systemUIPresenter: SystemUIPresenter
    let photoPickingService: PhotoPickingService
    let documentPickingService: DocumentPickingService
    let nowPlayingService: NowPlayingService
    let remoteCommandsService: RemoteCommandsService
    let notificationsService: NotificationsService
    let startupCoordinator: AppStartupCoordinator
    init() {
        let preferencesRepository = UserDefaultsPreferencesRepository()
        self.preferencesRepository = preferencesRepository
        settingsStore = SettingsStore(preferencesRepository: preferencesRepository)
        libraryStore = LibraryStore()
        playbackStore = PlaybackStore()
        systemUIPresenter = SystemUIPresenter()

        favoritesRepository = AppRuntime.isUITesting
            ? InMemoryFavoritesRepository()
            : UserDefaultsFavoritesRepository()
        listeningHistoryRepository = SQLiteListeningHistoryRepository()
        lyricsFileAssociationRepository = UserDefaultsLyricsFileAssociationRepository()
        lyricsRepository = FileLyricsRepository(associationRepository: lyricsFileAssociationRepository)
        visualMetadataOverridesRepository = UserDefaultsVisualMetadataOverridesRepository.shared
        customSongColorsRepository = UserDefaultsCustomSongColorsRepository.shared
        playbackService = AppRuntime.isUITesting
            ? InMemoryPlaybackService(store: playbackStore)
            : AudioPlaybackService()
        playbackStore.connect(playbackService: playbackService)
        audioSharing = LocalAudioSharing(playbackStore: playbackStore)

        let repository: MediaLibraryRepository = AppRuntime.isUITesting
            ? UITestMediaLibraryRepository()
            : DefaultMediaLibraryRepository()
        mediaLibraryRepository = repository
        libraryRepository = repository

        photoPickingService = MedioPhotoPickingService(presenter: systemUIPresenter)
        documentPickingService = MedioDocumentPickingService(presenter: systemUIPresenter)
        nowPlayingService = MedioNowPlayingService()
        remoteCommandsService = MedioRemoteCommandsService()
        notificationsService = MedioNotificationsService()
        startupCoordinator = AppStartupCoordinator()
    }

    struct MaintenanceResult {
        let organizedLyrics: Int
        let retriedArtwork: Int
    }

    private func checkLibraryRefresh() throws {
        if let message = libraryStore.lastStorageScanError {
            throw NSError(domain: "LibraryMaintenance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private var maintenanceTask: Task<MaintenanceResult, Error>?

    /// Shared by pull-to-refresh and Settings. Coalesces overlapping requests.
    func refreshLivedInLibrary(
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> MaintenanceResult {
        if let maintenanceTask { return try await maintenanceTask.value }
        let task = Task { @MainActor in
            let scan = ScanLibraryUseCase(dataSource: mediaLibraryRepository)
            progress(String(localized: "Refreshing library snapshot..."))
            ArtworkCache.shared.clear()
            await libraryStore.refresh(scanUseCase: scan)
            try checkLibraryRefresh()
            progress(String(localized: "Organizing loose lyrics files..."))
            let service = LyricsOrganizationService(associationRepository: lyricsFileAssociationRepository)
            let organized = try await service.organize { processed, total in
                progress(total == 0 ? String(localized: "No loose lyrics files found.")
                    : String(localized: "Organizing loose lyrics files \(processed)/\(total)..."))
            }
            if organized > 0 {
                progress(String(localized: "Refreshing snapshot after lyrics organization..."))
                await libraryStore.refresh(scanUseCase: scan)
                try checkLibraryRefresh()
            }
            ArtworkCache.shared.clear()
            let songIDs = libraryStore.librarySongs.map(\.id)
            ArtworkCache.shared.retry(songIDs)
            return MaintenanceResult(organizedLyrics: organized, retriedArtwork: songIDs.count)
        }
        maintenanceTask = task
        defer { maintenanceTask = nil }
        return try await task.value
    }

}
