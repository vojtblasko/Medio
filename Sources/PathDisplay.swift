import Foundation

enum AppFileRoot {
    static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL
    }

    static var documentsPath: String? {
        documentsURL?.path
    }

    static func contains(_ path: String, includeRoot: Bool = true) -> Bool {
        guard let docs = documentsPath else { return false }
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if includeRoot, std == docs { return true }
        return std.hasPrefix(docs + "/")
    }
}

// Shared helper to display file paths relative to the app's Documents sandbox.
extension String {
    /// Returns a display path using the app's Documents directory as the visible root.
    /// - If the path equals the Documents path, returns "/".
    /// - If the path is inside Documents, returns the relative subpath (e.g., "Music/Album").
    /// - If the path is outside Documents, returns "/" to hide it completely.
    var appRelativeDisplayPath: String {
        guard let docs = AppFileRoot.documentsPath else {
            return "/"
        }
        let std = URL(fileURLWithPath: self).standardizedFileURL.path
        if std == docs { return "/" }
        if std.hasPrefix(docs + "/") {
            let rel = String(std.dropFirst(docs.count + 1))
            return rel.isEmpty ? "/" : rel
        }
        // Path is outside the sandbox - hide it by returning root
        return "/"
    }

    var isInsideAppFileRoot: Bool {
        AppFileRoot.contains(self)
    }

    /// Returns an absolute-looking path rooted at the app's private sandbox.
    /// For example, `<sandbox>/Documents/Music` is displayed as `/Documents/Music`.
    var sandboxRelativeDisplayPath: String {
        let sandboxRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: self).standardizedFileURL.path
        if standardizedPath == sandboxRoot { return "/" }
        guard standardizedPath.hasPrefix(sandboxRoot + "/") else { return "/" }
        return "/" + standardizedPath.dropFirst(sandboxRoot.count + 1)
    }
}
