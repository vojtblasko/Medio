import Foundation

struct FileMoveService: @unchecked Sendable {
    private let fileManager: FileManager
    private let pathPolicy: AppFilePathPolicy?

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let resolvedRoot = rootURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        self.pathPolicy = resolvedRoot.map { AppFilePathPolicy(rootURL: $0, fileManager: fileManager) }
    }

    func canMove(_ path: String, toFolder destinationPath: String) -> Bool {
        guard !MedioShadowFolder.isFavorites(path) else { return false }
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        let destinationFolderURL = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
        guard let pathPolicy,
              pathPolicy.contains(sourceURL),
              (try? pathPolicy.validatedDirectory(destinationFolderURL)) != nil else { return false }
        guard fileManager.fileExists(atPath: sourceURL.path) else { return false }
        var isDirectory = ObjCBool(false)
        fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        guard sourceURL.path != destinationFolderURL.path else { return false }
        if isDirectory.boolValue, destinationFolderURL.path.hasPrefix(sourceURL.path + "/") {
            return false
        }
        return sourceURL.deletingLastPathComponent().path != destinationFolderURL.path
    }

    func canMove(_ paths: [String], toFolder destinationPath: String) -> Bool {
        paths.contains { canMove($0, toFolder: destinationPath) }
    }

    @discardableResult
    func move(paths: [String], toFolder destinationPath: String) async throws -> [URL] {
        try await moveBatch(paths: paths, toFolder: destinationPath).completed
    }

    func moveBatch(paths: [String], toFolder destinationPath: String) async throws -> FileOperationBatchResult {
        let destinationFolderURL = try validDestinationFolderURL(for: destinationPath)

        var result = FileOperationBatchResult()
        for path in paths {
            let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
            guard canMove(path, toFolder: destinationPath) else {
                result.failures.append(FileOperationFailure(source: sourceURL, message: "The item cannot be moved to that folder."))
                continue
            }
            do {
                let destinationURL = try await AppFileMutationCoordinator.shared.moveItem(
                    at: sourceURL,
                    toUniqueDestinationIn: destinationFolderURL
                )
                result.completed.append(destinationURL)
            } catch {
                result.failures.append(FileOperationFailure(source: sourceURL, message: error.localizedDescription))
            }
        }
        return result
    }

    @discardableResult
    func importFiles(at sourceURLs: [URL], toFolder destinationPath: String) async throws -> [URL] {
        try await importBatch(at: sourceURLs, toFolder: destinationPath).completed
    }

    func importBatch(at sourceURLs: [URL], toFolder destinationPath: String) async throws -> FileOperationBatchResult {
        let destinationFolderURL = try validDestinationFolderURL(for: destinationPath)

        var result = FileOperationBatchResult()
        for sourceURL in sourceURLs {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

            let sourceURL = sourceURL.standardizedFileURL
            guard fileManager.fileExists(atPath: sourceURL.path),
                  AppFilePathPolicy.isValidLeafName(sourceURL.lastPathComponent) else {
                result.failures.append(FileOperationFailure(source: sourceURL, message: "The item cannot be imported."))
                continue
            }
            do {
                let destinationURL = try await AppFileMutationCoordinator.shared.copyItem(
                    at: sourceURL,
                    toUniqueDestinationIn: destinationFolderURL
                )
                result.completed.append(destinationURL)
            } catch {
                result.failures.append(FileOperationFailure(source: sourceURL, message: error.localizedDescription))
            }
        }
        return result
    }

    private func validDestinationFolderURL(for destinationPath: String) throws -> URL {
        let destinationFolderURL = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
        guard let pathPolicy else { throw AppFilePolicyError.documentsDirectoryUnavailable }
        return try pathPolicy.validatedDirectory(destinationFolderURL)
    }
}
