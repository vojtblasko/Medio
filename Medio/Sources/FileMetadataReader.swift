import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum FileMetadataReader {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4p", "m4b", "aac", "wav", "wave", "aiff", "aif", "caf", "flac", "ogg", "oga", "opus", "alac", "amr", "wma", "m3p"]
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt",
        "mkv", "webm", "avi", "wmv", "asf",
        "vob", "mpeg", "mpg", "mpe", "mpv", "m2v",
        "3gp", "3g2", "ts", "mts", "m2ts", "ogv", "divx"
    ]

    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .nameKey,
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .typeIdentifierKey,
        .localizedTypeDescriptionKey,
    ]

    static func isSupportedMediaFile(url: URL, typeIdentifier: String?) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) || videoExtensions.contains(ext) { return true }

        guard let typeIdentifier, let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    static func directoryInfo(for url: URL, resourceValues: URLResourceValues? = nil) -> FileInfo {
        let values = resourceValues ?? (try? url.resourceValues(forKeys: resourceKeys))
        return FileInfo(
            id: url.path,
            isDirectory: true,
            displayName: values?.name ?? url.lastPathComponent,
            author: nil,
            album: nil,
            fileCreationDate: values?.creationDate,
            fileModificationDate: values?.contentModificationDate,
            typeIdentifier: values?.typeIdentifier,
            localizedTypeDescription: values?.localizedTypeDescription ?? "Folder"
        )
    }

    static func genericFileInfo(for url: URL, resourceValues: URLResourceValues? = nil) -> FileInfo {
        let values = resourceValues ?? (try? url.resourceValues(forKeys: resourceKeys))
        let fileCreationDate = values?.creationDate ?? fileAttributeDate(url: url, key: .creationDate)
        let fileModificationDate = values?.contentModificationDate ?? fileAttributeDate(url: url, key: .modificationDate)
        let fileSize = values?.fileSize ?? fileAttributeSize(url: url)
        let typeIdentifier = values?.typeIdentifier
        let typeDescription = values?.localizedTypeDescription ?? fallbackTypeDescription(for: url, typeIdentifier: typeIdentifier)

        return FileInfo(
            id: url.path,
            isDirectory: false,
            displayName: values?.name ?? url.lastPathComponent,
            author: nil,
            album: nil,
            fileCreationDate: fileCreationDate,
            fileModificationDate: fileModificationDate,
            fileSizeBytes: fileSize,
            typeIdentifier: typeIdentifier,
            localizedTypeDescription: typeDescription
        )
    }

    static func fileInfo(for url: URL, resourceValues: URLResourceValues? = nil) async -> FileInfo {
        let values = resourceValues ?? (try? url.resourceValues(forKeys: resourceKeys))

        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: String?
        var albumArtist: String?
        var composer: String?
        var trackNumber: String?
        var discNumber: String?
        var contentCreationDate: Date?
        var durationMs: Int?

        do {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.metadata)
            let commonMetadata = try await asset.load(.commonMetadata)
            for item in metadata + commonMetadata {
                let rawKey = metadataKey(for: item)
                let key = rawKey.lowercased()
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                let value = await metadataStringValue(for: item)

                if keyMatches(key, anyOf: ["title", "©nam"]) {
                    title = title ?? value
                } else if keyMatches(key, anyOf: ["albumartist", "album artist", "album_artist", "aarti", "soaa"]) {
                    albumArtist = albumArtist ?? value
                } else if keyMatches(key, anyOf: ["artist", "author", "©art", "©aut", "soar"]) {
                    artist = artist ?? value
                } else if keyMatches(key, anyOf: ["album", "©alb", "soal"]) {
                    album = album ?? value
                } else if keyMatches(key, anyOf: ["genre", "©gen"]) {
                    genre = genre ?? value
                } else if keyMatches(key, anyOf: ["composer", "writer", "©wrt"]) {
                    composer = composer ?? value
                } else if keyMatches(key, anyOf: ["track", "tracknumber", "trkn", "trck"]) || keyMatches(identifier, anyOf: ["track", "tracknumber", "trkn", "trck"]) {
                    trackNumber = trackNumber ?? normalizedOrdinal(value)
                } else if keyMatches(key, anyOf: ["disc", "disk", "discnumber", "disknumber", "tpos"]) || keyMatches(identifier, anyOf: ["disc", "disk", "discnumber", "disknumber", "tpos"]) {
                    discNumber = discNumber ?? normalizedOrdinal(value)
                } else if keyMatches(key, anyOf: ["creationdate", "creation date", "created", "encodeddate", "recordeddate", "releasedate", "release date", "date", "year", "©day"]) {
                    year = year ?? normalizedYear(value)
                    contentCreationDate = contentCreationDate ?? normalizedDate(value)
                }
            }

            if trackNumber == nil || discNumber == nil {
                let id3Metadata = try await asset.loadMetadata(for: .id3Metadata)
                for item in id3Metadata where trackNumber == nil || discNumber == nil {
                    let rawKey = metadataKey(for: item)
                    let key = rawKey.lowercased()
                    let identifier = item.identifier?.rawValue.lowercased() ?? ""
                    let value = await metadataStringValue(for: item)

                    if trackNumber == nil, keyMatches(key, anyOf: ["track", "tracknumber", "trkn", "trck"]) || keyMatches(identifier, anyOf: ["track", "tracknumber", "trkn", "trck"]) {
                        trackNumber = normalizedOrdinal(value)
                    } else if discNumber == nil, keyMatches(key, anyOf: ["disc", "disk", "discnumber", "disknumber", "tpos"]) || keyMatches(identifier, anyOf: ["disc", "disk", "discnumber", "disknumber", "tpos"]) {
                        discNumber = normalizedOrdinal(value)
                    }
                }
            }

            let duration = try await asset.load(.duration)
            if duration.isNumeric && duration.seconds.isFinite {
                durationMs = Int((duration.seconds * 1000.0).rounded())
            }
        } catch {
            // Gracefully handle errors (e.g., FLAC decoder unavailable)
        }

        let filenameTitle = url.deletingPathExtension().lastPathComponent
        let finalTitle = title?.nilIfEmpty ?? filenameTitle
        let finalArtist = artist?.nilIfEmpty ?? "Unknown Artist"
        let finalAlbum = album?.nilIfEmpty
        let fileCreationDate = values?.creationDate ?? fileAttributeDate(url: url, key: .creationDate)
        let fileModificationDate = values?.contentModificationDate ?? fileAttributeDate(url: url, key: .modificationDate)
        let fileSize = values?.fileSize ?? fileAttributeSize(url: url)
        let typeIdentifier = values?.typeIdentifier
        let typeDescription = values?.localizedTypeDescription ?? fallbackTypeDescription(for: url, typeIdentifier: typeIdentifier)

        return FileInfo(
            id: url.path,
            isDirectory: false,
            displayName: finalTitle,
            author: finalArtist,
            album: finalAlbum,
            durationMs: durationMs,
            genre: genre?.nilIfEmpty,
            year: year?.nilIfEmpty ?? normalizedYear(from: contentCreationDate ?? fileCreationDate),
            albumArtist: albumArtist?.nilIfEmpty,
            composer: composer?.nilIfEmpty,
            trackNumber: trackNumber?.nilIfEmpty,
            discNumber: discNumber?.nilIfEmpty,
            contentCreationDate: contentCreationDate,
            fileCreationDate: fileCreationDate,
            fileModificationDate: fileModificationDate,
            fileSizeBytes: fileSize,
            typeIdentifier: typeIdentifier,
            localizedTypeDescription: typeDescription
        )
    }

    static func cacheHasCurrentMetadata(_ item: FileInfo) -> Bool {
        if item.isDirectory {
            return item.fileCreationDate != nil || item.fileModificationDate != nil || item.localizedTypeDescription != nil
        }
        return item.fileSizeBytes != nil && item.typeIdentifier != nil && item.fileModificationDate != nil
    }

    private static func metadataKey(for item: AVMetadataItem) -> String {
        item.commonKey?.rawValue
            ?? item.identifier?.rawValue
            ?? item.key.map { String(describing: $0) }
            ?? ""
    }

    private static func metadataStringValue(for item: AVMetadataItem) async -> String? {
        if let stringValue = (try? await item.load(.stringValue))?.nilIfEmpty {
            return stringValue
        }
        if let numberValue = try? await item.load(.numberValue) {
            return numberValue.stringValue.nilIfEmpty
        }
        if let dataValue = try? await item.load(.dataValue), let decodedValue = decodedMetadataString(from: dataValue) {
            return decodedValue
        }
        if let dateValue = try? await item.load(.dateValue) {
            return isoDateFormatter.string(from: dateValue)
        }
        return nil
    }

    private static func keyMatches(_ key: String, anyOf needles: [String]) -> Bool {
        needles.contains { key.contains($0) }
    }

    private static func normalizedYear(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        if let match = value.range(of: #"\d{4}"#, options: .regularExpression) {
            return String(value[match])
        }
        return nil
    }

    private static func normalizedYear(from date: Date?) -> String? {
        guard let date else { return nil }
        return String(Calendar.current.component(.year, from: date))
    }

    private static func normalizedDate(_ value: String?) -> Date? {
        guard let value = value?.nilIfEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }

        for formatter in dateFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        if let match = value.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return yyyyMMddFormatter.date(from: String(value[match]))
        }

        if let year = normalizedYear(value), let intYear = Int(year) {
            return Calendar.current.date(from: DateComponents(year: intYear, month: 1, day: 1))
        }
        return nil
    }

    private static func normalizedOrdinal(_ value: String?) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        if let match = value.range(of: #"\d+"#, options: .regularExpression) {
            return String(value[match])
        }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        if let first = parts.first?.nilIfEmpty {
            return first
        }
        return value
    }

    private static func decodedMetadataString(from data: Data) -> String? {
        if data.isEmpty { return nil }
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
        ]

        for encoding in encodings {
            guard let rawString = String(data: data, encoding: encoding) else { continue }
            let cleaned = rawString
                .replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private static func fileAttributeDate(url: URL, key: FileAttributeKey) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[key] as? Date
    }

    private static func fileAttributeSize(url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.size] as? Int
    }

    private static func fallbackTypeDescription(for url: URL, typeIdentifier: String?) -> String? {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            return type.localizedDescription ?? type.preferredFilenameExtension?.uppercased()
        }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? nil : "\(ext) file"
    }

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }()

    private static let yyyyMMddFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
        "yyyy/MM/dd",
        "yyyy",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
