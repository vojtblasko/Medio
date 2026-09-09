import Foundation
import SQLite3

actor SQLiteListeningHistoryRepository: ListeningHistoryRepository {
    private let fileManager: FileManager
    private let databaseURL: URL
    private let previousDatabaseURL: URL?
    private let legacyFileURL: URL
    nonisolated(unsafe) private var database: OpaquePointer?

    init(
        fileManager: FileManager = .default,
        databaseURL: URL? = nil,
        legacyFileURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        if let databaseURL {
            self.databaseURL = databaseURL
            self.previousDatabaseURL = nil
        } else {
            self.databaseURL = applicationSupport.appendingPathComponent("medio-recapped.sqlite3", isDirectory: false)
            let previousFilename = ["medio", "wrap" + "ped"].joined(separator: "-") + ".sqlite3"
            self.previousDatabaseURL = applicationSupport.appendingPathComponent(previousFilename, isDirectory: false)
        }
        self.legacyFileURL = legacyFileURL
            ?? applicationSupport.appendingPathComponent("medio-listening-history.v1.json", isDirectory: false)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func loadSessions() async throws -> [ListeningSession] {
        let database = try openDatabase()
        let sql = """
        SELECT
            play_history.id,
            tracks.file_path,
            tracks.title,
            tracks.artist,
            tracks.duration_ms,
            play_history.played_at,
            play_history.listen_time_ms
        FROM play_history
        INNER JOIN tracks ON tracks.id = play_history.track_id
        ORDER BY play_history.played_at ASC, play_history.id ASC;
        """
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        var sessions: [ListeningSession] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw databaseError(String(cString: sqlite3_errmsg(database)))
            }

            let historyID = sqlite3_column_int64(statement, 0)
            let mediaID = string(at: 1, in: statement) ?? ""
            let title = string(at: 2, in: statement)
                ?? URL(fileURLWithPath: mediaID).deletingPathExtension().lastPathComponent
            let artist = string(at: 3, in: statement)
            let durationMs = optionalInt(at: 4, in: statement)
            let startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5)))
            let listenedMs = max(0, Int(sqlite3_column_int64(statement, 6)))
            let endedAt = startedAt.addingTimeInterval(TimeInterval(listenedMs) / 1_000)
            let completed = durationMs.map { duration in
                duration > 0 && listenedMs >= Int(Double(duration) * 0.8)
            } ?? false

            sessions.append(ListeningSession(
                id: stableUUID(for: historyID),
                mediaID: mediaID,
                title: title,
                artist: artist,
                album: nil,
                genre: nil,
                year: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                listenedMs: listenedMs,
                durationMs: durationMs,
                completed: completed
            ))
        }

        return sessions
    }

    func appendSession(_ session: ListeningSession) async throws {
        let database = try openDatabase()
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)

        do {
            let trackID = try upsertTrack(for: session, in: database)
            let insertHistory = try prepare(
                """
                INSERT INTO play_history (track_id, played_at, listen_time_ms)
                VALUES (?, ?, ?);
                """,
                in: database
            )
            defer { sqlite3_finalize(insertHistory) }

            sqlite3_bind_int64(insertHistory, 1, trackID)
            sqlite3_bind_int64(insertHistory, 2, Int64(session.startedAt.timeIntervalSince1970.rounded(.down)))
            sqlite3_bind_int64(insertHistory, 3, Int64(max(0, session.listenedMs)))
            try stepToCompletion(insertHistory, in: database)
            try execute("COMMIT;", in: database)
        } catch {
            rollback(database)
            throw error
        }
    }

    func clearSessions() async throws {
        let database = try openDatabase()
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)
        do {
            try execute("DELETE FROM play_history;", in: database)
            try execute("DELETE FROM tracks;", in: database)
            try execute("COMMIT;", in: database)
        } catch {
            rollback(database)
            throw error
        }
    }

    func deleteStoredData() async throws {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        try removeIfExists(databaseURL)
        if let previousDatabaseURL {
            try removeIfExists(previousDatabaseURL)
        }
        try removeIfExists(legacyFileURL)
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database {
            return database
        }

        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: databaseURL.path),
           let previousDatabaseURL,
           fileManager.fileExists(atPath: previousDatabaseURL.path) {
            try fileManager.moveItem(at: previousDatabaseURL, to: databaseURL)
        }

        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &openedDatabase, flags, nil) == SQLITE_OK,
              let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database."
            if let openedDatabase {
                sqlite3_close(openedDatabase)
            }
            throw databaseError(message)
        }

        do {
            try execute("PRAGMA foreign_keys = ON;", in: openedDatabase)
            try execute(
                """
                CREATE TABLE IF NOT EXISTS tracks (
                    id INTEGER PRIMARY KEY,
                    file_path TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    artist TEXT,
                    duration_ms INTEGER
                );
                """,
                in: openedDatabase
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS play_history (
                    id INTEGER PRIMARY KEY,
                    track_id INTEGER NOT NULL,
                    played_at INTEGER NOT NULL,
                    listen_time_ms INTEGER NOT NULL CHECK (listen_time_ms >= 0),
                    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
                );
                """,
                in: openedDatabase
            )
            database = openedDatabase
            try migrateLegacyHistoryIfNeeded(in: openedDatabase)
            return openedDatabase
        } catch {
            sqlite3_close(openedDatabase)
            database = nil
            throw error
        }
    }

    private func migrateLegacyHistoryIfNeeded(in database: OpaquePointer) throws {
        guard fileManager.fileExists(atPath: legacyFileURL.path) else { return }
        guard try rowCount(in: "play_history", database: database) == 0 else {
            do {
                try fileManager.removeItem(at: legacyFileURL)
            } catch {
                AppLog.persistence.error("Listening-history migration succeeded, but the legacy file could not be removed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let data = try Data(contentsOf: legacyFileURL)
        let sessions = try JSONDecoder().decode([ListeningSession].self, from: data)
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)

        do {
            for session in sessions {
                let trackID = try upsertTrack(for: session, in: database)
                let statement = try prepare(
                    """
                    INSERT INTO play_history (track_id, played_at, listen_time_ms)
                    VALUES (?, ?, ?);
                    """,
                    in: database
                )
                sqlite3_bind_int64(statement, 1, trackID)
                sqlite3_bind_int64(statement, 2, Int64(session.startedAt.timeIntervalSince1970.rounded(.down)))
                sqlite3_bind_int64(statement, 3, Int64(max(0, session.listenedMs)))
                do {
                    try stepToCompletion(statement, in: database)
                    sqlite3_finalize(statement)
                } catch {
                    sqlite3_finalize(statement)
                    throw error
                }
            }
            try execute("COMMIT;", in: database)
            try fileManager.removeItem(at: legacyFileURL)
        } catch {
            rollback(database)
            throw error
        }
    }

    private func rollback(_ database: OpaquePointer) {
        do {
            try execute("ROLLBACK;", in: database)
        } catch {
            AppLog.persistence.error("Listening-history transaction rollback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func upsertTrack(for session: ListeningSession, in database: OpaquePointer) throws -> Int64 {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.isEmpty
            ? URL(fileURLWithPath: session.mediaID).deletingPathExtension().lastPathComponent
            : title
        let normalizedArtist = session.artist?.trimmingCharacters(in: .whitespacesAndNewlines)

        let upsert = try prepare(
            """
            INSERT INTO tracks (file_path, title, artist, duration_ms)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                title = excluded.title,
                artist = COALESCE(excluded.artist, tracks.artist),
                duration_ms = COALESCE(excluded.duration_ms, tracks.duration_ms);
            """,
            in: database
        )
        defer { sqlite3_finalize(upsert) }

        bind(session.mediaID, at: 1, in: upsert)
        bind(normalizedTitle, at: 2, in: upsert)
        bind(normalizedArtist?.isEmpty == false ? normalizedArtist : nil, at: 3, in: upsert)
        bind(session.durationMs, at: 4, in: upsert)
        try stepToCompletion(upsert, in: database)

        let lookup = try prepare("SELECT id FROM tracks WHERE file_path = ?;", in: database)
        defer { sqlite3_finalize(lookup) }
        bind(session.mediaID, at: 1, in: lookup)
        guard sqlite3_step(lookup) == SQLITE_ROW else {
            throw databaseError("Unable to retrieve the normalized track.")
        }
        return sqlite3_column_int64(lookup, 0)
    }

    private func rowCount(in table: String, database: OpaquePointer) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM \(table);", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw databaseError(message)
        }
    }

    private func stepToCompletion(_ statement: OpaquePointer, in database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func string(at index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func optionalInt(at index: Int32, in statement: OpaquePointer) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func stableUUID(for historyID: Int64) -> UUID {
        let suffix = UInt64(bitPattern: historyID) & 0x0000_FFFF_FFFF_FFFF
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", suffix)) ?? UUID()
    }

    private func databaseError(_ message: String) -> NSError {
        NSError(
            domain: "SQLiteListeningHistoryRepository",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
