import UIKit
import Foundation
import Combine
import OSLog
import CryptoKit
import ImageIO

enum OnlineFeature: String, CaseIterable, Identifiable, Sendable {
    case artistLookup, imageMetadata, imageDownloads
    var id: String { rawValue }
    var title: String {
        switch self {
        case .artistLookup: String(localized: "Artist Lookup (MusicBrainz)")
        case .imageMetadata: String(localized: "Image & License Lookup (Wikimedia)")
        case .imageDownloads: String(localized: "Artist Image Downloads")
        }
    }
}

@MainActor
final class OnlineAccessStore: ObservableObject {
    static let shared = OnlineAccessStore()
    @Published var masterEnabled = false
    @Published private(set) var disabledFeatures: Set<String>
    @Published private(set) var transferredBytes: [String: Int64]
    @Published private(set) var trackingSince: Date
    private let defaults: UserDefaults
    private static let disabledKey = "medio.online.disabledFeatures"
    private static let usageKey = "medio.online.transferredBytes"
    private static let sinceKey = "medio.online.trackingSince"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledFeatures = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        let stored = defaults.dictionary(forKey: Self.usageKey) ?? [:]
        transferredBytes = stored.compactMapValues { ($0 as? NSNumber)?.int64Value }
        trackingSince = defaults.object(forKey: Self.sinceKey) as? Date ?? Date()
        defaults.set(trackingSince, forKey: Self.sinceKey)
    }

    func isEnabled(_ feature: OnlineFeature) -> Bool { !disabledFeatures.contains(feature.rawValue) }
    func allows(_ feature: OnlineFeature) -> Bool { masterEnabled && isEnabled(feature) }
    func setEnabled(_ enabled: Bool, for feature: OnlineFeature) {
        if enabled { disabledFeatures.remove(feature.rawValue) } else { disabledFeatures.insert(feature.rawValue) }
        defaults.set(Array(disabledFeatures), forKey: Self.disabledKey)
    }
    func record(bytes: Int64, for feature: OnlineFeature) {
        guard bytes > 0 else { return }
        transferredBytes[feature.rawValue, default: 0] += bytes
        defaults.set(transferredBytes, forKey: Self.usageKey)
    }
    func resetUsage() {
        transferredBytes = [:]
        trackingSince = Date()
        defaults.removeObject(forKey: Self.usageKey)
        defaults.set(trackingSince, forKey: Self.sinceKey)
    }
}

/// Counts actual HTTP traffic (including retries/redirects), excluding local cache hits.
private final class OnlineUsageTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let feature: OnlineFeature
    init(feature: OnlineFeature) { self.feature = feature }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let bytes = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }.reduce(Int64(0)) { total, metric in
            total + max(0, metric.countOfRequestHeaderBytesSent) + max(0, metric.countOfRequestBodyBytesSent)
                + max(0, metric.countOfResponseHeaderBytesReceived) + max(0, metric.countOfResponseBodyBytesReceived)
        }
        let feature = feature
        Task { @MainActor in OnlineAccessStore.shared.record(bytes: bytes, for: feature) }
    }
}

protocol ArtistProfileRepository: Sendable {
    func getImage(for artistName: String) -> UIImage?
    func setImage(_ image: UIImage?, for artistName: String)
    func cachedImageCount() -> Int
    func clearAllImages()
}

extension ArtistProfileRepository {
    func loadImage(for artistName: String) async -> UIImage? {
        await Task.detached(priority: .utility) {
            getImage(for: artistName)
        }.value
    }

    func storeImage(_ image: UIImage?, for artistName: String) async {
        await Task.detached(priority: .utility) {
            setImage(image, for: artistName)
        }.value
    }
}

protocol OnlineArtistImageRepository: Sendable {
    func fetchImage(for artistName: String) async -> UIImage?
}

enum ArtistProfileLookupPolicy {
    static func canFetchOnlineImage(for artistName: String) -> Bool {
        let normalized = artistName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return false }
        return normalized != "unknown" && normalized != "unknown artist"
    }
}

enum ArtistIdentityPolicy {
    static func namesMatch(_ artistName: String, candidateName: String?) -> Bool {
        let wanted = normalizedNameVariants(for: artistName)
        let candidate = normalizedNameVariants(for: candidateName ?? "")
        guard !wanted.isEmpty, !candidate.isEmpty else { return false }
        return !wanted.isDisjoint(with: candidate)
    }

    static func textLooksLikeMusicArtist(_ text: String) -> Bool {
        let normalized = normalizedSearchText(text)
        let musicTerms = [
            "singer",
            "songwriter",
            "musician",
            "band",
            "rapper",
            "composer",
            "dj",
            "vocalist",
            "instrumentalist",
            "music producer",
            "recording artist",
            "musical artist",
            "musical group",
            "music group",
            "music duo",
            "music trio",
            "electronic music",
            "hip hop group",
            "pop group",
            "rock group",
            "orchestra",
            "choir",
            "disc jockey",
            "record producer",
            "girl group",
            "boy band",
            "vocal group",
            "jazz ensemble"
        ]
        return musicTerms.contains { containsTerm($0, in: normalized) }
    }

