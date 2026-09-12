import Foundation

protocol PreferencesRepository: Sendable {
    func loadSettings() async throws -> SettingsSnapshot
    func saveSettings(_ snapshot: SettingsSnapshot) async throws
}

struct SettingsSnapshot: Codable, Equatable, Sendable {
    var accentColorRgba: UInt32
    var nowPlayingBackgroundModeRaw: Int
    var nowPlayingCustomBackgroundColorRgba: UInt32
    var nowPlayingAlbumColorIndex: Int
    var nowPlayingShowsTotalDuration: Bool

    var priorityFoldersCount: Int
    var homeSortByRaw: Int
    var homeSortAscending: Bool
    var lyricsEnabled: Bool
    var appCanConnectToInternet: Bool
    var medioReCappedEnabled: Bool
    var showUnknownArtists: Bool
    var showUnknownAlbums: Bool
    var priorityFolderPaths: [String?]
    var prioritySlotArtworkPaths: [String: String]
    var prioritySlotImageOnlyKeys: [String]
    var favoritesPriorityFolderEnabled: Bool
    var favoritesHomeFolderEnabled: Bool
    var primaryPriorityFolderPath: String?
    var favoritesSortByRaw: Int
    var favoritesSortAscending: Bool

    init(
        accentColorRgba: UInt32,
        nowPlayingBackgroundModeRaw: Int,
        nowPlayingCustomBackgroundColorRgba: UInt32,
        nowPlayingAlbumColorIndex: Int,
        nowPlayingShowsTotalDuration: Bool = false,
        priorityFoldersCount: Int,
        homeSortByRaw: Int,
        homeSortAscending: Bool,
        lyricsEnabled: Bool,
        appCanConnectToInternet: Bool = false,
        medioReCappedEnabled: Bool = true,
        showUnknownArtists: Bool = true,
        showUnknownAlbums: Bool = true,
        priorityFolderPaths: [String?] = [],
        prioritySlotArtworkPaths: [String: String] = [:],
        prioritySlotImageOnlyKeys: [String] = [],
        favoritesHomeFolderEnabled: Bool = true,
        favoritesPriorityFolderEnabled: Bool? = nil,
        primaryPriorityFolderPath: String? = nil,
        favoritesSortByRaw: Int = FavoritesSortBy.dateAdded.rawValue,
        favoritesSortAscending: Bool = false
    ) {
        self.accentColorRgba = accentColorRgba
        self.nowPlayingBackgroundModeRaw = nowPlayingBackgroundModeRaw
        self.nowPlayingCustomBackgroundColorRgba = nowPlayingCustomBackgroundColorRgba
        self.nowPlayingAlbumColorIndex = nowPlayingAlbumColorIndex
        self.nowPlayingShowsTotalDuration = nowPlayingShowsTotalDuration
        self.priorityFoldersCount = priorityFoldersCount
        self.homeSortByRaw = homeSortByRaw
        self.homeSortAscending = homeSortAscending
        self.lyricsEnabled = lyricsEnabled
        self.appCanConnectToInternet = appCanConnectToInternet
        self.medioReCappedEnabled = medioReCappedEnabled
        self.showUnknownArtists = showUnknownArtists
        self.showUnknownAlbums = showUnknownAlbums
        self.priorityFolderPaths = priorityFolderPaths
        self.prioritySlotArtworkPaths = prioritySlotArtworkPaths
        self.prioritySlotImageOnlyKeys = prioritySlotImageOnlyKeys
        self.favoritesPriorityFolderEnabled = favoritesPriorityFolderEnabled ?? favoritesHomeFolderEnabled
        self.favoritesHomeFolderEnabled = favoritesHomeFolderEnabled
        self.primaryPriorityFolderPath = primaryPriorityFolderPath
        self.favoritesSortByRaw = favoritesSortByRaw
        self.favoritesSortAscending = favoritesSortAscending
    }

