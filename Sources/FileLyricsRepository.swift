import Foundation

/// Stores managed lyrics files in the app's Documents folder (`Documents/Lyrics/`).
/// This folder is visible to the user if iTunes File Sharing is enabled.
final class FileLyricsRepository: LyricsSearchRepository, @unchecked Sendable {
    private let fileManager: FileManager
    private let associationRepository: LyricsFileAssociationRepository?
    private let migrationLock = NSLock()
    private var didCheckMigration = false

    init(fileManager: FileManager = .default, associationRepository: LyricsFileAssociationRepository? = nil) {
        self.fileManager = fileManager
        self.associationRepository = associationRepository
    }

    func loadLyrics(forMediaPath path: String) async throws -> String? {
        try migrateIfNeeded()

        // First check for associated lyrics file
        if let associationRepository = associationRepository,
           let associatedPath = associationRepository.getAssociatedLyricsFile(forMediaPath: path),
           fileManager.fileExists(atPath: associatedPath) {
            return try readTextFile(at: URL(fileURLWithPath: associatedPath))
        }

        // Fall back to standard lyrics files in the Lyrics directory.
        for url in try lyricsFileURLCandidates(forMediaPath: path) where fileManager.fileExists(atPath: url.path) {
            return try readTextFile(at: url)
        }

        // Auto-associate by lyrics tags, then strict filename title+artist matching.
        if let matchedURL = try await autoAssociateLyricsFile(forMediaPath: path) {
            return try readTextFile(at: matchedURL)
        }

        return nil
    }

