import Foundation
import Combine
import AVFoundation
import UIKit
import MediaPlayer

// MARK: - Protocols used by AppContainer and elsewhere
@MainActor
protocol NowPlayingService {
    func updateNowPlaying(item: MediaItem?, playback: PlaybackState)
}

@MainActor
protocol RemoteCommandsService {
    func connect(playbackService: PlaybackService, playbackStore: PlaybackStore)
    func disconnect()
}

@MainActor
final class NowPlayingViewModel: ObservableObject {
    @Published private(set) var item: MediaItem? = nil
    @Published private(set) var playback: PlaybackState = PlaybackState()
    @Published var artwork: UIImage? = nil
    @Published private(set) var artworkBackgroundColors: [UIColor] = []
    @Published private(set) var lyricsText: String? = nil
    @Published private(set) var lyricsLines: [String] = []
    @Published private(set) var activeLyricLineIndex: Int? = nil
    @Published private(set) var activeLyricLineProgress: CGFloat = 0

    private let playbackStore: PlaybackStore
    private let playbackService: PlaybackService
    private let lyricsRepository: LyricsRepository?
    private var cancellables: Set<AnyCancellable> = []
    private var lastStableItem: MediaItem? = nil
    private var currentArtworkPath: String? = nil
    private var artworkPaletteGeneration: Int = 0
    private var currentLyricsPath: String? = nil
    private var lyricsGeneration: Int = 0
    private var preparedLyrics: PreparedLyrics? = nil

