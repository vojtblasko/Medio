import Foundation

enum AppTab: Hashable {
    case home
    case library
    case playground
    case search
}

enum SheetRoute: Hashable, Identifiable {
    case nowPlaying
    case queue
    case settings
    case lyricsSettings
    case crashReportManager
    case favorites
    case favoritesAbout
    case fileAbout(path: String)
    case priorityFolderAbout(path: String)
    case prioritySlotAbout(slot: Int)
    case folder(path: String)
    case folderBrowser(path: String)
    case priorityFolderPicker(slot: Int)
    case moveItem(path: String)
    case moveItems
    case createFolder(parentPath: String?)
    case album(name: String)
    case artistAlbum(artistName: String, albumName: String)
    case albumAbout(name: String)
    case artistAlbumAbout(artistName: String, albumName: String)
    case artist(name: String)
    case artistAbout(name: String)

    var id: String {
        switch self {
        case .nowPlaying: return "nowPlaying"
        case .queue: return "queue"
        case .settings: return "settings"
        case .lyricsSettings: return "lyricsSettings"
        case .crashReportManager: return "crashReportManager"
        case .favorites: return "favorites"
        case .favoritesAbout: return "favoritesAbout"
        case .fileAbout(let path): return "fileAbout:\(path)"
        case .priorityFolderAbout(let path): return "priorityFolderAbout:\(path)"
        case .prioritySlotAbout(let slot): return "prioritySlotAbout:\(slot)"
        case .folder(let path): return "folder:\(path)"
        case .folderBrowser(let path): return "folderBrowser:\(path)"
        case .priorityFolderPicker(let slot): return "priorityFolderPicker:\(slot)"
        case .moveItem(let path): return "moveItem:\(path)"
        case .moveItems: return "moveItems"
        case .createFolder(let parentPath): return "createFolder:\(parentPath ?? "")"
        case .album(let name): return "album:\(name)"
        case .artistAlbum(let artistName, let albumName): return "artistAlbum:\(artistName):\(albumName)"
        case .albumAbout(let name): return "albumAbout:\(name)"
        case .artistAlbumAbout(let artistName, let albumName): return "artistAlbumAbout:\(artistName):\(albumName)"
        case .artist(let name): return "artist:\(name)"
        case .artistAbout(let name): return "artistAbout:\(name)"
        }
    }
}
