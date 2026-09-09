import Foundation

/// Builds derived library views (songs / albums / artists / folders) from a flat list of `FileInfo`.
///
/// Input can be:
/// - a full filesystem listing (files + folders), or
/// - only files
///
/// The output `items` will always include all required intermediate folders for navigation.
struct BuildLibraryIndexUseCase: Sendable {
    nonisolated(unsafe) private static var cachedFingerprint: Int?
    nonisolated(unsafe) private static var cachedResult: (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist])?
    private static let cacheLock = NSLock()

    static func splitArtistNames(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lower = trimmed.lowercased()
        let singleArtistExceptions: Set<String> = [
            "black country, new road",
            "earth, wind & fire",
            "peter, paul and mary",
            "crosby, stills, nash & young",
            "crosby, stills & nash",
            "emerson, lake & palmer",
            "blood, sweat & tears",
            "tyler, the creator"
        ]
        if singleArtistExceptions.contains(lower) {
            return [trimmed]
        }

        // Preserve "Last, The ..." style names when no other separators exist.
        if lower.contains(","),
           !lower.contains("feat"),
           !lower.contains("ft"),
           !lower.contains("featuring"),
           !lower.contains("&"),
           !lower.contains("/"),
           !lower.contains(";"),
           !lower.contains(" x ") {
            let parts = trimmed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2, parts[1].lowercased().hasPrefix("the ") {
                return [trimmed]
            }
        }

        var normalized = trimmed
        let separators = [
            " feat. ",
            " feat ",
            " featuring ",
            " ft. ",
            " ft ",
            " & ",
            " and ",
            " x ",
            ";",
            "|",
            "/"
        ]
        for separator in separators {
            normalized = normalized.replacingOccurrences(of: separator, with: ",", options: [.caseInsensitive])
        }

        let parts = normalized
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.isEmpty ? [trimmed] : parts
    }

    func execute(
        _ files: [FileInfo],
        useCache: Bool = true
    ) -> (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist]) {
        let interval = AppPerformance.signposter.beginInterval("LibraryIndex")
        defer { AppPerformance.signposter.endInterval("LibraryIndex", interval) }
        let fingerprint = fingerprint(for: files)

        if useCache {
            Self.cacheLock.lock()
            if let cachedFingerprint = Self.cachedFingerprint, cachedFingerprint == fingerprint, let cachedResult = Self.cachedResult {
                Self.cacheLock.unlock()
                return cachedResult
            }
            Self.cacheLock.unlock()
        }

        let merged = mergeDuplicates(files)
        let withFolders = ensureFolderChain(for: merged)

        let itemsSorted = withFolders.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }

        let songs = itemsSorted.filter { item in
            !item.isDirectory && FileMetadataReader.isSupportedMediaFile(
                url: URL(fileURLWithPath: item.id),
                typeIdentifier: item.typeIdentifier
            )
        }
        let displaySongs = songs.map(applyingVisualOverride)

        let groupedAlbums = Dictionary(grouping: displaySongs, by: { ($0.album?.nilIfEmpty) ?? "Unknown Album" })
        
        let groupedArtists = artistGroups(for: displaySongs)

        let albums: [ShadowAlbum] = groupedAlbums
            .map { (name, songs) in
                ShadowAlbum(
                    name: name,
                    songs: AlbumTrackOrdering.sorted(songs)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let artists: [ShadowArtist] = groupedArtists
            .map { (name, artistSongs) in
                ShadowArtist(
                    name: name,
                    songs: artistSongs.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        LibrarySearchTextIndex.shared.rebuild(
            items: itemsSorted,
            songs: displaySongs,
            albums: albums,
            artists: artists
        )
        let result = (itemsSorted, displaySongs, albums, artists)
        if useCache {
            Self.cacheLock.lock()
            Self.cachedFingerprint = fingerprint
            Self.cachedResult = result
            Self.cacheLock.unlock()
        }
        return result
    }
}

private extension BuildLibraryIndexUseCase {
    func artistGroups(for songs: [FileInfo]) -> [String: [FileInfo]] {
        var songIDsByArtist: [String: Set<String>] = [:]
        var firstCombinedNameByKey: [String: String] = [:]

        for song in songs {
            let artistString = song.author?.nilIfEmpty ?? "Unknown Artist"
            let names = Self.splitArtistNames(artistString)
            let artists = names.isEmpty ? ["Unknown Artist"] : names
            for artist in artists {
                songIDsByArtist[artist, default: []].insert(song.id)
            }
            if artists.count > 1 {
                firstCombinedNameByKey[artistGroupKey(artists)] = artistString
            }
        }

        var grouped: [String: [String: FileInfo]] = [:]
        for song in songs {
            let artistString = song.author?.nilIfEmpty ?? "Unknown Artist"
            let names = Self.splitArtistNames(artistString)
            let artists = names.isEmpty ? ["Unknown Artist"] : names

            let displayArtists: [String]
            if artists.count > 1, artistsShareExactlyTheSameSongs(artists, songIDsByArtist: songIDsByArtist) {
                let key = artistGroupKey(artists)
                displayArtists = [firstCombinedNameByKey[key] ?? artistString]
            } else {
                displayArtists = artists
            }

            for artist in displayArtists {
                grouped[artist, default: [:]][song.id] = song
            }
        }

        return grouped.mapValues { Array($0.values) }
    }

    func artistsShareExactlyTheSameSongs(_ artists: [String], songIDsByArtist: [String: Set<String>]) -> Bool {
        guard let first = artists.first.flatMap({ songIDsByArtist[$0] }), !first.isEmpty else { return false }
        return artists.dropFirst().allSatisfy { songIDsByArtist[$0] == first }
    }

    func artistGroupKey(_ artists: [String]) -> String {
        artists
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .sorted()
            .joined(separator: "|")
    }

    func fingerprint(for files: [FileInfo]) -> Int {
        var hasher = Hasher()
        hasher.combine(files.count)
        for file in files {
            hasher.combine(file.id)
            hasher.combine(file.isDirectory)
            hasher.combine(file.displayName)
            hasher.combine(file.author ?? "")
            hasher.combine(file.album ?? "")
            hasher.combine(file.durationMs ?? -1)
            hasher.combine(file.genre ?? "")
            hasher.combine(file.year ?? "")
            hasher.combine(file.albumArtist ?? "")
            hasher.combine(file.composer ?? "")
            hasher.combine(file.trackNumber ?? "")
            hasher.combine(file.discNumber ?? "")
            hasher.combine(file.contentCreationDate?.timeIntervalSince1970 ?? -1)
            hasher.combine(file.fileCreationDate?.timeIntervalSince1970 ?? -1)
            hasher.combine(file.fileModificationDate?.timeIntervalSince1970 ?? -1)
            hasher.combine(file.fileSizeBytes ?? -1)
            hasher.combine(file.typeIdentifier ?? "")
            hasher.combine(file.localizedTypeDescription ?? "")
            hasher.combine(UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: file.id))
        }
        return hasher.finalize()
    }

    func applyingVisualOverride(_ file: FileInfo) -> FileInfo {
        guard !file.isDirectory,
              let override = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: file.id) else {
            return file
        }
        var updated = file
        if let title = override.title?.nilIfEmpty { updated.displayName = title }
        if let artist = override.artist?.nilIfEmpty { updated.author = artist }
        if let album = override.album?.nilIfEmpty { updated.album = album }
        if let genre = override.genre?.nilIfEmpty { updated.genre = genre }
        if let year = override.year?.nilIfEmpty { updated.year = year }
        return updated
    }

    func mergeDuplicates(_ files: [FileInfo]) -> [FileInfo] {
        var byId: [String: FileInfo] = [:]
        byId.reserveCapacity(files.count)

        for f in files {
            if var existing = byId[f.id] {
                // Prefer richer metadata if we have duplicates.
                if existing.isDirectory && !f.isDirectory { existing.isDirectory = false }
                if existing.displayName.nilIfEmpty == nil, f.displayName.nilIfEmpty != nil { existing.displayName = f.displayName }
                if existing.author == nil, f.author != nil { existing.author = f.author }
                if existing.album == nil, f.album != nil { existing.album = f.album }
                if existing.durationMs == nil, f.durationMs != nil { existing.durationMs = f.durationMs }
                if existing.genre == nil, f.genre != nil { existing.genre = f.genre }
                if existing.year == nil, f.year != nil { existing.year = f.year }
                if existing.albumArtist == nil, f.albumArtist != nil { existing.albumArtist = f.albumArtist }
                if existing.composer == nil, f.composer != nil { existing.composer = f.composer }
                if existing.trackNumber == nil, f.trackNumber != nil { existing.trackNumber = f.trackNumber }
                if existing.discNumber == nil, f.discNumber != nil { existing.discNumber = f.discNumber }
                if existing.contentCreationDate == nil, f.contentCreationDate != nil { existing.contentCreationDate = f.contentCreationDate }
                if existing.fileCreationDate == nil, f.fileCreationDate != nil { existing.fileCreationDate = f.fileCreationDate }
                if existing.fileModificationDate == nil, f.fileModificationDate != nil { existing.fileModificationDate = f.fileModificationDate }
                if existing.fileSizeBytes == nil, f.fileSizeBytes != nil { existing.fileSizeBytes = f.fileSizeBytes }
                if existing.typeIdentifier == nil, f.typeIdentifier != nil { existing.typeIdentifier = f.typeIdentifier }
                if existing.localizedTypeDescription == nil, f.localizedTypeDescription != nil { existing.localizedTypeDescription = f.localizedTypeDescription }
                byId[f.id] = existing
            } else {
                byId[f.id] = f
            }
        }

        return Array(byId.values)
    }

    func ensureFolderChain(for items: [FileInfo]) -> [FileInfo] {
        var byId: [String: FileInfo] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        byId.reserveCapacity(items.count + 64)

        for item in items where !item.isDirectory {
            var parent = URL(fileURLWithPath: item.id).deletingLastPathComponent()
            while parent.path != "/" && parent.path != "." && parent.path != parent.deletingLastPathComponent().path {
                let path = parent.path
                if byId[path] == nil {
                    byId[path] = FileInfo(
                        id: path,
                        isDirectory: true,
                        displayName: parent.lastPathComponent.nilIfEmpty ?? path,
                        author: nil,
                        album: nil,
                        durationMs: nil
                    )
                }
                parent.deleteLastPathComponent()
            }
        }

        return Array(byId.values)
    }

}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
