import Foundation
import UniformTypeIdentifiers

struct ImportDocumentsUseCase {
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
    }

    /// Copies picked files/folders into the requested app-owned directory.
    /// Returns the destination URLs.
    func execute(urls: [URL], destinationDirectory: URL? = nil) async throws -> [URL] {
        try await executeBatch(urls: urls, destinationDirectory: destinationDirectory).completed
    }

    func executeBatch(urls: [URL], destinationDirectory: URL? = nil) async throws -> FileOperationBatchResult {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AppFilePolicyError.documentsDirectoryUnavailable
        }
        let policy = AppFilePathPolicy(rootURL: docs, fileManager: fileManager)
        let requestedDestination = destinationDirectory ?? docs
        let destination = try policy.validatedDirectory(requestedDestination, mustExist: false)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        return await AppFileMutationCoordinator.shared.importItems(urls, to: destination)
    }
}
