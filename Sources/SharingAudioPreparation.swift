import Foundation
@preconcurrency import AVFoundation

/// Creates a temporary audio-only AAC stream copy. The source is never changed.
enum SharingAudioPreparation {
    enum Failure: Error { case noAudio, conversionFailed }

    static func makeAudioCopy(from source: URL, compact: Bool) async throws -> URL {
        let work = Task.detached(priority: .utility) {
            try await convert(source: source, bitRate: compact ? 96_000 : 256_000)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private static func convert(source: URL, bitRate: Int) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.hasProtectedContent)) == false,
              let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MedioSharing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        let outputURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: outputURL) } }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.conversionFailed }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = (try? await asset.load(.commonMetadata)) ?? []
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: bitRate
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.conversionFailed }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw Failure.conversionFailed }
        writer.startSession(atSourceTime: .zero)
        do {
            while true {
                try Task.checkCancellation()
                guard reader.status != .failed, writer.status != .failed else { throw Failure.conversionFailed }
                if !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    continue
                }
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard input.append(sample) else { throw Failure.conversionFailed }
            }
            guard reader.status == .completed else { throw Failure.conversionFailed }
            input.markAsFinished()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw Failure.conversionFailed }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: outputURL.path)
            succeeded = true
            return outputURL
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }
}

/// Ownership follows the current stream, including connections still draining on the server.
final class SharedTemporaryAudio: @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}
