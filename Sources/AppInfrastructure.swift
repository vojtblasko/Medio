import Foundation
import OSLog
import UIKit

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Medio"

    static let files = Logger(subsystem: subsystem, category: "files")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let playback = Logger(subsystem: subsystem, category: "playback")
}

enum AppPerformance {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "Medio",
        category: "performance"
    )
}

enum AppRuntime {
    @MainActor private static var didPrepareUITestState = false
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-medioUITestMode")
    }

    static var shouldResetUITestState: Bool {
        ProcessInfo.processInfo.arguments.contains("-medioUITestReset")
    }

    @MainActor
    static func prepareUITestStateIfNeeded() {
        guard isUITesting, !didPrepareUITestState else { return }
        didPrepareUITestState = true
        UIView.setAnimationsEnabled(false)
        let fileManager = FileManager.default
        if shouldResetUITestState {
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                do {
                    let contents = try fileManager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
                    for url in contents { try fileManager.removeItem(at: url) }
                } catch {
                    AppLog.files.error("Could not reset the UI-test Documents directory: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("Example Folder", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            AppLog.files.error("Could not create the UI-test fixture folder: \(error.localizedDescription, privacy: .public)")
        }
        for name in ["Song One.mp3", "Song Two.mp3", "Example Video.mp4"] {
            let url = documents.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) {
                if !fileManager.createFile(atPath: url.path, contents: Data()) {
                    AppLog.files.error("Could not create UI-test fixture \(name, privacy: .public)")
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-medioUITestPriorityImage") {
            let size = CGSize(width: 240, height: 480)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.systemYellow.setFill()
                context.fill(CGRect(x: 70, y: 0, width: 100, height: 480))
            }
            let url = documents.appendingPathComponent("Priority Test Image.png")
            try? image.pngData()?.write(to: url)
            UserDefaults.standard.set(4, forKey: "medio.settings.priorityFoldersCount")
            UserDefaults.standard.set(["0": url.path], forKey: "medio.settings.prioritySlotArtworkPaths")
            UserDefaults.standard.set(["0"], forKey: "medio.settings.prioritySlotImageOnlyKeys")
        }

    }
}

struct UITestMediaLibraryRepository: MediaLibraryRepository, MediaLibraryProgressDataSource {
    func loadLibrary() async throws -> (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist]) {
        BuildLibraryIndexUseCase().execute(fixtureItems())
    }

    func loadCachedItems() -> [FileInfo]? { fixtureItems() }
    func cachedSnapshotDate() -> Date? { Date(timeIntervalSince1970: 1_700_000_000) }
    func scanAndCacheItems() async throws -> [FileInfo] { fixtureItems() }

    func scanAndCacheItems(progress: LibraryScanProgressHandler?) async throws -> [FileInfo] {
        let items = fixtureItems()
        if let progress {
            await progress(LibraryScanProgress(
                phase: .scanningFiles,
                completedItemCount: items.count,
                totalItemCount: items.count
            ))
        }
        return items
    }

    private func fixtureItems() -> [FileInfo] {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        var items = [
            FileInfo(
                id: documents.appendingPathComponent("Example Folder", isDirectory: true).path,
                isDirectory: true,
                displayName: "Example Folder",
                author: nil,
                album: nil
            ),
            FileInfo(
                id: documents.appendingPathComponent("Song One.mp3").path,
                isDirectory: false,
                displayName: "Song One",
                author: "Example Artist",
                album: "Example Album",
                durationMs: 180_000
            ),
            FileInfo(
                id: documents.appendingPathComponent("Song Two.mp3").path,
                isDirectory: false,
                displayName: "Song Two",
                author: "Example Artist",
                album: "Example Album",
                durationMs: 190_000
            ),
            FileInfo(
                id: documents.appendingPathComponent("Example Video.mp4").path,
                isDirectory: false,
                displayName: "Example Video",
                author: "Example Artist",
                album: "Example Album",
                durationMs: 60_000
            )
        ]
        if ProcessInfo.processInfo.arguments.contains("-medioUITestLongLibrary") {
            items += (1...24).map { index in
                FileInfo(
                    id: documents.appendingPathComponent("Fixture Track \(index).mp3").path,
                    isDirectory: false,
                    displayName: String(format: "Fixture Track %02d", index),
                    author: "Fixture Artist",
                    album: "Fixture Album",
                    durationMs: 120_000
                )
            }
        }
        return items
    }
}