    enum CodingKeys: String, CodingKey {
        case accentColorRgba
        case nowPlayingBackgroundModeRaw
        case nowPlayingCustomBackgroundColorRgba
        case nowPlayingAlbumColorIndex
        case nowPlayingShowsTotalDuration
        case priorityFoldersCount
        case homeSortByRaw
        case homeSortAscending
        case lyricsEnabled
        case appCanConnectToInternet
        case medioReCappedEnabled
        case showUnknownArtists
        case showUnknownAlbums
        case priorityFolderPaths
        case prioritySlotArtworkPaths
        case prioritySlotImageOnlyKeys
        case favoritesPriorityFolderEnabled
        case favoritesHomeFolderEnabled
        case primaryPriorityFolderPath
        case favoritesSortByRaw
        case favoritesSortAscending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accentColorRgba = try container.decode(UInt32.self, forKey: .accentColorRgba)
        self.nowPlayingBackgroundModeRaw = try container.decode(Int.self, forKey: .nowPlayingBackgroundModeRaw)
        self.nowPlayingCustomBackgroundColorRgba = try container.decode(UInt32.self, forKey: .nowPlayingCustomBackgroundColorRgba)
        self.nowPlayingAlbumColorIndex = try container.decode(Int.self, forKey: .nowPlayingAlbumColorIndex)
        self.nowPlayingShowsTotalDuration = try container.decodeIfPresent(Bool.self, forKey: .nowPlayingShowsTotalDuration) ?? false
        self.priorityFoldersCount = try container.decode(Int.self, forKey: .priorityFoldersCount)
        self.homeSortByRaw = try container.decode(Int.self, forKey: .homeSortByRaw)
        self.homeSortAscending = try container.decode(Bool.self, forKey: .homeSortAscending)
        self.lyricsEnabled = try container.decode(Bool.self, forKey: .lyricsEnabled)
        self.appCanConnectToInternet = try container.decodeIfPresent(Bool.self, forKey: .appCanConnectToInternet) ?? false
        self.medioReCappedEnabled = try container.decodeIfPresent(Bool.self, forKey: .medioReCappedEnabled) ?? true
        self.showUnknownArtists = try container.decodeIfPresent(Bool.self, forKey: .showUnknownArtists) ?? true
        self.showUnknownAlbums = try container.decodeIfPresent(Bool.self, forKey: .showUnknownAlbums) ?? true
        self.priorityFolderPaths = try container.decodeIfPresent([String?].self, forKey: .priorityFolderPaths) ?? []
        self.prioritySlotArtworkPaths = try container.decodeIfPresent([String: String].self, forKey: .prioritySlotArtworkPaths) ?? [:]
        self.prioritySlotImageOnlyKeys = try container.decodeIfPresent([String].self, forKey: .prioritySlotImageOnlyKeys) ?? []
        self.favoritesHomeFolderEnabled = try container.decodeIfPresent(Bool.self, forKey: .favoritesHomeFolderEnabled) ?? true
        self.favoritesPriorityFolderEnabled = try container.decodeIfPresent(Bool.self, forKey: .favoritesPriorityFolderEnabled) ?? favoritesHomeFolderEnabled
        self.primaryPriorityFolderPath = try container.decodeIfPresent(String.self, forKey: .primaryPriorityFolderPath)
        self.favoritesSortByRaw = try container.decodeIfPresent(Int.self, forKey: .favoritesSortByRaw) ?? FavoritesSortBy.dateAdded.rawValue
        self.favoritesSortAscending = try container.decodeIfPresent(Bool.self, forKey: .favoritesSortAscending) ?? false
    }

