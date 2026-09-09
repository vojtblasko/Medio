import Foundation

/// Queue mutation helpers. Since `PlaybackService` currently only supports `setQueue`,
/// these use-cases rebuild a new queue and call `setQueue` to apply it.
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

            // Start from authoritative visible queue from the store
            var curQueue = playbackStore.queue
            let curIndex = playbackStore.currentIndex ?? playbackStore.playback.queueIndex ?? 0

            // If empty, set new queue deterministically from items
            if curQueue.isEmpty {
                await playbackService.setQueue(items, startAt: 0)
                return
            }

            let safeCur = min(max(curIndex, 0), max(curQueue.count - 1, 0))

            // To prevent duplicates, remove any occurrences of items first
            let idsToInsert = Set(items.map { $0.id })
            curQueue.removeAll(where: { idsToInsert.contains($0.id) })

            // Insert items immediately after current item
            let insertAt = min(safeCur + 1, curQueue.count)
            curQueue.insert(contentsOf: items, at: insertAt)

            // New start index remains pointing to current item
            await playbackService.setQueue(curQueue, startAt: safeCur)
        }
    }

    /// Append items to the end of the queue ("Add to queue").
    @MainActor
    struct AddToQueueEndUseCase {
        func execute(_ items: [MediaItem], playbackStore: PlaybackStore, playbackService: PlaybackService) async {
            guard !items.isEmpty else { return }

            var curQueue = playbackStore.queue

            // If empty, deterministic set
            if curQueue.isEmpty {
                await playbackService.setQueue(items, startAt: 0)
                return
            }

            // Prevent duplicates by removing existing occurrences first
            let idsToAdd = Set(items.map { $0.id })
            curQueue.removeAll(where: { idsToAdd.contains($0.id) })

            let safeCur = playbackStore.currentIndex ?? playbackStore.playback.queueIndex ?? 0
            let newQueue = curQueue + items
            await playbackService.setQueue(newQueue, startAt: min(max(safeCur, 0), max(newQueue.count - 1, 0)))
        }
    }

    /// Remove specific items from the queue (by id). Adjust currentIndex to stay on the same logical track when possible.
    @MainActor
    struct RemoveFromQueueUseCase {
        func execute(ids: [String], playbackStore: PlaybackStore, playbackService: PlaybackService) async {
            guard !ids.isEmpty else { return }

            var curQueue = playbackStore.queue
            let curIndex = playbackStore.currentIndex ?? playbackStore.playback.queueIndex ?? 0

            // If queue empty or ids not present, noop
            let idsSet = Set(ids)
            guard curQueue.contains(where: { idsSet.contains($0.id) }) else { return }

            // Remember the currently playing item id to try to preserve it
            let currentId = (curIndex >= 0 && curIndex < curQueue.count) ? curQueue[curIndex].id : nil

            // Remove items
            curQueue.removeAll(where: { idsSet.contains($0.id) })

            // Deduplicate just in case
            var seen = Set<String>()
            curQueue.removeAll(where: { !seen.insert($0.id).inserted })

            // Determine new current index: prefer same item id if still present, otherwise clamp
            var newIndex: Int? = nil
            if let cid = currentId, let idx = curQueue.firstIndex(where: { $0.id == cid }) {
                newIndex = idx
            } else if !curQueue.isEmpty {
                newIndex = min(max(curIndex, 0), curQueue.count - 1)
            } else {
                newIndex = nil
            }

            await playbackService.setQueue(curQueue, startAt: newIndex ?? 0)
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
                files = libraryStore.librarySongs.filter { $0.id.hasPrefix(path) }
            case .album(let name):
                files = libraryStore.albums.first(where: { $0.name == name })?.songs ?? []
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