    init(playbackStore: PlaybackStore, playbackService: PlaybackService, lyricsRepository: LyricsRepository? = nil) {
        self.playbackStore = playbackStore
        self.playbackService = playbackService
        self.lyricsRepository = lyricsRepository

        Publishers.CombineLatest3(playbackStore.$nowPlaying, playbackStore.$queue, playbackStore.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newItem, queue, isPlaying in
                guard let self else { return }
                if let newItem {
                    self.lastStableItem = newItem
                    self.applyDisplayedItem(newItem)
                    return
                }
                if let lastStableItem = self.lastStableItem, (isPlaying || !queue.isEmpty) {
                    self.applyDisplayedItem(lastStableItem)
                    return
                }
                self.lastStableItem = nil
                self.applyDisplayedItem(nil)
            }
            .store(in: &cancellables)

        playbackStore.$playback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.playback = $0
                self?.updateLyricsForPlaybackPosition()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let currentPath = self.item?.id else { return }
                guard let changedPath = notification.userInfo?["path"] as? String else {
                    self.syncFromStore()
                    return
                }
                if changedPath == currentPath {
                    self.syncFromStore()
                }
            }
            .store(in: &cancellables)
    }

    private func applyDisplayedItem(_ newItem: MediaItem?, forceReload: Bool = false) {
        let oldID = item?.id
        let newID = newItem?.id
        item = newItem
        guard forceReload || oldID != newID else { return }
        loadArtwork()
        loadLyrics()
    }

    private func loadArtwork() {
        guard let item else {
            artwork = nil
            artworkBackgroundColors = []
            currentArtworkPath = nil
            return
        }
        guard item.id != currentArtworkPath else { return }
        currentArtworkPath = item.id
        let path = item.id
        if let customPath = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: path)?.coverArtworkPath,
           let customImage = VisualArtworkOverrideStore.image(at: customPath) {
            setArtwork(customImage, for: path)
            return
        }
        Task {
            let img = await ArtworkCache.extractArtwork(for: path)
            guard self.currentArtworkPath == path else { return }
            self.setArtwork(img, for: path)
        }
    }

    private func setArtwork(_ image: UIImage?, for path: String) {
        artwork = image
        artworkPaletteGeneration += 1
        let generation = artworkPaletteGeneration
        guard let image else {
            artworkBackgroundColors = []
            return
        }
        Task {
            let colors = await Self.extractBackgroundColors(from: image)
            guard self.currentArtworkPath == path, self.artworkPaletteGeneration == generation else { return }
            self.artworkBackgroundColors = colors
        }
    }

    private func loadLyrics() {
        guard let item else { return }
        guard item.id != currentLyricsPath else { return }
        currentLyricsPath = item.id
        lyricsGeneration += 1
        let generation = lyricsGeneration
        lyricsText = nil
        lyricsLines = []
        activeLyricLineIndex = nil
        preparedLyrics = nil
        Task {
            let text: String?
            do {
                text = try await lyricsRepository?.loadLyrics(forMediaPath: item.id)
            } catch {
                AppLog.persistence.error("Lyrics could not be loaded: \(error.localizedDescription, privacy: .public)")
                text = nil
            }
            guard self.currentLyricsPath == item.id, self.lyricsGeneration == generation else { return }
            self.preparedLyrics = Self.prepareLyrics(from: text, for: item)
            self.updateLyricsForPlaybackPosition()
        }
    }

    private func updateLyricsForPlaybackPosition() {
        guard let preparedLyrics else {
            lyricsText = nil
            lyricsLines = []
            activeLyricLineIndex = nil
            activeLyricLineProgress = 0
            return
        }
        if lyricsLines != preparedLyrics.lines {
            lyricsLines = preparedLyrics.lines
        }
        let activeState = preparedLyrics.activeState(atMs: playback.positionMs)
        activeLyricLineIndex = activeState?.lineIndex
        activeLyricLineProgress = activeState?.progress ?? 0
        lyricsText = preparedLyrics.plainText
    }

    private static func prepareLyrics(from rawLyrics: String?, for item: MediaItem) -> PreparedLyrics? {
        guard let rawLyrics else { return nil }
        let normalizedTitle = normalizeLyricComparableText(item.title)
        let normalizedArtist = normalizeLyricComparableText(item.artist)

        var plainLines: [String] = []
        var timedSegments: [TimedLyricSegment] = []

        let parsedLines = parseStructuredLyrics(rawLyrics)
        for parsed in parsedLines {
            let lyricLine = sanitizeLyricText(parsed.text)
            guard !lyricLine.isEmpty else { continue }
            if shouldHideLyricLine(lyricLine, normalizedTitle: normalizedTitle, normalizedArtist: normalizedArtist) {
                continue
            }
            let lineIndex = plainLines.count
            plainLines.append(lyricLine)
            for startMs in parsed.starts {
                timedSegments.append(TimedLyricSegment(lineIndex: lineIndex, startMs: startMs, endMs: parsed.endMs))
            }
        }

        if plainLines.isEmpty { return nil }

        let resolvedSegments = resolveTimedSegments(timedSegments)
        var linesWithBreaks = plainLines
        var segmentsWithBreaks = resolvedSegments

        if !resolvedSegments.isEmpty {
            for i in (0..<resolvedSegments.count - 1).reversed() {
                let current = resolvedSegments[i]
                let next = resolvedSegments[i + 1]
                let currentEndMs = current.endMs ?? min(next.startMs, current.startMs + 4_000)
                let pauseDurationMs = next.startMs - currentEndMs
                if pauseDurationMs > 10_000 && i > 0 && i < resolvedSegments.count - 2 {
                    let breakLineIndex = current.lineIndex + 1
                    let pausePlaceholder = "⟪pause:\(pauseDurationMs)⟫"
                    linesWithBreaks.insert(pausePlaceholder, at: breakLineIndex)
                    for j in (i + 1)..<segmentsWithBreaks.count {
                        segmentsWithBreaks[j].lineIndex += 1
                    }
                    let pauseSegment = TimedLyricSegment(lineIndex: breakLineIndex, startMs: currentEndMs, endMs: next.startMs)
                    segmentsWithBreaks.insert(pauseSegment, at: i + 1)
                }
            }
        }

        return PreparedLyrics(lines: linesWithBreaks, timedSegments: segmentsWithBreaks)
    }

    private static func parseStructuredLyrics(_ text: String) -> [ParsedLyricLine] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if normalized.localizedCaseInsensitiveContains("-->") {
            return parseSRTLyrics(normalized)
        }

        if normalized.localizedCaseInsensitiveContains("<tt")
            || normalized.localizedCaseInsensitiveContains("<p ") {
            let parsed = parseTTMLLyrics(normalized)
            if !parsed.isEmpty { return parsed }
        }

        return parseLRCLyrics(normalized)
    }

    private static func parseLRCLyrics(_ text: String) -> [ParsedLyricLine] {
        var parsed: [ParsedLyricLine] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            var starts: [Int] = []
            while line.hasPrefix("["),
                  let close = line.firstIndex(of: "]") {
                let token = String(line[line.index(after: line.startIndex)..<close])
                if let start = parseTimestamp(token) {
                    starts.append(start)
                    line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }

                if token.contains(":") {
                    line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }

            let cleaned = sanitizeLyricText(line)
            guard !cleaned.isEmpty else { continue }
            parsed.append(ParsedLyricLine(starts: starts.sorted(), endMs: nil, text: cleaned))
        }
        return parsed
    }

    private static func parseSRTLyrics(_ text: String) -> [ParsedLyricLine] {
        let lines = text.components(separatedBy: .newlines)
        var parsed: [ParsedLyricLine] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                index += 1
                continue
            }

            guard let cue = parseCueTiming(line) else {
                index += 1
                continue
            }

            index += 1
            var textLines: [String] = []
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.isEmpty {
                    index += 1
                    break
                }
                if parseCueTiming(next) != nil {
                    break
                }
                if !next.allSatisfy(\.isNumber) {
                    textLines.append(next)
                }
                index += 1
            }

            let lyric = sanitizeLyricText(textLines.joined(separator: " "))
            guard !lyric.isEmpty else { continue }
            parsed.append(ParsedLyricLine(starts: [cue.start], endMs: cue.end, text: lyric))
        }

        return parsed
    }

    private static func parseTTMLLyrics(_ text: String) -> [ParsedLyricLine] {
        let pattern = #"<p\b([^>]*)>(.*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let attributes = nsText.substring(with: match.range(at: 1))
            let body = nsText.substring(with: match.range(at: 2))
            guard let begin = attributeValue(named: "begin", in: attributes).flatMap(parseTimestamp) else {
                return nil
            }
            let end = attributeValue(named: "end", in: attributes).flatMap(parseTimestamp)
            let lyric = sanitizeLyricText(stripTagsAndDecodeEntities(body))
            guard !lyric.isEmpty else { return nil }
            return ParsedLyricLine(starts: [begin], endMs: end, text: lyric)
        }
    }

    private static func parseCueTiming(_ line: String) -> (start: Int, end: Int?)? {
        guard line.contains("-->") else { return nil }
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let startToken = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let endToken = parts[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let start = parseTimestamp(startToken) else { return nil }
        return (start, endToken.flatMap(parseTimestamp))
    }

    private static func parseTimestamp(_ raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }

        let parts = cleaned.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let secondsPart = parts.last ?? ""
        let secondPieces = secondsPart.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let seconds = Int(secondPieces.first ?? "") else { return nil }

        let fraction = secondPieces.count > 1 ? secondPieces[1] : ""
        let milliseconds: Int
        if fraction.isEmpty {
            milliseconds = 0
        } else {
            let padded = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            milliseconds = Int(padded) ?? 0
        }

        if parts.count == 3 {
            guard let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
            return ((hours * 3_600) + (minutes * 60) + seconds) * 1_000 + milliseconds
        }

        guard let minutes = Int(parts[0]) else { return nil }
        return ((minutes * 60) + seconds) * 1_000 + milliseconds
    }

    private static func attributeValue(named name: String, in attributes: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsAttributes = attributes as NSString
        guard let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: nsAttributes.length)),
              match.numberOfRanges >= 2 else { return nil }
        return nsAttributes.substring(with: match.range(at: 1))
    }

    private static func stripTagsAndDecodeEntities(_ raw: String) -> String {
        let noTags = raw.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func sanitizeLyricText(_ raw: String) -> String {
        stripTagsAndDecodeEntities(raw)
            .replacingOccurrences(of: #"\{\\[^}]+\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeLyricComparableText(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func shouldHideLyricLine(_ line: String, normalizedTitle: String, normalizedArtist: String) -> Bool {
        let normalized = normalizeLyricComparableText(line)
        guard !normalized.isEmpty else { return true }
        let hiddenTokens = ["instrumental", "lyrics by", "synced by"]
        if hiddenTokens.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") }) {
            return true
        }
        return false
    }

    private static func resolveTimedSegments(_ segments: [TimedLyricSegment]) -> [TimedLyricSegment] {
        segments.sorted {
            if $0.startMs == $1.startMs { return $0.lineIndex < $1.lineIndex }
            return $0.startMs < $1.startMs
        }
    }

    private static func extractBackgroundColors(from image: UIImage) async -> [UIColor] {
        await Task.detached(priority: .utility) {
            let sampleSize = CGSize(width: 28, height: 28)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: sampleSize, format: format)
            guard let cgImage = renderer.image(actions: { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: sampleSize))
                image.draw(in: CGRect(origin: .zero, size: sampleSize))
            }).cgImage else {
                return []
            }

            let width = cgImage.width
            let height = cgImage.height
            let bytesPerPixel = 4
            let bytesPerRow = width * bytesPerPixel
            var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return []
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            var buckets: [Int: PaletteBucket] = [:]
            for pixelOffset in stride(from: 0, to: bytes.count, by: bytesPerPixel) {
                let red = CGFloat(bytes[pixelOffset]) / 255.0
                let green = CGFloat(bytes[pixelOffset + 1]) / 255.0
                let blue = CGFloat(bytes[pixelOffset + 2]) / 255.0
                let alpha = CGFloat(bytes[pixelOffset + 3]) / 255.0
                guard alpha > 0.8 else { continue }

                let maxComponent = max(red, green, blue)
                let minComponent = min(red, green, blue)
                let brightness = maxComponent
                let saturation = maxComponent == 0 ? 0 : (maxComponent - minComponent) / maxComponent
                guard brightness > 0.12, brightness < 0.92 else { continue }

                let bucketRed = Int((red * 7).rounded())
                let bucketGreen = Int((green * 7).rounded())
                let bucketBlue = Int((blue * 7).rounded())
                let key = (bucketRed << 8) | (bucketGreen << 4) | bucketBlue
                var bucket = buckets[key] ?? PaletteBucket()
                let weight = 0.35 + saturation + (1 - abs(brightness - 0.55))
                bucket.red += red * weight
                bucket.green += green * weight
                bucket.blue += blue * weight
                bucket.weight += weight
                bucket.score += weight * (0.6 + saturation)
                buckets[key] = bucket
            }

            guard let bestBucket = buckets.values.max(by: { $0.score < $1.score }),
                  bestBucket.weight > 0 else {
                return []
            }

            let dominant = UIColor(
                red: bestBucket.red / bestBucket.weight,
                green: bestBucket.green / bestBucket.weight,
                blue: bestBucket.blue / bestBucket.weight,
                alpha: 1
            )
            return [
                dominant.adjustedBrightness(0.08),
                dominant.adjustedBrightness(-0.22),
                dominant.adjustedBrightness(-0.48)
            ]
        }.value
    }

    func syncFromStore() {
        currentArtworkPath = nil
        applyDisplayedItem(playbackStore.nowPlaying, forceReload: true)
        playback = playbackStore.playback
        updateLyricsForPlaybackPosition()
    }

    func playPause() async {
        if playbackStore.playback.isPlaying || playback.isPlaying {
            await playbackService.pause()
        } else {
            await playbackService.play()
        }
        syncFromStore()
    }

    func prev() async {
        await playbackService.skipPrevious()
        syncFromStore()
    }

    func next() async {
        await playbackService.skipNext()
        syncFromStore()
    }

    func toggleRepeat() async {
        await playbackService.cycleRepeatMode()
        syncFromStore()
    }

    func toggleShuffle() async {
        await playbackService.toggleShuffle()
        syncFromStore()
    }

    func seek(toMs: Int) async {
        await playbackService.seek(toMs: toMs)
        syncFromStore()
    }

    func refreshLyrics() {
        currentLyricsPath = nil
        loadLyrics()
    }
    func timestampForLyricLine(_ lineIndex: Int) -> Int? { preparedLyrics?.firstStartTimestamp(for: lineIndex) }
    func lyricProgressForLine(_ lineIndex: Int) -> CGFloat {
        guard activeLyricLineIndex == lineIndex else { return 0 }
        return min(max(activeLyricLineProgress, 0), 1)
    }
    func lyricLineHasExplicitEnd(_ lineIndex: Int) -> Bool { preparedLyrics?.hasExplicitEnd(for: lineIndex) ?? false }
}

