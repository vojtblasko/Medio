import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Filesystem-backed library repository.
///
/// Behavior:
/// - Loads a JSON cache synchronously first (fast startup).
/// - Kicks off a rescan of `Documents/` in the background and refreshes the cache for next launch.
/// - If no cache exists, does a full scan and writes the cache before returning.
protocol MediaLibraryRepository: LibraryRepository, MediaLibraryDataSource {
    func loadLibrary() async throws -> (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist])
}

struct DefaultMediaLibraryRepository: MediaLibraryRepository, MediaLibraryProgressDataSource, @unchecked Sendable {
    private static let scanCoordinator = MediaLibraryScanCoordinator()
    private let fileManager: FileManager
    private let documentsRootURL: URL?
    private let cacheStorageURL: URL?

    init(
        fileManager: FileManager = .default,
        documentsURL: URL? = nil,
        cacheURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.documentsRootURL = documentsURL
        self.cacheStorageURL = cacheURL
    }

    func loadLibrary() async throws -> (items: [FileInfo], songs: [FileInfo], albums: [ShadowAlbum], artists: [ShadowArtist]) {
        let indexer = BuildLibraryIndexUseCase()

        // Try to load cache quickly off the main thread.
        let cached = await Task.detached(priority: .utility) { () -> [FileInfo]? in
            return loadCachedItems()
        }.value

        if let cached = cached { return indexer.execute(cached) }

        // No cache: perform initial scan in background but await result since caller expects data.
        let scanned = try await Task.detached(priority: .userInitiated) { () -> [FileInfo] in
            return try await scanAndCacheItems()
        }.value

        return indexer.execute(scanned)
    }
}

// MARK: - Scan + metadata

extension DefaultMediaLibraryRepository {
    func loadCachedItems() -> [FileInfo]? {
        do {
            let url = try cacheFileURL()
            let items = try loadCache(from: url)
            let docsURL = try documentsURL()
            let docsPath = docsURL.standardizedFileURL.path
            return items.filter { item in
                let standardizedPath = URL(fileURLWithPath: item.id).standardizedFileURL.path
                guard standardizedPath.hasPrefix(docsPath + "/") else { return false }

                let relativePath = String(standardizedPath.dropFirst(docsPath.count)).lowercased()
                if relativePath == "/lyrics" || relativePath.hasPrefix("/lyrics/") { return false }
                if relativePath == "/users" || relativePath.hasPrefix("/users/") { return false }
                if relativePath == "/add music files here.txt" { return false }
                if hiddenLibraryFile(url: URL(fileURLWithPath: standardizedPath)) { return false }

                return !standardizedPath.isEmpty
            }
        } catch {
            AppLog.library.error("Library cache could not be loaded: \(error.localizedDescription, privacy: .public)")
            quarantineCorruptCache()
            return nil
        }
    }

