@preconcurrency import SwiftUI
import AVFoundation
import UIKit

enum MedioLayoutMetrics {
    static let pageControlHorizontalInset: CGFloat = 20
}

@available(iOS 26.0, *)
extension View {
    @ViewBuilder
    func glassButtonStyle() -> some View {
        self
            .buttonStyle(.glassProminent)
            .glassEffect(.regular)
    }
}

extension View {
    func medioAppChrome() -> some View {
        tint(.primary)
    }
    
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func glassButtonStyleFallback() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.82))
    }
    
    @ViewBuilder
    func glassButtonStyleCompat() -> some View {
        if #available(iOS 26.0, *) {
            self.glassButtonStyle()
        } else {
            self.glassButtonStyleFallback()
        }
    }
    
    @ViewBuilder
    func glassMiniplayer() -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            self
        }
    }

    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.tint(tint), in: shape)
        } else {
            self
                .background(.thinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Artwork Cache

@MainActor
final class ArtworkCache: ObservableObject {
    static let shared = ArtworkCache()

    private let images = NSCache<NSString, UIImage>()
    private var misses: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var preloadQueue: [String] = []
    private var preloadQueued: Set<String> = []
    private var activePreloadCount = 0
    private var accessOrder: [String] = []
    private var folderPreviewIndexInitialized = false
    private var folderPreviewPaths: [String: [String]] = [:]
    private let maxCachedImages = 72
    private let maxConcurrentPreloads = 2
    private let missRetryInterval: TimeInterval = 30
    private var memoryWarningObserver: NSObjectProtocol?
    private var lowPowerMode: Bool = false

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.trimCache(to: 16)
            }
        }
        images.countLimit = maxCachedImages
        images.totalCostLimit = 48 * 1_024 * 1_024
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setLowPowerMode(_ enabled: Bool) {
        lowPowerMode = enabled
        if enabled {
            trimCache(to: 8)
        }
    }

    func image(for path: String) -> UIImage? {
        if lowPowerMode {
            return nil
        }
        if let cached = images.object(forKey: path as NSString) {
            touch(path)
            return cached
        }
        guard !hasRecentMiss(for: path), !inFlight.contains(path) else { return nil }
        if preloadQueued.contains(path) {
            preloadQueue.removeAll { $0 == path }
        } else {
            preloadQueued.insert(path)
        }
        // Visible artwork gets priority but still shares the bounded decode queue.
        preloadQueue.insert(path, at: 0)
        startQueuedPreloadsIfNeeded()
        return nil
    }

    func preload(_ paths: [String]) {
        guard !lowPowerMode else { return }
        for path in paths {
            if images.object(forKey: path as NSString) != nil
                || hasRecentMiss(for: path)
                || inFlight.contains(path)
                || preloadQueued.contains(path) {
                continue
            }
            preloadQueue.append(path)
            preloadQueued.insert(path)
        }
        startQueuedPreloadsIfNeeded()
    }

    func retry(_ paths: [String]) {
        invalidate(paths)
        preload(paths)
    }

    func folderImages(for folderPath: String, librarySongs: [FileInfo]) -> [UIImage] {
        if !folderPreviewIndexInitialized {
            updateFolderPreviews(for: librarySongs)
        }
        let children = folderPreviewPaths[URL(fileURLWithPath: folderPath).standardizedFileURL.path] ?? []
        var result: [UIImage] = []
        for childPath in children.prefix(3) {
            if let img = image(for: childPath) { result.append(img) }
        }
        return result
    }

    /// Rebuild once when the library changes. Folder cells call `folderImages` frequently as
    /// artwork arrives, so deriving a signature from every song in every cell does not scale.
    func updateFolderPreviews(for librarySongs: [FileInfo]) {
        rebuildFolderPreviewIndex(librarySongs: librarySongs)
        folderPreviewIndexInitialized = true
    }

    func clear() {
        images.removeAllObjects()
        misses.removeAll()
        inFlight.removeAll()
        preloadQueue.removeAll()
        preloadQueued.removeAll()
        accessOrder.removeAll()
        folderPreviewIndexInitialized = false
        folderPreviewPaths.removeAll()
        NotificationCenter.default.post(name: .medioArtworkCacheDidChange, object: self)
    }

    func invalidate(_ paths: [String]) {
        let keys = Set(paths.flatMap { path -> [String] in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return path == standardized ? [path] : [path, standardized]
        })
        guard !keys.isEmpty else { return }

        for key in keys {
            images.removeObject(forKey: key as NSString)
            misses.removeValue(forKey: key)
            inFlight.remove(key)
            preloadQueued.remove(key)
            accessOrder.removeAll { $0 == key }
            postArtworkChange(for: key)
        }
        preloadQueue.removeAll { keys.contains($0) }
    }

    private func startQueuedPreloadsIfNeeded() {
        while activePreloadCount < maxConcurrentPreloads, !preloadQueue.isEmpty {
            let path = preloadQueue.removeFirst()
            preloadQueued.remove(path)
            guard images.object(forKey: path as NSString) == nil, !hasRecentMiss(for: path), !inFlight.contains(path) else {
                continue
            }

            activePreloadCount += 1
            inFlight.insert(path)
            Task {
                let image = await Self.extractArtwork(for: path)
                if let image {
                    self.store(Self.prepareForCache(image), for: path)
                } else {
                    self.recordMiss(for: path)
                }
                self.inFlight.remove(path)
                self.activePreloadCount -= 1
                self.startQueuedPreloadsIfNeeded()
            }
        }
    }

    nonisolated static func extractArtwork(for path: String) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            if path.lowercased().hasSuffix(".flac") {
                if let img = extractFLACArtworkManually(for: path) {
                    return img
                }
            }
            if let img = await extractAVFoundationArtwork(for: path) {
                return img
            }
            if FileMetadataReader.videoExtensions.contains(fileExtension) {
                return extractVideoFrameArtwork(for: path)
            }
            return nil
        }.value
    }

    private nonisolated static func extractFLACArtworkManually(for path: String) -> UIImage? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        // A FLAC file can have an ID3 prefix. Only inspect the prefix for the marker instead of
        // loading the entire audio file into memory just to read its metadata blocks.
        let prefixLimit = 1_048_576
        guard let prefix = try? handle.read(upToCount: prefixLimit),
              let marker = prefix.range(of: Data("fLaC".utf8)) else {
            return nil
        }

        var offset = UInt64(marker.upperBound)
        var fallbackImageData: Data?
        while true {
            do {
                try handle.seek(toOffset: offset)
            } catch {
                return nil
            }
            guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else { break }
            let header = headerData[headerData.startIndex]
            let isLastBlock = (header & 0x80) != 0
            let blockType = header & 0x7F
            let blockLength = (Int(headerData[headerData.startIndex + 1]) << 16)
                | (Int(headerData[headerData.startIndex + 2]) << 8)
                | Int(headerData[headerData.startIndex + 3])
            offset += 4
            if blockType == 6 {
                guard let block = try? handle.read(upToCount: blockLength), block.count == blockLength else {
                    return nil
                }
                if let picture = parseFLACPictureBlock(block[...]) {
                    if picture.type == 3, let image = UIImage(data: picture.data) {
                        return image
                    }
                    fallbackImageData = fallbackImageData ?? picture.data
                }
            }
            offset += UInt64(blockLength)
            if isLastBlock { break }
        }
        if let fallbackImageData {
            return UIImage(data: fallbackImageData)
        }
        return nil
    }

    private nonisolated static func parseFLACPictureBlock(_ block: Data.SubSequence) -> (type: UInt32, data: Data)? {
        var cursor = block.startIndex
        func readUInt32() -> UInt32? {
            guard cursor + 4 <= block.endIndex else { return nil }
            let value = (UInt32(block[cursor]) << 24)
                | (UInt32(block[cursor + 1]) << 16)
                | (UInt32(block[cursor + 2]) << 8)
                | UInt32(block[cursor + 3])
            cursor += 4
            return value
        }
        func skip(_ length: Int) -> Bool {
            guard length >= 0, cursor + length <= block.endIndex else { return false }
            cursor += length
            return true
        }
        guard let pictureType = readUInt32(),
              let mimeLength = readUInt32(),
              skip(Int(mimeLength)),
              let descriptionLength = readUInt32(),
              skip(Int(descriptionLength)),
              skip(16),
              let imageLength = readUInt32(),
              cursor + Int(imageLength) <= block.endIndex else {
            return nil
        }
        return (pictureType, Data(block[cursor..<(cursor + Int(imageLength))]))
    }

    private func store(_ image: UIImage, for path: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        images.setObject(image, forKey: path as NSString, cost: cost)
        misses.removeValue(forKey: path)
        touch(path)
        trimCache(to: maxCachedImages)
        postArtworkChange(for: path)
    }

    private func recordMiss(for path: String) {
        misses[path] = Date()
    }

    private func hasRecentMiss(for path: String) -> Bool {
        guard let missedAt = misses[path] else { return false }
        if Date().timeIntervalSince(missedAt) < missRetryInterval {
            return true
        }
        misses.removeValue(forKey: path)
        return false
    }

    private func touch(_ path: String) {
        if let existingIndex = accessOrder.firstIndex(of: path) {
            accessOrder.remove(at: existingIndex)
        }
        accessOrder.append(path)
    }

    private func trimCache(to targetCount: Int) {
        guard targetCount >= 0 else { return }
        while accessOrder.count > targetCount {
            let evictedPath = accessOrder.removeFirst()
            images.removeObject(forKey: evictedPath as NSString)
        }
    }

    private func postArtworkChange(for path: String) {
        let affectedFolders = folderPreviewPaths.compactMap { folder, children in
            children.contains(path) ? folder : nil
        }
        NotificationCenter.default.post(
            name: .medioArtworkCacheDidChange,
            object: self,
            userInfo: ["path": path, "folders": affectedFolders]
        )
    }

    private func rebuildFolderPreviewIndex(librarySongs: [FileInfo]) {
        var index: [String: [String]] = [:]
        var albumKeysByFolder: [String: Set<String>] = [:]
        for song in librarySongs where !song.isDirectory {
            let songPath = URL(fileURLWithPath: song.id).standardizedFileURL.path
            let albumKey = folderPreviewAlbumKey(for: song, songPath: songPath)
            var folder = URL(fileURLWithPath: songPath).deletingLastPathComponent().standardizedFileURL
            while !folder.path.isEmpty && folder.path != "/" {
                let folderPath = folder.path
                var previews = index[folderPath] ?? []
                var albumKeys = albumKeysByFolder[folderPath] ?? []
                if previews.count < 3, !albumKeys.contains(albumKey) {
                    previews.append(songPath)
                    albumKeys.insert(albumKey)
                    index[folderPath] = previews
                    albumKeysByFolder[folderPath] = albumKeys
                }
                folder.deleteLastPathComponent()
            }
        }
        folderPreviewPaths = index
    }

    private func folderPreviewAlbumKey(for song: FileInfo, songPath: String) -> String {
        if let album = normalizedFolderPreviewValue(song.album) {
            return "album:\(album)"
        }
        let parentPath = URL(fileURLWithPath: songPath).deletingLastPathComponent().standardizedFileURL.path
        return "folder:\(parentPath)"
    }

    private func normalizedFolderPreviewValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated private static func prepareForCache(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 320
        let largestSide = max(image.size.width, image.size.height)
        guard largestSide > maxDimension, largestSide > 0 else { return image }
        let scale = maxDimension / largestSide
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private nonisolated static func extractAVFoundationArtwork(for path: String) async -> UIImage? {
        do {
            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let commonMetadata = try await asset.load(.commonMetadata)
            let formatMetadata = try await asset.load(.metadata)
            for item in commonMetadata + formatMetadata {
                guard isArtworkMetadataItem(item) else { continue }
                if let data = try? await item.load(.dataValue), let img = imageFromArtworkData(data) {
                    return img
                }
                if let value = try? await item.load(.value), let img = imageFromArtworkValue(value) {
                    return img
                }
            }
        } catch {}
        return nil
    }

    private nonisolated static func isArtworkMetadataItem(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyArtwork {
            return true
        }

        let rawValues = [
            item.identifier?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { String(describing: $0) }
        ]
        .compactMap { $0?.lowercased() }

        return rawValues.contains { value in
            value.contains("artwork")
                || value.contains("attachedpicture")
                || value.contains("apic")
                || value.contains("covr")
                || value.contains("pic")
        }
    }

    private nonisolated static func imageFromArtworkValue(_ value: Any?) -> UIImage? {
        switch value {
        case let image as UIImage:
            return image
        case let data as Data:
            return imageFromArtworkData(data)
        case let data as NSData:
            return imageFromArtworkData(data as Data)
        case let string as String:
            guard let data = Data(base64Encoded: string) else { return nil }
            return imageFromArtworkData(data)
        case let dictionary as [String: Any]:
            for nestedValue in dictionary.values {
                if let image = imageFromArtworkValue(nestedValue) {
                    return image
                }
            }
            return nil
        case let array as [Any]:
            for nestedValue in array {
                if let image = imageFromArtworkValue(nestedValue) {
                    return image
                }
            }
            return nil
        default:
            return nil
        }
    }

    private nonisolated static func imageFromArtworkData(_ data: Data) -> UIImage? {
        if let image = UIImage(data: data) {
            return image
        }

        let signatures: [Data] = [
            Data([0xFF, 0xD8, 0xFF]),
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ]

        for signature in signatures {
            if let range = data.range(of: signature) {
                return UIImage(data: Data(data[range.lowerBound..<data.endIndex]))
            }
        }

        if let webpRange = data.range(of: Data("WEBP".utf8)), webpRange.lowerBound >= 8 {
            let riffStart = webpRange.lowerBound - 8
            if riffStart + 4 <= data.count,
               String(data: data[riffStart..<(riffStart + 4)], encoding: .ascii) == "RIFF" {
                return UIImage(data: Data(data[riffStart..<data.endIndex]))
            }
        }

        return nil
    }

    private nonisolated static func extractVideoFrameArtwork(for path: String) -> UIImage? {
        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            let image = try generator.copyCGImage(
                at: CMTime(seconds: 0.35, preferredTimescale: 600),
                actualTime: nil
            )
            return UIImage(cgImage: image)
        } catch {
            return nil
        }
    }
}

