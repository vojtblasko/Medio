import Foundation

protocol LyricsFileAssociationRepository: Sendable {
    func getAssociatedLyricsFile(forMediaPath path: String) -> String?
    func setAssociatedLyricsFile(_ lyricsPath: String, forMediaPath path: String) async throws
    func removeAssociatedLyricsFile(forMediaPath path: String) async throws
}

final class UserDefaultsLyricsFileAssociationRepository: LyricsFileAssociationRepository, @unchecked Sendable {
    private enum Keys {
        static let associations = "medio.lyricsFileAssociations.v2"
        static let legacyAssociations = "medio.lyricsFileAssociations"
    }

    private let defaults: UserDefaults
    private let fileURL: URL?
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: [String: String]?

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default, storageURL: URL? = nil) {
        self.defaults = defaults
        self.fileManager = fileManager

        let resolvedFileURL: URL?
        if let storageURL {
            let directory = storageURL.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                resolvedFileURL = storageURL
            } catch {
                AppLog.persistence.error("Lyrics association storage could not be prepared: \(error.localizedDescription, privacy: .public)")
                resolvedFileURL = nil
            }
        } else {
            do {
                let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = base.appendingPathComponent("Medio", isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                resolvedFileURL = directory.appendingPathComponent("lyrics-associations.v1.json", isDirectory: false)
            } catch {
                AppLog.persistence.error("Lyrics association storage could not be prepared: \(error.localizedDescription, privacy: .public)")
                resolvedFileURL = nil
            }
        }
        self.fileURL = resolvedFileURL
    }

    func getAssociatedLyricsFile(forMediaPath path: String) -> String? {
        withLock {
            var associations = loadAssociationsLocked()
            guard !associations.isEmpty else { return nil }
            let primaryMediaKey = encodeMediaPath(path)
            let lookupKeys = mediaLookupKeys(for: path)

            for key in lookupKeys {
                guard let storedPath = associations[key] else { continue }
                let resolvedPath = resolveStoredLyricsPath(storedPath)
                let encodedLyricsPath = encodeLyricsPath(resolvedPath)

                // Opportunistically migrate legacy keys/values to normalized entries.
                if key != primaryMediaKey || storedPath != encodedLyricsPath {
                    associations[primaryMediaKey] = encodedLyricsPath
                    for legacyKey in lookupKeys where legacyKey != primaryMediaKey {
                        associations.removeValue(forKey: legacyKey)
                    }
                    do {
                        try persistLocked(associations)
                    } catch {
                        AppLog.persistence.error("Lyrics association migration could not be saved: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return resolvedPath
            }

            return nil
        }
    }

    func setAssociatedLyricsFile(_ lyricsPath: String, forMediaPath path: String) async throws {
        try withLock {
            var associations = loadAssociationsLocked()
            let primaryMediaKey = encodeMediaPath(path)
            associations[primaryMediaKey] = encodeLyricsPath(lyricsPath)
            for key in mediaLookupKeys(for: path) where key != primaryMediaKey {
                associations.removeValue(forKey: key)
            }
            try persistLocked(associations)
        }
    }

    func removeAssociatedLyricsFile(forMediaPath path: String) async throws {
        try withLock {
            var associations = loadAssociationsLocked()
            for key in mediaLookupKeys(for: path) {
                associations.removeValue(forKey: key)
            }
            try persistLocked(associations)
        }
    }
}

private extension UserDefaultsLyricsFileAssociationRepository {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func loadAssociationsLocked() -> [String: String] {
        if let cache {
            return cache
        }

        if let fileURL, fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([String: String].self, from: data)
                cache = decoded
                return decoded
            } catch {
                AppLog.persistence.error("Lyrics associations were corrupt and will be rebuilt: \(error.localizedDescription, privacy: .public)")
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    AppLog.persistence.error("Corrupt lyrics associations could not be removed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if let stored = defaults.dictionary(forKey: Keys.associations) as? [String: String] {
            cache = stored
            return stored
        }

        if let legacy = defaults.dictionary(forKey: Keys.legacyAssociations) as? [String: String] {
            cache = legacy
            return legacy
        }

        cache = [:]
        return [:]
    }

    func persistLocked(_ associations: [String: String]) throws {
        if let fileURL {
            let data = try JSONEncoder().encode(associations)
            try data.write(to: fileURL, options: [.atomic])
        }

        defaults.set(associations, forKey: Keys.associations)
        cache = associations
    }

    func mediaLookupKeys(for path: String) -> [String] {
        var keys: [String] = []
        let encoded = encodeMediaPath(path)
        let standardized = standardizePath(path)
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path

        for candidate in [encoded, standardized, resolved, path] where !candidate.isEmpty {
            if !keys.contains(candidate) {
                keys.append(candidate)
            }
        }
        return keys
    }

    func resolveStoredLyricsPath(_ stored: String) -> String {
        let decoded = decodeLyricsPath(stored)
        guard !fileManager.fileExists(atPath: decoded),
              let managedLyricsDirectory = managedLyricsDirectoryPath() else {
            return decoded
        }

        let filename = URL(fileURLWithPath: decoded).lastPathComponent
        guard !filename.isEmpty else { return decoded }

        let fallback = managedLyricsDirectory.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: fallback.path) {
            return fallback.path
        }

        return decoded
    }

    func encodeMediaPath(_ path: String) -> String {
        standardizePath(path)
    }

    func encodeLyricsPath(_ path: String) -> String {
        let standardized = standardizePath(path)
        guard let managedLyricsDirectory = managedLyricsDirectoryPath() else {
            return "abs:\(standardized)"
        }

        if standardized == managedLyricsDirectory.path {
            return "lyrics:/"
        }
        if standardized.hasPrefix(managedLyricsDirectory.path + "/") {
            let relative = String(standardized.dropFirst(managedLyricsDirectory.path.count + 1))
            return "lyrics:\(relative)"
        }
        return "abs:\(standardized)"
    }

    func decodeLyricsPath(_ stored: String) -> String {
        if stored.hasPrefix("lyrics:") {
            let relative = String(stored.dropFirst(7))
            guard let managedLyricsDirectory = managedLyricsDirectoryPath() else {
                return standardizePath(relative)
            }
            if relative.isEmpty || relative == "/" {
                return managedLyricsDirectory.path
            }
            return managedLyricsDirectory.appendingPathComponent(relative, isDirectory: false).path
        }

        if stored.hasPrefix("docs:") {
            let relative = String(stored.dropFirst(5))
            if let managedLyricsDirectory = managedLyricsDirectoryPath() {
                if relative == "Lyrics" || relative == "Lyrics/" {
                    return managedLyricsDirectory.path
                }
                if relative.hasPrefix("Lyrics/") {
                    let suffix = String(relative.dropFirst("Lyrics/".count))
                    return managedLyricsDirectory.appendingPathComponent(suffix, isDirectory: false).path
                }
            }

            return standardizePath(relative)
        }

        if stored.hasPrefix("abs:") {
            return standardizePath(String(stored.dropFirst(4)))
        }

        // Legacy data was plain absolute path.
        return standardizePath(stored)
    }

    func managedLyricsDirectoryPath() -> URL? {
        (try? LyricsManagedStorage.lyricsDirectoryURL(fileManager: fileManager))?.standardizedFileURL
    }

    func standardizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