    func cachedSnapshotDate() -> Date? {
        guard let url = try? cacheFileURL(),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    func scanAndCacheItems() async throws -> [FileInfo] {
        try await scanAndCacheItems(progress: nil)
    }

    func scanAndCacheItems(progress: LibraryScanProgressHandler?) async throws -> [FileInfo] {
        let interval = AppPerformance.signposter.beginInterval("LibraryRefresh")
        defer { AppPerformance.signposter.endInterval("LibraryRefresh", interval) }
        let scanKey = try documentsURL().resolvingSymlinksInPath().standardizedFileURL.path
        return try await Self.scanCoordinator.run(key: scanKey) {
            try await Task.detached(priority: .utility) {
                let cachedState = self.loadCacheState()
                let items = try await self.scanDocumentsWithIncrementalReuse(
                    progress: progress,
                    cachedRecords: cachedState?.records ?? []
                )
                let records = self.makeCacheRecords(items)
                let fingerprint = self.cacheFingerprint(records)
                if cachedState?.fingerprint != fingerprint || cachedState?.version != CachedLibraryEnvelope.currentVersion {
                    let url = try self.cacheFileURL()
                    try self.saveCache(records, fingerprint: fingerprint, to: url)
                }
                return items
            }.value
        }
    }

    func clearCache() throws {
        let url = try cacheFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private extension DefaultMediaLibraryRepository {
    func scanDocuments() async throws -> [FileInfo] {
        return try await scanDocumentsWithIncrementalReuse(progress: nil, cachedRecords: [])
    }

    // Incremental scan: reuse cached FileInfo when file attributes match; otherwise extract metadata.
    func scanDocumentsWithIncrementalReuse(
        progress: LibraryScanProgressHandler?,
        cachedRecords: [CachedFileRecord]
    ) async throws -> [FileInfo] {
        let docsURL = try documentsURL().standardizedFileURL
        let keys = FileMetadataReader.resourceKeys

        let cachedRecordsByPath = Dictionary(uniqueKeysWithValues: cachedRecords.map { ($0.fileInfo.id, $0) })

        let enumeration = try documentURLsRecursively(under: docsURL)
        let documentURLs = enumeration.urls
        for issue in enumeration.issues {
            AppLog.library.warning("Skipped unreadable library folder: \(issue.path, privacy: .private(mask: .hash)); \(issue.message, privacy: .public)")
        }
        var results: [FileInfo] = []
        results.reserveCapacity(documentURLs.count)
        await reportScanProgress(completed: 0, total: documentURLs.count, to: progress)
        let reportStride = max(1, documentURLs.count / 24)

        let maxConcurrentMetadataReads = 4
        await withTaskGroup(of: FileInfo?.self) { group in
            var nextIndex = 0
            let initialCount = min(maxConcurrentMetadataReads, documentURLs.count)
            for _ in 0..<initialCount {
                let url = documentURLs[nextIndex]
                nextIndex += 1
                group.addTask {
                    await self.scannedFileInfo(
                        for: url,
                        documentsURL: docsURL,
                        resourceKeys: keys,
                        cachedRecordsByPath: cachedRecordsByPath
                    )
                }
            }

            var completed = 0
            while let info = await group.next() {
                if let info { results.append(info) }
                completed += 1
                if completed == documentURLs.count || completed % reportStride == 0 {
                    await reportScanProgress(completed: completed, total: documentURLs.count, to: progress)
                }

                if nextIndex < documentURLs.count {
                    let url = documentURLs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await self.scannedFileInfo(
                            for: url,
                            documentsURL: docsURL,
                            resourceKeys: keys,
                            cachedRecordsByPath: cachedRecordsByPath
                        )
                    }
                }
            }
        }

        results.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }

        return results
    }

    func scannedFileInfo(
        for rawURL: URL,
        documentsURL docsURL: URL,
        resourceKeys keys: Set<URLResourceKey>,
        cachedRecordsByPath: [String: CachedFileRecord]
    ) async -> FileInfo? {
        let url = rawURL.standardizedFileURL
        if url.lastPathComponent == ".DS_Store" { return nil }
        if url.pathExtension.lowercased() == "json", url.lastPathComponent.hasPrefix("medio-library-cache") {
            return nil
        }
        if url.lastPathComponent.lowercased() == "add music files here.txt" {
            return nil
        }
        // Ensure URL is within Documents directory to prevent showing parent folders.
        guard url.path.hasPrefix(docsURL.path + "/") else { return nil }

        // Skip internal/system folders and files.
        let relativePath = String(url.path.dropFirst(docsURL.path.count))
        let lowerRelativePath = relativePath.lowercased()
        if lowerRelativePath.hasPrefix("/lyrics/") || lowerRelativePath == "/lyrics" {
            return nil
        }
        if lowerRelativePath.hasPrefix("/users/") || lowerRelativePath == "/users" {
            return nil
        }
        // Skip the root Documents directory itself to prevent showing parent folders.
        if relativePath.isEmpty || relativePath == "/" {
            return nil
        }

        let rv = try? url.resourceValues(forKeys: keys)
        let isDir = rv?.isDirectory ?? false

        if isDir {
            return FileMetadataReader.directoryInfo(for: url, resourceValues: rv)
        }

        if hiddenLibraryFile(url: url) {
            return nil
        }

        let path = url.path
        let modDate = rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = rv?.fileSize ?? 0
        let isMediaFile = isSupportedMediaFile(url: url, typeIdentifier: rv?.typeIdentifier)

        if let cached = cachedRecordsByPath[path],
           cached.modificationTime == modDate,
           cached.fileSize == fileSize,
           FileMetadataReader.cacheHasCurrentMetadata(cached.fileInfo) {
            return cached.fileInfo
        }

        if isMediaFile {
            return await fileInfo(forMediaURL: url, resourceValues: rv)
        }
        return FileMetadataReader.genericFileInfo(for: url, resourceValues: rv)
    }

    func reportScanProgress(
        completed: Int,
        total: Int,
        to progress: LibraryScanProgressHandler?
    ) async {
        guard let progress else { return }
        await progress(
            LibraryScanProgress(
                phase: .scanningFiles,
                completedItemCount: completed,
                totalItemCount: total
            )
        )
    }

    func documentURLsRecursively(under rootURL: URL) throws -> (urls: [URL], issues: [LibraryScanIssue]) {
        let enumerationKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey
        ]
        var urls: [URL] = []
        var issues: [LibraryScanIssue] = []
        try appendDocumentURLs(in: rootURL, to: &urls, issues: &issues, prefetching: enumerationKeys)
        return (urls, issues)
    }

    func appendDocumentURLs(
        in directoryURL: URL,
        to urls: inout [URL],
        issues: inout [LibraryScanIssue],
        prefetching keys: Set<URLResourceKey>
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        for child in children {
            urls.append(child)

            let values = try? child.resourceValues(forKeys: keys)
            guard values?.isDirectory == true, values?.isPackage != true else { continue }
            do {
                try appendDocumentURLs(in: child, to: &urls, issues: &issues, prefetching: keys)
            } catch {
                issues.append(LibraryScanIssue(path: child.path, message: error.localizedDescription))
            }
        }
    }

    func fileInfo(forMediaURL url: URL, resourceValues: URLResourceValues? = nil) async -> FileInfo {
        await FileMetadataReader.fileInfo(for: url, resourceValues: resourceValues)
    }