    private static func normalizedNameVariants(for name: String) -> Set<String> {
        let normalized = normalizedSearchText(name)
        guard !normalized.isEmpty else { return [] }

        var variants: Set<String> = [normalized]
        if normalized.hasPrefix("the ") {
            variants.insert(String(normalized.dropFirst(4)))
        } else {
            variants.insert("the \(normalized)")
        }
        return variants
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func containsTerm(_ term: String, in text: String) -> Bool {
        let pattern = "\\b" + term
            .split(separator: " ")
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+") + "\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ArtistProfileDebugLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.medio.vojtblasko",
        category: "ArtistImage"
    )

    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = "[ArtistImage] \(message())"
        print(text)
        logger.notice("\(text, privacy: .public)")
        #endif
    }

    static func urlSummary(_ url: URL) -> String {
        let queryNames = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .map(\.name)
            .joined(separator: ",") ?? ""
        let queryText = queryNames.isEmpty ? "" : "?\(queryNames)"
        return "\(url.host ?? "?")\(url.path)\(queryText)"
    }

    static func errorSummary(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.code.rawValue) \(urlError.code)"
        }
        return error.localizedDescription
    }
}

actor ArtistProfileImageFetchGate {
    static let shared = ArtistProfileImageFetchGate()

    private var isBusy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !isBusy {
            isBusy = true
            ArtistProfileDebugLog.write("fetch gate acquired immediately")
            return
        }

        ArtistProfileDebugLog.write("fetch gate waiting behind \(waiters.count + 1) request(s)")
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
        ArtistProfileDebugLog.write("fetch gate acquired after wait")
    }

    func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            ArtistProfileDebugLog.write("fetch gate released")
            return
        }
        ArtistProfileDebugLog.write("fetch gate handing off to next request")
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

actor ArtistProfileImageLoader {
    static let shared = ArtistProfileImageLoader()

    private let profileRepository: ArtistProfileRepository
    private let onlineRepository: OnlineArtistImageRepository
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private let retryDelay: TimeInterval = 30

    init(
        profileRepository: ArtistProfileRepository = UserDefaultsArtistProfileRepository.shared,
        onlineRepository: OnlineArtistImageRepository = WikimediaPublicDomainArtistImageRepository.shared
    ) {
        self.profileRepository = profileRepository
        self.onlineRepository = onlineRepository
    }

    func image(for artistName: String, canFetchOnline: Bool) async -> UIImage? {
        if let cached = await profileRepository.loadImage(for: artistName) {
            ArtistProfileDebugLog.write("cache hit artist='\(artistName)'")
            return cached
        }
        guard canFetchOnline else {
            ArtistProfileDebugLog.write("skip artist='\(artistName)' reason=internet-disabled")
            return nil
        }
        guard ArtistProfileLookupPolicy.canFetchOnlineImage(for: artistName) else {
            ArtistProfileDebugLog.write("skip artist='\(artistName)' reason=unknown-artist")
            return nil
        }

        let key = UserDefaultsArtistProfileRepository.storageKey(for: artistName)
        if let failedDate = failedAt[key], Date().timeIntervalSince(failedDate) < retryDelay {
            ArtistProfileDebugLog.write("skip artist='\(artistName)' reason=recent-failure secondsAgo=\(Int(Date().timeIntervalSince(failedDate)))")
            return nil
        }
        if let existingTask = inFlight[key] {
            ArtistProfileDebugLog.write("join in-flight artist='\(artistName)'")
            return await existingTask.value
        }

        let profileRepository = self.profileRepository
        let onlineRepository = self.onlineRepository
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            ArtistProfileDebugLog.write("fetch queued artist='\(artistName)'")
            do {
                try await ArtistProfileImageFetchGate.shared.acquire()
            } catch {
                return nil
            }
            let fetchedImage = await onlineRepository.fetchImage(for: artistName)
            await ArtistProfileImageFetchGate.shared.release()

            guard let image = fetchedImage else {
                ArtistProfileDebugLog.write("fetch finished artist='\(artistName)' result=no-image")
                return nil
            }
            await profileRepository.storeImage(image, for: artistName)
            ArtistProfileDebugLog.write("fetch finished artist='\(artistName)' result=saved")
            return image
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil
        if image == nil {
            failedAt[key] = Date()
        } else {
            failedAt[key] = nil
        }
        return image
    }
}

final class UserDefaultsArtistProfileRepository: ArtistProfileRepository, @unchecked Sendable {
    static let shared = UserDefaultsArtistProfileRepository()
    private let legacyKey = "medio_artist_profiles"
    private let defaults: UserDefaults
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, UIImage>()
    private let migrationLock = NSLock()
    private var didMigrate = false