enum AppFilePolicyError: LocalizedError, Equatable {
    case documentsDirectoryUnavailable
    case invalidName
    case outsideDocuments
    case destinationIsNotDirectory

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Documents directory not found."
        case .invalidName:
            return "Enter a valid name without slashes or path components."
        case .outsideDocuments:
            return "The selected location is outside Medio."
        case .destinationIsNotDirectory:
            return "Choose a valid folder."
        }
    }
}

/// Defines the only filesystem boundary the app is allowed to mutate.
struct AppFilePathPolicy {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    static func documents(fileManager: FileManager = .default) throws -> AppFilePathPolicy {
        guard let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AppFilePolicyError.documentsDirectoryUnavailable
        }
        return AppFilePathPolicy(rootURL: root, fileManager: fileManager)
    }

    func contains(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = rootURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    func validatedDirectory(_ url: URL, mustExist: Bool = true) throws -> URL {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(candidate) else { throw AppFilePolicyError.outsideDocuments }

        if mustExist {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AppFilePolicyError.destinationIsNotDirectory
            }
        }
        return candidate
    }

    func destination(in parent: URL, named rawName: String, isDirectory: Bool) throws -> URL {
        let parent = try validatedDirectory(parent)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidLeafName(name) else { throw AppFilePolicyError.invalidName }

        let destination = parent.appendingPathComponent(name, isDirectory: isDirectory).standardizedFileURL
        guard contains(destination), destination.deletingLastPathComponent().path == parent.path else {
            throw AppFilePolicyError.outsideDocuments
        }
        return destination
    }

    func stableIdentity(for url: URL) -> String {
        let candidate = url.standardizedFileURL
        guard contains(candidate) else { return candidate.path }
        if candidate.path == rootURL.path { return "medio://documents" }
        let relative = candidate.path.dropFirst(rootURL.path.count + 1)
        return "medio://documents/" + relative
    }

    func url(forStableIdentity identity: String) -> URL? {
        let prefix = "medio://documents"
        guard identity == prefix || identity.hasPrefix(prefix + "/") else {
            let url = URL(fileURLWithPath: identity).standardizedFileURL
            return contains(url) ? url : nil
        }
        let relative = identity == prefix ? "" : String(identity.dropFirst(prefix.count + 1))
        guard !relative.split(separator: "/").contains("..") else { return nil }
        let url = relative.isEmpty ? rootURL : rootURL.appendingPathComponent(relative)
        return contains(url) ? url.standardizedFileURL : nil
    }

    static func isValidLeafName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("/") else { return false }
        guard !name.contains("/"), !name.contains(":"), !name.contains("\0") else { return false }
        return name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

enum PersistedMediaPath {
    static func encode(_ path: String) -> String {
        guard !path.contains("://") else { return path }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return (try? AppFilePathPolicy.documents())?.stableIdentity(for: url) ?? url.path
    }

    static func decode(_ identity: String) -> String {
        guard identity.hasPrefix("medio://documents") else { return identity }
        return (try? AppFilePathPolicy.documents())?.url(forStableIdentity: identity)?.path ?? identity
    }

    static func lookupKeys(for path: String) -> [String] {
        let standardized = path.contains("://") ? path : URL(fileURLWithPath: path).standardizedFileURL.path
        let encoded = encode(standardized)
        return encoded == standardized ? [encoded] : [encoded, standardized]
    }
}

final class LibrarySearchTextIndex: @unchecked Sendable {
    static let shared = LibrarySearchTextIndex()
    private let lock = NSLock()
    private var itemText: [String: String] = [:]
    private var albumText: [String: String] = [:]
    private var artistText: [String: String] = [:]

    func rebuild(items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist]) {
        var nextItems: [String: String] = [:]
        for item in items + songs {
            nextItems[item.id] = [item.displayName, item.author ?? "", item.album ?? ""]
                .joined(separator: " ")
                .lowercased()
        }
        let nextAlbums = Dictionary(uniqueKeysWithValues: albums.map { album in
            let songText = album.songs.compactMap { nextItems[$0.id] }.joined(separator: " ")
            return (album.name, (album.name + " " + songText).lowercased())
        })
        let nextArtists = Dictionary(uniqueKeysWithValues: artists.map { artist in
            let songText = artist.songs.compactMap { nextItems[$0.id] }.joined(separator: " ")
            return (artist.name, (artist.name + " " + songText).lowercased())
        })
        lock.lock()
        itemText = nextItems
        albumText = nextAlbums
        artistText = nextArtists
        lock.unlock()
    }

    func fileMatches(id: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        return itemText[id]?.contains(query) == true
    }

    func albumMatches(name: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        return albumText[name]?.contains(query) == true
    }

    func artistMatches(name: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        return artistText[name]?.contains(query) == true
    }
}

