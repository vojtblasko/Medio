@preconcurrency import AVFoundation
import Combine
import CoreGraphics
@preconcurrency import Foundation

@MainActor
protocol PlaybackVideoProviding: AnyObject {
    var videoPlayer: AVPlayer { get }
}

@MainActor
final class AudioPlaybackService: NSObject, PlaybackService, PlaybackServicePublishing, PlaybackVideoProviding {
    private let session: AVAudioSession
    private let player: AVQueuePlayer

    nonisolated(unsafe) private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var didPlayToEndObserver: NSObjectProtocol?

    private var queue: [MediaItem] = []
    private var originalQueue: [MediaItem] = []
    private var order: [Int] = [] // maps visible queue index -> originalQueue index
    private var currentIndex: Int? = nil
    private var isPlaying: Bool = false
    private var positionMs: Int = 0
    private var durationMs: Int? = nil
    private var audioLevels: [Double] = PlaybackAudioLevels.resting
    private var repeatMode: RepeatMode = .off
    private var shuffleEnabled: Bool = false
    private var shuffleSeed: UInt64? = nil
    private var requestedPlaying: Bool? = nil
    private let playerWindowSize = 3
    private var playerItemIndices: [ObjectIdentifier: Int] = [:]
    private var waveformCache: [String: AudioWaveform] = [:]
    private var waveformLoadTask: Task<Void, Never>? = nil
    private var waveformLoadPath: String? = nil

    // Serialize player operations to avoid races when commands arrive rapidly.
    private var lastOperation: Task<Void, Never>? = nil

    private let updatesSubject: CurrentValueSubject<PlaybackUpdate, Never>
    var playbackUpdates: AnyPublisher<PlaybackUpdate, Never> { updatesSubject.eraseToAnyPublisher() }
    var videoPlayer: AVPlayer { player }
    var bufferedPlayerItemCount: Int { player.items().count }