    func isSupportedMediaFile(url: URL, typeIdentifier: String?) -> Bool {
        FileMetadataReader.isSupportedMediaFile(url: url, typeIdentifier: typeIdentifier)
    }

    func hiddenLibraryFile(url: URL) -> Bool {
        false
    }
}

// MARK: - Cache

private extension DefaultMediaLibraryRepository {
    func cacheFileURL() throws -> URL {
        if let cacheStorageURL { return cacheStorageURL }
        let base = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("medio-library-cache.v4.json", isDirectory: false)
    }

    func loadCache(from url: URL) throws -> [FileInfo] {
        let data = try Data(contentsOf: url)
        if let envelope = try? JSONDecoder().decode(CachedLibraryEnvelope.self, from: data) {
            guard envelope.version == CachedLibraryEnvelope.currentVersion else {
                throw NSError(
                    domain: "MediaLibraryRepository.Cache",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported library cache version \(envelope.version)."]
                )
            }
            return envelope.records.map(\.fileInfo)
        }
        // support older cache format which was an array of FileInfo
        if let decoded = try? JSONDecoder().decode([FileInfo].self, from: data) {
            return decoded
        }

        // new format: array of CachedFileRecord
        let records = try JSONDecoder().decode([CachedFileRecord].self, from: data)
        return records.map { $0.fileInfo }
    }

    func loadCacheState() -> CachedLibraryEnvelope? {
        guard let url = try? cacheFileURL(), let data = try? Data(contentsOf: url) else { return nil }
        if let envelope = try? JSONDecoder().decode(CachedLibraryEnvelope.self, from: data) {
            return envelope
        }
        if let records = try? JSONDecoder().decode([CachedFileRecord].self, from: data) {
            return CachedLibraryEnvelope(version: 3, fingerprint: cacheFingerprint(records), records: records)
        }
        return nil
    }

    func makeCacheRecords(_ items: [FileInfo]) -> [CachedFileRecord] {
        var records: [CachedFileRecord] = []
        records.reserveCapacity(items.count)
        for fi in items {
            var modTime = fi.fileModificationDate?.timeIntervalSince1970 ?? 0
            var size = fi.fileSizeBytes ?? 0
            if !fi.isDirectory {
                if (modTime == 0 || size == 0),
                   let attributes = try? fileManager.attributesOfItem(atPath: fi.id) {
                    if modTime == 0, let date = attributes[.modificationDate] as? Date {
                        modTime = date.timeIntervalSince1970
                    }
                    if size == 0, let bytes = attributes[.size] as? Int {
                        size = bytes
                    }
                }
            }
            records.append(CachedFileRecord(fileInfo: fi, modificationTime: modTime, fileSize: size))
        }
        return records
    }

    func saveCache(_ records: [CachedFileRecord], fingerprint: UInt64, to url: URL) throws {
        let envelope = CachedLibraryEnvelope(
            version: CachedLibraryEnvelope.currentVersion,
            fingerprint: fingerprint,
            records: records
        )
        let data = try JSONEncoder().encode(envelope)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    func cacheFingerprint(_ records: [CachedFileRecord]) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        func combine(_ text: String) {
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
        }
        for record in records.sorted(by: { $0.fileInfo.id < $1.fileInfo.id }) {
            combine(record.fileInfo.id)
            combine(String(record.modificationTime))
            combine(String(record.fileSize))
            combine(record.fileInfo.displayName)
            combine(record.fileInfo.author ?? "")
            combine(record.fileInfo.album ?? "")
        }
        return value
    }

    func quarantineCorruptCache() {
        guard let url = try? cacheFileURL(), fileManager.fileExists(atPath: url.path) else { return }
        let quarantine = url.deletingLastPathComponent().appendingPathComponent("medio-library-cache.corrupt.\(UUID().uuidString).json")
        do {
            try fileManager.moveItem(at: url, to: quarantine)
        } catch {
            AppLog.library.error("Corrupt cache could not be quarantined: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Documents

private extension DefaultMediaLibraryRepository {
    func documentsURL() throws -> URL {
        if let documentsRootURL { return documentsRootURL }
        guard let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "MediaLibraryRepository", code: 1, userInfo: [NSLocalizedDescriptionKey: "Documents directory not found."])
        }
        return url
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// Cached record stored on disk to support incremental scanning
private struct CachedFileRecord: Codable, Sendable {
    let fileInfo: FileInfo
    let modificationTime: TimeInterval
    let fileSize: Int
}

private struct CachedLibraryEnvelope: Codable, Sendable {
    static let currentVersion = 4
    let version: Int
    let fingerprint: UInt64
    let records: [CachedFileRecord]
}

private struct LibraryScanIssue: Sendable {
    let path: String
    let message: String
}

private actor MediaLibraryScanCoordinator {
    private var inFlight: [String: Task<[FileInfo], Error>] = [:]

    func run(
        key: String,
        _ operation: @escaping @Sendable () async throws -> [FileInfo]
    ) async throws -> [FileInfo] {
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
