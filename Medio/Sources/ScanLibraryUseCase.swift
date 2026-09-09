import Foundation

struct LibraryScanProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case scanningFiles
        case buildingIndex
        case finishing
    }

    let phase: Phase
    let completedItemCount: Int
    let totalItemCount: Int?

    var fractionCompleted: Double? {
        guard let totalItemCount else { return nil }
        guard totalItemCount > 0 else { return completedItemCount > 0 ? 1 : 0 }
        return min(max(Double(completedItemCount) / Double(totalItemCount), 0), 1)
    }
}

typealias LibraryScanProgressHandler = @MainActor @Sendable (LibraryScanProgress) async -> Void

protocol MediaLibraryDataSource: Sendable {
    func loadCachedItems() -> [FileInfo]?
    func cachedSnapshotDate() -> Date?
    func scanAndCacheItems() async throws -> [FileInfo]
}

extension MediaLibraryDataSource {
    func cachedSnapshotDate() -> Date? {
        nil
    }
}

protocol MediaLibraryProgressDataSource: MediaLibraryDataSource {
    func scanAndCacheItems(progress: LibraryScanProgressHandler?) async throws -> [FileInfo]
}

struct ScanLibraryUseCase: Sendable {
    private let dataSource: MediaLibraryDataSource
    private let indexer: BuildLibraryIndexUseCase

    init(dataSource: MediaLibraryDataSource, indexer: BuildLibraryIndexUseCase = BuildLibraryIndexUseCase()) {
        self.dataSource = dataSource
        self.indexer = indexer
    }

    func execute(
        progress: LibraryScanProgressHandler? = nil
    ) async throws -> (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist]) {
        await report(
            LibraryScanProgress(phase: .preparing, completedItemCount: 0, totalItemCount: nil),
            to: progress
        )

        let scanned: [FileInfo]
        if let progressDataSource = dataSource as? MediaLibraryProgressDataSource {
            scanned = try await progressDataSource.scanAndCacheItems(progress: progress)
        } else {
            scanned = try await dataSource.scanAndCacheItems()
            await report(
                LibraryScanProgress(
                    phase: .scanningFiles,
                    completedItemCount: scanned.count,
                    totalItemCount: scanned.count
                ),
                to: progress
            )
        }

        await report(
            LibraryScanProgress(
                phase: .buildingIndex,
                completedItemCount: scanned.count,
                totalItemCount: scanned.count
            ),
            to: progress
        )
        let indexed = await Task.detached(priority: .utility) {
            indexer.execute(scanned)
        }.value
        await report(
            LibraryScanProgress(
                phase: .finishing,
                completedItemCount: scanned.count,
                totalItemCount: scanned.count
            ),
            to: progress
        )
        return indexed
    }

    private func report(_ value: LibraryScanProgress, to progress: LibraryScanProgressHandler?) async {
        guard let progress else { return }
        await progress(value)
    }
}
