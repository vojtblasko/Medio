import Foundation

/// Queue edits preserve the active track and playback clock.
@MainActor
struct QueueUseCases {
    /// Put a list of items into the queue without forcing playback state.
    @MainActor
    struct SetQueueUseCase {
        func execute(_ queue: [MediaItem], startIndex: Int, playbackService: PlaybackService) async {
            guard !queue.isEmpty else {
                await playbackService.setQueue([], startAt: 0)
                return
            }
            let safe = min(max(startIndex, 0), queue.count - 1)
            await playbackService.setQueue(queue, startAt: safe)
        }
    }

    /// Insert items immediately after the current item ("Play next").
    @MainActor
    struct PlayNextUseCase {
        func execute(_ items: [MediaItem], playbackStore: PlaybackStore, playbackService: PlaybackService) async {
            guard !items.isEmpty else { return }

            await Self.insert(items, atEnd: false, store: playbackStore, service: playbackService)
        }

        static func insert(_ items: [MediaItem], atEnd: Bool, store: PlaybackStore, service: PlaybackService) async {
            let queue = store.queue
            guard !queue.isEmpty else {
                await service.setQueue(items, startAt: 0)
                return
            }
            let current = store.queueIndexForControls ?? 0
            let ids = Set(items.map(\.id))
            // Never remove the active occurrence when moving requested items into the upcoming queue.
            let retained = queue.indices.filter { $0 == current || !ids.contains(queue[$0].id) }
            var updated = retained.map { queue[$0] }
            let newCurrent = retained.firstIndex(of: current) ?? 0
            updated.insert(contentsOf: items, at: atEnd ? updated.count : newCurrent + 1)
            await service.updateQueue(updated, currentIndex: newCurrent, preservingCurrentItem: true)
        }
    }

    /// Append items to the end of the queue ("Add to queue").
    @MainActor
    struct AddToQueueEndUseCase {
        func execute(_ items: [MediaItem], playbackStore: PlaybackStore, playbackService: PlaybackService) async {
            guard !items.isEmpty else { return }

            await PlayNextUseCase.insert(items, atEnd: true, store: playbackStore, service: playbackService)
        }
    }

    /// Remove specific items from the queue (by id). Adjust currentIndex to stay on the same logical track when possible.
    @MainActor
    struct RemoveFromQueueUseCase {
        func execute(ids: [String], playbackStore: PlaybackStore, playbackService: PlaybackService) async {
            guard !ids.isEmpty else { return }

            let queue = playbackStore.queue
            let current = playbackStore.queueIndexForControls ?? 0
            let idsSet = Set(ids)
            let retained = queue.indices.filter { !idsSet.contains(queue[$0].id) }
            guard retained.count != queue.count else { return }
            let newIndex = retained.firstIndex(of: current)
                ?? retained.firstIndex(where: { $0 > current }) ?? max(retained.count - 1, 0)
            await playbackService.updateQueue(retained.map { queue[$0] }, currentIndex: newIndex,
                                              preservingCurrentItem: retained.contains(current))
        }
    }

    /// Clear the queue completely and stop playback.
    @MainActor
    struct ClearQueueUseCase {
        func execute(playbackService: PlaybackService) async {
            await playbackService.setQueue([], startAt: 0)
        }
    }

    /// Replace the current queue with a freshly built context queue, keeping playback if possible.
    @MainActor
    struct ReplaceWithContextQueueUseCase {
        func execute(
            selected: FileInfo,
            context: PlaybackContext,
            libraryStore: LibraryStore,
            playbackService: PlaybackService,
            shouldAutoPlay: Bool
        ) async {
            let files: [FileInfo]
            switch context {
            case .explicit(let explicitFiles):
                files = explicitFiles
            case .folder(let path):
                files = libraryStore.librarySongs.filter { BuildPlaybackQueueUseCase.isInFolder($0.id, folderPath: path) }
            case .album(let name):
                files = AlbumTrackOrdering.sorted(libraryStore.albums.first(where: { $0.name == name })?.songs ?? [])
            case .artist(let name):
                files = libraryStore.artists.first(where: { $0.name == name })?.songs ?? []
            }

            let playableFiles = files.filter(Self.isPlayableMedia)
            guard let startIndex = playableFiles.firstIndex(where: { $0.id == selected.id }) else { return }
            let queue = playableFiles.map { file in
                let override = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: file.id)
                return MediaItem(
                    id: file.id,
                    title: override?.title ?? file.displayName,
                    artist: override?.artist ?? file.author,
                    album: override?.album ?? file.album,
                    genre: override?.genre ?? file.genre,
                    year: override?.year ?? file.year,
                    isVideo: Self.isVideo(file)
                )
            }

            await playbackService.setQueue(queue, startAt: startIndex)
            if shouldAutoPlay { await playbackService.play() }
        }

        private static func isVideo(_ file: FileInfo) -> Bool {
            let ext = URL(fileURLWithPath: file.id).pathExtension.lowercased()
            return FileMetadataReader.videoExtensions.contains(ext)
        }

        private static func isPlayableMedia(_ file: FileInfo) -> Bool {
            !file.isDirectory && FileMetadataReader.isSupportedMediaFile(
                url: URL(fileURLWithPath: file.id),
                typeIdentifier: file.typeIdentifier
            )
        }
    }
}
