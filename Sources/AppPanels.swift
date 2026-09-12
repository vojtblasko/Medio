import SwiftUI
import Foundation
import UniformTypeIdentifiers
import UIKit
import CoreImage

extension FileInfo {
    var medioAboutActionTitle: String {
        if MedioShadowFolder.isFavorites(id) { return "About Favorites" }
        switch fileType {
        case .folder: return String(localized: "About Folder")
        case .music: return String(localized: "About Music")
        case .lyrics:
            return URL(fileURLWithPath: id).pathExtension.lowercased() == "txt" ? String(localized: "About Text") : String(localized: "About Lyrics")
        case .video: return String(localized: "About Video")
        case .unrecognized:
            return URL(fileURLWithPath: id).pathExtension.lowercased() == "txt" ? String(localized: "About Text") : String(localized: "About File")
        }
    }
}

private enum CoverImageSource {
    case photos
    case files
}

private struct PendingCoverCrop: Identifiable {
    let id = UUID()
    let image: UIImage
}

@MainActor
private func loadCoverImageData(from source: CoverImageSource, container: AppContainer) async throws -> Data {
    switch source {
    case .photos:
        return try await container.photoPickingService.pickImage()
    case .files:
        let urls = try await container.documentPickingService.pickFile(contentTypes: [.image], allowsMultipleSelection: false)
        guard let url = urls.first else {
            throw SystemUIError.invalidSelection
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}

private func imageNeedsSquareCrop(_ image: UIImage) -> Bool {
    abs(image.size.width - image.size.height) > 1
}

private func artistImageNeedsSquareCrop(_ image: UIImage) -> Bool {
    image.size.height - image.size.width > 1
}

private enum FolderDestinationVisibility {
    private static let reCappedRootNames: Set<String> = [
        "medio recapped",
        ["medio", "wrap" + "ped"].joined(separator: " ")
    ]
    private static let appSandboxParentFolderNames: Set<String> = [
        "containers",
        "data"
    ]

    static func isSelectableFolder(_ path: String) -> Bool {
        guard let documentsPath = AppFileRoot.documentsPath else { return false }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardizedPath.hasPrefix(documentsPath + "/") else { return false }

        let relativePath = String(standardizedPath.dropFirst(documentsPath.count + 1))
        let components = relativePath
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != ".." }
        guard !components.isEmpty, components.joined(separator: "/") == relativePath else {
            return false
        }

        let normalizedComponents = components.map { $0.lowercased() }
        if let first = normalizedComponents.first, reCappedRootNames.contains(first) {
            return false
        }
        if components.count == 1, let first = normalizedComponents.first, appSandboxParentFolderNames.contains(first) {
            return false
        }
        return true
    }
}

@MainActor
private func saveCoverImage(_ image: UIImage, for paths: [String], container: AppContainer) throws {
    let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData() ?? Data()
    let artworkPath = try VisualArtworkOverrideStore.saveArtwork(data)
    for path in paths {
        var override = container.visualMetadataOverridesRepository.loadOverride(forMediaPath: path) ?? VisualMetadataOverride()
        override.coverArtworkPath = artworkPath
        container.visualMetadataOverridesRepository.saveOverride(override, forMediaPath: path)
    }
}

@MainActor
private func revertCoverImage(for paths: [String], container: AppContainer) {
    for path in paths {
        var override = container.visualMetadataOverridesRepository.loadOverride(forMediaPath: path) ?? VisualMetadataOverride()
        override.coverArtworkPath = nil
        container.visualMetadataOverridesRepository.saveOverride(override, forMediaPath: path)
    }
}

/// Shared preview/export geometry keeps panning inside the image at every zoom level.
struct CoverCropGeometry {
    static func imageRect(source: CGSize, viewport: CGSize, zoom: CGFloat, offset: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: viewport) }
        let scale = max(viewport.width / source.width, viewport.height / source.height) * max(1, zoom)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let limitX = max(0, (size.width - viewport.width) / 2)
        let limitY = max(0, (size.height - viewport.height) / 2)
        return CGRect(x: (viewport.width - size.width) / 2 + min(limitX, max(-limitX, offset.width)),
                      y: (viewport.height - size.height) / 2 + min(limitY, max(-limitY, offset.height)),
                      width: size.width, height: size.height)
    }
}

private struct CoverImageCropSheet: View {
    let image: UIImage
    var aspectRatio: CGFloat = 1
    let onCancel: () -> Void
    let onUse: (UIImage) -> Void
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var cropSize = CGSize(width: 1, height: 1)

    var body: some View {
        CompatibleNavigationStack {
            VStack(spacing: 18) {
                GeometryReader { proxy in
                    let width = max(1, min(proxy.size.width, proxy.size.height * aspectRatio))
                    let viewport = CGSize(width: width, height: width / aspectRatio)
                    let rect = CoverCropGeometry.imageRect(source: image.size, viewport: viewport, zoom: scale, offset: offset)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .frame(width: viewport.width, height: viewport.height)
                        .clipped()
                        .overlay(Rectangle().stroke(Color.primary.opacity(0.4), lineWidth: 1))
                        .accessibilityIdentifier("cover_crop_viewport")
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }.onEnded { _ in constrainOffset(in: viewport); lastOffset = offset })
                        .simultaneousGesture(MagnificationGesture().onChanged { value in
                            scale = min(5, max(1, lastScale * value))
                        }.onEnded { _ in lastScale = scale; constrainOffset(in: viewport) })
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .onAppear { cropSize = viewport }
                        .onChange(of: viewport) { size in cropSize = size; constrainOffset(in: size) }
                }
                .frame(minHeight: 240)
                Text("Drag or pinch to choose the crop.")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { scale }, set: {
                    scale = $0; lastScale = $0; constrainOffset(in: cropSize)
                }), in: 1...5) { Text("Zoom") } minimumValueLabel: {
                    Image(systemName: "minus.magnifyingglass")
                } maximumValueLabel: { Image(systemName: "plus.magnifyingglass") }
            }
            .padding()
            .navigationTitle("Crop Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Use Image") { onUse(renderedImage()) } }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset Crop") { offset = .zero; lastOffset = .zero; scale = 1; lastScale = 1 }
                }
            }
        }
    }

    private func constrainOffset(in viewport: CGSize) {
        let rect = CoverCropGeometry.imageRect(source: image.size, viewport: viewport, zoom: scale, offset: offset)
        offset = CGSize(width: rect.midX - viewport.width / 2, height: rect.midY - viewport.height / 2)
        lastOffset = offset
    }

    private func renderedImage() -> UIImage {
        let target = CGSize(width: aspectRatio >= 1 ? 900 : 900 * aspectRatio,
                            height: aspectRatio >= 1 ? 900 / aspectRatio : 900)
        let ratio = target.width / max(cropSize.width, 1)
        let rect = CoverCropGeometry.imageRect(source: image.size, viewport: target, zoom: scale,
            offset: CGSize(width: offset.width * ratio, height: offset.height * ratio))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            image.draw(in: rect)
        }
    }
}