// MARK: - Reusable Row Components

struct NowPlayingAudioVisualizer: View {
    var isPlaying: Bool
    var levels: [Double]
    var color: Color = .accentColor
    var size = CGSize(width: 24, height: 24)

    private var barSpacing: CGFloat { max(1, size.width * 0.045) }
    private var barWidth: CGFloat {
        max(1, (size.width - CGFloat(PlaybackAudioLevels.barCount - 1) * barSpacing) / CGFloat(PlaybackAudioLevels.barCount))
    }

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<PlaybackAudioLevels.barCount, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: size.height * CGFloat(level(at: index)))
                    .animation(.easeOut(duration: 0.10), value: level(at: index))
            }
        }
        // Each bar's two halves grow equally away from the horizontal centre line.
        .frame(width: size.width, height: size.height, alignment: .center)
        .accessibilityHidden(true)
    }

    private func level(at index: Int) -> Double {
        guard isPlaying, levels.indices.contains(index), levels[index].isFinite else { return 0.15 }
        return min(1, max(0.15, levels[index]))
    }
}

struct NowPlayingAudioVisualizerArtwork: View {
    var isPlaying: Bool
    var levels: [Double] = PlaybackAudioLevels.resting
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
            NowPlayingAudioVisualizer(
                isPlaying: isPlaying,
                levels: levels,
                color: .accentColor,
                size: CGSize(width: size * 0.56, height: size * 0.62)
            )
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .accessibilityLabel(isPlaying ? "Now playing" : "Paused")
    }
}

