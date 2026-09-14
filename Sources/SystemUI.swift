import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Service protocols

@MainActor
protocol PhotoPickingService: Sendable {
    /// Presents a photo picker and returns the selected image bytes (original).
    func pickImage() async throws -> Data
}

@MainActor
protocol DocumentPickingService: Sendable {
    /// Presents a document picker and returns a security-scoped URL if needed.
    func pickFile(contentTypes: [UTType], allowsMultipleSelection: Bool) async throws -> [URL]
}

// MARK: - Errors

enum SystemUIError: Error, LocalizedError {
    case cancelled
    case invalidSelection
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: return String(localized: "Cancelled.")
        case .invalidSelection: return String(localized: "Invalid selection.")
        case .presentationUnavailable: return String(localized: "UI presentation unavailable.")
        }
    }
}

// MARK: - Presenter (bridges services -> SwiftUI sheet)

@MainActor
final class SystemUIPresenter: ObservableObject {
    @Published var sheet: SystemSheet? = nil
    private var presentedSheet: SystemSheet?
    private var pendingResult: Swift.Result<SystemSheet.Result, Error>?
    private var hasDismissed = false
    private var isLoadingSelection = false
    private var presentationID = UUID()

    fileprivate func present(_ sheet: SystemSheet) async throws -> SystemSheet.Result {
        guard presentedSheet == nil else { throw SystemUIError.presentationUnavailable }
        return try await withCheckedThrowingContinuation { cont in
            let presented = sheet.withContinuation(cont)
            presentationID = UUID()
            hasDismissed = false
            presentedSheet = presented
            self.sheet = presented
        }
    }

    // PHPicker image providers may finish well after the sheet disappears.
    func beginLoadingSelection() {
        guard presentedSheet != nil, pendingResult == nil else { return }
        isLoadingSelection = true
    }

    func complete(_ result: Swift.Result<SystemSheet.Result, Error>) {
        guard presentedSheet != nil, pendingResult == nil else { return }
        isLoadingSelection = false
        pendingResult = result
        sheet = nil
        if hasDismissed { finishDismissal() }
    }

    func dismiss() {
        sheet = nil
    }

    func didDismiss() {
        guard presentedSheet != nil else { return }
        hasDismissed = true
        if pendingResult != nil {
            finishDismissal()
        } else {
            // UIDocumentPicker can dismiss its sheet before delivering didPickDocumentsAt
            // in the same event. Give that callback a chance before treating this as Cancel.
            let dismissedID = presentationID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presentationID == dismissedID else { return }
                self.finishDismissal()
            }
        }
    }

    private func finishDismissal() {
        guard hasDismissed, !isLoadingSelection, let presented = presentedSheet else { return }
        let result = pendingResult ?? .failure(SystemUIError.cancelled)
        presentedSheet = nil
        pendingResult = nil
        hasDismissed = false
        sheet = nil
        switch presented {
        case .photoPicker(let continuation), .documentPicker(_, _, let continuation):
            continuation?.resume(with: result)
        }
    }
}

enum SystemSheetResult: Sendable {
    case image(Data)
    case documents([URL])
}

enum SystemSheet: Identifiable {
    typealias Result = SystemSheetResult

    case photoPicker(continuation: CheckedContinuation<Result, Error>?)
    case documentPicker(types: [UTType], multiple: Bool, continuation: CheckedContinuation<Result, Error>?)

    var id: String {
        switch self {
        case .photoPicker: return "photoPicker"
        case .documentPicker(let types, let multiple, _):
            return "documentPicker:\(types.map { $0.identifier }.joined(separator: ",")):\(multiple)"
        }
    }

    func withContinuation(_ cont: CheckedContinuation<Result, Error>) -> SystemSheet {
        switch self {
        case .photoPicker:
            return .photoPicker(continuation: cont)
        case .documentPicker(let types, let multiple, _):
            return .documentPicker(types: types, multiple: multiple, continuation: cont)
        }
    }
}

// MARK: - Medio implementations (services)

@MainActor
final class MedioPhotoPickingService: PhotoPickingService {
    private let presenter: SystemUIPresenter

    init(presenter: SystemUIPresenter) {
        self.presenter = presenter
    }

    func pickImage() async throws -> Data {
        let result = try await presenter.present(.photoPicker(continuation: nil))
        guard case .image(let data) = result else { throw SystemUIError.invalidSelection }
        return data
    }
}

@MainActor
final class MedioDocumentPickingService: DocumentPickingService {
    private let presenter: SystemUIPresenter

    init(presenter: SystemUIPresenter) {
        self.presenter = presenter
    }

    func pickFile(contentTypes: [UTType], allowsMultipleSelection: Bool) async throws -> [URL] {
        let result = try await presenter.present(
            .documentPicker(types: contentTypes, multiple: allowsMultipleSelection, continuation: nil)
        )
        guard case .documents(let urls) = result else { throw SystemUIError.invalidSelection }
        return urls
    }
}

// MARK: - SwiftUI sheet content

struct SystemSheetHost: View {
    @ObservedObject var presenter: SystemUIPresenter
    var isActive = true

    var body: some View {
        EmptyView()
            .sheet(
                item: Binding<SystemSheet?>(
                    get: { isActive ? presenter.sheet : nil },
                    set: { _ in presenter.dismiss() }
                ),
                onDismiss: presenter.didDismiss
            ) { sheet in
                switch sheet {
                case .photoPicker:
                    PhotoPickerView(onBeginLoading: presenter.beginLoadingSelection) { result in
                        presenter.complete(result.map(SystemSheetResult.image))
                    }
                case .documentPicker(let types, let multiple, _):
                    DocumentPickerView(contentTypes: types, allowsMultipleSelection: multiple) { result in
                        presenter.complete(result.map(SystemSheetResult.documents))
                    }
                }
            }
    }
}

private struct PhotoPickerView: UIViewControllerRepresentable {
    typealias Completion = @MainActor @Sendable (Result<Data, Error>) -> Void
    let onBeginLoading: @MainActor @Sendable () -> Void
    let onComplete: Completion

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onBeginLoading: onBeginLoading, onComplete: onComplete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onBeginLoading: @MainActor @Sendable () -> Void
        let onComplete: Completion

        init(onBeginLoading: @escaping @MainActor @Sendable () -> Void, onComplete: @escaping Completion) {
            self.onBeginLoading = onBeginLoading
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let item = results.first else {
                onComplete(.failure(SystemUIError.cancelled))
                return
            }
            let provider = item.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else {
                onComplete(.failure(SystemUIError.invalidSelection))
                return
            }
            onBeginLoading()
            let complete = onComplete
            provider.loadObject(ofClass: UIImage.self) { object, error in
                let result: Result<Data, Error>
                if let error {
                    result = .failure(error)
                } else if let image = object as? UIImage, let data = image.pngData() {
                    result = .success(data)
                } else {
                    result = .failure(SystemUIError.invalidSelection)
                }
                Task { @MainActor in
                    complete(result)
                }
            }
        }
    }
}

private struct DocumentPickerView: UIViewControllerRepresentable {
    typealias Completion = @MainActor @Sendable (Result<[URL], Error>) -> Void
    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onComplete: Completion

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: Completion

        init(onComplete: @escaping Completion) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onComplete(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(.failure(SystemUIError.cancelled))
        }
    }
}
