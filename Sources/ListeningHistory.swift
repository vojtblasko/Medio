import Foundation

struct ListeningSession: Codable, Hashable, Identifiable {
    let id: UUID
    let mediaID: String
    let title: String
    let artist: String?
    let album: String?
    let genre: String?
    let year: String?
    let startedAt: Date
    let endedAt: Date
    let listenedMs: Int
    let durationMs: Int?
    let completed: Bool
}

protocol ListeningHistoryRepository: Sendable {
    func loadSessions() async throws -> [ListeningSession]
    func appendSession(_ session: ListeningSession) async throws
    func clearSessions() async throws
}

struct MedioReCappedReportExporter {
    private struct SongSummary {
        let id: String
        var title: String
        var artist: String
        var album: String
        var genre: String
        var year: String
        var path: String
        var plays: Int = 0
        var completedPlays: Int = 0
        var listenedMs: Int = 0
    }

    private struct CategorySummary {
        let name: String
        var plays: Int = 0
        var completedPlays: Int = 0
        var listenedMs: Int = 0
    }

    private let historyRepository: ListeningHistoryRepository
    private let fileManager: FileManager
    private let outputRoot: URL?

    init(
        historyRepository: ListeningHistoryRepository,
        fileManager: FileManager = .default,
        outputRoot: URL? = nil
    ) {
        self.historyRepository = historyRepository
        self.fileManager = fileManager
        self.outputRoot = outputRoot
    }

    @MainActor
    func export(libraryStore: LibraryStore, generatedAt: Date = Date()) async throws -> URL {
        let sessions = try await historyRepository.loadSessions()
        let root = try reportsRootURL()
        let reportDirectory = root.appendingPathComponent("Medio ReCapped \(Self.fileSafeDate(generatedAt))", isDirectory: true)
        try fileManager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

        let libraryByID = Dictionary(uniqueKeysWithValues: libraryStore.librarySongs.map { ($0.id, $0) })
        let songSummaries = makeSongSummaries(sessions: sessions, libraryByID: libraryByID)
        let artistSummaries = makeCategorySummaries(songs: songSummaries) { summary in
            let names = BuildLibraryIndexUseCase.splitArtistNames(summary.artist)
            return names.isEmpty ? ["Unknown Artist"] : names
        }
        let albumSummaries = makeCategorySummaries(songs: songSummaries) { [$0.album] }
        let genreSummaries = makeCategorySummaries(songs: songSummaries) { [$0.genre] }

        try write(summaryReport(
            generatedAt: generatedAt,
            sessions: sessions,
            songs: songSummaries,
            artists: artistSummaries,
            albums: albumSummaries,
            genres: genreSummaries,
            libraryStore: libraryStore
        ), named: "summary.txt", in: reportDirectory)
        try write(rankedSongsReport(title: "Top Songs", songs: songSummaries), named: "top-songs.txt", in: reportDirectory)
        try write(rankedCategoriesReport(title: "Top Artists", categories: artistSummaries), named: "top-artists.txt", in: reportDirectory)
        try write(rankedCategoriesReport(title: "Top Albums", categories: albumSummaries), named: "top-albums.txt", in: reportDirectory)
        try write(rankedCategoriesReport(title: "Top Genres", categories: genreSummaries), named: "top-genres.txt", in: reportDirectory)
        try write(librarySnapshotReport(libraryStore: libraryStore), named: "library-snapshot.txt", in: reportDirectory)
        try write(rawLogReport(sessions: sessions, libraryByID: libraryByID), named: "raw-listening-log.txt", in: reportDirectory)

        return reportDirectory
    }