private struct PreparedLyrics {
    let lines: [String]
    let timedSegments: [TimedLyricSegment]
    private let firstStartsByLine: [Int: Int]
    private let explicitEndsByLine: [Int: Bool]
    private let segmentEndByLine: [Int: Int]

    init(lines: [String], timedSegments: [TimedLyricSegment]) {
        self.lines = lines
        self.timedSegments = timedSegments
        var firstStarts: [Int: Int] = [:]
        var explicitEnds: [Int: Bool] = [:]
        var resolvedEnds: [Int: Int] = [:]
        for (index, segment) in timedSegments.enumerated() {
            if firstStarts[segment.lineIndex] == nil || segment.startMs < firstStarts[segment.lineIndex]! {
                firstStarts[segment.lineIndex] = segment.startMs
            }
            if segment.endMs != nil {
                explicitEnds[segment.lineIndex] = true
            }
            let inferredEnd = timedSegments.indices.contains(index + 1) ? timedSegments[index + 1].startMs : nil
            let candidateEnd = segment.endMs ?? inferredEnd
            if let candidateEnd, candidateEnd > segment.startMs {
                resolvedEnds[segment.lineIndex] = max(resolvedEnds[segment.lineIndex] ?? 0, candidateEnd)
            }
        }
        self.firstStartsByLine = firstStarts
        self.explicitEndsByLine = explicitEnds
        self.segmentEndByLine = resolvedEnds
    }