    private func updatePositionFromPlayer(suppressMinorRegression: Bool) {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        let updatedPositionMs = Int((seconds * 1000.0).rounded())
        let isMinorRegression = updatedPositionMs < positionMs
            && positionMs - updatedPositionMs <= 1_000
        if !suppressMinorRegression || !isPlaying || !isMinorRegression {
            positionMs = updatedPositionMs
        }
    }

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        self.player = AVQueuePlayer()
        self.updatesSubject = CurrentValueSubject(
            PlaybackUpdate(
                item: nil,
                queue: [],
                isPlaying: false,
                positionMs: 0,
                durationMs: nil,
                queueIndex: nil,
                repeatMode: .off,
                shuffleEnabled: false,
                audioLevels: PlaybackAudioLevels.resting
            )
        )
        super.init()
        // Handle end-of-track behavior ourselves so repeat/queue logic is deterministic.
        player.actionAtItemEnd = .none
        configureAudioSession()
        wirePlayerObservers()
        publishUpdate()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
        currentItemObservation?.invalidate()
        if let didPlayToEndObserver { NotificationCenter.default.removeObserver(didPlayToEndObserver) }
        waveformLoadTask?.cancel()
    }

    // MARK: - PlaybackService

    func setQueue(_ items: [MediaItem], startAt index: Int) async {
        let originalStartIndex = items.isEmpty ? nil : min(max(index, 0), items.count - 1)

        originalQueue = items
        if shuffleEnabled, items.count > 1 {
            let seed = UInt64(Date().timeIntervalSince1970 * 1_000)
            shuffleSeed = seed
            applyShuffle(seed: seed)
        } else {
            order = Array(0..<items.count)
        }
        rebuildVisibleQueue()
        currentIndex = originalStartIndex.flatMap { order.firstIndex(of: $0) }
        positionMs = 0
        durationMs = nil

        // Publish immediately so UI can render current track metadata without waiting
        // for AVQueuePlayer to finish rebuilding internal items.
        publishUpdate()

        // Ensure player updates are serialized.
        let operation = enqueueOperation { @MainActor in
            self.player.removeAllItems()
            self.playerItemIndices.removeAll()

            guard let start = self.currentIndex else {
                self.requestedPlaying = false
                self.isPlaying = false
                self.publishUpdate()
                return
            }

            self.fillPlayerWindow(startingAt: start)
            self.publishUpdate()
        }
        await operation.value
    }

    func play() async {
        activateSessionIfNeeded()
        let operation = enqueueOperation { @MainActor in
            self.requestedPlaying = true
            self.player.play()
            self.isPlaying = true
            self.publishUpdate()
        }
        await operation.value
    }

    func pause() async {
        let operation = enqueueOperation { @MainActor in
            self.requestedPlaying = false
            self.player.pause()
            self.isPlaying = false
            let seconds = self.player.currentTime().seconds
            if seconds.isFinite {
                self.positionMs = Int((seconds * 1000.0).rounded())
            }
            self.publishUpdate()
        }
        await operation.value
    }

    func seek(toMs: Int) async {
        let ms = max(0, toMs)
        let t = CMTime(milliseconds: ms)
        await withCheckedContinuation { cont in
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                cont.resume()
            }
        }

        positionMs = ms
        publishUpdate()
    }

    func skipNext() async {
        let operation = enqueueOperation { @MainActor in
            guard let idx = self.currentIndex else { return }

            // Repeat one always restarts current track instead of advancing.
            if self.repeatMode == .one {
                await self.seek(toMs: 0)
                if self.isPlaying {
                    self.activateSessionIfNeeded()
                    self.requestedPlaying = true
                    self.player.play()
                    self.publishUpdate()
                }
                return
            }

            // At end of queue
            if idx + 1 >= self.order.count {
                switch self.repeatMode {
                case .all:
                    // wrap to first
                    if !self.order.isEmpty {
                        self.currentIndex = 0
                        self.rebuildQueueStarting(at: 0, preservePlaying: true)
                    }
                    return
                case .off, .one:
                    self.requestedPlaying = false
                    self.player.pause()
                    self.isPlaying = false
                    self.publishUpdate()
                    return
                }
            }

            // Normal advance
            self.currentIndex = idx + 1
            self.player.advanceToNextItem()
            self.fillPlayerWindow(startingAt: idx + 1)
            self.positionMs = 0
            self.durationMs = nil
            self.publishUpdate()
        }
        await operation.value
    }

    func skipPrevious() async {
        let operation = enqueueOperation { @MainActor in
            guard let idx = self.currentIndex else { return }

            // If we're a few seconds in, "previous" means restart.
            if self.positionMs > 3_000 {
                await self.seek(toMs: 0)
                return
            }

            // If at first item and repeat all, go to last
            if idx == 0 {
                if self.repeatMode == .all, !self.order.isEmpty {
                    let lastIndex = self.order.count - 1
                    self.currentIndex = lastIndex
                    self.rebuildQueueStarting(at: lastIndex, preservePlaying: self.isPlaying)
                    return
                } else {
                    // At first item and not repeating all -> restart
                    await self.seek(toMs: 0)
                    return
                }
            }

            let prevIndex = idx - 1
            self.currentIndex = prevIndex
            self.rebuildQueueStarting(at: prevIndex, preservePlaying: self.isPlaying)
        }
        await operation.value
    }

    func toggleShuffle() async {
        let operation = enqueueOperation { @MainActor in
            let currentOriginalIndex = self.currentIndex.flatMap { index in
                self.order.indices.contains(index) ? self.order[index] : nil
            }
            self.shuffleEnabled.toggle()
            if self.shuffleEnabled {
                // generate a seed and shuffle order deterministically
                let seed = UInt64(Date().timeIntervalSince1970 * 1000.0)
                self.shuffleSeed = seed
                self.applyShuffle(seed: seed)
            } else {
                // restore original order
                self.order = Array(0..<(self.originalQueue.count))
            }
            self.rebuildVisibleQueue()

            self.currentIndex = currentOriginalIndex.flatMap { originalIndex in
                self.order.firstIndex(of: originalIndex)
            } ?? (self.queue.isEmpty ? nil : 0)

            if let idx = self.currentIndex {
                self.rebuildQueueStarting(at: idx, preservePlaying: self.isPlaying)
            } else {
                self.player.removeAllItems()
                self.publishUpdate()
            }
        }
        await operation.value
    }

    func cycleRepeatMode() async {
        switch repeatMode {
        case .off: repeatMode = .one
        case .one: repeatMode = .all
        case .all: repeatMode = .off
        }
        publishUpdate()
    }
}

// MARK: - Wiring / observers

