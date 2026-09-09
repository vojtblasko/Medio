import Foundation

private struct SettingsEnvelope: Codable {
    static let currentVersion = 2
    let version: Int
    let snapshot: SettingsSnapshot
}

enum SettingsPersistenceError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum SettingsPersistence {
    static let key = "medio.settings.v2"
    static let legacyKey = "medio.settings.v1"

    static func load(from defaults: UserDefaults) throws -> SettingsSnapshot? {
        if let data = defaults.data(forKey: key) {
            let envelope = try JSONDecoder().decode(SettingsEnvelope.self, from: data)
            guard envelope.version == SettingsEnvelope.currentVersion else {
                throw SettingsPersistenceError.unsupportedVersion(envelope.version)
            }
            return envelope.snapshot
        }
        if let data = defaults.data(forKey: legacyKey) {
            return try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        }
        return nil
    }

    static func save(_ snapshot: SettingsSnapshot, to defaults: UserDefaults) throws {
        let envelope = SettingsEnvelope(version: SettingsEnvelope.currentVersion, snapshot: snapshot)
        let data = try JSONEncoder().encode(envelope)
        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }
}

final class SettingsDefaultsStorage: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}

actor UserDefaultsPreferencesRepository: PreferencesRepository {
    private let storage: SettingsDefaultsStorage

    init(storage: SettingsDefaultsStorage = SettingsDefaultsStorage(.standard)) {
        self.storage = storage
    }

    func loadSettings() async throws -> SettingsSnapshot {
        let defaults = storage.defaults
        do {
            return try SettingsPersistence.load(from: defaults) ?? .defaults
        } catch {
            AppLog.persistence.error("Settings data is corrupt: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: SettingsPersistence.key)
            return .defaults
        }
    }

    func saveSettings(_ snapshot: SettingsSnapshot) async throws {
        try SettingsPersistence.save(snapshot, to: storage.defaults)
    }
}
