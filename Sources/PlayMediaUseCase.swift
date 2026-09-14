import Foundation

enum PlaybackQueueContext: Equatable {
    case album(name: String)
    case artist(name: String)
    case folder(path: String)
    case explicit(files: [FileInfo])
}

struct BuildPlaybackQueueUseCase {
    @MainActor
    func execute(selected: FileInfo, context: PlaybackQueueContext, libraryStore: LibraryStore) -> (queue: [MediaItem], startIndex: Int) {
        guard Self.isPlayableMedia(selected) else { return ([], 0) }

        let contextFiles: [FileInfo] = switch context {
        case .album(let name):
            AlbumTrackOrdering.sorted(libraryStore.albums.first(where: { $0.name == name })?.songs ?? [])
        case .artist(let name):
            libraryStore.artists.first(where: { $0.name == name })?.songs ?? []
        case .folder(let path):
            libraryStore.allItems.filter { Self.isInFolder($0.id, folderPath: path) && !$0.isDirectory }
        case .explicit(let files):
            files.filter { !$0.isDirectory }
        }
        let playableFiles = contextFiles.filter(Self.isPlayableMedia)
        // A stale context must never start an unrelated song when the tapped item is missing.
        let files = playableFiles.contains(where: { $0.id == selected.id }) ? playableFiles : [selected]

        let queue: [MediaItem] = files.map {
            MediaItem(
                id: $0.id,
                title: $0.displayName,
                artist: $0.author,
                album: $0.album,
                genre: $0.genre,
                year: $0.year,
                isVideo: Self.isVideo($0)
            )
        }

        let startIndex = queue.firstIndex(where: { $0.id == selected.id }) ?? 0
        return (queue, min(max(startIndex, 0), max(queue.count - 1, 0)))
    }

    static func isInFolder(_ itemPath: String, folderPath: String) -> Bool {
        let folder = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        let item = URL(fileURLWithPath: itemPath).standardizedFileURL.path
        return item != folder && item.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    private static func isPlayableMedia(_ file: FileInfo) -> Bool {
        !file.isDirectory && FileMetadataReader.isSupportedMediaFile(
            url: URL(fileURLWithPath: file.id),
            typeIdentifier: file.typeIdentifier
        )
    }

    private static func isVideo(_ file: FileInfo) -> Bool {
        FileMetadataReader.videoExtensions.contains(URL(fileURLWithPath: file.id).pathExtension.lowercased())
    }
}

struct PlayMediaUseCase {
    private let buildQueue: BuildPlaybackQueueUseCase

    init(buildQueue: BuildPlaybackQueueUseCase = BuildPlaybackQueueUseCase()) {
        self.buildQueue = buildQueue
    }

    @MainActor
    func execute(
        selected: FileInfo,
        context: PlaybackQueueContext,
        libraryStore: LibraryStore,
        playbackService: PlaybackService
    ) async {
        let built = buildQueue.execute(selected: selected, context: context, libraryStore: libraryStore)
        guard !built.queue.isEmpty else { return }
        await playbackService.setQueue(built.queue, startAt: built.startIndex)
        await playbackService.play()
    }
}