    init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil) {
        self.defaults = defaults
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let base = (try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = base.appendingPathComponent("Medio/ArtistProfiles", isDirectory: true)
        }
        memoryCache.countLimit = 32
    }

    func getImage(for artistName: String) -> UIImage? {
        migrateLegacyImagesIfNeeded()
        let storageKey = Self.storageKey(for: artistName)
        if let cached = memoryCache.object(forKey: storageKey as NSString) { return cached }
        guard let data = try? Data(contentsOf: imageURL(forStorageKey: storageKey)),
              let image = UIImage(data: data) else { return nil }
        memoryCache.setObject(image, forKey: storageKey as NSString, cost: data.count)
        return image
    }

    func setImage(_ image: UIImage?, for artistName: String) {
        migrateLegacyImagesIfNeeded()
        let storageKey = Self.storageKey(for: artistName)
        let url = imageURL(forStorageKey: storageKey)
        if let image, let data = image.jpegData(compressionQuality: 0.8) {
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                memoryCache.setObject(image, forKey: storageKey as NSString, cost: data.count)
            } catch {
                AppLog.persistence.error("Artist image could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            memoryCache.removeObject(forKey: storageKey as NSString)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                AppLog.persistence.error("Artist image could not be removed: \(error.localizedDescription, privacy: .public)")
            }
        }
        NotificationCenter.default.post(
            name: .medioArtistProfileImagesDidChange,
            object: self,
            userInfo: ["artist": artistName, "artistKey": storageKey]
        )
    }

    func cachedImageCount() -> Int {
        migrateLegacyImagesIfNeeded()
        return ((try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "jpg" }.count
    }

    func clearAllImages() {
        memoryCache.removeAllObjects()
        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        } catch {
            AppLog.persistence.error("Artist image cache could not be cleared: \(error.localizedDescription, privacy: .public)")
        }
        defaults.removeObject(forKey: legacyKey)
        NotificationCenter.default.post(name: .medioArtistProfileImagesDidChange, object: self)
    }

    private func migrateLegacyImagesIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !didMigrate else { return }
        didMigrate = true
        guard let data = defaults.data(forKey: legacyKey),
              let images = try? JSONDecoder().decode([String: Data].self, from: data) else { return }

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            for (name, imageData) in images {
                try imageData.write(
                    to: imageURL(forStorageKey: Self.storageKey(for: name)),
                    options: [.atomic]
                )
            }
            defaults.removeObject(forKey: legacyKey)
        } catch {
            AppLog.persistence.error("Artist image migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func imageURL(forStorageKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest).appendingPathExtension("jpg")
    }

    static func storageKey(for artistName: String) -> String {
        artistName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

struct ArtistImageLicensePolicy {
    static func allows(licenseText: String, licenseURL: String = "", shortName: String = "") -> Bool {
        let joinedText = [licenseText, licenseURL, shortName]
            .map(normalized)
            .joined(separator: " ")

        guard !containsRestrictedLicenseMarker(joinedText) else { return false }

        return joinedText.contains("cc0")
            || joinedText.contains("public domain")
            || joinedText.contains("/publicdomain/zero/1.0")
            || joinedText.contains("/publicdomain/mark/1.0")
            || joinedText.contains("creative commons attribution-share alike")
            || joinedText.contains("creative commons attribution share alike")
            || joinedText.contains("creative commons attribution")
            || joinedText.contains("cc by-sa")
            || joinedText.contains("cc-by-sa")
            || joinedText.contains("cc by ")
            || joinedText.contains("cc-by ")
            || joinedText.contains("creativecommons.org/licenses/by/")
            || joinedText.contains("creativecommons.org/licenses/by-sa/")
            || joinedText.contains("gnu free documentation license")
            || joinedText.contains("gfdl")
            || joinedText.contains("free art license")
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func containsRestrictedLicenseMarker(_ value: String) -> Bool {
        value.contains("noncommercial")
            || value.contains("non-commercial")
            || value.contains("by-nc")
            || value.contains("by nc")
            || value.contains("no derivative")
            || value.contains("no-derivative")
            || value.contains("nonderivative")
            || value.contains("by-nd")
            || value.contains("by nd")
            || value.contains("fair use")
            || value.contains("all rights reserved")
    }
}

actor MusicBrainzRateLimiter {
    static let shared = MusicBrainzRateLimiter()
    private var lastRequestDate: Date?

    func waitForTurn() async {
        if Task.isCancelled { return }
        if let lastRequestDate {
            let elapsed = Date().timeIntervalSince(lastRequestDate)
            let delay = 1.1 - elapsed
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
        lastRequestDate = Date()
    }
}

final class WikimediaPublicDomainArtistImageRepository: OnlineArtistImageRepository, @unchecked Sendable {
    static let shared = WikimediaPublicDomainArtistImageRepository()

    private let session: URLSession
    private let musicBrainzRateLimiter: MusicBrainzRateLimiter
    private let userAgent: String
    private let requestAllowed: @Sendable (OnlineFeature) async -> Bool

    init(session: URLSession? = nil, musicBrainzRateLimiter: MusicBrainzRateLimiter = .shared,
         requestAllowed: @escaping @Sendable (OnlineFeature) async -> Bool = { feature in
             await MainActor.run { OnlineAccessStore.shared.allows(feature) }
         }) {
        self.requestAllowed = requestAllowed
        self.session = session ?? Self.defaultSession
        self.musicBrainzRateLimiter = musicBrainzRateLimiter
        let bundleID = Bundle.main.bundleIdentifier ?? "com.medio.vojtblasko"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        self.userAgent = "Medio/\(version) (\(bundleID); local iOS music library artist image lookup)"
    }

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    func fetchImage(for artistName: String) async -> UIImage? {
        let trimmed = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ArtistProfileDebugLog.write("online lookup skipped empty artist name")
            return nil
        }

        ArtistProfileDebugLog.write("online lookup started artist='\(trimmed)'")
        DiagnosticsCenter.recordInternet("Started online artist image search for '\(trimmed)'.")

        var candidates = await wikidataEntityCandidates(for: trimmed)
        candidates.append(contentsOf: await musicBrainzCandidates(for: trimmed))
        candidates = uniqueCandidates(candidates)
        ArtistProfileDebugLog.write("artist='\(trimmed)' candidates=\(candidates.map(\.debugDescription).joined(separator: " | "))")

        for candidate in candidates where !Task.isCancelled {
            ArtistProfileDebugLog.write("artist='\(trimmed)' trying \(candidate.debugDescription)")
            if let image = await fetchImage(from: candidate) {
                ArtistProfileDebugLog.write("artist='\(trimmed)' success via \(candidate.debugDescription)")
                DiagnosticsCenter.recordInternet("Artist image search succeeded for '\(trimmed)' using \(candidate.debugDescription).")
                return image
            }
            ArtistProfileDebugLog.write("artist='\(trimmed)' no image via \(candidate.debugDescription)")
        }
        ArtistProfileDebugLog.write("artist='\(trimmed)' failed all candidates")
        DiagnosticsCenter.recordInternet("Artist image search finished without an image for '\(trimmed)'.")
        return nil
    }

    private func fetchImage(from candidate: WikimediaImageCandidate) async -> UIImage? {
        do {
            switch candidate {
            case .commonsFile(let title):
                return await fetchImageForCommonsFile(title)
            case .commonsCategory(let title):
                guard let url = categoryURL(forTitle: title) else { return nil }
                let response = try await decoded(WikimediaSearchResponse.self, from: url, service: .wikimedia)
                return await firstLicensedImage(in: response)
            case .wikidataEntity(let entityID):
                guard let imageTitle = try await wikidataImageTitle(for: entityID) else { return nil }
                return await fetchImageForCommonsFile(imageTitle)
            case .wikipediaPage(let host, let title):
                guard let entityID = try await wikidataEntityID(fromWikipediaHost: host, title: title) else { return nil }
                return await fetchImage(from: .wikidataEntity(entityID))
            }
        } catch {
            ArtistProfileDebugLog.write("candidate failed \(candidate.debugDescription) error=\(ArtistProfileDebugLog.errorSummary(error))")
            return nil
        }
    }

    private func fetchImageForCommonsFile(_ title: String) async -> UIImage? {
        guard let url = imageInfoURL(forTitle: title) else {
            ArtistProfileDebugLog.write("commons file='\(title)' no action-api url, falling back to core API")
            return await fetchImageThroughWikimediaCoreAPI(fileTitle: title)
        }

        do {
            let response = try await decoded(WikimediaSearchResponse.self, from: url, service: .wikimedia)
            guard let imageInfo = response.firstImageInfo else {
                ArtistProfileDebugLog.write("commons file='\(title)' missing imageinfo, falling back to core API")
                return await fetchImageThroughWikimediaCoreAPI(fileTitle: title)
            }
            guard imageInfo.isSupportedRasterImage, licensePasses(imageInfo.extmetadata) else {
                ArtistProfileDebugLog.write("commons file='\(title)' rejected mime='\(imageInfo.mime ?? "unknown")' license='\(imageInfo.licenseDebugText)'")
                return nil
            }
            if let image = await fetchRasterImage(from: imageInfo) {
                return image
            }
            ArtistProfileDebugLog.write("commons file='\(title)' action-api raster download failed, falling back to core API")
        } catch {
            // Commons action API can fail independently from the core file API.
            // Keep structured artist-image candidates alive instead of giving up.
            ArtistProfileDebugLog.write("commons file='\(title)' action-api failed error=\(ArtistProfileDebugLog.errorSummary(error)), falling back to core API")
        }

        return await fetchImageThroughWikimediaCoreAPI(fileTitle: title)
    }

    private func wikidataEntityCandidates(for artistName: String) async -> [WikimediaImageCandidate] {
        guard let searchURL = wikidataEntitySearchURL(for: artistName) else {
            ArtistProfileDebugLog.write("wikidata candidates artist='\(artistName)' skipped invalid search url")
            return []
        }
        do {
            let response = try await decoded(WikidataEntitySearchResponse.self, from: searchURL, service: .wikimedia)
            let candidates = response.search
                .filter { result in
                    guard ArtistIdentityPolicy.namesMatch(artistName, candidateName: result.label) else { return false }
                    return ArtistIdentityPolicy.textLooksLikeMusicArtist(result.description ?? "")
                }
                .prefix(4)
                .map { WikimediaImageCandidate.wikidataEntity($0.id) }
            ArtistProfileDebugLog.write("wikidata candidates artist='\(artistName)' count=\(candidates.count)")
            return candidates
        } catch {
            ArtistProfileDebugLog.write("wikidata candidates artist='\(artistName)' failed error=\(ArtistProfileDebugLog.errorSummary(error))")
            return []
        }
    }

    private func musicBrainzCandidates(for artistName: String) async -> [WikimediaImageCandidate] {
        guard let searchURL = musicBrainzSearchURL(for: artistName) else {
            ArtistProfileDebugLog.write("musicbrainz candidates artist='\(artistName)' skipped invalid search url")
            return []
        }
        do {
            let search = try await decoded(MusicBrainzArtistSearchResponse.self, from: searchURL, service: .musicBrainz)
            let artists = search.artists
                .filter { artist in
                    guard let score = artist.score else { return true }
                    return score >= 75
                }
                .filter { artist in
                    ArtistIdentityPolicy.namesMatch(artistName, candidateName: artist.name)
                }
                .prefix(3)

            var candidates: [WikimediaImageCandidate] = []
            for artist in artists where !Task.isCancelled {
                guard let lookupURL = musicBrainzArtistLookupURL(id: artist.id) else { continue }
                let detail = try await decoded(MusicBrainzArtistLookupResponse.self, from: lookupURL, service: .musicBrainz)
                candidates.append(contentsOf: candidatesFromMusicBrainzRelations(detail.relations ?? []))
            }
            let unique = uniqueCandidates(candidates)
            ArtistProfileDebugLog.write("musicbrainz candidates artist='\(artistName)' artists=\(artists.count) candidates=\(unique.count)")
            return unique
        } catch {
            ArtistProfileDebugLog.write("musicbrainz candidates artist='\(artistName)' failed error=\(ArtistProfileDebugLog.errorSummary(error))")
            return []
        }
    }

    private func uniqueCandidates(_ candidates: [WikimediaImageCandidate]) -> [WikimediaImageCandidate] {
        var seen: Set<WikimediaImageCandidate> = []
        var result: [WikimediaImageCandidate] = []
        for candidate in candidates where seen.insert(candidate).inserted {
            result.append(candidate)
        }
        return result
    }

    private func candidatesFromMusicBrainzRelations(_ relations: [MusicBrainzURLRelation]) -> [WikimediaImageCandidate] {
        relations.compactMap { relation in
            guard let resource = relation.url?.resource else { return nil }
            return candidate(fromResourceURLString: resource)
        }
    }

    private func candidate(fromResourceURLString resource: String) -> WikimediaImageCandidate? {
        guard let url = URL(string: resource),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }

        if host == "commons.wikimedia.org" {
            guard let title = wikiTitle(fromPath: components.percentEncodedPath) else { return nil }
            if title.localizedCaseInsensitiveContains("File:") {
                return .commonsFile(title.normalizedWikiTitle(prefix: "File"))
            }
            if title.localizedCaseInsensitiveContains("Category:") {
                return .commonsCategory(title.normalizedWikiTitle(prefix: "Category"))
            }
        }

        if host == "www.wikidata.org" || host == "wikidata.org" {
            let entityID = components.percentEncodedPath.split(separator: "/").last.map(String.init) ?? ""
            guard entityID.hasPrefix("Q") else { return nil }
            return .wikidataEntity(entityID)
        }

        if host.hasSuffix(".wikipedia.org"),
           let title = wikiTitle(fromPath: components.percentEncodedPath) {
            return .wikipediaPage(host: host, title: title)
        }

        return nil
    }

    private func firstLicensedImage(in response: WikimediaSearchResponse) async -> UIImage? {
        let pages = response.query?.pages?.values.sorted { lhs, rhs in
            (lhs.index ?? Int.max) < (rhs.index ?? Int.max)
        } ?? []

        for page in pages where !Task.isCancelled {
            guard let imageInfo = page.imageinfo?.first else {
                ArtistProfileDebugLog.write("search page='\(page.title)' skipped reason=missing-imageinfo")
                continue
            }
            guard imageInfo.isSupportedRasterImage else {
                ArtistProfileDebugLog.write("search page='\(page.title)' skipped reason=unsupported-mime mime='\(imageInfo.mime ?? "unknown")'")
                continue
            }
            guard licensePasses(imageInfo.extmetadata) else {
                ArtistProfileDebugLog.write("search page='\(page.title)' skipped reason=license license='\(imageInfo.licenseDebugText)'")
                continue
            }
            guard let image = await fetchRasterImage(from: imageInfo) else {
                ArtistProfileDebugLog.write("search page='\(page.title)' skipped reason=raster-download-failed")
                continue
            }
            return image
        }
        return nil
    }

    private func fetchRasterImage(from imageInfo: WikimediaImageInfo) async -> UIImage? {
        guard let rawImageURL = imageInfo.thumburl ?? imageInfo.url else {
            ArtistProfileDebugLog.write("raster image skipped reason=missing-url")
            return nil
        }
        guard let imageURL = URL(string: rawImageURL) else {
            ArtistProfileDebugLog.write("raster image skipped reason=invalid-url raw='\(rawImageURL)'")
            return nil
        }
        guard imageURL.isSupportedRasterImageURL else {
            ArtistProfileDebugLog.write("raster image skipped reason=unsupported-url url=\(ArtistProfileDebugLog.urlSummary(imageURL))")
            return nil
        }

        do {
            let imageData = try await requestData(from: imageURL, service: .wikimedia)
            guard let image = Self.downsampledImage(from: imageData) else {
                ArtistProfileDebugLog.write("raster image decode failed bytes=\(imageData.count) url=\(ArtistProfileDebugLog.urlSummary(imageURL))")
                return nil
            }
            ArtistProfileDebugLog.write("raster image decoded bytes=\(imageData.count) url=\(ArtistProfileDebugLog.urlSummary(imageURL))")
            return image
        } catch {
            ArtistProfileDebugLog.write("raster image request failed url=\(ArtistProfileDebugLog.urlSummary(imageURL)) error=\(ArtistProfileDebugLog.errorSummary(error))")
            return nil
        }
    }

    private func fetchImageThroughWikimediaCoreAPI(fileTitle: String) async -> UIImage? {
        guard let url = wikimediaCoreFileURL(forTitle: fileTitle) else {
            ArtistProfileDebugLog.write("core api file='\(fileTitle)' skipped invalid url")
            return nil
        }
        do {
            let response = try await decoded(WikimediaCoreFileResponse.self, from: url, service: .wikimedia)
            guard let rawImageURL = response.bestRasterURL else {
                ArtistProfileDebugLog.write("core api file='\(fileTitle)' skipped reason=no-bitmap-rendition")
                return nil
            }
            guard let imageURL = URL(string: rawImageURL) else {
                ArtistProfileDebugLog.write("core api file='\(fileTitle)' skipped invalid image url raw='\(rawImageURL)'")
                return nil
            }
            guard imageURL.isSupportedRasterImageURL else {
                ArtistProfileDebugLog.write("core api file='\(fileTitle)' skipped unsupported url=\(ArtistProfileDebugLog.urlSummary(imageURL))")
                return nil
            }
            let imageData = try await requestData(from: imageURL, service: .wikimedia)
            guard let image = Self.downsampledImage(from: imageData) else {
                ArtistProfileDebugLog.write("core api file='\(fileTitle)' decode failed bytes=\(imageData.count)")
                return nil
            }
            ArtistProfileDebugLog.write("core api file='\(fileTitle)' decoded bytes=\(imageData.count)")
            return image
        } catch {
            ArtistProfileDebugLog.write("core api file='\(fileTitle)' failed error=\(ArtistProfileDebugLog.errorSummary(error))")
            return nil
        }
    }

    private func wikidataEntitySearchURL(for artistName: String) -> URL? {
        let trimmed = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "limit", value: "5")
        ]
        return components?.url
    }

    private func categoryURL(forTitle title: String) -> URL? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "maxlag", value: "5"),
            URLQueryItem(name: "generator", value: "categorymembers"),
            URLQueryItem(name: "gcmtitle", value: title.normalizedWikiTitle(prefix: "Category")),
            URLQueryItem(name: "gcmtype", value: "file"),
            URLQueryItem(name: "gcmlimit", value: "12"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "640")
        ]
        return components?.url
    }

    private func imageInfoURL(forTitle title: String) -> URL? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "maxlag", value: "5"),
            URLQueryItem(name: "titles", value: title.normalizedWikiTitle(prefix: "File")),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "640")
        ]
        return components?.url
    }

    private func wikimediaCoreFileURL(forTitle title: String) -> URL? {
        let normalizedTitle = title.normalizedWikiTitle(prefix: "File")
        let fileName = String(normalizedTitle.dropFirst("File:".count))
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/")
        guard let encodedFileName = fileName.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }
        return URL(string: "https://api.wikimedia.org/core/v1/commons/file/\(encodedFileName)")
    }

    private func musicBrainzSearchURL(for artistName: String) -> URL? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(artistName)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3")
        ]
        return components?.url
    }

    private func musicBrainzArtistLookupURL(id: String) -> URL? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "url-rels")
        ]
        return components?.url
    }

    private func wikidataImageTitle(for entityID: String) async throws -> String? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetclaims"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "maxlag", value: "5"),
            URLQueryItem(name: "entity", value: entityID),
            URLQueryItem(name: "property", value: "P18")
        ]
        guard let url = components?.url else { return nil }
        let response = try await decoded(WikidataClaimsResponse.self, from: url, service: .wikimedia)
        guard let fileName = response.claims?["P18"]?.first?.mainsnak?.datavalue?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileName.isEmpty else { return nil }
        return "File:\(fileName)"
    }

    private func wikidataEntityID(fromWikipediaHost host: String, title: String) async throws -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/w/api.php"
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "maxlag", value: "5"),
            URLQueryItem(name: "prop", value: "pageprops"),
            URLQueryItem(name: "ppprop", value: "wikibase_item"),
            URLQueryItem(name: "titles", value: title)
        ]
        guard let url = components.url else { return nil }
        let response = try await decoded(WikimediaSearchResponse.self, from: url, service: .wikimedia)
        return response.query?.pages?.values.compactMap { $0.pageprops?.wikibaseItem }.first
    }

    private func wikiTitle(fromPath percentEncodedPath: String) -> String? {
        let prefix = "/wiki/"
        guard percentEncodedPath.hasPrefix(prefix) else { return nil }
        let rawTitle = String(percentEncodedPath.dropFirst(prefix.count))
        return rawTitle.removingPercentEncoding?
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func decoded<T: Decodable>(_ type: T.Type, from url: URL, service: ArtistImageNetworkService) async throws -> T {
        let data = try await requestData(from: url, service: service)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestData(from url: URL, service: ArtistImageNetworkService) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let wantsJSON = url.path.hasSuffix("/w/api.php") || url.host == "api.wikimedia.org" || service == .musicBrainz
        request.setValue(wantsJSON ? "application/json" : "*/*", forHTTPHeaderField: "Accept")
        let feature: OnlineFeature = service == .musicBrainz ? .artistLookup : (wantsJSON ? .imageMetadata : .imageDownloads)

        let summary = ArtistProfileDebugLog.urlSummary(url)
        var lastError: Error?
        for attempt in 0..<3 {
            if service == .musicBrainz {
                await musicBrainzRateLimiter.waitForTurn()
            }
            try Task.checkCancellation()
            guard await requestAllowed(feature) else { throw URLError(.notConnectedToInternet) }
            ArtistProfileDebugLog.write("request attempt=\(attempt + 1) service=\(service.debugName) url=\(summary)")
            DiagnosticsCenter.recordInternet("Request attempt \(attempt + 1) | service=\(service.debugName) | url=\(summary)")
            do {
                let (data, response) = try await session.data(for: request, delegate: OnlineUsageTaskDelegate(feature: feature))
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    ArtistProfileDebugLog.write("request http-failed attempt=\(attempt + 1) service=\(service.debugName) status=\(http.statusCode) url=\(summary)")
                    DiagnosticsCenter.recordInternet("HTTP failure | service=\(service.debugName) | status=\(http.statusCode) | url=\(summary)")
                    throw URLError(.badServerResponse)
                }
                let maximumBytes = wantsJSON ? 2_000_000 : 12_000_000
                guard data.count <= maximumBytes else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                ArtistProfileDebugLog.write("request success attempt=\(attempt + 1) service=\(service.debugName) bytes=\(data.count) url=\(summary)")
                let status = ((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "unknown"
                DiagnosticsCenter.recordInternet("Downloaded response | service=\(service.debugName) | status=\(status) | bytes=\(data.count) | url=\(summary)")
                return data
            } catch {
                if Task.isCancelled { throw error }
                ArtistProfileDebugLog.write("request failed attempt=\(attempt + 1) service=\(service.debugName) url=\(summary) error=\(ArtistProfileDebugLog.errorSummary(error))")
                DiagnosticsCenter.recordInternet("Request failed | service=\(service.debugName) | url=\(summary) | error=\(ArtistProfileDebugLog.errorSummary(error))")
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64((0.35 * Double(attempt + 1)) * 1_000_000_000))
                }
            }
        }
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    private func licensePasses(_ metadata: [String: WikimediaMetadataValue]?) -> Bool {
        let values = metadata ?? [:]
        let text = values
            .values
            .compactMap(\.value)
            .map(Self.plainLicenseText)
            .joined(separator: " ")
            .lowercased()
        let licenseURL = Self.plainLicenseText(values["LicenseUrl"]?.value ?? "").lowercased()
        let shortName = Self.plainLicenseText(values["LicenseShortName"]?.value ?? "").lowercased()

        guard !text.contains("noncommercial"),
              !text.contains("no derivative"),
              !text.contains("fair use") else { return false }

        return ArtistImageLicensePolicy.allows(
            licenseText: text,
            licenseURL: licenseURL,
            shortName: shortName
        )
    }

    private static func plainLicenseText(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func downsampledImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

}

private struct WikimediaSearchResponse: Decodable {
    let query: WikimediaQuery?
}

private struct WikimediaQuery: Decodable {
    let pages: [String: WikimediaPage]?
}

private struct WikimediaPage: Decodable {
    let index: Int?
    let title: String
    let imageinfo: [WikimediaImageInfo]?
    let pageprops: WikimediaPageProps?

    enum CodingKeys: String, CodingKey {
        case index
        case title
        case imageinfo
        case pageprops
    }
}

private struct WikimediaImageInfo: Decodable {
    let url: String?
    let thumburl: String?
    let mime: String?
    let extmetadata: [String: WikimediaMetadataValue]?
}

private struct WikimediaCoreFileResponse: Decodable {
    let preferred: WikimediaCoreFileRendition?
    let thumbnail: WikimediaCoreFileRendition?
    let original: WikimediaCoreFileRendition?
}

private struct WikimediaCoreFileRendition: Decodable {
    let mediatype: String?
    let url: String?
}

private struct WikimediaMetadataValue: Decodable {
    let value: String?

    enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringValue = try? container.decode(String.self, forKey: .value) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self, forKey: .value) {
            value = String(intValue)
        } else if let doubleValue = try? container.decode(Double.self, forKey: .value) {
            value = String(doubleValue)
        } else if let boolValue = try? container.decode(Bool.self, forKey: .value) {
            value = String(boolValue)
        } else {
            value = nil
        }
    }
}