enum PlaybackIndicatorScope: Int, CaseIterable, Identifiable {
    case songs = 1, albums = 2, artists = 4
    static let key = "medio.settings.playbackIndicatorScopes"
    static let all = 7
    var id: Int { rawValue }
    var title: String { switch self { case .songs: String(localized: "Songs"); case .albums: String(localized: "Albums"); case .artists: String(localized: "Artists") } }
}

struct PlaybackIndicatorSettingsSection: View {
    @AppStorage(PlaybackIndicatorScope.key) private var scopes = PlaybackIndicatorScope.all
    var body: some View {
        Section("Playback Indicators") {
            HStack {
                Button("All") { scopes = PlaybackIndicatorScope.all }
                Spacer()
                Button("None") { scopes = 0 }
            }.buttonStyle(.borderless)
            ForEach(PlaybackIndicatorScope.allCases) { scope in
                Button { scopes ^= scope.rawValue } label: {
                    HStack {
                        Text(scope.title).foregroundStyle(.primary)
                        Spacer()
                        if scopes & scope.rawValue != 0 { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityValue(scopes & scope.rawValue != 0 ? "Selected" : "Not selected")
                .accessibilityIdentifier("settings_indicator_\(scope.title.lowercased())")
            }
            Text("Show the audio spectrum in place of artwork for the current song, its album, or its artist.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PlaybackQueueProgressModifier: ViewModifier {
    let path: String
    @EnvironmentObject private var playbackStore: PlaybackStore
    func body(content: Content) -> some View {
        content.opacity(playbackStore.pastQueueItemIDs.contains(path) ? 0.5 : 1)
    }
}

extension View {
    func playbackQueueProgress(for path: String) -> some View { modifier(PlaybackQueueProgressModifier(path: path)) }
}

struct MediaItemRow: View {
    let item: FileInfo
    let librarySongs: [FileInfo]
    @EnvironmentObject private var playbackStore: PlaybackStore
    @State private var visualOverride: VisualMetadataOverride? = nil

    private var displayName: String {
        visualOverride?.title ?? item.displayName
    }

    private var displayArtist: String {
        visualOverride?.artist ?? item.author ?? ""
    }

    @AppStorage(PlaybackIndicatorScope.key) private var indicatorScopes = PlaybackIndicatorScope.all

    private var showsNowPlayingVisualizer: Bool {
        indicatorScopes & PlaybackIndicatorScope.songs.rawValue != 0 && item.fileType == .music && playbackStore.nowPlaying?.id == item.id
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            artworkThumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.isDirectory, !displayArtist.isEmpty {
                    Text(displayArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .playbackQueueProgress(for: item.id)
        .onAppear(perform: loadOverride)
        .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { notification in
            guard let changedPath = notification.userInfo?["path"] as? String else {
                loadOverride()
                return
            }
            if changedPath == item.id {
                loadOverride()
            }
        }
    }

    private func loadOverride() {
        visualOverride = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: item.id)
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if MedioShadowFolder.isFavorites(item.id) {
            FavoriteFolderArtworkView()
        } else if item.isDirectory {
            FolderArtworkView(path: item.id, librarySongs: librarySongs)
        } else if showsNowPlayingVisualizer {
            NowPlayingAudioVisualizerArtwork(
                isPlaying: playbackStore.isPlaying,
                levels: playbackStore.audioLevels
            )
        } else if item.fileType == .music || item.fileType == .video {
            SongArtworkView(path: item.id)
        } else {
            Image(systemName: item.fileType == .lyrics ? "music.note.list" : "doc")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct FavoriteFolderArtworkView: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.yellow)
        .frame(width: 44, height: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.systemGray5)))
    }
}

struct FavoritePriorityArtworkView: View {
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: max(17, size * 0.5), weight: .bold))
            .foregroundStyle(.yellow)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.systemGray5)))
    }
}