private extension AudioPlaybackService {
    func configureAudioSession() {
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Best-effort; playback may still work without session configuration.
        }
    }

    func activateSessionIfNeeded() {
        do { try session.setActive(true, options: []) } catch {}
    }

    func wirePlayerObservers() {
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                let playerReportsPlaying = player.timeControlStatus == .playing
                if let requestedPlaying = self.requestedPlaying {
                    if requestedPlaying {
                        self.isPlaying = true
                        if playerReportsPlaying {
                            self.requestedPlaying = nil
                        }
                    } else {
                        if playerReportsPlaying {
                            self.player.pause()
                        } else {
                            self.requestedPlaying = nil
                        }
                        self.isPlaying = false
                    }
                } else {
                    self.isPlaying = playerReportsPlaying
                }
                self.publishUpdate()
            }
        }

        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Keep internal index in sync with player's currentItem
                self.syncCurrentIndexWithPlayerCurrentItem()
                self.publishUpdate()
            }
        }

        let interval = CMTime(seconds: 0.18, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updatePositionFromPlayer(suppressMinorRegression: true)

                if let dur = self.player.currentItem?.duration, dur.isNumeric, dur.seconds.isFinite {
                    self.durationMs = Int((dur.seconds * 1000.0).rounded())
                } else {
                    self.durationMs = nil
                }
                self.publishUpdate()
            }
        }

        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let endedItem = notification.object as? AVPlayerItem else { return }
            let endedItemID = ObjectIdentifier(endedItem)
            Task { @MainActor in
                guard self.player.items().contains(where: { ObjectIdentifier($0) == endedItemID }) else { return }
                await self.handleItemDidEnd()
            }
        }
    }

    func handleItemDidEnd() async {
        switch repeatMode {
        case .one:
            await seek(toMs: 0)
            await play()
            return
        case .all, .off:
            break
        }

        // If we've reached the end of the visible queue
        if let idx = currentIndex, idx + 1 >= order.count {
            if repeatMode == .all, !order.isEmpty {
                currentIndex = 0
                let operation = enqueueOperation { @MainActor in
                    self.rebuildQueueStarting(at: 0, preservePlaying: true)
                }
                await operation.value
            } else {
                player.pause()
                requestedPlaying = false
                isPlaying = false
                publishUpdate()
            }
            return
        }

        // otherwise normal flow: advance to next
        let operation = enqueueOperation { @MainActor in
            if let idx = self.currentIndex, idx + 1 < self.order.count {
                self.currentIndex = idx + 1
                self.player.advanceToNextItem()
                self.fillPlayerWindow(startingAt: idx + 1)
                self.positionMs = 0
                self.durationMs = nil
                self.publishUpdate()
            }
        }
        await operation.value
    }

    func rebuildQueueStarting(at start: Int, preservePlaying: Bool) {
        // Rebuild the AVQueuePlayer items from the visible order starting at `start`.
        player.removeAllItems()
        playerItemIndices.removeAll()

        fillPlayerWindow(startingAt: start)

        currentIndex = start
        positionMs = 0
        durationMs = nil

        if preservePlaying {
            activateSessionIfNeeded()
            requestedPlaying = true
            player.play()
            isPlaying = true
        } else {
            requestedPlaying = false
            isPlaying = false
        }

        publishUpdate()
    }

    func syncCurrentIndexWithPlayerCurrentItem() {
        guard let playerItem = player.currentItem else { return }
        currentIndex = playerItemIndices[ObjectIdentifier(playerItem)] ?? currentIndex
    }

    func rebuildVisibleQueue() {
        queue = order.compactMap { index in
            originalQueue.indices.contains(index) ? originalQueue[index] : nil
        }
    }

    /// Keep only the current item and a small look-ahead in AVQueuePlayer. The complete logical
    /// queue stays available to the UI without creating thousands of AVPlayerItems.
    func fillPlayerWindow(startingAt start: Int) {
        guard queue.indices.contains(start) else { return }
        let desiredCount = min(playerWindowSize, queue.count - start)
        var loadedCount = player.items().count

        while loadedCount < desiredCount {
            let logicalIndex = start + loadedCount
            guard queue.indices.contains(logicalIndex) else { break }
            let item = AVPlayerItem(url: URL(fileURLWithPath: queue[logicalIndex].id))
            let previousItem = player.items().last
            guard player.canInsert(item, after: previousItem) else { break }
            player.insert(item, after: previousItem)
            playerItemIndices[ObjectIdentifier(item)] = logicalIndex
            loadedCount += 1
        }
    }

    func enqueueOperation(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let prev = lastOperation
        let task = Task { @MainActor in
            if let p = prev { _ = await p.value }
            await op()
        }
        lastOperation = task
        return task
    }

    // Fisher-Yates deterministic shuffle using a uint64 RNG
    func applyShuffle(seed: UInt64) {
        guard originalQueue.count > 1 else {
            order = Array(0..<originalQueue.count)
            return
        }
        var rng = seed
        func next() -> UInt64 {
            rng &+= 0x9e3779b97f4a7c15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }

        var arr = Array(0..<originalQueue.count)
        var i = arr.count - 1
        while i > 0 {
            let r = Int(next() % UInt64(i + 1))
            arr.swapAt(i, r)
            i -= 1
        }
        order = arr
    }

    func publishUpdate() {
        let item: MediaItem? = {
            guard let idx = currentIndex, queue.indices.contains(idx) else { return nil }
            return queue[idx]
        }()
        refreshAudioLevels(for: item)

        updatesSubject.send(
            PlaybackUpdate(
                item: item,
                queue: queue,
                isPlaying: isPlaying,
                positionMs: positionMs,
                durationMs: durationMs,
                queueIndex: currentIndex,
                repeatMode: repeatMode,
                shuffleEnabled: shuffleEnabled,
                audioLevels: audioLevels
            )
        )
    }

    func refreshAudioLevels(for item: MediaItem?) {
        guard isPlaying, let item, !item.isVideo else {
            audioLevels = PlaybackAudioLevels.resting
            return
        }

        if let waveform = waveformCache[item.id] {
            audioLevels = waveform.levels(atMs: positionMs, barCount: PlaybackAudioLevels.barCount)
            return
        }

        audioLevels = PlaybackAudioLevels.resting
        guard waveformLoadPath != item.id else { return }

        waveformLoadTask?.cancel()
        waveformLoadPath = item.id
        let path = item.id
        waveformLoadTask = Task {
            let waveform = await Self.loadWaveform(for: path)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.waveformLoadPath == path else { return }
                self.waveformLoadPath = nil
                self.waveformLoadTask = nil
                if let waveform {
                    self.waveformCache[path] = waveform
                }
                if self.currentItemID == path {
                    self.publishUpdate()
                }
            }
        }
    }

    var currentItemID: String? {
        guard let idx = currentIndex, queue.indices.contains(idx) else { return nil }
        return queue[idx].id
    }

    nonisolated static func loadWaveform(for path: String) async -> AudioWaveform? {
        await Task.detached(priority: .utility) {
            do {
                return try AudioWaveform.load(from: path)
            } catch {
                return nil
            }
        }.value
    }
}

