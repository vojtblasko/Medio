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

}