private struct WikimediaPageProps: Decodable {
    let wikibaseItem: String?

    enum CodingKeys: String, CodingKey {
        case wikibaseItem = "wikibase_item"
    }
}

private struct WikidataClaimsResponse: Decodable {
    let claims: [String: [WikidataClaim]]?
}

private struct WikidataEntitySearchResponse: Decodable {
    let search: [WikidataEntitySearchResult]
}

private struct WikidataEntitySearchResult: Decodable {
    let id: String
    let label: String?
    let description: String?
}

private struct WikidataClaim: Decodable {
    let mainsnak: WikidataSnak?
}

private struct WikidataSnak: Decodable {
    let datavalue: WikidataDataValue?
}

private struct WikidataDataValue: Decodable {
    let value: String?
}

private struct MusicBrainzArtistSearchResponse: Decodable {
    let artists: [MusicBrainzSearchArtist]
}

private struct MusicBrainzSearchArtist: Decodable {
    let id: String
    let name: String?
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let intScore = try? container.decode(Int.self, forKey: .score) {
            score = intScore
        } else if let stringScore = try? container.decode(String.self, forKey: .score) {
            score = Int(stringScore)
        } else {
            score = nil
        }
    }
}

private struct MusicBrainzArtistLookupResponse: Decodable {
    let relations: [MusicBrainzURLRelation]?
}

