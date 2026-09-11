@preconcurrency import AVFoundation
import Combine
import Accelerate
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
    private let spectrumReader = AudioSpectrumReader()
    private var spectrumTask: Task<Void, Never>?
    private var spectrumRequestID: UUID?
    private var spectrumPath: String?
    private var spectrumPositionMs: Int?

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
        spectrumTask?.cancel()
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

        let interval = CMTime(seconds: 0.10, preferredTimescale: 600)
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

    func publishUpdate(refreshSpectrum: Bool = true) {
        let item: MediaItem? = {
            guard let idx = currentIndex, queue.indices.contains(idx) else { return nil }
            return queue[idx]
        }()
        if refreshSpectrum { refreshAudioLevels(for: item) }

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
            spectrumTask?.cancel()
            spectrumTask = nil
            spectrumRequestID = nil
            spectrumPositionMs = nil
            audioLevels = PlaybackAudioLevels.resting
            return
        }

        if spectrumPath != item.id {
            spectrumTask?.cancel()
            spectrumTask = nil
            spectrumPositionMs = nil
            spectrumPath = item.id
            audioLevels = PlaybackAudioLevels.resting
        }
        guard spectrumTask == nil else { return }
        if let previousPosition = spectrumPositionMs, abs(positionMs - previousPosition) < 75 { return }

        let path = item.id
        let sampledPosition = positionMs
        let requestID = UUID()
        spectrumPositionMs = sampledPosition
        spectrumRequestID = requestID
        let reader = spectrumReader
        spectrumTask = Task { [weak self] in
            let levels = await reader.levels(for: path, atMs: sampledPosition)
            guard !Task.isCancelled, let self, self.spectrumRequestID == requestID else { return }
            self.spectrumTask = nil
            guard self.isPlaying, self.currentItemID == path,
                  abs(self.positionMs - sampledPosition) < 250 else { return }
            self.audioLevels = levels
            self.publishUpdate(refreshSpectrum: false)
        }
    }

    var currentItemID: String? {
        guard let idx = currentIndex, queue.indices.contains(idx) else { return nil }
        return queue[idx].id
    }
}

private extension CMTime {
    init(milliseconds: Int) {
        self = CMTime(seconds: Double(milliseconds) / 1000.0, preferredTimescale: 600)
    }
}

/// Reads only a short window at the playhead. Work and memory stay bounded even for long tracks.
actor AudioSpectrumReader {
    private var path: String?
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private let analyzer = AudioSpectrumAnalyzer()

    func levels(for path: String, atMs positionMs: Int) -> [Double] {
        guard !Task.isCancelled else { return PlaybackAudioLevels.resting }
        if self.path != path {
            self.path = path
            file = try? AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
            buffer = file.flatMap {
                AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: AVAudioFrameCount(AudioSpectrumAnalyzer.sampleCount))
            }
        }
        guard let file, let buffer, file.length > 0 else { return PlaybackAudioLevels.resting }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return PlaybackAudioLevels.resting }
        let targetFrame = AVAudioFramePosition(Double(max(0, positionMs)) * sampleRate / 1_000)
        guard targetFrame < file.length else { return PlaybackAudioLevels.resting }
        do {
            file.framePosition = targetFrame
            try file.read(into: buffer, frameCount: AVAudioFrameCount(AudioSpectrumAnalyzer.sampleCount))
            guard !Task.isCancelled, let samples = buffer.floatChannelData else { return PlaybackAudioLevels.resting }
            let channels = (0..<Int(buffer.format.channelCount)).map { channel in
                Array(UnsafeBufferPointer(start: samples[channel], count: Int(buffer.frameLength)))
            }
            return analyzer.levels(channels: channels, sampleRate: sampleRate)
        } catch {
            // Unsupported or corrupt media should not trigger repeated reads on every UI tick.
            self.file = nil
            self.buffer = nil
            return PlaybackAudioLevels.resting
        }
    }
}

/// Seven low-to-high frequency bands from a Hann-windowed Fourier transform, not time samples.
final class AudioSpectrumAnalyzer {
    static let sampleCount = 4_096
    static let bandEdges: [Double] = [20, 100, 250, 630, 1_600, 4_000, 10_000, 24_000]
    private let transform = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(sampleCount), .FORWARD)
    private let window: [Float] = (0..<sampleCount).map {
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(sampleCount - 1)))
    }

    deinit {
        if let transform { vDSP_DFT_DestroySetup(transform) }
    }

    func levels(channels: [[Float]], sampleRate: Double) -> [Double] {
        guard let transform, sampleRate.isFinite, sampleRate > 0, !channels.isEmpty else {
            return PlaybackAudioLevels.resting
        }
        let count = Self.sampleCount
        var powers = [Double](repeating: 0, count: count / 2 + 1)
        let imaginaryInput = [Float](repeating: 0, count: count)
        var realOutput = imaginaryInput
        var imaginaryOutput = imaginaryInput
        for channel in channels {
            var input = imaginaryInput
            for index in 0..<min(count, channel.count) {
                input[index] = channel[index].isFinite ? channel[index] * window[index] : 0
            }
            vDSP_DFT_Execute(transform, input, imaginaryInput, &realOutput, &imaginaryOutput)
            for index in powers.indices {
                let real = Double(realOutput[index])
                let imaginary = Double(imaginaryOutput[index])
                powers[index] += real * real + imaginary * imaginary
            }
        }
        // Combine channel power, so opposite-phase stereo channels cannot cancel each other.
        let windowSum = Double(window.reduce(0, +))
        let normalization = 4 / (windowSum * windowSum * Double(channels.count))
        let resolution = sampleRate / Double(count)
        return (0..<PlaybackAudioLevels.barCount).map { band in
            let lower = max(1, Int(ceil(Self.bandEdges[band] / resolution)))
            let upper = min(powers.count, Int(ceil(min(Self.bandEdges[band + 1], sampleRate / 2) / resolution)))
            guard lower < upper else { return 0.15 }
            let power = powers[lower..<upper].reduce(0, +) * normalization
            let decibels = 10 * log10(max(power, 1e-12))
            return 0.15 + 0.85 * min(1, max(0, (decibels + 65) / 65))
        }
    }
}