private extension CMTime {
    init(milliseconds: Int) {
        self = CMTime(seconds: Double(milliseconds) / 1000.0, preferredTimescale: 600)
    }
}

private struct AudioWaveform: Sendable {
    let durationMs: Int
    let levels: [Double]

    static func load(from path: String) throws -> AudioWaveform? {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32 else { return nil }

        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard sampleRate > 0, totalFrames > 0 else { return nil }

        let durationSeconds = Double(totalFrames) / sampleRate
        let durationMs = Int((durationSeconds * 1000).rounded())
        let binCount = min(1_200, max(120, Int((durationSeconds * 5).rounded())))
        var sums = Array(repeating: 0.0, count: binCount)
        var counts = Array(repeating: 0, count: binCount)

        let chunkFrameCount: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) else {
            return nil
        }

        let channelCount = max(1, Int(format.channelCount))
        let sampleStride = max(1, Int(sampleRate / 220))

        while file.framePosition < totalFrames {
            let startFrame = file.framePosition
            let remaining = totalFrames - startFrame
            let framesToRead = AVAudioFrameCount(min(Int64(chunkFrameCount), remaining))
            try file.read(into: buffer, frameCount: framesToRead)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let floatData = buffer.floatChannelData else { break }

            for frame in stride(from: 0, to: frameLength, by: sampleStride) {
                let absoluteFrame = startFrame + AVAudioFramePosition(frame)
                let bin = min(
                    binCount - 1,
                    max(0, Int((Double(absoluteFrame) / Double(totalFrames)) * Double(binCount)))
                )
                var sampleTotal = 0.0
                if format.isInterleaved {
                    let interleaved = floatData[0]
                    for channel in 0..<channelCount {
                        sampleTotal += Double(abs(interleaved[frame * channelCount + channel]))
                    }
                } else {
                    for channel in 0..<channelCount {
                        sampleTotal += Double(abs(floatData[channel][frame]))
                    }
                }
                sums[bin] += sampleTotal / Double(channelCount)
                counts[bin] += 1
            }
        }

        var rawLevels = sums.enumerated().map { index, value in
            counts[index] > 0 ? value / Double(counts[index]) : 0
        }
        let sorted = rawLevels.sorted()
        let referenceIndex = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * 0.92)))
        let reference = max(sorted[referenceIndex], 0.000_001)
        rawLevels = rawLevels.map { value in
            let normalized = min(1, max(0, value / reference))
            return max(0.15, pow(normalized, 0.55))
        }

        return AudioWaveform(durationMs: durationMs, levels: rawLevels)
    }

    func levels(atMs positionMs: Int, barCount: Int) -> [Double] {
        guard durationMs > 0, !levels.isEmpty else {
            return Array(repeating: 0.15, count: barCount)
        }
        let progress = min(1, max(0, Double(positionMs) / Double(durationMs)))
        let centerIndex = Int((progress * Double(levels.count - 1)).rounded())
        let offsets = [-2, -1, 0, 1, 2, 3]

        return (0..<barCount).map { index in
            let offset = index < offsets.count ? offsets[index] : index - (barCount / 2)
            let levelIndex = min(levels.count - 1, max(0, centerIndex + offset))
            return max(0.15, min(1, levels[levelIndex]))
        }
    }
}