private struct MusicBrainzURLRelation: Decodable {
    let type: String?
    let url: MusicBrainzRelationURL?
}

private struct MusicBrainzRelationURL: Decodable {
    let resource: String?
}

private enum WikimediaImageCandidate: Hashable {
    case commonsFile(String)
    case commonsCategory(String)
    case wikidataEntity(String)
    case wikipediaPage(host: String, title: String)
}

private enum ArtistImageNetworkService {
    case musicBrainz
    case wikimedia
}

private extension WikimediaImageCandidate {
    var debugDescription: String {
        switch self {
        case .commonsFile(let title):
            return "commonsFile(\(title))"
        case .commonsCategory(let title):
            return "commonsCategory(\(title))"
        case .wikidataEntity(let entityID):
            return "wikidataEntity(\(entityID))"
        case .wikipediaPage(let host, let title):
            return "wikipediaPage(\(host)/\(title))"
        }
    }
}

private extension ArtistImageNetworkService {
    var debugName: String {
        switch self {
        case .musicBrainz:
            return "musicbrainz"
        case .wikimedia:
            return "wikimedia"
        }
    }
}

private extension WikimediaSearchResponse {
    var firstImageInfo: WikimediaImageInfo? {
        let pages = query?.pages?.values.sorted { lhs, rhs in
            (lhs.index ?? Int.max) < (rhs.index ?? Int.max)
        } ?? []
        return pages.compactMap { $0.imageinfo?.first }.first
    }
}