    var plainText: String? { lines.isEmpty ? nil : lines.joined(separator: "\n") }
    func firstStartTimestamp(for lineIndex: Int) -> Int? { firstStartsByLine[lineIndex] }
    func hasExplicitEnd(for lineIndex: Int) -> Bool { explicitEndsByLine[lineIndex] ?? false }
    func activeState(atMs positionMs: Int) -> LyricActiveState? {
        guard !timedSegments.isEmpty else { return nil }
        if positionMs < timedSegments[0].startMs { return nil }
        var low = 0, high = timedSegments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if timedSegments[mid].startMs <= positionMs {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let segment = timedSegments[max(0, high)]
        let progress: CGFloat
        if positionMs <= segment.startMs {
            progress = 0
        } else if let endMs = resolvedEnd(for: segment), endMs > segment.startMs {
            progress = CGFloat(positionMs - segment.startMs) / CGFloat(endMs - segment.startMs)
        } else {
            progress = 0
        }
        return LyricActiveState(lineIndex: segment.lineIndex, progress: min(max(progress, 0), 1))
    }

    private func resolvedEnd(for segment: TimedLyricSegment) -> Int? {
        if let explicitEnd = segment.endMs, explicitEnd > segment.startMs {
            return explicitEnd
        }
        return segmentEndByLine[segment.lineIndex]
    }
}

private struct ParsedLyricLine {
    let starts: [Int]
    let endMs: Int?
    let text: String
}

private struct TimedLyricSegment {
    var lineIndex: Int
    let startMs: Int
    var endMs: Int?
}

private struct LyricActiveState {
    let lineIndex: Int
    let progress: CGFloat
}

private struct PaletteBucket {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var weight: CGFloat = 0
    var score: CGFloat = 0
}

// MARK: - MedioNowPlayingService with artwork
@MainActor
final class MedioNowPlayingService: NowPlayingService {
    private var lastItemID: String? = nil
    private var lastPlayback: PlaybackState = PlaybackState()
    private var cachedArtworkItemID: String? = nil
    private var cachedArtwork: MPMediaItemArtwork? = nil
    private var artworkMisses: Set<String> = []
    private var artworkLoadTask: Task<Void, Never>? = nil
    private var lastNowPlayingInfo: [String: Any] = [:]