private struct QueueItemRow: View {
    let item: MediaItem
    let isCurrent: Bool
    var repeatsCurrent = false

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? (repeatsCurrent ? "repeat.1" : "speaker.wave.2.fill") : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(2)
                Text(localizedMediaPlaceholder(item.artist ?? "Unknown Artist"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct QueuePanel: View {
    @ObservedObject var vm: QueueViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Group {
            List {
                if vm.queue.isEmpty {
                    CompatibleContentUnavailableView(String(localized: "Queue Empty"), systemImage: "music.note.list")
                } else {
                    ForEach(Array(vm.queue.enumerated()), id: \.offset) { index, item in
                        Button {
                            Task { await vm.play(at: index) }
                        } label: {
                            QueueItemRow(item: item, isCurrent: vm.currentIndex == index, repeatsCurrent: vm.playback.repeatMode == .one)
                                .opacity(index < (vm.currentIndex ?? 0) ? 0.5 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityIdentifier("queue_item_\(index)")
                        .accessibilityValue(vm.currentIndex == index && vm.playback.repeatMode == .one ? "Loop song" : "")
                        .medioNativeDrag(
                            container.libraryStore.allItems.first(where: { $0.id == item.id })
                        )
                    }
                    .onDelete { offsets in
                        Task { await vm.remove(at: offsets) }
                    }
                    .onMove { offsets, destination in
                        Task { await vm.move(from: offsets, to: destination) }
                    }
                    if vm.playback.repeatMode == .all {
                        Label("Loop queue", systemImage: "repeat")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("queue_repeat_all")
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") { Task { await vm.clear() } }
                        .disabled(vm.queue.isEmpty)
                }
            }
        }
    }
}

struct FavoritesPanel: View {
    @ObservedObject var vm: FavoritesViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer
    @State private var showViewOptions = false
    @AppStorage("medio.home.viewStyle") private var browserViewStyle: FileBrowserViewStyle = .list
    @AppStorage(FileBrowserIconSizing.storageKey) private var browserIconSize = FileBrowserIconSizing.defaultSize

    private var fileGridColumns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: FileBrowserIconSizing.gridMinimum(for: browserIconSize),
                maximum: FileBrowserIconSizing.gridMaximum(for: browserIconSize)
            ),
            spacing: 12,
            alignment: .top
        )]
    }

    var body: some View {
        Group {
            switch browserViewStyle {
            case .icons:
                favoritesIconContent
            case .list:
                favoritesListContent
            case .desktop:
                favoritesDesktopContent
            }
        }
        .searchable(
            text: $vm.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .navigationTitle("Favorites")
        .toolbar {
            CircularTrailingToolbarItem {
                favoritesOptionsMenu
            }
        }
        .sheet(isPresented: $showViewOptions) {
            FileBrowserViewOptionsPanel(iconSize: $browserIconSize)
        }
    }

    private var favoritesListContent: some View {
        List {
            if vm.filtered.isEmpty {
                CompatibleContentUnavailableView(
                    vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Favorites") : String(localized: "No Results"),
                    systemImage: "star"
                )
            } else {
                ForEach(vm.filtered) { item in
                    HStack(spacing: 12) {
                        favoriteButton(for: item) {
                            MediaItemRow(item: item, librarySongs: container.libraryStore.librarySongs)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button(role: .destructive) {
                            Task {
                                await container.libraryStore.setFavorite(
                                    item.id,
                                    isFavorite: false,
                                    favoritesRepository: container.favoritesRepository
                                )
                            }
                        } label: {
                            Image(systemName: "star.slash")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove Favorite")
                    }
                }
            }
        }
    }

    private var favoritesIconContent: some View {
        ScrollView {
            if vm.filtered.isEmpty {
                CompatibleContentUnavailableView(
                    vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Favorites") : String(localized: "No Results"),
                    systemImage: "star"
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: fileGridColumns, alignment: .leading, spacing: 22) {
                    ForEach(vm.filtered) { item in
                        favoriteIconButton(for: item)
                    }
                }
                .padding(16)
            }
        }
        .background(Color.clear)
    }

    private var favoritesDesktopContent: some View {
        DesktopFileCanvas(
            items: vm.filtered,
            librarySongs: container.libraryStore.librarySongs,
            storageContainerPath: "medio://desktop/favorites",
            filesystemContainerPath: nil,
            defaultDropTitle: String(localized: "Arrange Favorites"),
            emptyTitle: vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Favorites") : String(localized: "No Results"),
            emptySystemImage: "star",
            isSelecting: false,
            selectedItemIDs: [],
            isMovable: { _ in true },
            isFolderDropEnabled: { _ in false },
            onOpen: { item in Task { await vm.play(item) } },
            dragPaths: { [$0.id] },
            makeMenu: favoriteItemMenu,
            onMove: { _, _ in },
            onImport: { _, _ in },
            onSpringLoad: { _ in }
        ) { }
    }

    @ViewBuilder
    private func favoriteButton<Label: View>(
        for item: FileInfo,
        allowsDrag: Bool = true,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let button = Button {
            Task { await vm.play(item) }
        } label: {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .contextMenu {
            Button(item.medioAboutActionTitle, systemImage: "info.circle") {
                router.present(.fileAbout(path: item.id))
            }
        }
        if allowsDrag {
            button.medioNativeDrag(item)
        } else {
            button
        }
    }

    private func favoriteIconButton(for item: FileInfo) -> some View {
        favoriteButton(for: item, allowsDrag: false) {
            FileBrowserIconTile(
                item: item,
                librarySongs: container.libraryStore.librarySongs,
                isSelecting: false,
                isSelected: false,
                isMovable: true,
                usesCardBackground: false,
                iconSize: FileBrowserIconSizing.clamped(browserIconSize)
            )
        }
    }

    private var favoritesOptionsMenu: some View {
        NativeBrowserOptionsMenu(accessibilityLabel: String(localized: "Favorites Options")) {
            UIMenu(children: [
                BrowserOptionsMenu.section([BrowserOptionsMenu.action("Settings", "gearshape") { router.present(.settings) }]),
                BrowserOptionsMenu.views(selected: browserViewStyle) { browserViewStyle = $0 },
                BrowserOptionsMenu.sorts(FavoritesSortBy.menuCases, selected: container.settingsStore.favoritesSortBy,
                    ascending: container.settingsStore.favoritesSortAscending, title: { $0.title }) {
                        container.settingsStore.selectFavoritesSort($0)
                    },
                BrowserOptionsMenu.section([BrowserOptionsMenu.action("View Options", "slider.horizontal.3") { showViewOptions = true }])
            ])
        }
    }


    private func favoriteItemMenu(for item: FileInfo) -> UIMenu {
        UIMenu(children: [
            UIAction(title: item.medioAboutActionTitle, image: UIImage(systemName: "info.circle")) { _ in
                router.present(.fileAbout(path: item.id))
            }
        ])
    }

}

struct FavoritesAboutPanel: View {
    @ObservedObject var libraryStore: LibraryStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        List {
            Section("Favorites") {
                CompatibleLabeledContent("Songs", value: "\(libraryStore.favorites.count)")
                Text("Favorites is an in-app shadow folder. It links to the original songs without moving them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About Favorites")
    }
}

struct FileAboutPanel: View {
    let path: String
    let item: FileInfo?
    @ObservedObject var container: AppContainer
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    var titleOverride: String? = nil
    @EnvironmentObject private var router: AppRouter
    @State private var showEditMetadata = false
    @State private var showCoverSourceDialog = false
    @State private var showFolderColorSheet = false
    @State private var pendingCoverCrop: PendingCoverCrop?
    @State private var metadataOverride: VisualMetadataOverride?
    @State private var properties: FileProperties?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var query = ""
    @State private var showsAbsoluteLocation = false

    var body: some View {
        Group {
            List {
                if showsFileSection {
                    Section("File") {
                        editableTitleButton
                        Text(path.sandboxRelativeDisplayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if item?.isDirectory == true, showsIconSection {
                    Section("Icon") {
                        coverIconButton(subtitle: String(localized: "Choose image, file, or folder color"))
                    }
                } else {
                    if showsIconSection {
                        Section("Icon") {
                            coverIconButton(subtitle: String(localized: "Choose image from Photos or Files"))
                        }
                    }
                    if showsEditableMetadataSection {
                        Section("Editable Metadata") {
                            editableMetadataRow("Artist", value: metadataOverride?.artist ?? item?.author ?? "Unknown Artist")
                            editableMetadataRow(String(localized: "Album"), value: metadataOverride?.album ?? item?.album ?? "Unknown Album")
                            editableMetadataRow(String(localized: "Genre"), value: metadataOverride?.genre ?? item?.genre ?? String(localized: "Not Set"))
                            editableMetadataRow(String(localized: "Year"), value: metadataOverride?.year ?? item?.year ?? String(localized: "Not Set"))
                        }
                    }
                }
                if showsPropertiesSection {
                    Section("Properties") {
                        if let properties {
                            CompatibleLabeledContent(String(localized: "Kind"), value: properties.kind)
                            locationButton(properties.location)
                            if let size = properties.size { CompatibleLabeledContent(String(localized: "Size"), value: size) }
                            if let itemCount = properties.itemCount { CompatibleLabeledContent("Items", value: itemCount) }
                            if let created = properties.created { CompatibleLabeledContent(String(localized: "Created"), value: created) }
                            if let modified = properties.modified { CompatibleLabeledContent(String(localized: "Modified"), value: modified) }
                            if let lastOpened = properties.lastOpened { CompatibleLabeledContent(String(localized: "Last Opened"), value: lastOpened) }
                        } else {
                            ProgressView("Loading properties")
                        }
                    }
                }
                if let item, showsMetadataSection {
                    Section("Metadata") {
                        if let author = item.author { CompatibleLabeledContent("Artist", value: author) }
                        if let album = item.album { CompatibleLabeledContent(String(localized: "Album"), value: album) }
                        if let duration = item.durationMs { CompatibleLabeledContent(String(localized: "Duration"), value: formattedDuration(duration)) }
                    }
                }
                if !hasSearchResults {
                    CompatibleContentUnavailableView(String(localized: "No Results"), systemImage: "magnifyingglass")
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .compatibleScrollContentBackgroundHidden()
            .background(Color.black.ignoresSafeArea())
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .navigationTitle(aboutTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { aboutToolbar }
            .sheet(isPresented: $showEditMetadata, onDismiss: {
                loadOverride()
                nowPlayingVM.syncFromStore()
            }) {
                EditMetadataView(
                    title: aboutTitle.replacingOccurrences(of: "About", with: String(localized: "Edit")),
                    filePaths: [path],
                    currentOverride: metadataOverride,
                    defaultValues: defaultMetadataValues,
                    fields: editableFields
                )
            }
            .sheet(item: $pendingCoverCrop) { pending in
                CoverImageCropSheet(
                    image: pending.image,
                    onCancel: { pendingCoverCrop = nil },
                    onUse: { image in
                        applyPickedCover(image)
                        pendingCoverCrop = nil
                    }
                )
            }
            .sheet(isPresented: $showFolderColorSheet) {
                FolderColorPickerSheet(
                    initialColor: currentFolderColor,
                    hasSavedColor: metadataOverride?.folderColorRgba != nil,
                    onCancel: { showFolderColorSheet = false },
                    onSave: { color in
                        applyFolderColor(color)
                        showFolderColorSheet = false
                    },
                    onRevert: {
                        revertFolderColor()
                        showFolderColorSheet = false
                    }
                )
            }
            .alert("Cover Icon", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task(id: path) {
                loadOverride()
                properties = await FileProperties.load(for: path)
            }
            .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { notification in
                guard let changedPath = notification.userInfo?["path"] as? String else {
                    loadOverride()
                    return
                }
                if changedPath == path {
                    loadOverride()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ToolbarContentBuilder
    private var aboutToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            if router.sheet != nil, !router.canGoBackInSheet {
                Button {
                    router.dismissSheet()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            aboutOptionsMenu
        }
    }

    private var aboutOptionsMenu: some View {
        ToolbarGlassMenu(accessibilityLabel: String(localized: "File Options")) {
            Button("Edit Details", systemImage: "pencil") {
                showEditMetadata = true
            }
            Divider()
            Button("Choose Icon from Photos", systemImage: "photo.on.rectangle") {
                Task { await pickCover(from: .photos) }
            }
            Button("Choose Icon from Files", systemImage: "folder") {
                Task { await pickCover(from: .files) }
            }
            if item?.isDirectory == true {
                Button("Change Folder Color", systemImage: "paintpalette") {
                    showFolderColorSheet = true
                }
            }
            if metadataOverride?.coverArtworkPath != nil {
                Divider()
                Button("Revert Icon", systemImage: "arrow.counterclockwise", role: .destructive) {
                    revertCover()
                }
            }
            if item?.isDirectory == true, metadataOverride?.folderColorRgba != nil {
                Button("Revert Folder Color", systemImage: "arrow.counterclockwise.circle", role: .destructive) {
                    revertFolderColor()
                }
            }
        }
    }

    @ViewBuilder
    private var editableTitleButton: some View {
        Button {
            showEditMetadata = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func editableMetadataRow(_ label: String, value: String) -> some View {
        Button {
            showEditMetadata = true
        } label: {
            CompatibleLabeledContent(label, value: value)
        }
        .buttonStyle(.plain)
    }

    private func locationButton(_ absoluteLocation: String) -> some View {
        Button {
            showsAbsoluteLocation.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Location")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(showsAbsoluteLocation ? absoluteLocation : absoluteLocation.sandboxRelativeDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(showsAbsoluteLocation ? "Shows full device path. Double-tap for sandbox-relative path." : "Shows sandbox-relative path. Double-tap for full device path.")
    }

    @ViewBuilder
    private func coverIconButton(subtitle: String) -> some View {
        Button {
            showCoverSourceDialog = true
        } label: {
            HStack(spacing: 12) {
                AboutCoverThumbnail(path: path, item: item, librarySongs: container.libraryStore.librarySongs)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item?.isDirectory == true ? "Folder Icon" : "Cover Icon")
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCoverSourceDialog, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            CoverIconOptionsPopover(
                isFolder: item?.isDirectory == true,
                hasCover: metadataOverride?.coverArtworkPath != nil,
                hasFolderColor: metadataOverride?.folderColorRgba != nil,
                choosePhotos: {
                    showCoverSourceDialog = false
                    Task { await pickCover(from: .photos) }
                },
                chooseFiles: {
                    showCoverSourceDialog = false
                    Task { await pickCover(from: .files) }
                },
                changeFolderColor: {
                    showCoverSourceDialog = false
                    showFolderColorSheet = true
                },
                revertCover: {
                    showCoverSourceDialog = false
                    revertCover()
                },
                revertFolderColor: {
                    showCoverSourceDialog = false
                    revertFolderColor()
                }
            )
            .compatiblePopoverCompactAdaptation()
        }
    }

    private var displayTitle: String {
        metadataOverride?.title ?? item?.displayName ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private var aboutTitle: String {
        titleOverride ?? item?.medioAboutActionTitle ?? aboutTitleForPath(path)
    }

    private var showsFileSection: Bool {
        matchesSearch(["file", "name", displayTitle, path, path.appRelativeDisplayPath])
    }

    private var showsIconSection: Bool {
        matchesSearch(["icon", "cover", "photos", "files", item?.isDirectory == true ? "folder color" : nil])
    }

    private var showsEditableMetadataSection: Bool {
        guard item?.fileType == .music || item?.fileType == .video else { return false }
        return matchesSearch([
            "editable metadata artist album genre year",
            metadataOverride?.artist ?? item?.author,
            metadataOverride?.album ?? item?.album,
            metadataOverride?.genre ?? item?.genre,
            metadataOverride?.year ?? item?.year
        ])
    }

    private var showsPropertiesSection: Bool {
        matchesSearch([
            "properties kind location size items created modified last opened",
            properties?.kind,
            properties?.location,
            properties?.size,
            properties?.itemCount,
            properties?.created,
            properties?.modified,
            properties?.lastOpened
        ])
    }

    private var showsMetadataSection: Bool {
        guard let item else { return false }
        return matchesSearch([
            "metadata artist album duration",
            item.author,
            item.album,
            item.durationMs.map(formattedDuration)
        ])
    }

    private var hasSearchResults: Bool {
        showsFileSection || showsIconSection || showsEditableMetadataSection || showsPropertiesSection || showsMetadataSection
    }

    private func matchesSearch(_ values: [String?]) -> Bool {
        let normalizedQuery = normalizedSearchText(query)
        guard !normalizedQuery.isEmpty else { return true }
        let searchableText = values.compactMap { $0 }.joined(separator: " ")
        return normalizedSearchText(searchableText).contains(normalizedQuery)
    }

    private func normalizedSearchText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var editableFields: [EditableMetadataField] {
        if item?.fileType == .music || item?.fileType == .video {
            return EditableMetadataField.allCases
        }
        return [.title]
    }

    private var defaultMetadataValues: [EditableMetadataField: String] {
        [
            .title: item?.displayName ?? URL(fileURLWithPath: path).lastPathComponent,
            .artist: item?.author ?? "",
            .album: item?.album ?? "",
            .genre: item?.genre ?? "",
            .year: item?.year ?? ""
        ]
    }

    private var currentFolderColor: Color {
        guard let rgba = metadataOverride?.folderColorRgba else { return .blue }
        return Color(uiColor: UIColor(hexRGBA: rgba))
    }

    private func loadOverride() {
        metadataOverride = container.visualMetadataOverridesRepository.loadOverride(forMediaPath: path)
    }

    private func pickCover(from source: CoverImageSource) async {
        do {
            let data = try await loadCoverImageData(from: source, container: container)
            guard let image = UIImage(data: data) else {
                throw SystemUIError.invalidSelection
            }
            if imageNeedsSquareCrop(image) {
                pendingCoverCrop = PendingCoverCrop(image: image)
            } else {
                applyPickedCover(image)
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func applyPickedCover(_ image: UIImage) {
        do {
            try saveCoverImage(image, for: [path], container: container)
            loadOverride()
            nowPlayingVM.syncFromStore()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func revertCover() {
        revertCoverImage(for: [path], container: container)
        loadOverride()
        nowPlayingVM.syncFromStore()
    }

    private func applyFolderColor(_ color: Color) {
        var override = container.visualMetadataOverridesRepository.loadOverride(forMediaPath: path) ?? VisualMetadataOverride()
        override.folderColorRgba = UIColor(color).rgbaToken
        container.visualMetadataOverridesRepository.saveOverride(override, forMediaPath: path)
        loadOverride()
    }

    private func revertFolderColor() {
        var override = container.visualMetadataOverridesRepository.loadOverride(forMediaPath: path) ?? VisualMetadataOverride()
        override.folderColorRgba = nil
        container.visualMetadataOverridesRepository.saveOverride(override, forMediaPath: path)
        loadOverride()
    }

    private func formattedDuration(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private func aboutTitleForPath(_ path: String) -> String {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ext == "txt" { return String(localized: "About Text") }
    return String(localized: "About File")
}

private struct AboutCoverThumbnail: View {
    let path: String
    let item: FileInfo?
    let librarySongs: [FileInfo]
    @State private var metadataOverride: VisualMetadataOverride?

    var body: some View {
        Group {
            if let image = VisualArtworkOverrideStore.image(at: metadataOverride?.coverArtworkPath) {
                Image(uiImage: image)
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if MedioShadowFolder.isFavorites(path) {
                FavoriteFolderArtworkView()
            } else if item?.isDirectory == true {
                FolderArtworkView(path: path, librarySongs: librarySongs)
            } else if item?.fileType == .music || item?.fileType == .video {
                SongArtworkView(path: path)
            } else {
                Image(systemName: item?.fileType == .lyrics ? "doc.text" : "doc")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear(perform: loadOverride)
        .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { notification in
            guard let changedPath = notification.userInfo?["path"] as? String else {
                loadOverride()
                return
            }
            if changedPath == path {
                loadOverride()
            }
        }
    }

    private func loadOverride() {
        metadataOverride = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: path)
    }
}

private struct CoverIconOptionsPopover: View {
    let isFolder: Bool
    let hasCover: Bool
    let hasFolderColor: Bool
    let choosePhotos: () -> Void
    let chooseFiles: () -> Void
    let changeFolderColor: () -> Void
    let revertCover: () -> Void
    let revertFolderColor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: choosePhotos) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: chooseFiles) {
                Label("Choose from Files", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isFolder {
                Divider()
                Button(action: changeFolderColor) {
                    Label("Change Folder Color", systemImage: "paintpalette")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if hasCover || (isFolder && hasFolderColor) {
                Divider()
                if hasCover {
                    Button(role: .destructive, action: revertCover) {
                        Label("Revert Icon", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if isFolder && hasFolderColor {
                    Button(role: .destructive, action: revertFolderColor) {
                        Label("Revert Folder Color", systemImage: "arrow.counterclockwise.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(minWidth: 240)
    }
}

private struct FolderColorPickerSheet: View {
    let initialColor: Color
    let hasSavedColor: Bool
    let onCancel: () -> Void
    let onSave: (Color) -> Void
    let onRevert: () -> Void

    @State private var selectedColor: Color

    init(
        initialColor: Color,
        hasSavedColor: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Color) -> Void,
        onRevert: @escaping () -> Void
    ) {
        self.initialColor = initialColor
        self.hasSavedColor = hasSavedColor
        self.onCancel = onCancel
        self.onSave = onSave
        self.onRevert = onRevert
        _selectedColor = State(initialValue: initialColor)
    }

    var body: some View {
        CompatibleNavigationStack {
            Form {
                Section("Folder Color") {
                    ColorPicker("Color", selection: $selectedColor, supportsOpacity: false)
                }
                if hasSavedColor {
                    Section {
                        Button("Revert Folder Color", role: .destructive, action: onRevert)
                    }
                }
            }
            .navigationTitle("Folder Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selectedColor)
                    }
                }
            }
        }
        .compatibleMediumPresentationDetent()
    }
}

private struct FileProperties {
    let kind: String
    let location: String
    let size: String?
    let itemCount: String?
    let created: String?
    let modified: String?
    let lastOpened: String?

    static func load(for path: String) async -> FileProperties {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let url = URL(fileURLWithPath: path)
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            var isDirectory = ObjCBool(false)
            fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

            let kind: String
            let size: String?
            let itemCount: String?
            if isDirectory.boolValue {
                kind = String(localized: "Folder")
                size = nil
                let children = (try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                itemCount = "\(children.count)"
            } else {
                let ext = url.pathExtension.uppercased()
                kind = ext.isEmpty ? "File" : "\(ext) File"
                if let bytes = attrs?[.size] as? NSNumber {
                    size = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
                } else {
                    size = nil
                }
                itemCount = nil
            }

            return FileProperties(
                kind: kind,
                location: url.deletingLastPathComponent().standardizedFileURL.path,
                size: size,
                itemCount: itemCount,
                created: (attrs?[.creationDate] as? Date)?.formatted(date: .abbreviated, time: .shortened),
                modified: (attrs?[.modificationDate] as? Date)?.formatted(date: .abbreviated, time: .shortened),
                lastOpened: MedioLastOpenedStore.date(for: path)?.formatted(date: .abbreviated, time: .shortened)
            )
        }.value
    }
}

struct FolderPanel: View {
    @ObservedObject var vm: FolderViewModel
    let path: String
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isMovingItems = false
    @State private var showMoveStatus = false
    @State private var moveStatusMessage = ""
    @State private var folderDropFrames: [String: CGRect] = [:]
    @State private var activeFolderDropPath: String?
    @State private var showViewOptions = false
    @AppStorage("medio.home.viewStyle") private var browserViewStyle: FileBrowserViewStyle = .list
    @AppStorage(FileBrowserIconSizing.storageKey) private var browserIconSize = FileBrowserIconSizing.defaultSize

    private var selectedMovableIDs: [String] {
        selectedItemIDs.sorted()
    }

    private var folderTitle: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private var fileGridColumns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: FileBrowserIconSizing.gridMinimum(for: browserIconSize),
                maximum: FileBrowserIconSizing.gridMaximum(for: browserIconSize)
            ),
            spacing: 12,
            alignment: .top
        )]
    }

    var body: some View {
        Group {
            switch browserViewStyle {
            case .icons:
                folderIconContent
            case .list:
                folderListContent
            case .desktop:
                folderDesktopContent
            }
        }
        .nativeDefaultDropDestination(
            title: "Drop in \(folderTitle)",
            isTargeted: browserViewStyle != .desktop && activeFolderDropPath == path
        )
        .onPreferenceChange(NativeFolderDropFramePreferenceKey.self) { folderDropFrames = $0 }
        .background {
            if browserViewStyle != .desktop {
                NativeFileDropInteractionBridge(
                    defaultDestinationPath: path,
                    internalMoveDefaultDestinationPath: path,
                    folderFrames: folderDropFrames,
                    onTargetChanged: { activeFolderDropPath = $0 },
                    onMove: { paths, destinationPath in
                        Task { @MainActor in
                            await move(paths: paths, toFolder: destinationPath, closeToRoot: false)
                        }
                    },
                    onImport: { result, _ in handleFolderImport(result) },
                    onSpringLoad: { router.push(.folder(path: $0)) }
                )
            }
        }
        .searchable(
            text: $vm.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { folderToolbar }
        .alert("Move", isPresented: $showMoveStatus) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(moveStatusMessage)
        }
        .onAppear {
            MedioLastOpenedStore.record(path)
        }
        .sheet(isPresented: $showViewOptions) {
            FileBrowserViewOptionsPanel(iconSize: $browserIconSize)
        }
    }

    private var folderListContent: some View {
        List {
            if vm.filtered.isEmpty {
                CompatibleContentUnavailableView(
                    vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Folder Empty") : String(localized: "No Results"),
                    systemImage: "folder"
                )
            } else {
                ForEach(vm.filtered) { item in
                    folderItemButton(for: item)
                }
            }
        }
        .listStyle(.plain)
        .compatibleScrollContentBackgroundHidden()
    }

    private var folderIconContent: some View {
        ScrollView {
            if vm.filtered.isEmpty {
                CompatibleContentUnavailableView(
                    vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Folder Empty") : String(localized: "No Results"),
                    systemImage: "folder"
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: fileGridColumns, alignment: .leading, spacing: 22) {
                    ForEach(vm.filtered) { item in
                        folderItemIconButton(for: item)
                    }
                }
                .padding(16)
            }
        }
        .background(Color.clear)
    }

    private var folderDesktopContent: some View {
        DesktopFileCanvas(
            items: vm.filtered,
            librarySongs: container.libraryStore.librarySongs,
            storageContainerPath: path,
            filesystemContainerPath: path,
            defaultDropTitle: "Drop in \(folderTitle)",
            emptyTitle: vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Folder Empty") : String(localized: "No Results"),
            emptySystemImage: "folder",
            isSelecting: isSelecting,
            selectedItemIDs: selectedItemIDs,
            isMovable: { _ in true },
            isFolderDropEnabled: { $0.isDirectory },
            onOpen: openFolderItem,
            dragPaths: dragPaths,
            makeMenu: folderItemMenu,
            onMove: { paths, destinationPath in
                Task { @MainActor in
                    await move(paths: paths, toFolder: destinationPath, closeToRoot: false)
                }
            },
            onImport: { result, _ in handleFolderImport(result) },
            onSpringLoad: { router.push(.folder(path: $0)) }
        ) { }
    }

    private var folderOptionsMenu: some View {
        NativeBrowserOptionsMenu(accessibilityLabel: String(localized: "Folder Options")) {
            UIMenu(children: [
                BrowserOptionsMenu.section([
                    BrowserOptionsMenu.action("Select", "checkmark.circle") { isSelecting = true },
                    BrowserOptionsMenu.action(String(localized: "New Folder"), "folder.badge.plus") { router.present(.createFolder(parentPath: path)) },
                    BrowserOptionsMenu.action("Import Files", "square.and.arrow.down") { Task { await importFilesFromPicker() } },
                    BrowserOptionsMenu.action("Settings", "gearshape") { router.present(.settings) }
                ]),
                BrowserOptionsMenu.views(selected: browserViewStyle) { browserViewStyle = $0 },
                BrowserOptionsMenu.sorts(HomeSortBy.menuCases, selected: container.settingsStore.homeSortBy,
                    ascending: container.settingsStore.homeSortAscending, title: { $0.title }, select: applySort),
                BrowserOptionsMenu.section([BrowserOptionsMenu.action("View Options", "slider.horizontal.3") { showViewOptions = true }])
            ])
        }
    }


    @ToolbarContentBuilder
    private var folderToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelecting {
                Button("Move") {
                    router.presentMoveItems(selectedMovableIDs)
                }
                .disabled(selectedMovableIDs.isEmpty || isMovingItems)

                Button("Done") {
                    exitSelectionMode()
                }
            } else {
                folderOptionsMenu
            }
        }
    }

    private func folderItemButton(for item: FileInfo) -> some View {
        Button {
            if isSelecting {
                toggleSelection(for: item)
                return
            }
            if item.isDirectory {
                router.push(.folder(path: item.id))
            } else {
                Task {
                    await vm.play(item)
                }
            }
        } label: {
            Group {
                if isSelecting {
                    SelectableMediaItemRow(
                        item: item,
                        isSelected: selectedItemIDs.contains(item.id),
                        isMovable: true
                    )
                } else {
                    MediaItemRow(item: item, librarySongs: container.libraryStore.librarySongs)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .onDrag {
            dragProvider(for: item)
        } preview: {
            MultiItemDragPreview(paths: dragPreviewPaths(for: item))
        }
        .nativeFolderDropDestination(
            path: item.id,
            enabled: item.isDirectory && !MedioShadowFolder.isFavorites(item.id),
            isTargeted: activeFolderDropPath == item.id
        )
        .contextMenu {
            folderItemContextMenu(for: item)
        }
    }

    private func folderItemIconButton(for item: FileInfo) -> some View {
        Button {
            openFolderItem(item)
        } label: {
            FileBrowserIconTile(
                item: item,
                librarySongs: container.libraryStore.librarySongs,
                isSelecting: isSelecting,
                isSelected: selectedItemIDs.contains(item.id),
                isMovable: true,
                usesCardBackground: false,
                iconSize: FileBrowserIconSizing.clamped(browserIconSize)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .nativeFolderDropDestination(
            path: item.id,
            enabled: item.isDirectory,
            isTargeted: activeFolderDropPath == item.id
        )
        .contextMenu {
            folderItemContextMenu(for: item)
        }
    }

    private func openFolderItem(_ item: FileInfo) {
        if isSelecting {
            toggleSelection(for: item)
        } else if item.isDirectory {
            router.push(.folder(path: item.id))
        } else {
            Task { await vm.play(item) }
        }
    }

    @ViewBuilder
    private func folderItemContextMenu(for item: FileInfo) -> some View {
        Button("Select", systemImage: "checkmark.circle") {
            isSelecting = true
            selectedItemIDs = [item.id]
        }
        Button(item.medioAboutActionTitle, systemImage: "info.circle") {
            router.present(.fileAbout(path: item.id))
        }
        Button("Move", systemImage: "folder") {
            router.presentMoveItems([item.id])
        }
        if !selectedMovableIDs.isEmpty {
            Button("Move Selected", systemImage: "folder.badge.person.crop") {
                router.presentMoveItems(selectedMovableIDs)
            }
        }
    }

    private func folderItemMenu(for item: FileInfo) -> UIMenu {
        var actions: [UIMenuElement] = [
            UIAction(title: String(localized: "Select"), image: UIImage(systemName: "checkmark.circle")) { _ in
                isSelecting = true
                selectedItemIDs = [item.id]
            },
            UIAction(title: item.medioAboutActionTitle, image: UIImage(systemName: "info.circle")) { _ in
                router.present(.fileAbout(path: item.id))
            },
            UIAction(title: String(localized: "Move"), image: UIImage(systemName: "folder")) { _ in
                router.presentMoveItems([item.id])
            }
        ]
        if !selectedMovableIDs.isEmpty {
            actions.append(UIAction(title: String(localized: "Move Selected"), image: UIImage(systemName: "folder.badge.person.crop")) { _ in
                router.presentMoveItems(selectedMovableIDs)
            })
        }
        return UIMenu(children: actions)
    }

    private func applySort(_ sort: HomeSortBy) {
        container.settingsStore.selectSort(sort)
    }


    private func toggleSelection(for item: FileInfo) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedItemIDs.removeAll()
    }

    private func dragProvider(for item: FileInfo) -> NSItemProvider {
        if isSelecting {
            if !selectedItemIDs.contains(item.id) {
                selectedItemIDs = [item.id]
            }
        }
        let paths = dragPaths(for: item)
        return makeMoveItemProvider(items: dragFileInfos(
            paths: paths,
            knownItems: container.libraryStore.allItems + vm.filtered + [item]
        ))
    }

    private func dragPreviewPaths(for item: FileInfo) -> [String] {
        let paths = dragPaths(for: item)
        return paths.isEmpty ? [item.id] : paths
    }

    private func dragPaths(for item: FileInfo) -> [String] {
        if isSelecting {
            if selectedItemIDs.contains(item.id), !selectedMovableIDs.isEmpty {
                return selectedMovableIDs
            }
            return [item.id]
        }
        return [item.id]
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            switch result {
            case .success(let importedURLs):
                guard !importedURLs.isEmpty else { return }
                await container.libraryStore.refresh(scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository))
            case .failure(let error):
                moveStatusMessage = error.localizedDescription
                showMoveStatus = true
            }
        }
    }

    private func importFilesFromPicker() async {
        do {
            let urls = try await container.documentPickingService.pickFile(
                contentTypes: [.item],
                allowsMultipleSelection: true
            )
            let importedURLs = try await ImportDocumentsUseCase().execute(
                urls: urls,
                destinationDirectory: URL(fileURLWithPath: path, isDirectory: true)
            )
            guard !importedURLs.isEmpty else {
                moveStatusMessage = String(localized: "No files were imported.")
                showMoveStatus = true
                return
            }
            await container.libraryStore.refresh(
                scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository)
            )
        } catch SystemUIError.cancelled {
            return
        } catch {
            moveStatusMessage = error.localizedDescription
            showMoveStatus = true
        }
    }

    private func move(paths: [String], toFolder destinationPath: String, closeToRoot: Bool) async {
        isMovingItems = true
        defer { isMovingItems = false }
        do {
            let result = try await FileMoveService().moveBatch(paths: paths, toFolder: destinationPath)
            guard !result.completed.isEmpty else {
                moveStatusMessage = result.failures.first?.message ?? String(localized: "These items cannot be moved to that folder.")
                showMoveStatus = true
                return
            }
            await container.libraryStore.refresh(scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository))
            let failedSourcePaths = Set(result.failures.map { $0.source.standardizedFileURL.path })
            let movedSourcePaths = paths.filter {
                !failedSourcePaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path)
            }
            selectedItemIDs.subtract(movedSourcePaths)
            if selectedItemIDs.isEmpty {
                isSelecting = false
            }
            if closeToRoot {
                router.resetPushStack()
                router.resetSheetStack()
            }
            if let failure = result.failures.first {
                moveStatusMessage = "Some items were not moved: \(failure.message)"
                showMoveStatus = true
            }
        } catch {
            moveStatusMessage = error.localizedDescription
            showMoveStatus = true
        }
    }
}

struct PriorityFolderPickerPanel: View {
    let slot: Int
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer

    private var folders: [FileInfo] {
        let result = container.libraryStore.allItems.filter { item in
            item.isDirectory && FolderDestinationVisibility.isSelectableFolder(item.id)
        }

        var seen: Set<String> = []
        return result
            .filter { item in
                let path = URL(fileURLWithPath: item.id).standardizedFileURL.path
                return seen.insert(path).inserted
            }
            .sorted { lhs, rhs in
                return lhs.id.appRelativeDisplayPath.localizedCaseInsensitiveCompare(rhs.id.appRelativeDisplayPath) == .orderedAscending
            }
    }

    var body: some View {
        Group {
            List(folders) { folder in
                Button {
                    container.settingsStore.assignPriorityFolder(folder.id, to: slot)
                    router.dismissSheet()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.displayName)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(folder.id.appRelativeDisplayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Priority Folder")
        }
    }
}

struct PrioritySlotAboutPanel: View {
    let slot: Int
    @Environment(\.medioRootContentWidth) private var rootWidth
    @Environment(\.medioUsesCompactRootChrome) private var compact
    @EnvironmentObject private var container: AppContainer
    @State private var showCoverSourceDialog = false
    @State private var pendingCoverCrop: PendingCoverCrop?
    @State private var errorMessage: String?
    @State private var showError = false

    private var cardAspectRatio: CGFloat {
        HomePriorityLayoutMetrics.cardAspectRatio(contentWidth: rootWidth, compact: compact)
    }

    private var artworkPath: String? {
        container.settingsStore.prioritySlotArtworkPath(at: slot)
    }

    var body: some View {
        List {
            Section("Priority Image") {
                HStack(spacing: 12) {
                    priorityPreview
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Image-only Priority")
                        Text("The Home card displays only this image and does not open when tapped. Long press it for options.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Image") {
                Button(artworkPath == nil ? "Choose Image" : "Change Image") {
                    showCoverSourceDialog = true
                }
                if artworkPath != nil {
                    if container.settingsStore.isPrioritySlotImageOnly(slot) {
                        Button("Show Folder Card Again") {
                            container.settingsStore.setPrioritySlotImageOnly(false, at: slot)
                        }
                    }
                    Button("Remove Image", role: .destructive) {
                        container.settingsStore.setPrioritySlotArtworkPath(nil, at: slot)
                        container.settingsStore.setPrioritySlotImageOnly(false, at: slot)
                    }
                }
            }
        }
        .navigationTitle("Make Priority Image")
        .confirmationDialog("Priority Image", isPresented: $showCoverSourceDialog) {
            Button("Choose from Photos") {
                Task { await pickImage(from: .photos) }
            }
            Button("Choose from Files") {
                Task { await pickImage(from: .files) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $pendingCoverCrop) { pending in
            CoverImageCropSheet(
                image: pending.image,
                aspectRatio: cardAspectRatio,
                onCancel: { pendingCoverCrop = nil },
                onUse: { image in
                    applyImage(image)
                    pendingCoverCrop = nil
                }
            )
        }
        .alert("Priority Image", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var priorityPreview: some View {
        if let image = VisualArtworkOverrideStore.image(at: artworkPath) {
            Image(uiImage: image)
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 88, height: 88 / cardAspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 88, height: 88 / cardAspectRatio)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @MainActor
    private func pickImage(from source: CoverImageSource) async {
        do {
            let data = try await loadCoverImageData(from: source, container: container)
            guard let image = UIImage(data: data) else {
                throw SystemUIError.invalidSelection
            }
            pendingCoverCrop = PendingCoverCrop(image: image)
        } catch SystemUIError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func applyImage(_ image: UIImage) {
        do {
            let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData() ?? Data()
            let artworkPath = try VisualArtworkOverrideStore.saveArtwork(data)
            container.settingsStore.setPrioritySlotArtworkPath(artworkPath, at: slot)
            container.settingsStore.setPrioritySlotImageOnly(true, at: slot)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

struct MoveItemPanel: View {
    let paths: [String]
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer
    @State private var query = ""
    @State private var isMoving = false
    @State private var errorMessage: String?

    private var destinationFolders: [FileInfo] {
        let fileMoveService = FileMoveService()
        var folders: [FileInfo] = []
        folders.append(contentsOf: container.libraryStore.allItems.filter(\.isDirectory))

        var seen: Set<String> = []
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folders.filter { folder in
            guard FolderDestinationVisibility.isSelectableFolder(folder.id) else { return false }
            guard seen.insert(folder.id).inserted else { return false }
            guard fileMoveService.canMove(paths, toFolder: folder.id) else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return folder.displayName.lowercased().contains(normalizedQuery)
                || folder.id.appRelativeDisplayPath.lowercased().contains(normalizedQuery)
        }
    }

    var body: some View {
        Group {
            List {
                Section(paths.count == 1 ? "Item" : "Items") {
                    ForEach(paths, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                    }
                }
                Section("Destination") {
                    if destinationFolders.isEmpty {
                        CompatibleContentUnavailableView(String(localized: "No Available Folder"), systemImage: "folder")
                    } else {
                        ForEach(destinationFolders) { folder in
                            Button {
                                Task { await move(to: folder.id) }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.blue)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.displayName)
                                            .lineLimit(nil)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(folder.id.appRelativeDisplayPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(nil)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .disabled(isMoving)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle(paths.count == 1 ? "Move Item" : "Move Items")
        }
    }

    private func move(to destinationPath: String) async {
        isMoving = true
        defer { isMoving = false }
        do {
            let result = try await FileMoveService().moveBatch(paths: paths, toFolder: destinationPath)
            guard !result.completed.isEmpty else {
                errorMessage = result.failures.first?.message ?? String(localized: "These items cannot be moved to that folder.")
                return
            }
            await container.libraryStore.refresh(scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository))
            if let failure = result.failures.first {
                errorMessage = "Some items were not moved: \(failure.message)"
                return
            }
            router.dismissSheet()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CreateFolderScreen: View {
    @StateObject private var vm: CreateFolderViewModel
    @EnvironmentObject private var router: AppRouter

    init(parentPath: String?) {
        _vm = StateObject(wrappedValue: CreateFolderViewModel(parentPath: parentPath))
    }

    var body: some View {
        Group {
            Form {
                TextField("Folder name", text: $vm.name)
                if let error = vm.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Button("Create") {
                    Task { await createFolder() }
                }
            }
            .navigationTitle("Create Folder")
        }
    }

    private func createFolder() async {
        await vm.create()
        guard vm.errorMessage == nil else { return }
        let fileManager = FileManager.default
        let base: URL
        if let parentPath = vm.parentPath {
            base = URL(fileURLWithPath: parentPath, isDirectory: true)
        } else if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            base = docs
        } else {
            vm.errorMessage = "Documents directory not found."
            return
        }
        do {
            let policy = try AppFilePathPolicy.documents(fileManager: fileManager)
            let destination = try policy.destination(in: base, named: vm.name, isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            router.dismissSheet()
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }
}

struct AlbumPanel: View {
    @ObservedObject var vm: AlbumViewModel
    let name: String
    let artistName: String?
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Group {
            List {
                Section {
                    albumHeader
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 18, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if vm.filtered.isEmpty {
                    Section("Music Files") {
                        CompatibleContentUnavailableView(
                            vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Music Files") : String(localized: "No Results"),
                            systemImage: "music.note"
                        )
                    }
                } else {
                    ForEach(AlbumTrackOrdering.sections(for: vm.filtered)) { trackSection in
                        Section(trackSection.title ?? "Music Files") {
                            ForEach(trackSection.songs) { song in
                                Button {
                                    Task {
                                        await vm.play(song)
                                    }
                                } label: {
                                    AlbumTrackRow(item: song)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(song.displayName)
                                .medioNativeDrag(song)
                                .contextMenu {
                                    Button(song.medioAboutActionTitle, systemImage: "info.circle") {
                                        router.present(.fileAbout(path: song.id))
                                    }
                                }
                            }
                        }
                    }
                }
                Section("About \(name)") {
                    CompatibleLabeledContent(String(localized: "Tracks"), value: "\(vm.metadata.songCountInAlbumFolders)")
                    CompatibleLabeledContent("Artist", value: vm.metadata.subtitleArtist)
                    CompatibleLabeledContent(String(localized: "Year"), value: vm.metadata.subtitleYear)
                    CompatibleLabeledContent(String(localized: "Genre"), value: vm.metadata.genre)
                    CompatibleLabeledContent(String(localized: "Credits"), value: vm.metadata.credits)
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $vm.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .navigationTitle(localizedMediaPlaceholder(name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CircularTrailingToolbarItem {
                    ToolbarGlassMenu(accessibilityLabel: String(localized: "Album Options")) {
                        Button("About Album", systemImage: "info.circle") {
                            if let artistName {
                                router.present(.artistAlbumAbout(artistName: artistName, albumName: name))
                            } else {
                                router.present(.albumAbout(name: name))
                            }
                        }
                    }
                }
            }
        }
    }

    private var albumHeader: some View {
        AlbumHeaderArtwork(
            subtitle: albumHeroSubtitle,
            songs: vm.songs
        )
    }

    private var albumHeroSubtitle: String {
        let artist = vm.metadata.subtitleArtist == "NA" ? nil : vm.metadata.subtitleArtist
        let year = vm.metadata.subtitleYear == "NA" ? nil : vm.metadata.subtitleYear
        let tracks = String(localized: "\(vm.metadata.songCountInAlbumFolders) songs")
        return [artist, year, tracks]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

}

private struct AlbumHeaderArtwork: View {
    let subtitle: String
    let songs: [FileInfo]
    private let artworkCache: ArtworkCache = .shared
    @State private var representativeOverride: VisualMetadataOverride?
    @State private var artworkRevision = 0

    private var representativePath: String? {
        songs.first?.id
    }

    private var artwork: UIImage? {
        if let image = VisualArtworkOverrideStore.image(at: representativeOverride?.coverArtworkPath) {
            return image
        }
        guard let path = representativePath else { return nil }
        return artworkCache.image(for: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let artwork {
                    MediaCoverArtwork(image: artwork)
                        .frame(maxWidth: .infinity)
                } else {
                    ZStack {
                        Color(.systemGray5)
                        Image(systemName: "square.stack")
                            .font(.system(size: 72, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
            }

            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .onAppear(perform: loadOverride)
        .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { _ in
            loadOverride()
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioArtworkCacheDidChange)) { notification in
            guard notification.userInfo?["path"] as? String == representativePath else { return }
            artworkRevision &+= 1
        }
    }

    private func loadOverride() {
        guard let representativePath else {
            representativeOverride = nil
            return
        }
        representativeOverride = UserDefaultsVisualMetadataOverridesRepository.shared.loadOverride(forMediaPath: representativePath)
    }
}

private struct AlbumTrackRow: View {
    let item: FileInfo
    @EnvironmentObject private var playbackStore: PlaybackStore
    @AppStorage(PlaybackIndicatorScope.key) private var indicatorScopes = PlaybackIndicatorScope.all

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if indicatorScopes & PlaybackIndicatorScope.songs.rawValue != 0, playbackStore.nowPlaying?.id == item.id {
                NowPlayingAudioVisualizerArtwork(isPlaying: playbackStore.isPlaying, levels: playbackStore.audioLevels)
            } else if let trackNumber = displayTrackNumber {
                Text(trackNumber)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
            } else {
                SongArtworkView(path: item.id)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let duration = durationText {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, displayTrackNumber == nil ? 0 : 4)
        .playbackQueueProgress(for: item.id)
    }

    private var displayTrackNumber: String? {
        guard let raw = item.trackNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let first = raw.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? nil : first
    }

    private var durationText: String? {
        item.durationMs.map(formattedDuration)
    }
}

private struct SongTitleAndDurationRow: View {
    let item: FileInfo

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SongArtworkView(path: item.id)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let duration = item.durationMs.map(formattedDuration) {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private func formattedDuration(_ ms: Int) -> String {
    let total = max(0, ms / 1000)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
    }
    return "\(minutes):\(String(format: "%02d", seconds))"
}

struct AlbumAboutPanel: View {
    @ObservedObject var vm: AlbumViewModel
    let name: String
    @EnvironmentObject private var container: AppContainer
    @State private var showEditMetadata = false
    @State private var showCoverSourceDialog = false
    @State private var pendingCoverCrop: PendingCoverCrop?
    @State private var representativeOverride: VisualMetadataOverride?
    @State private var errorMessage: String?
    @State private var showError = false

    private var filePaths: [String] { vm.songs.map(\.id) }
    private var representativePath: String? { filePaths.first }

    var body: some View {
        List {
            Section("About \(name)") {
                Button {
                    showCoverSourceDialog = true
                } label: {
                    HStack(spacing: 12) {
                        if let representativePath {
                            AboutCoverThumbnail(
                                path: representativePath,
                                item: vm.songs.first,
                                librarySongs: container.libraryStore.librarySongs
                            )
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cover Icon")
                                .foregroundStyle(.primary)
                            Text("Choose image from Photos or Files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                editableMetadataRow(String(localized: "Album"), value: representativeOverride?.album ?? name)
                editableMetadataRow("Artist", value: representativeOverride?.artist ?? vm.metadata.subtitleArtist)
                editableMetadataRow(String(localized: "Genre"), value: representativeOverride?.genre ?? vm.metadata.genre)
                editableMetadataRow(String(localized: "Year"), value: representativeOverride?.year ?? vm.metadata.subtitleYear)
            }
            Section("Properties") {
                CompatibleLabeledContent(String(localized: "Tracks"), value: "\(vm.metadata.songCountInAlbumFolders)")
                CompatibleLabeledContent(String(localized: "Credits"), value: vm.metadata.credits)
            }
        }
        .navigationTitle("About \(name)")
        .sheet(isPresented: $showEditMetadata, onDismiss: loadOverride) {
            EditMetadataView(
                title: "Edit \(name)",
                filePaths: filePaths,
                currentOverride: representativeOverride,
                defaultValues: [
                    .album: name,
                    .artist: vm.metadata.subtitleArtist,
                    .genre: vm.metadata.genre == "NA" ? "" : vm.metadata.genre,
                    .year: vm.metadata.subtitleYear == "NA" ? "" : vm.metadata.subtitleYear
                ],
                fields: [.album, .artist, .genre, .year]
            )
        }
        .sheet(item: $pendingCoverCrop) { pending in
            CoverImageCropSheet(
                image: pending.image,
                onCancel: { pendingCoverCrop = nil },
                onUse: { image in
                    applyPickedCover(image)
                    pendingCoverCrop = nil
                }
            )
        }
        .confirmationDialog("Cover Icon", isPresented: $showCoverSourceDialog) {
            Button("Choose from Photos") {
                Task { await pickCover(from: .photos) }
            }
            Button("Choose from Files") {
                Task { await pickCover(from: .files) }
            }
            if representativeOverride?.coverArtworkPath != nil {
                Button("Revert to Original Cover", role: .destructive) {
                    revertCover()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Cover Icon", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: filePaths.joined(separator: "|")) {
            loadOverride()
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { _ in
            loadOverride()
        }
    }

    private func editableMetadataRow(_ label: String, value: String) -> some View {
        Button {
            showEditMetadata = true
        } label: {
            CompatibleLabeledContent(label, value: value)
        }
        .buttonStyle(.plain)
    }

    private func loadOverride() {
        guard let representativePath else {
            representativeOverride = nil
            return
        }
        representativeOverride = container.visualMetadataOverridesRepository.loadOverride(forMediaPath: representativePath)
    }

    private func pickCover(from source: CoverImageSource) async {
        guard !filePaths.isEmpty else { return }
        do {
            let data = try await loadCoverImageData(from: source, container: container)
            guard let image = UIImage(data: data) else {
                throw SystemUIError.invalidSelection
            }
            if artistImageNeedsSquareCrop(image) {
                pendingCoverCrop = PendingCoverCrop(image: image)
            } else {
                applyPickedCover(image)
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func applyPickedCover(_ image: UIImage) {
        do {
            try saveCoverImage(image, for: filePaths, container: container)
            loadOverride()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func revertCover() {
        revertCoverImage(for: filePaths, container: container)
        loadOverride()
    }
}

struct ArtistPanel: View {
    @ObservedObject var vm: ArtistViewModel
    let name: String
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Group {
            List {
                Section {
                    artistHeader
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if !vm.filteredMostPlayedSongs.isEmpty {
                    Section("Most Played Songs") {
                        ForEach(vm.filteredMostPlayedSongs) { song in
                            artistSongButton(for: song)
                        }
                    }
                }
                if !vm.filteredAlbums.isEmpty {
                    Section("Discography") {
                        ForEach(vm.filteredAlbums) { album in
                            Button {
                                router.push(.artistAlbum(artistName: name, albumName: album.name))
                            } label: {
                                ArtistAlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("About \(album.name)", systemImage: "rectangle.stack") {
                                    router.present(.artistAlbumAbout(artistName: name, albumName: album.name))
                                }
                            }
                        }
                    }
                }
                Section("All Music") {
                    if vm.filtered.isEmpty {
                        CompatibleContentUnavailableView(
                            vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Music") : String(localized: "No Results"),
                            systemImage: "music.note"
                        )
                    } else {
                        ForEach(vm.filtered) { song in
                            artistSongButton(for: song)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $vm.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .navigationTitle(localizedMediaPlaceholder(name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CircularTrailingToolbarItem {
                    ToolbarGlassMenu(accessibilityLabel: String(localized: "Artist Options")) {
                        Button("About Artist", systemImage: "person") {
                            router.present(.artistAbout(name: name))
                        }
                    }
                }
            }
        }
    }

    private func artistSongButton(for song: FileInfo) -> some View {
        Button {
            Task {
                await vm.play(song)
            }
        } label: {
            SongTitleAndDurationRow(item: song)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(song.displayName)
        .medioNativeDrag(song)
        .contextMenu {
            Button(song.medioAboutActionTitle, systemImage: "info.circle") {
                router.present(.fileAbout(path: song.id))
            }
        }
    }

    private var artistHeader: some View {
        ArtistHeaderArtwork(
            subtitle: String(localized: "\(vm.albums.count) releases") + " • " + String(localized: "\(vm.songs.count) songs"),
            image: vm.artistImage
        )
    }
}

private struct ArtistHeaderArtwork: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let subtitle: String
    let image: UIImage?

    private var heroHeight: CGFloat {
        horizontalSizeClass == .compact ? 320 : 360
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color(.systemGray5)
                            Image(systemName: "person.fill")
                                .font(.system(size: 72, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .clipped()
            }
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()

            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }
}

private struct ArtistAlbumCard: View {
    let album: ShadowAlbum

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let firstSong = album.songs.first {
                SongArtworkView(path: firstSong.id, size: 76, cornerRadius: 12)
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, height: 76)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(localizedMediaPlaceholder(album.name))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let year = album.releaseYear {
                    Text(year)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var detailText: String {
        var parts = [
            album.releaseKind.rawValue,
            String(localized: "\(album.songs.count) songs")
        ]
        if let duration = album.totalDurationMs {
            parts.append(Self.formattedDuration(duration))
        }
        return parts.joined(separator: " • ")
    }

    private static func formattedDuration(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

struct ArtistAboutPanel: View {
    @ObservedObject var vm: ArtistViewModel
    let name: String
    @EnvironmentObject private var container: AppContainer
    @State private var showEditMetadata = false
    @State private var showCoverSourceDialog = false
    @State private var pendingCoverCrop: PendingCoverCrop?
    @State private var representativeOverride: VisualMetadataOverride?
    @State private var cachedArtistImage: UIImage?
    @State private var errorMessage: String?
    @State private var showError = false

    private var filePaths: [String] { vm.songs.map(\.id) }
    private var representativePath: String? { filePaths.first }

    var body: some View {
        List {
            Section("Artist") {
                Button {
                    showCoverSourceDialog = true
                } label: {
                    HStack(spacing: 12) {
                        ArtistProfileArtworkView(
                            artistName: name,
                            canFetchOnline: container.settingsStore.appCanConnectToInternet,
                            size: 60,
                            cornerRadius: 12
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Artist Photo")
                                .foregroundStyle(.primary)
                            Text(artistPhotoSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                editableMetadataRow("Artist", value: representativeOverride?.artist ?? name)
                editableMetadataRow(String(localized: "Genre"), value: representativeOverride?.genre ?? commonGenre)
                editableMetadataRow(String(localized: "Year"), value: representativeOverride?.year ?? commonYear)
            }
            Section("Properties") {
                CompatibleLabeledContent("Songs", value: "\(vm.songs.count)")
                CompatibleLabeledContent(String(localized: "Releases"), value: "\(vm.albums.count)")
            }
        }
        .navigationTitle("About Artist")
        .sheet(isPresented: $showEditMetadata, onDismiss: loadOverride) {
            EditMetadataView(
                title: String(localized: "Edit Artist"),
                filePaths: filePaths,
                currentOverride: representativeOverride,
                defaultValues: [
                    .artist: name,
                    .genre: commonGenre == "NA" ? "" : commonGenre,
                    .year: commonYear == "NA" ? "" : commonYear
                ],
                fields: [.artist, .genre, .year]
            )
        }
        .sheet(item: $pendingCoverCrop) { pending in
            CoverImageCropSheet(
                image: pending.image,
                onCancel: { pendingCoverCrop = nil },
                onUse: { image in
                    applyPickedCover(image)
                    pendingCoverCrop = nil
                }
            )
        }
        .confirmationDialog("Artist Photo", isPresented: $showCoverSourceDialog) {
            if canFetchOnlineArtistPhoto {
                Button("Fetch Online Photo", systemImage: "network") {
                    Task { await fetchOnlineArtistImage() }
                }
            }
            Button("Choose from Photos") {
                Task { await pickCover(from: .photos) }
            }
            Button("Choose from Files") {
                Task { await pickCover(from: .files) }
            }
            if cachedArtistImage != nil {
                Button("Remove Artist Photo", role: .destructive) {
                    revertCover()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Artist Photo", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: "\(name)|\(filePaths.joined(separator: "|"))") {
            loadOverride()
            await reloadArtistImageState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioVisualMetadataOverridesDidChange)) { _ in
            loadOverride()
        }
        .onReceive(NotificationCenter.default.publisher(for: .medioArtistProfileImagesDidChange)) { notification in
            guard let changedKey = notification.userInfo?["artistKey"] as? String else {
                Task { await reloadArtistImageState() }
                return
            }
            if changedKey == UserDefaultsArtistProfileRepository.storageKey(for: name) {
                Task { await reloadArtistImageState() }
            }
        }
    }

    private var commonGenre: String {
        uniqueOrNA(vm.songs.map { $0.genre })
    }

    private var commonYear: String {
        uniqueOrNA(vm.songs.map { $0.year })
    }

    private var artistPhotoSubtitle: String {
        if cachedArtistImage != nil {
            return String(localized: "Using artist profile image")
        }
        if canFetchOnlineArtistPhoto {
            return String(localized: "Fetch from allowed online sources or choose image")
        }
        if container.settingsStore.appCanConnectToInternet {
            return String(localized: "Choose image manually")
        }
        return String(localized: "Choose image or enable internet access")
    }

    private var canFetchOnlineArtistPhoto: Bool {
        container.settingsStore.appCanConnectToInternet
            && ArtistProfileLookupPolicy.canFetchOnlineImage(for: name)
    }

    private func editableMetadataRow(_ label: String, value: String) -> some View {
        Button {
            showEditMetadata = true
        } label: {
            CompatibleLabeledContent(label, value: value)
        }
        .buttonStyle(.plain)
    }

    private func loadOverride() {
        guard let representativePath else {
            representativeOverride = nil
            return
        }
        representativeOverride = container.visualMetadataOverridesRepository.loadOverride(forMediaPath: representativePath)
    }

    private func reloadArtistImageState() async {
        cachedArtistImage = await ArtistProfileImageLoader.shared.image(for: name, canFetchOnline: false)
    }

    private func fetchOnlineArtistImage() async {
        guard container.settingsStore.appCanConnectToInternet else {
            errorMessage = String(localized: "Internet access is off.")
            showError = true
            return
        }
        guard ArtistProfileLookupPolicy.canFetchOnlineImage(for: name) else {
            errorMessage = String(localized: "Online artist-photo lookup is skipped for Unknown Artist.")
            showError = true
            return
        }
        guard let image = await ArtistProfileImageLoader.shared.image(for: name, canFetchOnline: true) else {
            errorMessage = String(localized: "No usable artist photo was found from the allowed online sources.")
            showError = true
            return
        }
        cachedArtistImage = image
    }

    private func pickCover(from source: CoverImageSource) async {
        do {
            let data = try await loadCoverImageData(from: source, container: container)
            guard let image = UIImage(data: data) else {
                throw SystemUIError.invalidSelection
            }
            if imageNeedsSquareCrop(image) {
                pendingCoverCrop = PendingCoverCrop(image: image)
            } else {
                applyPickedCover(image)
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func applyPickedCover(_ image: UIImage) {
        Task {
            await UserDefaultsArtistProfileRepository.shared.storeImage(image, for: name)
            cachedArtistImage = image
        }
    }

    private func revertCover() {
        Task {
            await UserDefaultsArtistProfileRepository.shared.storeImage(nil, for: name)
            cachedArtistImage = nil
        }
    }

    private func uniqueOrNA(_ values: [String?]) -> String {
        let unique = values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                    result.append(value)
                }
            }
        return unique.isEmpty ? "NA" : unique.joined(separator: ", ")
    }
}

struct FolderBrowserScreen: View {
    let path: String
    @ObservedObject var router: AppRouter
    @ObservedObject var container: AppContainer

    private var children: [FileInfo] {
        let pathWithSlash = path.hasSuffix("/") ? path : path + "/"
        return container.libraryStore.allItems.filter { item in
            guard item.id.hasPrefix(pathWithSlash) else { return false }
            return !String(item.id.dropFirst(pathWithSlash.count)).contains("/")
        }
    }

    var body: some View {
        Group {
            List(children) { item in
                Button(item.displayName) {
                    if item.isDirectory {
                        router.present(.folderBrowser(path: item.id))
                    } else {
                        router.present(.fileAbout(path: item.id))
                    }
                }
                .contextMenu {
                    Button(item.medioAboutActionTitle, systemImage: "info.circle") {
                        router.present(.fileAbout(path: item.id))
                    }
                    Button("Move", systemImage: "folder") {
                        router.presentMoveItems([item.id])
                    }
                }
            }
            .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
        }
    }
}
