import CoreMedia
import Foundation
@preconcurrency import SoundAnalysis

enum SpeechlessMusicPolicy: String, CaseIterable, Identifiable, Sendable {
    case include
    case exclude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .include: return "Include"
        case .exclude: return "Exclude"
        }
    }
}

enum SpeechAnalysisState: Equatable, Sendable {
    case notRequested
    case speechDetected
    case analysisUnavailable
}

struct MissingLyricsFile: Identifiable, Equatable, Sendable {
    let song: FileInfo
    let speechAnalysis: SpeechAnalysisState

    var id: String { song.id }
}

struct MissingLyricsScanReport: Equatable, Sendable {
    let files: [MissingLyricsFile]
    let speechlessMusicExcludedCount: Int
    let lyricsReadFailureCount: Int
    let speechAnalysisFailureCount: Int
}

struct MissingLyricsScanProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let message: String
}

protocol AudioSpeechDetecting: Sendable {
    func containsSpeech(in mediaURL: URL) async throws -> Bool
}

/// Uses Apple's built-in, on-device sound classifier. Singing and other vocal
/// categories count as speech because those are the files most likely to need lyrics.
final class SoundAnalysisSpeechDetector: AudioSpeechDetecting, @unchecked Sendable {
    func containsSpeech(in mediaURL: URL) async throws -> Bool {
        let analyzer = try SNAudioFileAnalyzer(url: mediaURL)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 600)
        request.overlapFactor = 0.5
        let observer = SpeechClassificationObserver()
        try analyzer.add(request, withObserver: observer)

        return try await withCheckedThrowingContinuation { continuation in
            analyzer.analyze { _ in
                // Keep both objects alive until asynchronous analysis completes.
                _ = analyzer
                _ = observer
                if let error = observer.analysisError {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: observer.detectedSpeech)
                }
            }
        }
    }
}

private final class SpeechClassificationObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var foundSpeech = false
    private var storedError: Error?

    var detectedSpeech: Bool {
        lock.withLock { foundSpeech }
    }

    var analysisError: Error? {
        lock.withLock { storedError }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }
        let containsSpeech = classificationResult.classifications.contains { classification in
            classification.confidence >= 0.15 && Self.isSpeechOrVocal(classification.identifier)
        }
        guard containsSpeech else { return }
        lock.withLock { foundSpeech = true }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.withLock { storedError = error }
    }

    private static func isSpeechOrVocal(_ identifier: String) -> Bool {
        let normalized = identifier.lowercased()
        // Avoid treating the instrument label "singing bowl" as a human voice.
        if normalized.contains("singing_bowl") || normalized.contains("singing bowl") {
            return false
        }
        let tokens = Set(normalized.split { !$0.isLetter }.map(String.init))
        let voiceTokens: Set<String> = ["speech", "singing", "choir", "chant", "mantra", "rapping", "humming", "yodeling"]
        return !tokens.isDisjoint(with: voiceTokens)
            || normalized.contains("vocal_music")
            || normalized.contains("vocal music")
    }
}

struct MissingLyricsScanner: Sendable {
    let lyricsRepository: LyricsRepository
    let speechDetector: AudioSpeechDetecting

    init(
        lyricsRepository: LyricsRepository,
        speechDetector: AudioSpeechDetecting = SoundAnalysisSpeechDetector()
    ) {
        self.lyricsRepository = lyricsRepository
        self.speechDetector = speechDetector
    }

    func scan(
        songs: [FileInfo],
        speechlessMusicPolicy: SpeechlessMusicPolicy,
        progress: @escaping @MainActor @Sendable (MissingLyricsScanProgress) -> Void = { _ in }
    ) async throws -> MissingLyricsScanReport {
        var missingLyrics: [FileInfo] = []
        var lyricsReadFailureCount = 0

        for (index, song) in songs.enumerated() {
            try Task.checkCancellation()
            await progress(
                MissingLyricsScanProgress(
                    completed: index,
                    total: songs.count,
                    message: "Checking lyrics \(index + 1) of \(songs.count)…"
                )
            )

            do {
                let lyrics = try await lyricsRepository.loadLyrics(forMediaPath: song.id)
                let hasLyrics = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                if !hasLyrics {
                    missingLyrics.append(song)
                }
            } catch {
                lyricsReadFailureCount += 1
            }
        }

        guard speechlessMusicPolicy == .exclude else {
            let files = missingLyrics.map {
                MissingLyricsFile(song: $0, speechAnalysis: .notRequested)
            }
            await progress(
                MissingLyricsScanProgress(
                    completed: songs.count,
                    total: songs.count,
                    message: "Found \(files.count) file\(files.count == 1 ? "" : "s") without lyrics."
                )
            )
            return MissingLyricsScanReport(
                files: files,
                speechlessMusicExcludedCount: 0,
                lyricsReadFailureCount: lyricsReadFailureCount,
                speechAnalysisFailureCount: 0
            )
        }

        let musicToAnalyze = missingLyrics.filter { $0.fileType == .music }
        let totalProgress = songs.count + musicToAnalyze.count
        var analyzedMusicCount = 0
        var speechlessMusicExcludedCount = 0
        var speechAnalysisFailureCount = 0
        var files: [MissingLyricsFile] = []

        for song in missingLyrics {
            try Task.checkCancellation()
            guard song.fileType == .music else {
                files.append(MissingLyricsFile(song: song, speechAnalysis: .notRequested))
                continue
            }

            await progress(
                MissingLyricsScanProgress(
                    completed: songs.count + analyzedMusicCount,
                    total: totalProgress,
                    message: "Detecting speech \(analyzedMusicCount + 1) of \(musicToAnalyze.count)…"
                )
            )
            analyzedMusicCount += 1

            do {
                if try await speechDetector.containsSpeech(in: URL(fileURLWithPath: song.id)) {
                    files.append(MissingLyricsFile(song: song, speechAnalysis: .speechDetected))
                } else {
                    speechlessMusicExcludedCount += 1
                }
            } catch {
                speechAnalysisFailureCount += 1
                files.append(MissingLyricsFile(song: song, speechAnalysis: .analysisUnavailable))
            }
        }

        await progress(
            MissingLyricsScanProgress(
                completed: totalProgress,
                total: totalProgress,
                message: "Found \(files.count) file\(files.count == 1 ? "" : "s") without lyrics."
            )
        )
        return MissingLyricsScanReport(
            files: files,
            speechlessMusicExcludedCount: speechlessMusicExcludedCount,
            lyricsReadFailureCount: lyricsReadFailureCount,
            speechAnalysisFailureCount: speechAnalysisFailureCount
        )
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