/// Preserve the complete source artwork, including portrait and landscape covers.
struct MediaCoverArtwork: View {
    let image: UIImage
    var contentMode: ContentMode = .fit

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: contentMode)
    }
}

struct SongArtworkView: View {
    let path: String
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 6
    var fallbackSystemImage: String = "music.note"
    var artworkCache: ArtworkCache = .shared
    @State private var visualOverride: VisualMetadataOverride? = nil
    @State private var cachedArtwork: UIImage?

    private var customArtwork: UIImage? {
        VisualArtworkOverrideStore.image(at: visualOverride?.coverArtworkPath)
    }

    var body: some View {
        Group {
            if let img = customArtwork {
                MediaCoverArtwork(image: img, contentMode: .fill)
            } else if let img = cachedArtwork {
                MediaCoverArtwork(image: img, contentMode: .fill)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: max(14, size * 0.32), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color(.systemGray5)))
        .onAppear {
            loadOverride()
            cachedArtwork = artworkCache.image(for: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioArtworkCacheDidChange)) { notification in
            guard notification.userInfo?["path"] as? String == path else { return }
            cachedArtwork = artworkCache.image(for: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { notification in
            guard let changedPath = notification.userInfo?["path"] as? String else {
                loadOverride()
                return
            }
            if changedPath == path {
                loadOverride()
            }
        }
    }

    private func loadOverride() {
        visualOverride = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: path)
    }
}

struct FolderArtworkView: View {
    let path: String
    let librarySongs: [FileInfo]
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 6
    var artworkCache: ArtworkCache = .shared
    @State private var visualOverride: VisualMetadataOverride? = nil
    @State private var artworkRevision = 0