    @MainActor
    static func fromStore(_ store: SettingsStore) -> SettingsSnapshot {
        let pathPolicy = try? AppFilePathPolicy.documents()
        func persistedPath(_ path: String?) -> String? {
            guard let path else { return nil }
            return pathPolicy?.stableIdentity(for: URL(fileURLWithPath: path)) ?? path
        }
        return SettingsSnapshot(
            accentColorRgba: store.accentColor.rgba,
            nowPlayingBackgroundModeRaw: store.nowPlayingBackgroundMode.rawValue,
            nowPlayingCustomBackgroundColorRgba: store.nowPlayingCustomBackgroundColor.rgba,
            nowPlayingAlbumColorIndex: store.nowPlayingAlbumColorIndex,
            nowPlayingShowsTotalDuration: store.nowPlayingShowsTotalDuration,
            priorityFoldersCount: store.priorityFoldersCount,
            homeSortByRaw: store.homeSortBy.rawValue,
            homeSortAscending: store.homeSortAscending,
            lyricsEnabled: store.lyricsEnabled,
            appCanConnectToInternet: store.appCanConnectToInternet,
            medioReCappedEnabled: store.medioReCappedEnabled,
            showUnknownArtists: store.showUnknownArtists,
            showUnknownAlbums: store.showUnknownAlbums,
            priorityFolderPaths: store.priorityFolderPaths.map(persistedPath),
            prioritySlotArtworkPaths: store.prioritySlotArtworkPaths,
            prioritySlotImageOnlyKeys: Array(store.prioritySlotImageOnlyKeys).sorted(),
            favoritesHomeFolderEnabled: store.favoritesHomeFolderEnabled,
            favoritesPriorityFolderEnabled: store.favoritesPriorityFolderEnabled,
            primaryPriorityFolderPath: persistedPath(store.primaryPriorityFolderPath),
            favoritesSortByRaw: store.favoritesSortBy.rawValue,
            favoritesSortAscending: store.favoritesSortAscending
        )
    }

    @MainActor
    func apply(to store: SettingsStore) {
        let pathPolicy = try? AppFilePathPolicy.documents()
        func restoredPath(_ identity: String?) -> String? {
            guard let identity else { return nil }
            return pathPolicy?.url(forStableIdentity: identity)?.path ?? identity
        }
        store.accentColor = ColorToken(rgba: accentColorRgba)
        store.nowPlayingBackgroundMode = NowPlayingBackgroundMode(rawValue: nowPlayingBackgroundModeRaw) ?? .dynamic
        store.nowPlayingCustomBackgroundColor = ColorToken(rgba: nowPlayingCustomBackgroundColorRgba)
        store.nowPlayingAlbumColorIndex = min(3, max(0, nowPlayingAlbumColorIndex))
        store.nowPlayingShowsTotalDuration = nowPlayingShowsTotalDuration

        store.priorityFoldersCount = min(10, max(0, priorityFoldersCount))
        store.homeSortBy = HomeSortBy(rawValue: homeSortByRaw) ?? .added
        store.homeSortAscending = homeSortAscending
        store.lyricsEnabled = lyricsEnabled
        store.appCanConnectToInternet = appCanConnectToInternet
        store.medioReCappedEnabled = medioReCappedEnabled
        store.showUnknownArtists = showUnknownArtists
        store.showUnknownAlbums = showUnknownAlbums
        store.priorityFolderPaths = priorityFolderPaths.map(restoredPath)
        store.prioritySlotArtworkPaths = prioritySlotArtworkPaths
        store.prioritySlotImageOnlyKeys = Set(prioritySlotImageOnlyKeys)
        store.favoritesHomeFolderEnabled = favoritesHomeFolderEnabled
        store.favoritesPriorityFolderEnabled = favoritesPriorityFolderEnabled
        store.primaryPriorityFolderPath = restoredPath(primaryPriorityFolderPath)
        store.favoritesSortBy = FavoritesSortBy(rawValue: favoritesSortByRaw) ?? .dateAdded
        store.favoritesSortAscending = favoritesSortAscending
    }

    static var defaults: SettingsSnapshot {
        SettingsSnapshot(
            accentColorRgba: 0x000000FF,
            nowPlayingBackgroundModeRaw: NowPlayingBackgroundMode.dynamic.rawValue,
            nowPlayingCustomBackgroundColorRgba: 0x000000FF,
            nowPlayingAlbumColorIndex: 0,
            priorityFoldersCount: 4,
            homeSortByRaw: HomeSortBy.added.rawValue,
            homeSortAscending: true,
            lyricsEnabled: true
        )
    }
}