    func updateNowPlaying(item: MediaItem?, playback: PlaybackState) {
        lastItemID = item?.id
        lastPlayback = playback
        var info: [String: Any] = [:]
        guard let item else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            cachedArtworkItemID = nil
            cachedArtwork = nil
            lastNowPlayingInfo = [:]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let path = item.id
        if cachedArtworkItemID != path {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            cachedArtworkItemID = path
            cachedArtwork = nil
        }

        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = item.artist ?? "Unknown Artist"
        info[MPMediaItemPropertyAlbumTitle] = item.album ?? ""
        info[MPNowPlayingInfoPropertyPlaybackRate] = playback.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(playback.positionMs) / 1000.0
        if let duration = playback.durationMs {
            info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000.0
        }
        if let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }
        lastNowPlayingInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard cachedArtwork == nil,
              artworkLoadTask == nil,
              !artworkMisses.contains(path) else {
            return
        }

        artworkLoadTask = Task {
            let image = await ArtworkCache.extractArtwork(for: path)
            guard !Task.isCancelled else { return }
            self.artworkLoadTask = nil
            guard self.lastItemID == path else { return }
            guard let image else {
                self.artworkMisses.insert(path)
                return
            }

            let preparedImage = Self.preparedArtworkImage(from: image)
            guard let cgImage = preparedImage.cgImage,
                  let artwork = Self.makeNowPlayingArtwork(
                    cgImage: cgImage,
                    scale: preparedImage.scale
                  ) else {
                self.artworkMisses.insert(path)
                return
            }
            self.cachedArtworkItemID = path
            self.cachedArtwork = artwork
            var updatedInfo = self.lastNowPlayingInfo
            updatedInfo[MPMediaItemPropertyArtwork] = artwork
            self.lastNowPlayingInfo = updatedInfo
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
        }
    }