private extension WikimediaImageInfo {
    var isSupportedRasterImage: Bool {
        if let mime = mime?.lowercased(), !mime.isEmpty {
            return Self.supportedRasterMimeTypes.contains(mime)
        }
        guard let rawImageURL = url ?? thumburl,
              let imageURL = URL(string: rawImageURL) else {
            return false
        }
        return imageURL.isSupportedRasterImageURL
    }

    var licenseDebugText: String {
        extmetadata?["LicenseShortName"]?.value
            ?? extmetadata?["License"]?.value
            ?? extmetadata?["UsageTerms"]?.value
            ?? "unknown"
    }

    private static let supportedRasterMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp"
    ]
}

private extension WikimediaCoreFileResponse {
    var bestRasterURL: String? {
        [preferred, thumbnail, original]
            .compactMap { $0 }
            .first { $0.isBitmap }?
            .url
    }
}

private extension WikimediaCoreFileRendition {
    var isBitmap: Bool {
        mediatype?.uppercased() == "BITMAP"
    }
}

private extension URL {
    var isSupportedRasterImageURL: Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.hasSuffix(".jpg")
            || lowercasedPath.hasSuffix(".jpeg")
            || lowercasedPath.hasSuffix(".png")
            || lowercasedPath.hasSuffix(".webp")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func normalizedWikiTitle(prefix: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedPrefix = "\(prefix):"
        if trimmed.range(of: wantedPrefix, options: [.caseInsensitive, .anchored]) != nil {
            return trimmed
        }
        let components = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        if components.count == 2, ["file", "category"].contains(components[0].lowercased()) {
            return "\(wantedPrefix)\(components[1])"
        }
        return "\(wantedPrefix)\(trimmed)"
    }
}