    private var childImages: [UIImage] {
        artworkCache.folderImages(for: path, librarySongs: librarySongs)
    }

    private var customArtwork: UIImage? {
        VisualArtworkOverrideStore.image(at: visualOverride?.coverArtworkPath)
    }

    private var folderTint: Color {
        if let rgba = visualOverride?.folderColorRgba {
            return Color(uiColor: UIColor(hexRGBA: rgba))
        }
        return .blue
    }

    private var folderBackground: Color {
        if visualOverride?.folderColorRgba != nil {
            return folderTint.opacity(0.16)
        }
        return Color(.systemGray5)
    }

    var body: some View {
        Group {
            if let img = customArtwork {
                Image(uiImage: img)
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if visualOverride?.folderColorRgba != nil || childImages.isEmpty {
                Image(systemName: "folder.fill")
                    .font(.system(size: max(16, size * 0.45)))
                    .foregroundStyle(folderTint)
            } else if childImages.count == 1 {
                Image(uiImage: childImages[0])
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                collage(images: childImages)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .background(RoundedRectangle(cornerRadius: cornerRadius).fill(folderBackground))
        .onAppear(perform: loadOverride)
        .onReceive(NotificationCenter.default.publisher(for: .medioArtworkCacheDidChange)) { notification in
            let folders = notification.userInfo?["folders"] as? [String] ?? []
            if folders.contains(URL(fileURLWithPath: path).standardizedFileURL.path) {
                artworkRevision &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { notification in
            guard let changedPath = notification.userInfo?["path"] as? String else {
                loadOverride()
                return
            }
            if changedPath == path {
                loadOverride()
            }
        }
    }

    @ViewBuilder
    private func collage(images: [UIImage]) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                VStack(spacing: 1) {
                    Image(uiImage: images[0])
                        .interpolation(.high)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: (geo.size.width - 1) / 2, height: images.count > 2 ? (geo.size.height - 1) / 2 : geo.size.height)
                        .clipped()
                    if images.count > 2 {
                        Image(uiImage: images[2])
                            .interpolation(.high)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: (geo.size.width - 1) / 2, height: (geo.size.height - 1) / 2)
                            .clipped()
                    }
                }
                if images.count > 1 {
                    Image(uiImage: images[1])
                        .interpolation(.high)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: (geo.size.width - 1) / 2)
                        .clipped()
                }
            }
        }
    }