struct FileOperationFailure: Error, Equatable {
    let source: URL
    let message: String
}

struct FileOperationBatchResult: Equatable {
    var completed: [URL] = []
    var failures: [FileOperationFailure] = []

    var isComplete: Bool { failures.isEmpty }
}

/// Serializes mutations and performs replacements through a sibling temporary file.
actor AppFileMutationCoordinator {
    static let shared = AppFileMutationCoordinator()

    func copyReplacingItem(at source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".medio-import-\(UUID().uuidString)")

        do {
            try fileManager.copyItem(at: source, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func copyItem(at source: URL, toUniqueDestinationIn directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = Self.uniqueDestinationURL(
            fileManager: fileManager,
            initial: directory.appendingPathComponent(source.lastPathComponent)
        )
        try copyReplacingItem(at: source, to: destination)
        return destination
    }

    func moveItem(at source: URL, toUniqueDestinationIn directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = Self.uniqueDestinationURL(
            fileManager: fileManager,
            initial: directory.appendingPathComponent(source.lastPathComponent)
        )
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    func importItems(_ sources: [URL], to directory: URL) -> FileOperationBatchResult {
        var result = FileOperationBatchResult()
        var seenSources = Set<String>()

        for source in sources {
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

            let standardizedSource = source.standardizedFileURL
            let duplicateKey = standardizedSource.path
            guard seenSources.insert(duplicateKey).inserted else { continue }
            guard Self.isImportableSource(standardizedSource),
                  AppFilePathPolicy.isValidLeafName(standardizedSource.lastPathComponent) else {
                result.failures.append(FileOperationFailure(source: source, message: "The item cannot be imported."))
                continue
            }

            do {
                let destination = try copyItem(at: standardizedSource, toUniqueDestinationIn: directory)
                result.completed.append(destination)
            } catch {
                result.failures.append(FileOperationFailure(source: source, message: error.localizedDescription))
            }
        }
        return result
    }

    private nonisolated static func isImportableSource(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".DS_Store" else { return false }
        guard name.localizedCaseInsensitiveCompare("Add music files here.txt") != .orderedSame else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated static func uniqueDestinationURL(fileManager: FileManager, initial: URL) -> URL {
        guard fileManager.fileExists(atPath: initial.path) else { return initial }
        let ext = initial.pathExtension
        let base = ext.isEmpty ? initial.lastPathComponent : initial.deletingPathExtension().lastPathComponent
        let parent = initial.deletingLastPathComponent()
        for index in 2...10_000 {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return parent.appendingPathComponent(UUID().uuidString)
    }
}

actor AppStartupCoordinator {
    private var didPrepare = false

    func prepareFileSystem() async {
        guard !didPrepare else { return }
        didPrepare = true
        let interval = AppPerformance.signposter.beginInterval("StartupMigrations")
        defer { AppPerformance.signposter.endInterval("StartupMigrations", interval) }
        let fileManager = FileManager.default

        do {
            guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw AppFilePolicyError.documentsDirectoryUnavailable
            }
            let markerURL = documentsURL.appendingPathComponent("Add music files here.txt")
            if fileManager.fileExists(atPath: markerURL.path) {
                try fileManager.removeItem(at: markerURL)
            }
            _ = try LyricsManagedStorage.ensureLyricsDirectoryExists(fileManager: fileManager)
            try LyricsManagedStorage.migrateFromApplicationSupportIfNeeded(fileManager: fileManager)

            if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                for name in ["medio-library-cache.v2.json", "medio-library-cache.v3.json"] {
                    let obsoleteCache = cachesURL.appendingPathComponent(name)
                    if fileManager.fileExists(atPath: obsoleteCache.path) {
                        try fileManager.removeItem(at: obsoleteCache)
                    }
                }
            }
        } catch {
            AppLog.files.error("Startup filesystem migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