    func loadLyricsForSearch(forMediaPaths paths: [String]) async throws -> [String: String] {
        try migrateIfNeeded()
        let fileManager = self.fileManager
        let associationRepository = self.associationRepository

        return try await Task.detached(priority: .utility) {
            let lyricsDirectory = try LyricsManagedStorage.lyricsDirectoryURL(fileManager: fileManager)
            let files = (try? fileManager.contentsOfDirectory(
                at: lyricsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, $0) })
            var result: [String: String] = [:]
            result.reserveCapacity(min(paths.count, files.count))

            for path in paths {
                guard !Task.isCancelled else { break }
                var lyricsURL: URL?
                if let associatedPath = associationRepository?.getAssociatedLyricsFile(forMediaPath: path),
                   fileManager.fileExists(atPath: associatedPath) {
                    lyricsURL = URL(fileURLWithPath: associatedPath)
                } else {
                    let safeName = LyricsManagedStorage.safeName(forMediaPath: path)
                    lyricsURL = Self.supportedLyricsExtensions.lazy
                        .compactMap { filesByName["\(safeName).\($0)"] }
                        .first
                }

                if let lyricsURL,
                   let data = try? Data(contentsOf: lyricsURL),
                   let text = Self.decodeSearchText(from: data) {
                    result[path] = text
                }
            }
            return result
        }.value
    }

    func saveLyrics(_ lrc: String, forMediaPath path: String) async throws {
        try migrateIfNeeded()
        let url = try lyricsFileURL(forMediaPath: path)
        try ensureLyricsDirectoryExists()
        try lrc.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    func deleteLyrics(forMediaPath path: String) async throws {
        let url = try lyricsFileURL(forMediaPath: path)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

private extension FileLyricsRepository {
    func migrateIfNeeded() throws {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !didCheckMigration else { return }
        try LyricsManagedStorage.migrateFromApplicationSupportIfNeeded(fileManager: fileManager)
        didCheckMigration = true
    }

    static func decodeSearchText(from data: Data) -> String? {
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1]
        for encoding in encodings {
            guard let raw = String(data: data, encoding: encoding) else { continue }
            let cleaned = raw.replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    func ensureLyricsDirectoryExists() throws {
        _ = try LyricsManagedStorage.ensureLyricsDirectoryExists(fileManager: fileManager)
    }

    func lyricsDirectoryURL() throws -> URL {
        try LyricsManagedStorage.lyricsDirectoryURL(fileManager: fileManager)
    }

    func lyricsFileURL(forMediaPath path: String) throws -> URL {
        let dir = try lyricsDirectoryURL()
        let safeName = LyricsManagedStorage.safeName(forMediaPath: path)
        return dir.appendingPathComponent("\(safeName).lrc", isDirectory: false)
    }

    func lyricsFileURLCandidates(forMediaPath path: String) throws -> [URL] {
        let dir = try lyricsDirectoryURL()
        let safeName = LyricsManagedStorage.safeName(forMediaPath: path)

        return Self.supportedLyricsExtensions.map { ext in
            dir.appendingPathComponent("\(safeName).\(ext)", isDirectory: false)
        }
    }

    func readTextFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let decoded = decodeText(from: data) {
            return decoded
        }

        throw NSError(
            domain: "FileLyricsRepository",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding for lyrics file at \(url.lastPathComponent)."]
        )
    }

    func decodeText(from data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
        ]

        for encoding in encodings {
            guard let raw = String(data: data, encoding: encoding) else { continue }
            let cleaned = raw.replacingOccurrences(of: "\u{0000}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    func autoAssociateLyricsFile(forMediaPath mediaPath: String) async throws -> URL? {
        let lyricsDirectory = try lyricsDirectoryURL()
        guard fileManager.fileExists(atPath: lyricsDirectory.path) else { return nil }

        let mediaURL = URL(fileURLWithPath: mediaPath)
        guard fileManager.fileExists(atPath: mediaURL.path) else { return nil }

        let mediaInfo = await FileMetadataReader.fileInfo(for: mediaURL)
        let mediaSignature = LyricsSignature(
            title: normalizeForMatch(mediaInfo.displayName),
            artist: normalizeForMatch(mediaInfo.author),
            album: normalizeForMatch(mediaInfo.album)
        )
        guard !mediaSignature.title.isEmpty else { return nil }

        let candidateURLs = try fileManager.contentsOfDirectory(
            at: lyricsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { Self.supportedLyricsExtensions.contains($0.pathExtension.lowercased()) }

        var bestMatch: (url: URL, score: Int)? = nil

        for candidateURL in candidateURLs {
            guard let text = try? readTextFile(at: candidateURL) else { continue }
            let signature = parseLRCTags(from: text)
            let score = matchScore(media: mediaSignature, lyrics: signature)
            guard score > 0 else { continue }

            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (candidateURL, score)
            }
        }

        let matchedByTags = bestMatch?.url
        let matchedByFilename = candidateURLs.first {
            LyricsFilenameExactMatcher.matchesExactly(
                lyricsFilenameBase: $0.deletingPathExtension().lastPathComponent,
                songTitle: mediaInfo.displayName,
                songArtist: mediaInfo.author ?? ""
            )
        }

        let mediaBaseName = normalizeForMatch(mediaURL.deletingPathExtension().lastPathComponent)
        let matchedByBaseName = candidateURLs.first {
            let lyricBaseName = normalizeForMatch($0.deletingPathExtension().lastPathComponent)
            return !lyricBaseName.isEmpty && (lyricBaseName == mediaSignature.title || lyricBaseName == mediaBaseName)
        }

        guard let bestURL = matchedByTags ?? matchedByFilename ?? matchedByBaseName else { return nil }
        if let associationRepository {
            try await associationRepository.setAssociatedLyricsFile(bestURL.path, forMediaPath: mediaPath)
        }
        return bestURL
    }

    func parseLRCTags(from text: String) -> LyricsSignature {
        var title = ""
        var artist = ""
        var album = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]"),
                  closeBracket > line.startIndex else { continue }

            let content = line[line.index(after: line.startIndex)..<closeBracket]
            guard let separator = content.firstIndex(of: ":") else { continue }

            let rawKey = String(content[..<separator]).lowercased()
            let rawValue = String(content[content.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawValue.isEmpty else { continue }

            switch rawKey {
            case "ti", "title":
                if title.isEmpty { title = normalizeForMatch(rawValue) }
            case "ar", "artist":
                if artist.isEmpty { artist = normalizeForMatch(rawValue) }
            case "al", "album":
                if album.isEmpty { album = normalizeForMatch(rawValue) }
            default:
                break
            }
        }

        return LyricsSignature(title: title, artist: artist, album: album)
    }

    func matchScore(media: LyricsSignature, lyrics: LyricsSignature) -> Int {
        guard !lyrics.title.isEmpty, lyrics.title == media.title else { return 0 }

        var score = 10
        if !lyrics.artist.isEmpty, !media.artist.isEmpty {
            score += (lyrics.artist == media.artist) ? 5 : -8
        }
        if !lyrics.album.isEmpty, !media.album.isEmpty, lyrics.album == media.album {
            score += 2
        }
        return max(score, 0)
    }

    func normalizeForMatch(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !folded.isEmpty else { return "" }

        var normalizedScalars: [UnicodeScalar] = []
        normalizedScalars.reserveCapacity(folded.unicodeScalars.count)
        guard let whitespace = UnicodeScalar(32) else { return folded.lowercased() }

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalizedScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                normalizedScalars.append(whitespace)
            }
        }

        let compact = String(String.UnicodeScalarView(normalizedScalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return compact.lowercased()
    }

    static let supportedLyricsExtensions: [String] = ["lrc", "srt", "ttml", "ttlm", "txt", "xml"]
}

private struct LyricsSignature {
    let title: String
    let artist: String
    let album: String
}

// MARK: - Lyrics Storage (visible in Documents)

enum LyricsManagedStorage {
    private static let lyricsFolderName = "Lyrics"

    static func safeName(forMediaPath path: String) -> String {
        path
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    /// Returns the URL for `Documents/Lyrics`. Creates the directory if needed.
    static func lyricsDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "LyricsManagedStorage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Documents directory not found."])
        }
        return documents.appendingPathComponent(lyricsFolderName, isDirectory: true)
    }

    @discardableResult
    static func ensureLyricsDirectoryExists(fileManager: FileManager = .default) throws -> URL {
        let url = try lyricsDirectoryURL(fileManager: fileManager)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Migrates lyrics from the old hidden location (`Application Support/Medio/Lyrics`) to the new visible `Documents/Lyrics`.
    /// Call this once on app start to preserve any previously imported lyrics.
    static func migrateFromApplicationSupportIfNeeded(fileManager: FileManager = .default) throws {
        // Old location: Application Support/Medio/Lyrics
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldMedioDir = appSupport.appendingPathComponent("Medio", isDirectory: true)
        let oldLyricsDir = oldMedioDir.appendingPathComponent(lyricsFolderName, isDirectory: true)
        guard fileManager.fileExists(atPath: oldLyricsDir.path) else { return }

        let newLyricsDir = try ensureLyricsDirectoryExists(fileManager: fileManager)

        let entries = try fileManager.contentsOfDirectory(at: oldLyricsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        for fileURL in entries {
            let destination = newLyricsDir.appendingPathComponent(fileURL.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: fileURL)
            } else {
                try fileManager.moveItem(at: fileURL, to: destination)
            }
        }

        // Remove the old directory and its parent if empty
        try fileManager.removeItem(at: oldLyricsDir)
        if let remaining = try? fileManager.contentsOfDirectory(at: oldMedioDir, includingPropertiesForKeys: nil),
           remaining.isEmpty {
            try fileManager.removeItem(at: oldMedioDir)
        }
    }
}

// MARK: - Filename Matching

enum LyricsFilenameExactMatcher {
    static func matchesExactly(lyricsFilenameBase: String, songTitle: String, songArtist: String) -> Bool {
        let normalizedFilename = normalizeFilenameBase(lyricsFilenameBase)
        let normalizedTitle = normalizeValue(songTitle)
        let normalizedArtist = normalizeValue(songArtist)
        guard !normalizedTitle.isEmpty, !normalizedArtist.isEmpty else { return false }

        let expectedFormats = [
            "\(normalizedTitle) - \(normalizedArtist)",
            "\(normalizedArtist) - \(normalizedTitle)",
        ]
        return expectedFormats.contains(normalizedFilename)
    }

    private static func normalizeFilenameBase(_ value: String) -> String {
        let withHyphen = value
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        let normalizedSeparator = withHyphen.replacingOccurrences(
            of: #"\s*-\s*"#,
            with: " - ",
            options: .regularExpression
        )
        return normalizeValue(normalizedSeparator)
    }

    private static func normalizeValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
}