    private func loadOverride() {
        visualOverride = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: path)
    }
}

struct AlbumRow: View {
    let album: ShadowAlbum
    @EnvironmentObject private var playbackStore: PlaybackStore
    @AppStorage(PlaybackIndicatorScope.key) private var indicatorScopes = PlaybackIndicatorScope.all

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if indicatorScopes & PlaybackIndicatorScope.albums.rawValue != 0,
               album.songs.contains(where: { $0.id == playbackStore.nowPlaying?.id }) {
                NowPlayingAudioVisualizerArtwork(isPlaying: playbackStore.isPlaying, levels: playbackStore.audioLevels)
            } else if let firstSong = album.songs.first {
                SongArtworkView(path: firstSong.id)
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(localizedMediaPlaceholder(album.name))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "\(album.songs.count) songs"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ArtistRow: View {
    let artist: ShadowArtist
    @EnvironmentObject private var playbackStore: PlaybackStore
    @AppStorage(PlaybackIndicatorScope.key) private var indicatorScopes = PlaybackIndicatorScope.all
    var canFetchProfileImage = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if indicatorScopes & PlaybackIndicatorScope.artists.rawValue != 0,
               artist.songs.contains(where: { $0.id == playbackStore.nowPlaying?.id }) {
                NowPlayingAudioVisualizerArtwork(isPlaying: playbackStore.isPlaying, levels: playbackStore.audioLevels)
            } else {
                ArtistProfileArtworkView(artistName: artist.name, canFetchOnline: canFetchProfileImage)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(localizedMediaPlaceholder(artist.name))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "\(artist.songs.count) songs"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ArtistProfileArtworkView: View {
    let artistName: String
    var canFetchOnline = false
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: max(16, size * 0.38), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(artistName)|\(canFetchOnline)") {
            await fetchOnlineImageIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioArtistProfileImagesDidChange)) { notification in
            guard let changedKey = notification.userInfo?["artistKey"] as? String else {
                Task { await reloadImage() }
                return
            }
            if changedKey == UserDefaultsArtistProfileRepository.storageKey(for: artistName) {
                Task { await reloadImage() }
            }
        }
    }

    private func reloadImage() async {
        image = await ArtistProfileImageLoader.shared.image(for: artistName, canFetchOnline: false)
    }

    @MainActor
    private func fetchOnlineImageIfNeeded() async {
        await reloadImage()
        let hasCachedImage = image != nil
        ArtistProfileDebugLog.write("artwork view artist='\(artistName)' canFetchOnline=\(canFetchOnline) cached=\(hasCachedImage)")
        guard canFetchOnline else {
            ArtistProfileDebugLog.write("artwork view artist='\(artistName)' did-not-fetch reason=internet-disabled")
            return
        }
        guard ArtistProfileLookupPolicy.canFetchOnlineImage(for: artistName) else {
            ArtistProfileDebugLog.write("artwork view artist='\(artistName)' did-not-fetch reason=unknown-artist")
            return
        }
        guard image == nil else {
            ArtistProfileDebugLog.write("artwork view artist='\(artistName)' did-not-fetch reason=cached")
            return
        }
        guard let fetchedImage = await ArtistProfileImageLoader.shared.image(for: artistName, canFetchOnline: canFetchOnline),
              !Task.isCancelled else { return }
        image = fetchedImage
    }
}

/// Localize only Medio's placeholder names; user metadata remains verbatim.
func localizedMediaPlaceholder(_ value: String) -> String {
    switch value {
    case "Unknown Artist": return String(localized: "Unknown Artist")
    case "Unknown Album": return String(localized: "Unknown Album")
    default: return value
    }
}
