import Foundation

protocol LyricsRepository: Sendable {
    func loadLyrics(forMediaPath path: String) async throws -> String?
    func saveLyrics(_ lrc: String, forMediaPath path: String) async throws
    func deleteLyrics(forMediaPath path: String) async throws
}

/// Optional batch capability used by library search. It intentionally avoids expensive
/// per-song metadata matching when thousands of songs are searched at once.
protocol LyricsSearchRepository: LyricsRepository {
    func loadLyricsForSearch(forMediaPaths paths: [String]) async throws -> [String: String]
}
