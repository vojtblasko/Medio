import Foundation

struct LyricsOrganizationService: @unchecked Sendable {
    typealias ProgressHandler = @MainActor @Sendable (_ processed: Int, _ total: Int) -> Void

    private let fileManager: FileManager
    private let associationRepository: LyricsFileAssociationRepository

    init(
        fileManager: FileManager = .default,
        associationRepository: LyricsFileAssociationRepository
    ) {
        self.fileManager = fileManager
        self.associationRepository = associationRepository
    }

    func organize(progress: @escaping ProgressHandler = { _, _ in }) async throws -> Int {
        guard let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "LyricsOrganizationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Documents directory not found."])
        }

        let musicExts = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "alac"]
        let lyricsExts = ["lrc", "srt", "ttml", "ttlm", "txt", "xml"]

        let discovered = try await Task.detached(priority: .utility) {
            let musicFiles = try findFilesRecursively(in: docsDir, extensions: musicExts, excludeDir: "Lyrics", fileManager: fileManager)
            let lyricsFiles = try findFilesRecursively(in: docsDir, extensions: lyricsExts, excludeDir: "Lyrics", fileManager: fileManager)
            return (musicFiles: musicFiles, lyricsFiles: lyricsFiles)
        }.value

        let lyricsDir = try LyricsManagedStorage.ensureLyricsDirectoryExists(fileManager: fileManager)
        await progress(0, discovered.lyricsFiles.count)

        var organizedCount = 0
        for (index, lyricFile) in discovered.lyricsFiles.enumerated() {
            await progress(index, discovered.lyricsFiles.count)
            let metadataMatch = try? await matchLyricsToMusic(lyricFile: lyricFile, against: discovered.musicFiles)
            let filenameMatch = await matchByFilename(lyricFile: lyricFile, against: discovered.musicFiles)

            if let matched = metadataMatch ?? filenameMatch {
                try await moveAndAssociateLyrics(lyricFile: lyricFile, with: matched, targetDir: lyricsDir)
                organizedCount += 1
            }
        }

        await progress(discovered.lyricsFiles.count, discovered.lyricsFiles.count)
        return organizedCount
    }

    private func matchLyricsToMusic(lyricFile: URL, against musicFiles: [URL]) async throws -> URL? {
        let data = try Data(contentsOf: lyricFile)
        guard let text = decodeLyricsText(data) else { return nil }
        let tags = parseLyricIdentity(from: text)
        guard !tags.title.isEmpty else { return nil }

        var best: (url: URL, score: Int)?
        for musicFile in musicFiles {
            let info = await FileMetadataReader.fileInfo(for: musicFile)
            let title = normalizeLyricsMatchValue(info.displayName)
            let artist = normalizeLyricsMatchValue(info.author)
            var score = 0
            if title == tags.title { score += 10 }
            if !artist.isEmpty, artist == tags.artist { score += 5 }
            guard score > 0 else { continue }
            if best == nil || score > best!.score {
                best = (musicFile, score)
            }
        }
        return best?.url
    }

    private func matchByFilename(lyricFile: URL, against musicFiles: [URL]) async -> URL? {
        let lyricBase = normalizeLyricsMatchValue(lyricFile.deletingPathExtension().lastPathComponent)
        guard !lyricBase.isEmpty else { return nil }

        for musicFile in musicFiles {
            let songBase = normalizeLyricsMatchValue(musicFile.deletingPathExtension().lastPathComponent)
            if lyricBase == songBase {
                return musicFile
            }
        }

        for musicFile in musicFiles {
            let info = await FileMetadataReader.fileInfo(for: musicFile)
            if LyricsFilenameExactMatcher.matchesExactly(
                lyricsFilenameBase: lyricFile.deletingPathExtension().lastPathComponent,
                songTitle: info.displayName,
                songArtist: info.author ?? ""
            ) {
                return musicFile
            }
        }

        return nil
    }

    private func moveAndAssociateLyrics(lyricFile: URL, with musicFile: URL, targetDir: URL) async throws {
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let target = uniqueLyricsDestination(for: lyricFile, in: targetDir, fileManager: fileManager)
        if lyricFile.standardizedFileURL.path != target.standardizedFileURL.path {
            try await AppFileMutationCoordinator.shared.copyReplacingItem(at: lyricFile, to: target)
            try fileManager.removeItem(at: lyricFile)
        }
        try await associationRepository.setAssociatedLyricsFile(target.path, forMediaPath: musicFile.path)
    }
}

private func findFilesRecursively(in root: URL, extensions allowedExtensions: [String], excludeDir: String, fileManager: FileManager) throws -> [URL] {
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in true }
    ) else { return [] }

    let allowed = Set(allowedExtensions.map { $0.lowercased() })
    var urls: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        if url.lastPathComponent.caseInsensitiveCompare(excludeDir) == .orderedSame {
            enumerator.skipDescendants()
            continue
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true { continue }
        if allowed.contains(url.pathExtension.lowercased()) {
            urls.append(url)
        }
    }
    return urls
}

private func uniqueLyricsDestination(for source: URL, in directory: URL, fileManager: FileManager) -> URL {
    let base = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var candidate = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
    var index = 1
    while fileManager.fileExists(atPath: candidate.path) {
        let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
        candidate = directory.appendingPathComponent(name, isDirectory: false)
        index += 1
    }
    return candidate
}

private func decodeLyricsText(_ data: Data) -> String? {
    for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
        if let decoded = String(data: data, encoding: encoding)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !decoded.isEmpty {
            return decoded
        }
    }
    return nil
}

private func parseLyricIdentity(from text: String) -> (title: String, artist: String) {
    var title = ""
    var artist = ""
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("["),
              let end = line.firstIndex(of: "]"),
              let separator = line.firstIndex(of: ":") else { continue }
        let key = line[line.index(after: line.startIndex)..<separator].lowercased()
        let value = String(line[line.index(after: separator)..<end])
        if key == "ti" || key == "title" {
            title = title.isEmpty ? normalizeLyricsMatchValue(value) : title
        } else if key == "ar" || key == "artist" {
            artist = artist.isEmpty ? normalizeLyricsMatchValue(value) : artist
        }
    }
    return (title, artist)
}

private func normalizeLyricsMatchValue(_ value: String?) -> String {
    guard let value else { return "" }
    return value
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .lowercased()
}