    private static func preparedArtworkImage(from image: UIImage) -> UIImage {
        let maxSide: CGFloat = 768
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated private static func makeNowPlayingArtwork(
        cgImage: CGImage,
        scale imageScale: CGFloat
    ) -> MPMediaItemArtwork? {
        let scale = max(imageScale, 1)
        let boundsSize = CGSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
        guard boundsSize.width.isFinite,
              boundsSize.height.isFinite,
              boundsSize.width > 0,
              boundsSize.height > 0 else {
            return nil
        }

        // MediaPlayer invokes this handler on its own access queue. Keep it free of
        // UIKit rendering and main-actor state to avoid crossing queue boundaries.
        return MPMediaItemArtwork(boundsSize: boundsSize) { _ in
            UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        }
    }

    func refreshArtworkIfNeeded(for item: MediaItem?) {
        guard let item, item.id == lastItemID else { return }
        cachedArtworkItemID = nil
        cachedArtwork = nil
        artworkMisses.remove(item.id)
        updateNowPlaying(item: item, playback: lastPlayback)
    }
}

@MainActor
final class MedioRemoteCommandsService: RemoteCommandsService {
    private var commandTargets: [Any] = []

    func connect(playbackService: PlaybackService, playbackStore: PlaybackStore) {
        disconnect()
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        commandTargets.append(center.playCommand.addTarget { _ in
            Task { await playbackService.play() }
            return .success
        })

        center.pauseCommand.isEnabled = true
        commandTargets.append(center.pauseCommand.addTarget { _ in
            Task { await playbackService.pause() }
            return .success
        })

        center.togglePlayPauseCommand.isEnabled = true
        commandTargets.append(center.togglePlayPauseCommand.addTarget { _ in
            Task {
                if playbackStore.playback.isPlaying {
                    await playbackService.pause()
                } else {
                    await playbackService.play()
                }
            }
            return .success
        })

        center.nextTrackCommand.isEnabled = true
        commandTargets.append(center.nextTrackCommand.addTarget { _ in
            Task { await playbackService.skipNext() }
            return .success
        })

        center.previousTrackCommand.isEnabled = true
        commandTargets.append(center.previousTrackCommand.addTarget { _ in
            Task { await playbackService.skipPrevious() }
            return .success
        })

        center.changePlaybackPositionCommand.isEnabled = true
        commandTargets.append(center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { await playbackService.seek(toMs: Int(event.positionTime * 1000.0)) }
            return .success
        })
    }

