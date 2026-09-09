import Foundation

/// Persists favorite file paths in `UserDefaults`.
@MainActor
final class UserDefaultsFavoritesRepository: FavoritesRepository {
    private let defaults: UserDefaults
    private let key: String
    private let addedDatesKey: String
    private let fileURL: URL?

    init(defaults: UserDefaults = .standard, key: String = "medio.favorites.v1") {
        self.defaults = defaults
        self.key = key
        self.addedDatesKey = "\(key).addedDates"
        // Prepare an atomic file-backed store in Application Support as a more robust persistence.
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("Medio", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("favorites.v1.json")
        } catch {
            AppLog.persistence.error("Favorites storage could not be prepared: \(error.localizedDescription, privacy: .public)")
            self.fileURL = nil
        }
    }

    func loadFavorites() async throws -> Set<String> {
        // Prefer file-backed cache (atomic), fall back to UserDefaults for compatibility
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let values = try JSONDecoder().decode([String].self, from: data)
                return Set(values.map(PersistedMediaPath.decode))
            } catch {
                AppLog.persistence.error("Favorites file was corrupt; using the compatibility snapshot: \(error.localizedDescription, privacy: .public)")
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    AppLog.persistence.error("Corrupt favorites file could not be removed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let arr = defaults.stringArray(forKey: key) ?? []
        return Set(arr.map(PersistedMediaPath.decode))
    }

    func loadFavoriteAddedDates() async throws -> [String: Date] {
        let values = defaults.dictionary(forKey: addedDatesKey) as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: values.map {
            (PersistedMediaPath.decode($0.key), Date(timeIntervalSince1970: $0.value))
        })
    }

    func setFavorite(_ path: String, isFavorite: Bool) async throws -> Set<String> {
        var set = try await loadFavorites()
        let before = set

        if isFavorite {
            set.insert(path)
        } else {
            set.remove(path)
        }

        // Idempotent: if no change, just return
        if set == before { return set }

        let arr = set.map(PersistedMediaPath.encode).sorted()

        // Write atomically to file if available
        if let url = fileURL {
            let data = try JSONEncoder().encode(arr)
            try data.write(to: url, options: [.atomic])
        }

        // Also keep UserDefaults in sync for other consumers
        defaults.set(arr, forKey: key)

        var addedDates = try await loadFavoriteAddedDates()
        if isFavorite {
            addedDates[path] = addedDates[path] ?? Date()
        } else {
            addedDates.removeValue(forKey: path)
        }
        let timestamps = Dictionary(uniqueKeysWithValues: addedDates.map {
            (PersistedMediaPath.encode($0.key), $0.value.timeIntervalSince1970)
        })
        defaults.set(timestamps, forKey: addedDatesKey)

        // Notify observers about change so stores/viewmodels update immediately.
        NotificationCenter.default.post(
            name: .medioFavoritesDidChange,
            object: self,
            userInfo: [
                "favorites": Array(set).sorted(),
                "addedDates": addedDates.mapValues(\.timeIntervalSince1970)
            ]
        )

        return set
    }
}