    private func reportsRootURL() throws -> URL {
        if let outputRoot { return outputRoot }
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "MedioReCappedReportExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Missing Documents directory.")])
        }
        let currentRoot = documents.appendingPathComponent("Medio ReCapped", isDirectory: true)
        migratePreviousReportDirectory(to: currentRoot, in: documents)
        return currentRoot
    }

    private func migratePreviousReportDirectory(to currentRoot: URL, in documents: URL) {
        let previousBrand = ["Medio", "Wrap" + "ped"].joined(separator: " ")
        let previousRoot = documents.appendingPathComponent(previousBrand, isDirectory: true)
        if !fileManager.fileExists(atPath: currentRoot.path), fileManager.fileExists(atPath: previousRoot.path) {
            do {
                try fileManager.moveItem(at: previousRoot, to: currentRoot)
            } catch {
                AppLog.persistence.error("ReCapped directory migration failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: currentRoot, includingPropertiesForKeys: nil)
        } catch {
            guard fileManager.fileExists(atPath: currentRoot.path) else { return }
            AppLog.persistence.error("ReCapped directory migration could not enumerate files: \(error.localizedDescription, privacy: .public)")
            return
        }
        let previousPrefix = "Wrap" + "ped "
        for child in children where child.lastPathComponent.hasPrefix(previousPrefix) {
            let suffix = child.lastPathComponent.dropFirst(previousPrefix.count)
            let renamed = currentRoot.appendingPathComponent("Medio ReCapped \(suffix)", isDirectory: true)
            guard !fileManager.fileExists(atPath: renamed.path) else { continue }
            do {
                try fileManager.moveItem(at: child, to: renamed)
            } catch {
                AppLog.persistence.error("ReCapped report rename failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func write(_ text: String, named filename: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(filename, isDirectory: false), atomically: true, encoding: .utf8)
    }

    private func makeSongSummaries(
        sessions: [ListeningSession],
        libraryByID: [String: FileInfo]
    ) -> [SongSummary] {
        var summaries: [String: SongSummary] = [:]
        for session in sessions where session.listenedMs > 0 {
            let libraryItem = libraryByID[session.mediaID]
            var summary = summaries[session.mediaID] ?? SongSummary(
                id: session.mediaID,
                title: firstNonEmpty(session.title, libraryItem?.displayName, fallback: URL(fileURLWithPath: session.mediaID).deletingPathExtension().lastPathComponent),
                artist: firstNonEmpty(session.artist, libraryItem?.author, fallback: "Unknown Artist"),
                album: firstNonEmpty(session.album, libraryItem?.album, fallback: "Unknown Album"),
                genre: firstNonEmpty(session.genre, libraryItem?.genre, fallback: "Unknown Genre"),
                year: firstNonEmpty(session.year, libraryItem?.year, fallback: "Unknown Year"),
                path: session.mediaID
            )
            summary.plays += 1
            summary.completedPlays += session.completed ? 1 : 0
            summary.listenedMs += session.listenedMs
            summaries[session.mediaID] = summary
        }
        return summaries.values.sorted(by: summarySort)
    }

    private func makeCategorySummaries(
        songs: [SongSummary],
        namesForSong: (SongSummary) -> [String]
    ) -> [CategorySummary] {
        var summaries: [String: CategorySummary] = [:]
        for song in songs {
            let names = namesForSong(song)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for name in names.isEmpty ? ["Unknown"] : names {
                var summary = summaries[name] ?? CategorySummary(name: name)
                summary.plays += song.plays
                summary.completedPlays += song.completedPlays
                summary.listenedMs += song.listenedMs
                summaries[name] = summary
            }
        }
        return summaries.values.sorted {
            if $0.listenedMs != $1.listenedMs { return $0.listenedMs > $1.listenedMs }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @MainActor
    private func summaryReport(
        generatedAt: Date,
        sessions: [ListeningSession],
        songs: [SongSummary],
        artists: [CategorySummary],
        albums: [CategorySummary],
        genres: [CategorySummary],
        libraryStore: LibraryStore
    ) -> String {
        let totalMs = sessions.reduce(0) { $0 + max(0, $1.listenedMs) }
        let completed = sessions.filter(\.completed).count
        let firstDate = sessions.map(\.startedAt).min()
        let lastDate = sessions.map(\.endedAt).max()
        var lines: [String] = [
            "Medio ReCapped",
            "Generated: \(Self.displayDateTime(generatedAt))",
            "",
            "Listening Summary",
            "Total listening time: \(Self.durationText(totalMs))",
            "Recorded plays: \(sessions.count)",
            "Completed plays: \(completed)",
            "Unique songs played: \(songs.count)",
            "First recorded play: \(firstDate.map(Self.displayDateTime) ?? "No listening history yet")",
            "Last recorded play: \(lastDate.map(Self.displayDateTime) ?? "No listening history yet")",
            "",
            "Top Picks",
            "Top song: \(songs.first.map { "\($0.title) - \($0.artist) (\(Self.durationText($0.listenedMs)))" } ?? "No listening history yet")",
            "Top artist: \(artists.first.map { "\($0.name) (\(Self.durationText($0.listenedMs)))" } ?? "No listening history yet")",
            "Top album: \(albums.first.map { "\($0.name) (\(Self.durationText($0.listenedMs)))" } ?? "No listening history yet")",
            "Top genre: \(genres.first.map { "\($0.name) (\(Self.durationText($0.listenedMs)))" } ?? "No listening history yet")",
            "",
            "Library Snapshot",
            "Songs in library: \(libraryStore.librarySongs.count)",
            "Albums in library: \(libraryStore.albums.count)",
            "Artists in library: \(libraryStore.artists.count)",
            "Favorite songs: \(libraryStore.favorites.count)"
        ]
        if sessions.isEmpty {
            lines += [
                "",
                "Note",
                "Listening history starts after this version records playback. Export again after listening for a while to fill the ranked reports."
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func rankedSongsReport(title: String, songs: [SongSummary]) -> String {
        var lines = [title, ""]
        if songs.isEmpty {
            lines.append("No listening history yet.")
        } else {
            for (index, song) in songs.enumerated() {
                lines += [
                    "\(index + 1). \(song.title)",
                    "Artist: \(song.artist)",
                    "Album: \(song.album)",
                    "Genre: \(song.genre)",
                    "Year: \(song.year)",
                    "Plays: \(song.plays)",
                    "Completed plays: \(song.completedPlays)",
                    "Listening time: \(Self.durationText(song.listenedMs))",
                    "Path: \(song.path.appRelativeDisplayPath)",
                    ""
                ]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func rankedCategoriesReport(title: String, categories: [CategorySummary]) -> String {
        var lines = [title, ""]
        if categories.isEmpty {
            lines.append("No listening history yet.")
        } else {
            for (index, category) in categories.enumerated() {
                lines += [
                    "\(index + 1). \(category.name)",
                    "Listening time: \(Self.durationText(category.listenedMs))",
                    "Plays: \(category.plays)",
                    "Completed plays: \(category.completedPlays)",
                    ""
                ]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private func librarySnapshotReport(libraryStore: LibraryStore) -> String {
        var lines: [String] = [
            "Library Snapshot",
            "",
            "Songs: \(libraryStore.librarySongs.count)",
            "Albums: \(libraryStore.albums.count)",
            "Artists: \(libraryStore.artists.count)",
            "Favorites: \(libraryStore.favorites.count)",
            "",
            "Songs"
        ]
        for song in libraryStore.librarySongs.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
            lines += [
                "",
                "Title: \(song.displayName)",
                "Artist: \(song.author ?? "Unknown Artist")",
                "Album: \(song.album ?? "Unknown Album")",
                "Genre: \(song.genre ?? "Unknown Genre")",
                "Year: \(song.year ?? "Unknown Year")",
                "Duration: \(song.durationMs.map(Self.durationText) ?? "Unknown")",
                "Favorite: \(libraryStore.favorites.contains(song.id) ? "Yes" : "No")",
                "Path: \(song.id.appRelativeDisplayPath)"
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func rawLogReport(sessions: [ListeningSession], libraryByID: [String: FileInfo]) -> String {
        var lines: [String] = ["Raw Listening Log", ""]
        if sessions.isEmpty {
            lines.append("No listening history yet.")
        } else {
            for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
                let libraryItem = libraryByID[session.mediaID]
                lines += [
                    "Session: \(session.id.uuidString)",
                    "Started: \(Self.displayDateTime(session.startedAt))",
                    "Ended: \(Self.displayDateTime(session.endedAt))",
                    "Title: \(firstNonEmpty(session.title, libraryItem?.displayName, fallback: URL(fileURLWithPath: session.mediaID).deletingPathExtension().lastPathComponent))",
                    "Artist: \(firstNonEmpty(session.artist, libraryItem?.author, fallback: "Unknown Artist"))",
                    "Album: \(firstNonEmpty(session.album, libraryItem?.album, fallback: "Unknown Album"))",
                    "Genre: \(firstNonEmpty(session.genre, libraryItem?.genre, fallback: "Unknown Genre"))",
                    "Year: \(firstNonEmpty(session.year, libraryItem?.year, fallback: "Unknown Year"))",
                    "Listening time: \(Self.durationText(session.listenedMs))",
                    "Duration: \(session.durationMs.map(Self.durationText) ?? "Unknown")",
                    "Completed: \(session.completed ? "Yes" : "No")",
                    "Path: \(session.mediaID.appRelativeDisplayPath)",
                    ""
                ]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func firstNonEmpty(_ values: String?..., fallback: String) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }

    private func summarySort(_ lhs: SongSummary, _ rhs: SongSummary) -> Bool {
        if lhs.listenedMs != rhs.listenedMs { return lhs.listenedMs > rhs.listenedMs }
        if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    static func durationText(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private static func displayDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private static func fileSafeDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }
}