    func disconnect() {
        let center = MPRemoteCommandCenter.shared()
        for target in commandTargets {
            center.playCommand.removeTarget(target)
            center.pauseCommand.removeTarget(target)
            center.togglePlayPauseCommand.removeTarget(target)
            center.nextTrackCommand.removeTarget(target)
            center.previousTrackCommand.removeTarget(target)
            center.changePlaybackPositionCommand.removeTarget(target)
        }
        commandTargets.removeAll()
    }
}

@MainActor
final class NowPlayingSyncViewModel: ObservableObject {
    private let playbackStore: PlaybackStore
    private let nowPlayingService: NowPlayingService
    private var cancellables: Set<AnyCancellable> = []

    init(playbackStore: PlaybackStore, nowPlayingService: NowPlayingService) {
        self.playbackStore = playbackStore
        self.nowPlayingService = nowPlayingService

        Publishers.CombineLatest(playbackStore.$nowPlaying, playbackStore.$playback)
            .receive(on: DispatchQueue.main)
            .map { item, playback in
                NowPlayingSyncSnapshot(item: item, playback: playback)
            }
            .removeDuplicates()
            .sink { [weak self] snapshot in
                self?.nowPlayingService.updateNowPlaying(item: snapshot.item, playback: snapshot.playback)
            }
            .store(in: &cancellables)
    }

    func syncNow() {
        nowPlayingService.updateNowPlaying(item: playbackStore.nowPlaying, playback: playbackStore.playback)
    }
}

private struct NowPlayingSyncSnapshot: Equatable {
    let item: MediaItem?
    let playback: PlaybackState
    private let positionBucket: Int

    init(item: MediaItem?, playback: PlaybackState) {
        self.item = item
        self.playback = playback
        positionBucket = playback.isPlaying
            ? playback.positionMs / 5_000
            : playback.positionMs / 1_000
    }

    static func == (lhs: NowPlayingSyncSnapshot, rhs: NowPlayingSyncSnapshot) -> Bool {
        lhs.item?.id == rhs.item?.id
            && lhs.item?.title == rhs.item?.title
            && lhs.item?.artist == rhs.item?.artist
            && lhs.item?.album == rhs.item?.album
            && lhs.playback.isPlaying == rhs.playback.isPlaying
            && lhs.playback.durationMs == rhs.playback.durationMs
            && lhs.playback.queueIndex == rhs.playback.queueIndex
            && lhs.playback.repeatMode == rhs.playback.repeatMode
            && lhs.playback.shuffleEnabled == rhs.playback.shuffleEnabled
            && lhs.positionBucket == rhs.positionBucket
    }
}

private extension UIColor {
    func adjustedBrightness(_ delta: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return self
        }
        return UIColor(hue: hue, saturation: saturation, brightness: min(max(brightness + delta, 0), 1), alpha: alpha)
    }
}
