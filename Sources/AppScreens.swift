import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - App Screens

/// UIKit owns checkmark placement, subtitles, and Liquid Glass menu presentation.
struct NativeBrowserOptionsMenu: View {
    let accessibilityLabel: String
    let makeMenu: () -> UIMenu
    @Environment(\.medioUsesCompactRootChrome) private var compact

    var body: some View {
        NativeBrowserMenuButton(accessibilityLabel: accessibilityLabel, makeMenu: makeMenu)
            .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
    }
}

private struct NativeBrowserMenuButton: UIViewRepresentable {
    let accessibilityLabel: String
    let makeMenu: () -> UIMenu

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
        button.tintColor = .label
        button.showsMenuAsPrimaryAction = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.accessibilityLabel = accessibilityLabel
        button.menu = makeMenu()
    }
}

@MainActor
enum BrowserOptionsMenu {
    static func action(_ title: String, _ symbol: String, enabled: Bool = true, perform: @escaping () -> Void) -> UIAction {
        UIAction(title: NSLocalizedString(title, comment: "Browser menu action"), image: UIImage(systemName: symbol), attributes: enabled ? [] : [.disabled]) { _ in perform() }
    }

    static func section(_ children: [UIMenuElement]) -> UIMenu {
        UIMenu(options: .displayInline, children: children)
    }

    static func views(selected: FileBrowserViewStyle, select: @escaping (FileBrowserViewStyle) -> Void) -> UIMenu {
        section(FileBrowserViewStyle.menuCases.map { style in
            UIAction(title: style.title, image: UIImage(systemName: style.systemImage), state: selected == style ? .on : .off) { _ in select(style) }
        })
    }

    static func sorts<T: Equatable>(_ options: [T], selected: T, ascending: Bool,
                                    title: (T) -> String, select: @escaping (T) -> Void) -> UIMenu {
        section(options.map { sort in
            let action = UIAction(title: title(sort), state: selected == sort ? .on : .off) { _ in select(sort) }
            action.subtitle = selected == sort ? (ascending ? String(localized: "Ascending") : String(localized: "Descending")) : nil
            return action
        })
    }
}

private enum ToolbarGlassControlMetrics {
    static let size: CGFloat = 44
}

struct ToolbarGlassMenu<Content: View>: View {
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactChrome
    let systemImage: String
    let accessibilityLabel: String
    let content: Content

    init(
        systemImage: String = "ellipsis",
        accessibilityLabel: String,
        @ViewBuilder content: () -> Content
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Menu {
                    content
                } label: {
                    Label(accessibilityLabel, systemImage: systemImage)
                }
                .labelStyle(.iconOnly)
            } else {
                Menu {
                    content
                } label: {
                    Image(systemName: systemImage)
                        .font(usesCompactChrome ? .body.weight(.semibold) : .title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(
                            width: usesCompactChrome ? 36 : ToolbarGlassControlMetrics.size,
                            height: usesCompactChrome ? 36 : ToolbarGlassControlMetrics.size
                        )
                        .contentShape(Circle())
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ToolbarGlassButton: View {
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactChrome
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    private var controlSize: CGFloat {
        usesCompactChrome ? 36 : ToolbarGlassControlMetrics.size
    }

    private var iconFont: Font {
        usesCompactChrome ? .body.weight(.semibold) : .title3.weight(.semibold)
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button(action: action) {
                    Label(accessibilityLabel, systemImage: systemImage)
                }
                .labelStyle(.iconOnly)
            } else {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(iconFont)
                        .foregroundStyle(.primary)
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: controlSize, height: controlSize)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

enum FileBrowserIconSizing {
    static let storageKey = "medio.home.iconSize"
    static let defaultSize = 58.0
    static let range = 46.0...84.0

    static func clamped(_ size: Double) -> CGFloat {
        CGFloat(min(range.upperBound, max(range.lowerBound, size)))
    }

    static func gridMinimum(for size: Double) -> CGFloat {
        clamped(size) + 8
    }

    static func gridMaximum(for size: Double) -> CGFloat {
        gridMinimum(for: size) + 12
    }
}

struct FileBrowserViewOptionsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var iconSize: Double

    var body: some View {
        CompatibleNavigationStack {
            Form {
                Section("Icons") {
                    Slider(
                        value: $iconSize,
                        in: FileBrowserIconSizing.range,
                        step: 2
                    ) {
                        Text("Icon Size")
                    } minimumValueLabel: {
                        Image(systemName: "square.grid.2x2")
                            .font(.caption)
                    } maximumValueLabel: {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.title3)
                    }
                    .accessibilityIdentifier("browser_icon_size")

                    CompatibleLabeledContent("Icon Size", value: "\(Int(iconSize.rounded())) pt")
                }
            }
            .navigationTitle("View Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .compatibleMediumPresentationDetent()
        .compatiblePresentationDragIndicatorVisible()
    }
}

private enum HomeScrollTopAnchor {
    static let id = "home-scroll-top"
}

enum HomePriorityLayoutMetrics {
    static let textCardHeight: CGFloat = 88
    static let compactTextCardHeight: CGFloat = 74
    static let minimumColumnWidth: CGFloat = 156
    static let compactMinimumColumnWidth: CGFloat = 136
    static let iconSize: CGFloat = 44
    static let compactIconSize: CGFloat = 36

    static func cardAspectRatio(contentWidth: CGFloat, compact: Bool) -> CGFloat {
        let width = max(1, contentWidth - 32)
        let minimum = compact ? compactMinimumColumnWidth : minimumColumnWidth
        let columns = max(1, floor((width + 12) / (minimum + 12)))
        return ((width - (columns - 1) * 12) / columns) / (compact ? compactTextCardHeight : textCardHeight)
    }
}

private struct LibraryLoadingStatusView: View {
    let progress: LibraryScanProgress?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("Loading Library")
                .font(.headline)
                .foregroundStyle(.primary)

            if let fractionCompleted {
                VStack(spacing: 8) {
                    ProgressView(value: fractionCompleted, total: 1)
                        .frame(maxWidth: 320)
                    Text(detailText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(detailText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading library")
        .accessibilityValue(detailText)
    }

    private var fractionCompleted: Double? {
        progress?.fractionCompleted
    }

    private var detailText: String {
        guard let progress else {
            return String(localized: "Preparing library scan")
        }

        switch progress.phase {
        case .preparing:
            return String(localized: "Preparing library scan")
        case .scanningFiles:
            if let total = progress.totalItemCount {
                let percent = Int(((progress.fractionCompleted ?? 0) * 100).rounded())
                return String(localized: "\(percent)% complete — scanned \(progress.completedItemCount) of \(total)")
            }
            return String(localized: "Scanning files")
        case .buildingIndex:
            return String(localized: "Building library")
        case .finishing:
            return String(localized: "Finishing library")
        }
    }
}

struct HomeScreen: View {
    @ObservedObject var vm: HomeViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactChrome
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var moveStatusMessage = ""
    @State private var showMoveStatus = false
    @State private var isMovingItems = false
    @State private var folderDropFrames: [String: CGRect] = [:]
    @State private var activeFolderDropPath: String?
    @State private var showViewOptions = false
    @State private var isRootTitleCollapsed = false
    @AppStorage("medio.home.viewStyle") private var browserViewStyle: FileBrowserViewStyle = .list
    @AppStorage(FileBrowserIconSizing.storageKey) private var browserIconSize = FileBrowserIconSizing.defaultSize

    private var selectedMovableIDs: [String] {
        selectedItemIDs.filter { !MedioShadowFolder.isFavorites($0) }.sorted()
    }

    private var priorityGridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: usesCompactChrome
                    ? HomePriorityLayoutMetrics.compactMinimumColumnWidth
                    : HomePriorityLayoutMetrics.minimumColumnWidth),
                spacing: 12,
                alignment: .top
            )
        ]
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

    private var priorityGrid: some View {
        LazyVGrid(columns: priorityGridColumns, alignment: .leading, spacing: 12) {
            priorityCards
        }
    }

    private var priorityCards: some View {
        ForEach(vm.prioritySlots) { slot in
            priorityButton(for: slot)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch browserViewStyle {
                case .icons:
                    homeIconContent
                case .list:
                    homeListContent
                case .desktop:
                    homeDesktopContent
                }
            }
            .rootChromeCollapseObserver { updateRootTitleCollapsed($0) }
            .searchable(
                text: $vm.query,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search"
            )
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .nativeDefaultDropDestination(
                title: String(localized: "Drop in Home"),
                isTargeted: browserViewStyle != .desktop && activeFolderDropPath == AppFileRoot.documentsPath
            )
            .onPreferenceChange(NativeFolderDropFramePreferenceKey.self) { folderDropFrames = $0 }
            .onChange(of: router.homeScrollToTopCounter) { _ in
                scrollHomeToTop(using: proxy)
            }
            .background {
                if browserViewStyle != .desktop {
                    NativeFileDropInteractionBridge(
                        defaultDestinationPath: AppFileRoot.documentsPath,
                        internalMoveDefaultDestinationPath: AppFileRoot.documentsPath,
                        folderFrames: folderDropFrames,
                        onTargetChanged: { activeFolderDropPath = $0 },
                        onMove: { paths, destinationPath in
                            Task { @MainActor in
                                await move(paths: paths, toFolder: destinationPath)
                            }
                        },
                        onImport: { result, _ in handleFolderImport(result) },
                        onSpringLoad: { router.push(.folder(path: $0)) }
                    )
                }
            }
        }
        .compatibleRootPageTitle("Home", isCollapsed: isRootTitleCollapsed)
        .toolbar { mainToolbar }
        .alert("Move", isPresented: $showMoveStatus) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(moveStatusMessage)
        }
        .sheet(isPresented: $showViewOptions) {
            FileBrowserViewOptionsPanel(iconSize: $browserIconSize)
        }
        .refreshable {
            await container.libraryStore.refresh(scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository))
        }
    }

    private var homeScrollTopAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(HomeScrollTopAnchor.id)
            .accessibilityHidden(true)
    }

    private func scrollHomeToTop(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(HomeScrollTopAnchor.id, anchor: .top)
            }
        }
    }

    private func updateRootTitleCollapsed(_ isCollapsed: Bool) {
        guard isRootTitleCollapsed != isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            isRootTitleCollapsed = isCollapsed
        }
    }

    private var homeListContent: some View {
        List {
            if !vm.prioritySlots.isEmpty {
                Text("Priority Folders")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .id(HomeScrollTopAnchor.id)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)

                priorityGrid
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
            }

            if container.settingsStore.priorityFoldersCount > 0 {
                Text("Files")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .if(vm.prioritySlots.isEmpty) {
                        $0.id(HomeScrollTopAnchor.id)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            if vm.filteredItems.isEmpty {
                Group {
                    if container.libraryStore.isLoading {
                        LibraryLoadingStatusView(progress: container.libraryStore.loadingProgress)
                    } else {
                        CompatibleContentUnavailableView(
                            vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Files") : String(localized: "No Results"),
                            systemImage: "folder"
                        ) {
                            Text(homeEmptyStateDescription)
                        }
                    }
                }
                .if(vm.prioritySlots.isEmpty && container.settingsStore.priorityFoldersCount == 0) {
                    $0.id(HomeScrollTopAnchor.id)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } else {
                ForEach(Array(vm.filteredItems.enumerated()), id: \.element.id) { index, item in
                    homeFileRow(for: item)
                        .if(index == 0 && vm.prioritySlots.isEmpty && container.settingsStore.priorityFoldersCount == 0) {
                            $0.id(HomeScrollTopAnchor.id)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }
        }
        .listStyle(.plain)
        .compatibleScrollContentBackgroundHidden()
        .compatibleTopScrollContentMargin(8)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private var homeIconContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                homeScrollTopAnchor

                if !vm.prioritySlots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Priority Folders")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        priorityGrid
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if container.settingsStore.priorityFoldersCount > 0 {
                        Text("Files")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    if vm.filteredItems.isEmpty {
                        if container.libraryStore.isLoading {
                            LibraryLoadingStatusView(progress: container.libraryStore.loadingProgress)
                                .frame(maxWidth: .infinity)
                        } else {
                            CompatibleContentUnavailableView(
                                vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Files") : String(localized: "No Results"),
                                systemImage: "folder"
                            ) {
                                Text(homeEmptyStateDescription)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        LazyVGrid(columns: fileGridColumns, alignment: .leading, spacing: 22) {
                            ForEach(vm.filteredItems) { item in
                                homeIconButton(for: item)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.clear)
    }

    private var homeDesktopContent: some View {
        DesktopFileCanvas(
            items: vm.filteredItems,
            librarySongs: container.libraryStore.librarySongs,
            storageContainerPath: AppFileRoot.documentsPath ?? "medio://desktop/home",
            filesystemContainerPath: AppFileRoot.documentsPath,
            defaultDropTitle: String(localized: "Drop in Home"),
            emptyTitle: vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No Files") : String(localized: "No Results"),
            emptySystemImage: "folder",
            isLoading: container.libraryStore.isLoading,
            loadingProgress: container.libraryStore.loadingProgress,
            isSelecting: isSelecting,
            selectedItemIDs: selectedItemIDs,
            isMovable: isMovableHomeItem,
            isFolderDropEnabled: { $0.isDirectory && !MedioShadowFolder.isFavorites($0.id) },
            onOpen: openHomeItem,
            dragPaths: dragPaths,
            makeMenu: homeItemMenu,
            onMove: { paths, destinationPath in
                Task { @MainActor in
                    await move(paths: paths, toFolder: destinationPath)
                }
            },
            onImport: { result, _ in handleFolderImport(result) },
            onSpringLoad: { router.push(.folder(path: $0)) }
        ) {
            LazyVStack(alignment: .leading, spacing: 10) {
                homeScrollTopAnchor

                if !vm.prioritySlots.isEmpty {
                    Text("Priority Folders")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    priorityGrid
                }

                if container.settingsStore.priorityFoldersCount > 0 {
                    Text("Files")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func homeFileRow(for item: FileInfo) -> some View {
        libraryButton(for: item)
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
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
                homeOptionsMenu
            }
        }
    }

    private var homeOptionsMenu: some View {
        NativeBrowserOptionsMenu(accessibilityLabel: String(localized: "Home Options")) {
            UIMenu(children: [
                BrowserOptionsMenu.section([
                    BrowserOptionsMenu.action("Select", "checkmark.circle") { isSelecting = true },
                    BrowserOptionsMenu.action(String(localized: "New Folder"), "folder.badge.plus") { router.present(.createFolder(parentPath: nil)) },
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


    @ViewBuilder
    private func libraryButton(for item: FileInfo) -> some View {
        Button {
            openHomeItem(item)
        } label: {
            Group {
                if isSelecting {
                    SelectableMediaItemRow(
                        item: item,
                        isSelected: selectedItemIDs.contains(item.id),
                        isMovable: isMovableHomeItem(item)
                    )
                } else {
                    MediaItemRow(item: item, librarySongs: container.libraryStore.librarySongs)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .accessibilityIdentifier("file_item_\(item.displayName)")
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
            homeItemContextMenu(for: item)
        }
    }

    private func homeIconButton(for item: FileInfo) -> some View {
        Button {
            openHomeItem(item)
        } label: {
            FileBrowserIconTile(
                item: item,
                librarySongs: container.libraryStore.librarySongs,
                isSelecting: isSelecting,
                isSelected: selectedItemIDs.contains(item.id),
                isMovable: isMovableHomeItem(item),
                usesCardBackground: false,
                iconSize: FileBrowserIconSizing.clamped(browserIconSize)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .accessibilityIdentifier("file_item_\(item.displayName)")
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
            homeItemContextMenu(for: item)
        }
    }

    private func openHomeItem(_ item: FileInfo) {
        if isSelecting {
            toggleSelection(for: item)
        } else if MedioShadowFolder.isFavorites(item.id) {
            router.push(.favorites)
        } else if item.isDirectory {
            router.push(.folder(path: item.id))
        } else {
            Task { await vm.play(item) }
        }
    }

    @ViewBuilder
    private func homeItemContextMenu(for item: FileInfo) -> some View {
        if MedioShadowFolder.isFavorites(item.id) {
            Button("About Favorites", systemImage: "star") {
                router.present(.favoritesAbout)
            }
        } else {
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
    }

    private func homeItemMenu(for item: FileInfo) -> UIMenu {
        if MedioShadowFolder.isFavorites(item.id) {
            return UIMenu(children: [
                UIAction(title: String(localized: "About Favorites"), image: UIImage(systemName: "star")) { _ in
                    router.present(.favoritesAbout)
                }
            ])
        }

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


    private func priorityButton(for slot: HomePrioritySlot) -> some View {
        let item = priorityMovableItem(for: slot)
        let makeProvider: (() -> NSItemProvider)? = item.map { item in
            { dragProvider(for: item) }
        }

        return NativeGridItemInteractionHost(
            makeProvider: makeProvider,
            previewTitle: priorityAccessibilityLabel(for: slot),
            makeMenu: { priorityMenu(for: slot) }
        ) {
            Button {
                if isSelecting, let item {
                    toggleSelection(for: item)
                } else {
                    openPrioritySlot(slot)
                }
            } label: {
                HomePrioritySlotCard(
                    slot: slot,
                    librarySongs: container.libraryStore.librarySongs,
                    libraryItems: container.libraryStore.allItems,
                    settingsStore: container.settingsStore,
                    isSelecting: isSelecting,
                    isSelected: item.map { selectedItemIDs.contains($0.id) } ?? false,
                    isMovable: item != nil
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel(priorityAccessibilityLabel(for: slot))
            .environment(\.medioUsesCompactRootChrome, usesCompactChrome)
        }
        .frame(height: priorityCardHeight, alignment: .top)
        .background {
            // Keep glass in the grid's SwiftUI hierarchy, outside the per-card UIKit hosts.
            if !isPrioritySlotImageOnly(slot) {
                Color.clear
                    .liquidGlassCard(cornerRadius: usesCompactChrome ? 14 : 16)
                    .opacity(isSelecting && item == nil ? 0.62 : 1)
            }
        }
        .nativeFolderDropDestination(
            path: priorityDropDestination(for: slot),
            enabled: priorityDropDestination(for: slot) != nil,
            isTargeted: activeFolderDropPath == priorityDropDestination(for: slot)
        )
    }

    private var priorityCardHeight: CGFloat {
        usesCompactChrome ? HomePriorityLayoutMetrics.compactTextCardHeight : HomePriorityLayoutMetrics.textCardHeight
    }

    private func openPrioritySlot(_ slot: HomePrioritySlot) {
        guard !isPrioritySlotImageOnly(slot) else { return }
        switch slot.content {
        case .favorites:
            router.push(.favorites)
        case .folder(let item, _):
            router.push(.folder(path: item.id))
        case .empty(let storageSlot):
            router.present(.priorityFolderPicker(slot: storageSlot))
        }
    }

    private func priorityMenu(for slot: HomePrioritySlot) -> UIMenu {
        switch slot.content {
        case .favorites:
            return UIMenu(children: [UIAction(title: String(localized: "About Favorites"), image: UIImage(systemName: "star")) { _ in
                router.present(.favoritesAbout)
            }])
        case .folder(let item, let storageSlot):
            var actions: [UIMenuElement] = [
                UIAction(title: item.medioAboutActionTitle, image: UIImage(systemName: "info.circle")) { _ in
                    router.present(.fileAbout(path: item.id))
                },
                UIAction(title: String(localized: "Change Folder"), image: UIImage(systemName: "folder")) { _ in
                    router.present(.priorityFolderPicker(slot: storageSlot))
                },
                UIAction(title: String(localized: "Make Image"), image: UIImage(systemName: "photo")) { _ in
                    router.present(.prioritySlotAbout(slot: storageSlot))
                },
                UIAction(
                    title: String(localized: "Remove"),
                    image: UIImage(systemName: "pin.slash"),
                    attributes: .destructive
                ) { _ in
                    container.settingsStore.resetPrioritySlot(at: storageSlot)
                }
            ]
            if container.settingsStore.isPrioritySlotImageOnly(storageSlot) {
                actions.insert(UIAction(title: String(localized: "Show Folder Card"), image: UIImage(systemName: "folder")) { _ in
                    container.settingsStore.setPrioritySlotImageOnly(false, at: storageSlot)
                }, at: 3)
            }
            return UIMenu(children: actions)
        case .empty(let storageSlot):
            var actions: [UIMenuElement] = [
                UIAction(title: String(localized: "Choose Folder"), image: UIImage(systemName: "folder")) { _ in
                    router.present(.priorityFolderPicker(slot: storageSlot))
                },
                UIAction(title: String(localized: "Make Image"), image: UIImage(systemName: "photo")) { _ in
                    router.present(.prioritySlotAbout(slot: storageSlot))
                }
            ]
            if container.settingsStore.isPrioritySlotImageOnly(storageSlot) {
                actions.append(UIAction(title: String(localized: "Show Folder Card"), image: UIImage(systemName: "folder")) { _ in
                    container.settingsStore.setPrioritySlotImageOnly(false, at: storageSlot)
                })
            }
            if container.settingsStore.prioritySlotArtworkPath(at: storageSlot) != nil {
                actions.append(UIAction(
                    title: String(localized: "Remove"),
                    image: UIImage(systemName: "pin.slash"),
                    attributes: .destructive
                ) { _ in
                    container.settingsStore.resetPrioritySlot(at: storageSlot)
                })
            }
            return UIMenu(children: actions)
        }
    }

    private func priorityAccessibilityLabel(for slot: HomePrioritySlot) -> String {
        switch slot.content {
        case .favorites:
            return MedioShadowFolder.favoritesName
        case .folder(let item, _):
            return item.displayName
        case .empty(let storageSlot):
            return String(localized: "Choose priority folder \(storageSlot + 2)")
        }
    }

    private func priorityDropDestination(for slot: HomePrioritySlot) -> String? {
        guard !isPrioritySlotImageOnly(slot) else { return nil }
        if case .folder(let item, _) = slot.content {
            return item.id
        }
        return nil
    }

    private func priorityMovableItem(for slot: HomePrioritySlot) -> FileInfo? {
        guard !isPrioritySlotImageOnly(slot) else { return nil }
        if case .folder(let item, _) = slot.content {
            return item
        }
        return nil
    }

    private func isPrioritySlotImageOnly(_ slot: HomePrioritySlot) -> Bool {
        switch slot.content {
        case .favorites:
            return false
        case .folder(_, let storageSlot), .empty(let storageSlot):
            // A missing or unreadable image renders as a text card, so its sizing and
            // interactions must use that same fallback instead of reserving image height.
            return container.settingsStore.isPrioritySlotImageOnly(storageSlot)
                && VisualArtworkOverrideStore.image(at: container.settingsStore.prioritySlotArtworkPath(at: storageSlot)) != nil
        }
    }

    private func isMovableHomeItem(_ item: FileInfo) -> Bool {
        !MedioShadowFolder.isFavorites(item.id)
    }

    private func toggleSelection(for item: FileInfo) {
        guard isMovableHomeItem(item) else { return }
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

    private var homeEmptyStateDescription: String {
        if !vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "No file, album, artist, or folder matches this search.")
        }

        if let error = container.libraryStore.lastStorageScanError {
            return String(localized: "Storage refresh failed: \(error)")
        }

        if let summary = container.libraryStore.lastStorageScanSummary {
            if summary.scannedItemCount == 0 {
                return String(localized: "Storage was scanned, but Medio found no files in On My iPhone > Medio.")
            }
            if summary.visibleHomeItemCount == 0 {
                return String(localized: "Storage was scanned and \(summary.scannedItemCount) items were found, but none are visible on Home.")
            }
        }

        return String(localized: "Put files in On My iPhone > Medio, then pull down to refresh storage.")
    }

    private func dragProvider(for item: FileInfo) -> NSItemProvider {
        if isSelecting {
            if !selectedItemIDs.contains(item.id), isMovableHomeItem(item) {
                selectedItemIDs = [item.id]
            }
        }
        let paths = dragPaths(for: item)
        return makeMoveItemProvider(items: dragFileInfos(
            paths: paths,
            knownItems: container.libraryStore.allItems + [item]
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
            return isMovableHomeItem(item) ? [item.id] : []
        }
        return isMovableHomeItem(item) ? [item.id] : []
    }

    private func importFilesFromPicker() async {
        do {
            let urls = try await container.documentPickingService.pickFile(
                contentTypes: [.item],
                allowsMultipleSelection: true
            )
            let importedURLs = try await ImportDocumentsUseCase().execute(urls: urls)
            guard !importedURLs.isEmpty else {
                moveStatusMessage = String(localized: "No files were imported.")
                showMoveStatus = true
                return
            }
            await container.libraryStore.refresh(scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository))
        } catch SystemUIError.cancelled {
            return
        } catch {
            moveStatusMessage = error.localizedDescription
            showMoveStatus = true
        }
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

    private func move(paths: [String], toFolder destinationPath: String) async {
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

struct FileBrowserIconTile: View {
    let item: FileInfo
    let librarySongs: [FileInfo]
    let isSelecting: Bool
    let isSelected: Bool
    let isMovable: Bool
    var usesCardBackground = true
    var iconSize: CGFloat = CGFloat(FileBrowserIconSizing.defaultSize)
    @EnvironmentObject private var playbackStore: PlaybackStore

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: usesCardBackground ? .center : .leading, spacing: usesCardBackground ? 8 : 7) {
                artwork
                    .frame(width: iconSize, height: iconSize)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(item.displayName)
                    .font(usesCardBackground ? .subheadline : .system(size: 15, weight: .regular))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(usesCardBackground ? .center : .leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: usesCardBackground ? 36 : 40, alignment: .topLeading)

                if usesCardBackground {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(usesCardBackground ? 10 : 0)
            .frame(maxWidth: .infinity, minHeight: iconSize + (usesCardBackground ? 66 : 50), alignment: .topLeading)
            .background(
                usesCardBackground ? Color(.secondarySystemGroupedBackground) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(isMovable ? 0.9 : 0.35))
                    .padding(8)
            }
        }
        .opacity(isSelecting && !isMovable ? 0.62 : 1)
        .playbackQueueProgress(for: item.id)
    }

    private var subtitle: String {
        if !item.isDirectory,
           item.fileType == .music || item.fileType == .video,
           let author = item.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty {
            return author
        }
        return item.localizedTypeDescription ?? item.fileType.rawValue
    }

    @AppStorage(PlaybackIndicatorScope.key) private var indicatorScopes = PlaybackIndicatorScope.all

    private var showsNowPlayingVisualizer: Bool {
        indicatorScopes & PlaybackIndicatorScope.songs.rawValue != 0 && item.fileType == .music && playbackStore.nowPlaying?.id == item.id
    }

    @ViewBuilder
    private var artwork: some View {
        if MedioShadowFolder.isFavorites(item.id) {
            FavoriteFolderArtworkView()
        } else {
            switch item.fileType {
            case .folder:
                FolderArtworkView(path: item.id, librarySongs: librarySongs)
            case .music:
                if showsNowPlayingVisualizer {
                    NowPlayingAudioVisualizerArtwork(
                        isPlaying: playbackStore.isPlaying,
                        levels: playbackStore.audioLevels,
                        size: iconSize,
                        cornerRadius: 8
                    )
                } else {
                    SongArtworkView(path: item.id, size: iconSize, cornerRadius: 8)
                }
            case .video:
                SongArtworkView(path: item.id, size: iconSize, cornerRadius: 8, fallbackSystemImage: "film.fill")
            case .lyrics:
                fileSymbol("doc.text.fill", color: .orange)
            case .unrecognized:
                fileSymbol("doc.fill", color: .secondary)
            }
        }
    }

    private func fileSymbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 52, height: 52)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DesktopCanvasFrameReader: View {
    let onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { onChange(frame) }
                .onChange(of: frame) { newFrame in onChange(newFrame) }
        }
    }
}

struct DesktopFileCanvas<Header: View>: View {
    private let tileSize = CGSize(width: 112, height: 126)
    private let itemSpacing: CGFloat = 14

    let items: [FileInfo]
    let librarySongs: [FileInfo]
    let storageContainerPath: String
    let filesystemContainerPath: String?
    let defaultDropTitle: String
    let emptyTitle: String
    let emptySystemImage: String
    let isLoading: Bool
    let loadingProgress: LibraryScanProgress?
    let isSelecting: Bool
    let selectedItemIDs: Set<String>
    let isMovable: (FileInfo) -> Bool
    let isFolderDropEnabled: (FileInfo) -> Bool
    let onOpen: (FileInfo) -> Void
    let dragPaths: (FileInfo) -> [String]
    let makeMenu: (FileInfo) -> UIMenu
    let onMove: ([String], String) -> Void
    let onImport: (Result<[URL], Error>, String) -> Void
    let onSpringLoad: (String) -> Void
    let header: Header

    @State private var positions: [String: CGPoint] = [:]
    @State private var canvasFrame = CGRect.zero
    @State private var folderDropFrames: [String: CGRect] = [:]
    @State private var activeFolderDropPath: String?

    init(
        items: [FileInfo],
        librarySongs: [FileInfo],
        storageContainerPath: String,
        filesystemContainerPath: String?,
        defaultDropTitle: String,
        emptyTitle: String,
        emptySystemImage: String,
        isLoading: Bool = false,
        loadingProgress: LibraryScanProgress? = nil,
        isSelecting: Bool,
        selectedItemIDs: Set<String>,
        isMovable: @escaping (FileInfo) -> Bool,
        isFolderDropEnabled: @escaping (FileInfo) -> Bool,
        onOpen: @escaping (FileInfo) -> Void,
        dragPaths: @escaping (FileInfo) -> [String],
        makeMenu: @escaping (FileInfo) -> UIMenu,
        onMove: @escaping ([String], String) -> Void,
        onImport: @escaping (Result<[URL], Error>, String) -> Void,
        onSpringLoad: @escaping (String) -> Void,
        @ViewBuilder header: () -> Header
    ) {
        self.items = items
        self.librarySongs = librarySongs
        self.storageContainerPath = storageContainerPath
        self.filesystemContainerPath = filesystemContainerPath
        self.defaultDropTitle = defaultDropTitle
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.isLoading = isLoading
        self.loadingProgress = loadingProgress
        self.isSelecting = isSelecting
        self.selectedItemIDs = selectedItemIDs
        self.isMovable = isMovable
        self.isFolderDropEnabled = isFolderDropEnabled
        self.onOpen = onOpen
        self.dragPaths = dragPaths
        self.makeMenu = makeMenu
        self.onMove = onMove
        self.onImport = onImport
        self.onSpringLoad = onSpringLoad
        self.header = header()
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    ZStack(alignment: .topLeading) {
                        if items.isEmpty {
                            if isLoading {
                                LibraryLoadingStatusView(progress: loadingProgress)
                                    .frame(width: viewport.size.width)
                                    .padding(.top, 40)
                            } else {
                                CompatibleContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
                                    .frame(width: viewport.size.width)
                                    .padding(.top, 40)
                            }
                        } else {
                            ForEach(items) { item in
                                desktopItem(item, canvasWidth: viewport.size.width)
                            }
                        }
                    }
                    .frame(
                        width: viewport.size.width,
                        height: canvasHeight(minimum: viewport.size.height),
                        alignment: .topLeading
                    )
                    .background {
                        DesktopCanvasFrameReader { frame in
                            if canvasFrame != frame {
                                canvasFrame = frame
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .frame(minWidth: viewport.size.width, alignment: .topLeading)
            }
            .onAppear {
                synchronizePositions(canvasWidth: viewport.size.width)
            }
            .onChange(of: viewport.size.width) { width in
                synchronizePositions(canvasWidth: width)
            }
            .task(id: items.map(\.id)) {
                synchronizePositions(canvasWidth: viewport.size.width)
            }
        }
        .background(Color(.systemGroupedBackground))
        .nativeDefaultDropDestination(
            title: defaultDropTitle,
            isTargeted: filesystemContainerPath.map { activeFolderDropPath == $0 } ?? false
        )
        .onPreferenceChange(NativeFolderDropFramePreferenceKey.self) { folderDropFrames = $0 }
        .background {
            NativeFileDropInteractionBridge(
                defaultDestinationPath: filesystemContainerPath,
                internalMoveDefaultDestinationPath: filesystemContainerPath,
                folderFrames: folderDropFrames,
                onTargetChanged: { activeFolderDropPath = $0 },
                onMove: moveIntoFolder,
                onImport: onImport,
                onSpringLoad: onSpringLoad,
                onPin: pin
            )
        }
    }

    private func desktopItem(_ item: FileInfo, canvasWidth: CGFloat) -> some View {
        NativeDesktopItemInteractionHost(
            makeMenu: { makeMenu(item) },
            onDragChanged: { globalPoint in
                activeFolderDropPath = hoveredFolder(
                    at: globalPoint,
                    excluding: Set(dragPaths(item))
                )
            },
            onDragEnded: { globalPoint in
                let paths = dragPaths(item)
                if let destinationPath = hoveredFolder(at: globalPoint, excluding: Set(paths)) {
                    moveIntoFolder(paths: paths, destinationPath: destinationPath)
                } else {
                    pin(paths: paths, at: globalPoint)
                }
                activeFolderDropPath = nil
            },
            onDragCancelled: {
                activeFolderDropPath = nil
            }
        ) {
            Button {
                onOpen(item)
            } label: {
                FileBrowserIconTile(
                    item: item,
                    librarySongs: librarySongs,
                    isSelecting: isSelecting,
                    isSelected: selectedItemIDs.contains(item.id),
                    isMovable: isMovable(item),
                    usesCardBackground: false
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.displayName)
            .accessibilityIdentifier("file_item_\(item.displayName)")
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .nativeFolderDropDestination(
            path: item.id,
            enabled: isFolderDropEnabled(item),
            isTargeted: activeFolderDropPath == item.id
        )
        .position(clampedPosition(for: item.id, canvasWidth: canvasWidth))
    }

    private func synchronizePositions(canvasWidth: CGFloat) {
        guard canvasWidth > 0 else { return }
        let stored = MedioDesktopPositionStore.positions(
            in: storageContainerPath,
            canvasSize: CGSize(width: canvasWidth, height: 0)
        )
        var next: [String: CGPoint] = [:]
        var additions: [String: CGPoint] = [:]

        for (index, item) in items.enumerated() {
            if let point = stored[item.id] {
                next[item.id] = point
            } else {
                let point = initialPosition(index: index, itemID: item.id, canvasWidth: canvasWidth)
                next[item.id] = point
                additions[item.id] = point
            }
        }

        positions = next
        if !additions.isEmpty {
            MedioDesktopPositionStore.set(
                additions,
                in: storageContainerPath,
                canvasSize: CGSize(width: canvasWidth, height: 0)
            )
        }
    }

    private func initialPosition(index: Int, itemID: String, canvasWidth: CGFloat) -> CGPoint {
        let usableWidth = max(tileSize.width, canvasWidth - 32)
        let columnWidth = tileSize.width + itemSpacing
        let columns = max(1, Int(usableWidth / columnWidth))
        let column = index % columns
        let row = index / columns
        let stableJitter = itemID.utf8.reduce(0) { ($0 + Int($1)) % 13 }
        let jitter = CGFloat(stableJitter - 6)
        return CGPoint(
            x: 16 + tileSize.width / 2 + CGFloat(column) * columnWidth + jitter,
            y: 16 + tileSize.height / 2 + CGFloat(row) * (tileSize.height + itemSpacing) - jitter / 2
        )
    }

    private func clampedPosition(for itemID: String, canvasWidth: CGFloat) -> CGPoint {
        let fallback = CGPoint(x: 16 + tileSize.width / 2, y: 16 + tileSize.height / 2)
        return clamped(positions[itemID] ?? fallback, canvasWidth: canvasWidth)
    }

    private func clamped(_ point: CGPoint, canvasWidth: CGFloat) -> CGPoint {
        let halfWidth = tileSize.width / 2
        let halfHeight = tileSize.height / 2
        return CGPoint(
            x: min(max(point.x, halfWidth + 8), max(halfWidth + 8, canvasWidth - halfWidth - 8)),
            y: max(point.y, halfHeight + 8)
        )
    }

    private func canvasHeight(minimum: CGFloat) -> CGFloat {
        let lowestItem = positions.values.map(\.y).max() ?? 0
        return max(minimum, lowestItem + tileSize.height / 2 + 32)
    }

    private func pin(paths: [String], at globalPoint: CGPoint) {
        let visiblePaths = Set(items.map(\.id))
        guard !paths.isEmpty else { return }
        guard paths.allSatisfy(visiblePaths.contains) else {
            if let filesystemContainerPath {
                onMove(paths, filesystemContainerPath)
            }
            return
        }

        let localPoint = CGPoint(
            x: globalPoint.x - canvasFrame.minX,
            y: globalPoint.y - canvasFrame.minY
        )
        let anchorPath = paths[0]
        let anchor = positions[anchorPath] ?? localPoint
        let translation = CGSize(width: localPoint.x - anchor.x, height: localPoint.y - anchor.y)
        var updates: [String: CGPoint] = [:]

        for path in paths {
            let current = positions[path] ?? anchor
            updates[path] = clamped(
                CGPoint(x: current.x + translation.width, y: current.y + translation.height),
                canvasWidth: canvasFrame.width
            )
        }

        positions.merge(updates, uniquingKeysWith: { _, latest in latest })
        MedioDesktopPositionStore.set(
            updates,
            in: storageContainerPath,
            canvasSize: canvasFrame.size
        )
    }

    private func moveIntoFolder(paths: [String], destinationPath: String) {
        let movedPaths = paths.filter { $0 != destinationPath && !MedioShadowFolder.isFavorites($0) }
        guard !movedPaths.isEmpty else { return }
        MedioDesktopPositionStore.remove(itemPaths: movedPaths, from: storageContainerPath)
        positions = positions.filter { !movedPaths.contains($0.key) }
        onMove(movedPaths, destinationPath)
    }

    private func hoveredFolder(at globalPoint: CGPoint, excluding paths: Set<String>) -> String? {
        nativeDropDestination(
            at: globalPoint,
            folderFrames: folderDropFrames.filter { !paths.contains($0.key) },
            defaultPath: nil
        )
    }
}

let medioInternalMovePayloadType = UTType(
    exportedAs: "com.vojtech.medio.internal-move-paths",
    conformingTo: .json
)
let medioInternalMovePayloadTypeIdentifier = medioInternalMovePayloadType.identifier

let medioLegacyMovePayloadTypeIdentifiers = [
    UTType.utf8PlainText.identifier,
    UTType.plainText.identifier,
    UTType.text.identifier
]

let medioMovePayloadTypeIdentifiers = [
    medioInternalMovePayloadTypeIdentifier
] + medioLegacyMovePayloadTypeIdentifiers

let medioRootDropPayloadTypeIdentifiers = [
    medioInternalMovePayloadTypeIdentifier,
    UTType.fileURL.identifier
] + medioLegacyMovePayloadTypeIdentifiers

let medioFolderDropPayloadTypeIdentifiers = [
    medioInternalMovePayloadTypeIdentifier,
    UTType.fileURL.identifier
] + medioLegacyMovePayloadTypeIdentifiers

struct MedioDragPayload: Codable, Equatable {
    let version: Int
    let items: [FileInfo]

    init(items: [FileInfo]) {
        version = 1
        self.items = items
    }

    var paths: [String] {
        items.map(\.id)
    }
}

private let medioLocalDragPathsLock = NSLock()
nonisolated(unsafe) private var medioLocalDragPaths: [String] = []

private func cachedLocalMovePaths(from providers: [NSItemProvider]) -> [String] {
    guard providers.contains(where: {
        $0.hasItemConformingToTypeIdentifier(medioInternalMovePayloadTypeIdentifier)
    }) else { return [] }
    medioLocalDragPathsLock.lock()
    defer { medioLocalDragPathsLock.unlock() }
    return medioLocalDragPaths
}

private func setCachedLocalMovePaths(_ paths: [String]) {
    medioLocalDragPathsLock.lock()
    medioLocalDragPaths = paths
    medioLocalDragPathsLock.unlock()
}

private func clearCachedLocalMovePaths() {
    setCachedLocalMovePaths([])
}

/// Creates the native drag item provider. The private JSON representation keeps Medio metadata
/// intact for local moves, while the file-backed provider lets compatible apps receive the file.
func makeMoveItemProvider(items: [FileInfo]) -> NSItemProvider {
    let existingItems = items.filter { FileManager.default.fileExists(atPath: $0.id) }
    let primaryURL = existingItems.first.map {
        URL(fileURLWithPath: $0.id, isDirectory: $0.isDirectory).standardizedFileURL
    }
    let provider = primaryURL.flatMap(NSItemProvider.init(contentsOf:)) ?? NSItemProvider()

    if let first = items.first {
        provider.suggestedName = items.count == 1 ? first.displayName : "\(items.count) items"
    }

    if let primaryURL, let first = items.first {
        let contentType = first.isDirectory
            ? UTType.folder
            : first.typeIdentifier.flatMap(UTType.init)
                ?? UTType(filenameExtension: primaryURL.pathExtension)
                ?? .data
        if !provider.hasItemConformingToTypeIdentifier(contentType.identifier) {
            provider.registerFileRepresentation(
                forTypeIdentifier: contentType.identifier,
                fileOptions: [.openInPlace],
                visibility: .all
            ) { completion in
                completion(primaryURL, true, nil)
                return nil
            }
        }
    }

    let payload = MedioDragPayload(items: items)
    guard !items.isEmpty, let data = try? JSONEncoder().encode(payload) else {
        return provider
    }

    // SwiftUI's DropInfo must be able to see this representation to validate a native drop.
    // Other apps use the standard file representation registered above.
    provider.registerDataRepresentation(
        forTypeIdentifier: medioInternalMovePayloadTypeIdentifier,
        visibility: .all
    ) { completion in
        completion(data, nil)
        return nil
    }
    setCachedLocalMovePaths(payload.paths)

    return provider
}

func dragFileInfos(paths: [String], knownItems: [FileInfo]) -> [FileInfo] {
    let knownByPath = Dictionary(knownItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return paths.map { path in
        if let known = knownByPath[path] {
            return known
        }

        var isDirectory = ObjCBool(false)
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
        return FileInfo(
            id: path,
            isDirectory: isDirectory.boolValue,
            displayName: url.lastPathComponent,
            author: nil,
            album: nil
        )
    }
}

@discardableResult
func importDroppedFiles(
    from providers: [NSItemProvider],
    toFolder destinationPath: String,
    onComplete: @escaping (Result<[URL], Error>) -> Void
) -> Bool {
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !fileProviders.isEmpty else { return false }

    let group = DispatchGroup()
    let state = DroppedFileImportState()

    for provider in fileProviders {
        group.enter()
        provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { sourceURL, error in
            guard let sourceURL, error == nil else {
                state.record(error: error ?? droppedFileImportError(String(localized: "The dropped file could not be opened.")))
                group.leave()
                return
            }

            Task {
                defer { group.leave() }
                do {
                    let result = try await FileMoveService().importBatch(at: [sourceURL], toFolder: destinationPath)
                    state.record(importedURLs: result.completed)
                    if let failure = result.failures.first {
                        state.record(error: droppedFileImportError(failure.message))
                    }
                } catch {
                    state.record(error: error)
                }
            }
        }
    }

    group.notify(queue: .main) {
        let (importedURLs, firstError) = state.snapshot()

        if !importedURLs.isEmpty {
            onComplete(.success(importedURLs))
        } else {
            onComplete(.failure(firstError ?? droppedFileImportError(String(localized: "The dropped files could not be imported."))))
        }
    }
    return true
}

private final class DroppedFileImportState: @unchecked Sendable {
    private let lock = NSLock()
    private var importedURLs: [URL] = []
    private var firstError: Error?

    func record(importedURLs: [URL]) {
        lock.lock()
        self.importedURLs.append(contentsOf: importedURLs)
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        firstError = firstError ?? error
        lock.unlock()
    }

    func snapshot() -> ([URL], Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (importedURLs, firstError)
    }
}

private func droppedFileImportError(_ message: String) -> NSError {
    NSError(domain: "DroppedFileImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@discardableResult
func loadMovePaths(
    from providers: [NSItemProvider],
    onLoad: @escaping @MainActor @Sendable ([String]) -> Void
) -> Bool {
    if let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(medioInternalMovePayloadTypeIdentifier)
    }) {
        provider.loadDataRepresentation(forTypeIdentifier: medioInternalMovePayloadTypeIdentifier) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(MedioDragPayload.self, from: data),
                  !payload.paths.isEmpty else { return }
            Task { @MainActor in
                onLoad(payload.paths)
            }
        }
        return true
    }

    guard let provider = providers.first(where: { provider in
        provider.canLoadObject(ofClass: NSString.self)
            || medioLegacyMovePayloadTypeIdentifiers.contains {
                provider.hasItemConformingToTypeIdentifier($0)
            }
    }) else {
        return false
    }

    if provider.canLoadObject(ofClass: NSString.self) {
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String else { return }
            let paths = parsedMovePaths(raw)
            guard !paths.isEmpty else { return }
            Task { @MainActor in
                onLoad(paths)
            }
        }
        return true
    }

    guard let typeIdentifier = medioLegacyMovePayloadTypeIdentifiers.first(where: {
        provider.hasItemConformingToTypeIdentifier($0)
    }) else { return false }

    provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
        guard let data, let raw = String(data: data, encoding: .utf8) else { return }
        let paths = parsedMovePaths(raw)
        guard !paths.isEmpty else { return }
        Task { @MainActor in
            onLoad(paths)
        }
    }
    return true
}

private func parsedMovePaths(_ raw: String) -> [String] {
    raw
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

struct SelectableMediaItemRow: View {
    let item: FileInfo
    let isSelected: Bool
    let isMovable: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(isMovable ? 0.85 : 0.35))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.body)
                    .foregroundStyle(isMovable ? .primary : .secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.isDirectory, let author = item.author, !author.isEmpty {
                    Text(author)
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

struct MultiItemDragPreview: View {
    let paths: [String]

    private var count: Int {
        max(paths.count, 1)
    }

    private var title: String {
        guard let first = paths.first else { return "Item" }
        let name = URL(fileURLWithPath: first).lastPathComponent
        return name.isEmpty ? "Item" : name
    }

    private var iconName: String {
        guard count == 1, let first = paths.first else { return "square.stack.fill" }
        var isDirectory = ObjCBool(false)
        FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory)
        return isDirectory.boolValue ? "folder.fill" : "doc.fill"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(0..<min(count, 3), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .frame(width: 142, height: 52)
                        .rotationEffect(.degrees(rotation(for: index)))
                        .offset(x: CGFloat(index) * 5, y: -CGFloat(index) * 4)
                }

                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .foregroundStyle(Color.accentColor)
                    Text(count > 1 ? "\(count) items" : title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12)
                .frame(width: 142, height: 52, alignment: .leading)
            }

            if count > 1 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 10, y: -12)
            }
        }
        .frame(width: 156, height: 64)
    }

    private func rotation(for index: Int) -> Double {
        switch index {
        case 0: return -5
        case 1: return 4
        default: return -1
        }
    }
}

extension View {
    /// Starts a system drag for a file-backed content row. The provider exposes Medio's private
    /// metadata payload for in-app moves and the actual file URL for compatible destination apps.
    func medioNativeDrag(_ item: FileInfo) -> some View {
        onDrag {
            makeMoveItemProvider(items: [item])
        } preview: {
            MultiItemDragPreview(paths: [item.id])
        }
    }

    @ViewBuilder
    func medioNativeDrag(_ item: FileInfo?) -> some View {
        if let item {
            medioNativeDrag(item)
        } else {
            self
        }
    }
}

struct NativeFolderDropFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Desktop items move as soon as the pointer moves, leaving a stationary long press exclusively
/// for the context menu. This matches desktop dragging and avoids UIDragInteraction's lift delay.
struct NativeDesktopItemInteractionHost<Content: View>: UIViewControllerRepresentable {
    let makeMenu: () -> UIMenu
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onDragCancelled: () -> Void
    let content: Content

    init(
        makeMenu: @escaping () -> UIMenu,
        onDragChanged: @escaping (CGPoint) -> Void,
        onDragEnded: @escaping (CGPoint) -> Void,
        onDragCancelled: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.makeMenu = makeMenu
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.onDragCancelled = onDragCancelled
        self.content = content()
    }

    func makeUIViewController(context: Context) -> NativeDesktopItemInteractionHostingController<Content> {
        NativeDesktopItemInteractionHostingController(
            rootView: content,
            makeMenu: makeMenu,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            onDragCancelled: onDragCancelled
        )
    }

    func updateUIViewController(
        _ uiViewController: NativeDesktopItemInteractionHostingController<Content>,
        context: Context
    ) {
        uiViewController.rootView = content
        uiViewController.makeMenu = makeMenu
        uiViewController.onDragChanged = onDragChanged
        uiViewController.onDragEnded = onDragEnded
        uiViewController.onDragCancelled = onDragCancelled
    }
}

final class NativeDesktopItemInteractionHostingController<Content: View>:
    UIHostingController<Content>, UIContextMenuInteractionDelegate {
    var makeMenu: () -> UIMenu
    var onDragChanged: (CGPoint) -> Void
    var onDragEnded: (CGPoint) -> Void
    var onDragCancelled: () -> Void

    init(
        rootView: Content,
        makeMenu: @escaping () -> UIMenu,
        onDragChanged: @escaping (CGPoint) -> Void,
        onDragEnded: @escaping (CGPoint) -> Void,
        onDragCancelled: @escaping () -> Void
    ) {
        self.makeMenu = makeMenu
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.onDragCancelled = onDragCancelled
        super.init(rootView: rootView)
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view.superview)
        let globalPoint = recognizer.location(in: view.window)

        switch recognizer.state {
        case .began:
            view.layer.zPosition = 1_000
            view.alpha = 0.88
            fallthrough
        case .changed:
            view.transform = CGAffineTransform(
                translationX: translation.x,
                y: translation.y
            ).scaledBy(x: 1.04, y: 1.04)
            onDragChanged(globalPoint)
        case .ended:
            onDragEnded(globalPoint)
            resetDragAppearance()
        case .cancelled, .failed:
            onDragCancelled()
            resetDragAppearance()
        default:
            break
        }
    }

    private func resetDragAppearance() {
        UIView.animate(withDuration: 0.16) {
            self.view.transform = .identity
            self.view.alpha = 1
        }
        view.layer.zPosition = 0
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeMenu()
        }
    }
}

/// Each priority card gets its own UIKit host view and UIDragInteraction. This prevents the grid's
/// enclosing List cell from treating all long presses as a drag of its first movable card.
struct NativeGridItemInteractionHost<Content: View>: UIViewControllerRepresentable {
    let makeProvider: (() -> NSItemProvider)?
    let previewTitle: String
    let makeMenu: () -> UIMenu
    let content: Content

    init(
        makeProvider: (() -> NSItemProvider)?,
        previewTitle: String,
        makeMenu: @escaping () -> UIMenu,
        @ViewBuilder content: () -> Content
    ) {
        self.makeProvider = makeProvider
        self.previewTitle = previewTitle
        self.makeMenu = makeMenu
        self.content = content()
    }

    func makeUIViewController(context: Context) -> NativeGridItemInteractionHostingController<Content> {
        NativeGridItemInteractionHostingController(
            rootView: content,
            makeProvider: makeProvider,
            previewTitle: previewTitle,
            makeMenu: makeMenu
        )
    }

    func updateUIViewController(
        _ uiViewController: NativeGridItemInteractionHostingController<Content>,
        context: Context
    ) {
        uiViewController.rootView = content
        uiViewController.makeProvider = makeProvider
        uiViewController.previewTitle = previewTitle
        uiViewController.makeMenu = makeMenu
    }

    @available(iOS 16.0, *)
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: NativeGridItemInteractionHostingController<Content>,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 180
        if let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        let fitting = uiViewController.sizeThatFits(in: CGSize(width: width, height: 180))
        return CGSize(width: width, height: min(180, max(88, fitting.height)))
    }
}

final class NativeGridItemInteractionHostingController<Content: View>:
    UIHostingController<Content>, UIDragInteractionDelegate, UIContextMenuInteractionDelegate {
    var makeProvider: (() -> NSItemProvider)?
    var previewTitle: String
    var makeMenu: () -> UIMenu

    init(
        rootView: Content,
        makeProvider: (() -> NSItemProvider)?,
        previewTitle: String,
        makeMenu: @escaping () -> UIMenu
    ) {
        self.makeProvider = makeProvider
        self.previewTitle = previewTitle
        self.makeMenu = makeMenu
        super.init(rootView: rootView)
        if #available(iOS 16.4, *) {
            // The surrounding grid owns safe-area layout, not each embedded card.
            safeAreaRegions = []
        }
        view.backgroundColor = .clear
        // Empty slots can become folders without recreating the host. The delegate returns
        // no items until a provider is assigned.
        view.addInteraction(UIDragInteraction(delegate: self))
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        guard let provider = makeProvider?() else { return [] }
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.previewProvider = {
            PriorityCardDragPreview.make(title: self.previewTitle)
        }
        return [dragItem]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        previewForLifting item: UIDragItem,
        session: UIDragSession
    ) -> UITargetedDragPreview? {
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 16)
        return UITargetedDragPreview(view: view, parameters: parameters)
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionAllowsMoveOperation session: UIDragSession
    ) -> Bool {
        true
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool {
        false
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeMenu()
        }
    }
}

private enum PriorityCardDragPreview {
    @MainActor
    static func make(title: String) -> UIDragPreview {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 64))
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 16
        container.layer.cornerCurve = .continuous

        let icon = UIImageView(image: UIImage(systemName: "folder.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: 14, y: 14, width: 36, height: 36)
        container.addSubview(icon)

        let label = UILabel(frame: CGRect(x: 60, y: 8, width: 106, height: 48))
        label.text = title
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 2
        label.adjustsFontForContentSizeCategory = true
        container.addSubview(label)

        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: container.bounds, cornerRadius: 16)
        return UIDragPreview(view: container, parameters: parameters)
    }
}

private struct NativeFolderDropDestinationModifier: ViewModifier {
    let path: String?
    let enabled: Bool
    let isTargeted: Bool

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: NativeFolderDropFramePreferenceKey.self,
                        value: enabled ? path.map { [$0: proxy.frame(in: .global)] } ?? [:] : [:]
                    )
                }
            }
            .overlay {
                if enabled, isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 2.5)
                        }
                        .overlay(alignment: .trailing) {
                            Image(systemName: "folder.badge.plus")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.trailing, 14)
                        }
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isTargeted)
            .compatibleSelectionFeedback(trigger: isTargeted)
    }
}

private struct NativeDefaultDropDestinationModifier: ViewModifier {
    let title: String
    let isTargeted: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .overlay(alignment: .top) {
                        Label(title, systemImage: "tray.and.arrow.down.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 14)
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isTargeted)
    }
}

extension View {
    /// Registers a folder's visible bounds with the list's single native drop interaction.
    func nativeFolderDropDestination(path: String?, enabled: Bool, isTargeted: Bool) -> some View {
        modifier(NativeFolderDropDestinationModifier(path: path, enabled: enabled, isTargeted: isTargeted))
    }

    /// Shows where a drop will land when the pointer is not over a child folder row.
    func nativeDefaultDropDestination(title: String, isTargeted: Bool) -> some View {
        modifier(NativeDefaultDropDestinationModifier(title: title, isTargeted: isTargeted))
    }
}

func nativeDropDestination(
    at point: CGPoint,
    folderFrames: [String: CGRect],
    defaultPath: String?
) -> String? {
    folderFrames
        .filter { $0.value.contains(point) }
        .min { lhs, rhs in
            let lhsArea = lhs.value.width * lhs.value.height
            let rhsArea = rhs.value.width * rhs.value.height
            return lhsArea == rhsArea ? lhs.key < rhs.key : lhsArea < rhsArea
        }?
        .key ?? defaultPath
}

func nativeDropDefaultDestination(
    isInternalMove: Bool,
    defaultPath: String?,
    internalMovePath: String?
) -> String? {
    isInternalMove ? internalMovePath ?? defaultPath : defaultPath
}

/// Installs one UIKit drop interaction on the SwiftUI list. A single interaction avoids nested
/// SwiftUI drop targets competing and resolves child folders by their visible row frames.
struct NativeFileDropInteractionBridge: UIViewRepresentable {
    let defaultDestinationPath: String?
    let internalMoveDefaultDestinationPath: String?
    let folderFrames: [String: CGRect]
    let onTargetChanged: (String?) -> Void
    let onMove: ([String], String) -> Void
    let onImport: (Result<[URL], Error>, String) -> Void
    let onSpringLoad: (String) -> Void
    var onPin: (([String], CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.configure(from: self)
        context.coordinator.attach(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.configure(from: self)
        context.coordinator.attach(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        private weak var attachedView: UIView?
        private var dropInteraction: UIDropInteraction?
        private var defaultDestinationPath: String?
        private var internalMoveDefaultDestinationPath: String?
        private var folderFrames: [String: CGRect] = [:]
        private var activeFolderPath: String?
        private var currentProviders: [NSItemProvider] = []
        private var currentDraggedPaths: [String] = []
        private var isLoadingDraggedPaths = false
        private var springLoadWorkItem: DispatchWorkItem?
        private var onTargetChanged: (String?) -> Void = { _ in }
        private var onMove: ([String], String) -> Void = { _, _ in }
        private var onImport: (Result<[URL], Error>, String) -> Void = { _, _ in }
        private var onSpringLoad: (String) -> Void = { _ in }
        private var onPin: (([String], CGPoint) -> Void)?

        func configure(from bridge: NativeFileDropInteractionBridge) {
            defaultDestinationPath = bridge.defaultDestinationPath
            internalMoveDefaultDestinationPath = bridge.internalMoveDefaultDestinationPath
            folderFrames = bridge.folderFrames
            onTargetChanged = bridge.onTargetChanged
            onMove = bridge.onMove
            onImport = bridge.onImport
            onSpringLoad = bridge.onSpringLoad
            onPin = bridge.onPin
        }

        func attach(from hostView: UIView) {
            DispatchQueue.main.async { [weak self, weak hostView] in
                guard let self, let hostView else { return }
                guard hostView.window != nil else { return }
                let targetView = hostView.firstSuperview(of: UIScrollView.self)
                    ?? hostView.visibleScrollViewMatchingOwnFrame()
                guard let targetView else { return }
                guard self.attachedView !== targetView || self.dropInteraction == nil else { return }

                self.detach()
                let interaction = UIDropInteraction(delegate: self)
                targetView.addInteraction(interaction)
                self.dropInteraction = interaction
                self.attachedView = targetView
            }
        }

        func detach() {
            springLoadWorkItem?.cancel()
            springLoadWorkItem = nil
            currentProviders = []
            currentDraggedPaths = []
            isLoadingDraggedPaths = false
            clearCachedLocalMovePaths()
            if let dropInteraction {
                attachedView?.removeInteraction(dropInteraction)
            }
            dropInteraction = nil
            attachedView = nil
            updateActiveFolder(nil)
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            let canPinInternalMove = onPin != nil && session.hasItemsConforming(
                toTypeIdentifiers: [medioInternalMovePayloadTypeIdentifier]
            )
            return (defaultDestinationPath != nil || internalMoveDefaultDestinationPath != nil || canPinInternalMove)
                && session.hasItemsConforming(toTypeIdentifiers: medioFolderDropPayloadTypeIdentifiers)
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
            currentProviders = session.items.map(\.itemProvider)
            cacheDraggedPathsIfNeeded(from: currentProviders)
            let target = resolvedTarget(for: session)
            let isInternalMove = session.hasItemsConforming(
                toTypeIdentifiers: [medioInternalMovePayloadTypeIdentifier]
            )
            let canPin = isInternalMove
                && target.hoveredFolderPath == nil
                && target.globalPoint != nil
                && onPin != nil
            guard target.destinationPath != nil || canPin else {
                updateActiveFolder(nil)
                return UIDropProposal(operation: .forbidden)
            }

            return UIDropProposal(operation: isInternalMove ? .move : .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            currentProviders = []
            currentDraggedPaths = []
            isLoadingDraggedPaths = false
            clearCachedLocalMovePaths()
            updateActiveFolder(nil)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            let target = resolvedTarget(for: session)
            let providers = session.items.map(\.itemProvider)
            let isInternalMove = session.hasItemsConforming(
                toTypeIdentifiers: [medioInternalMovePayloadTypeIdentifier]
            )
            currentProviders = []
            currentDraggedPaths = []
            isLoadingDraggedPaths = false
            clearCachedLocalMovePaths()
            updateActiveFolder(nil)

            if isInternalMove,
               target.hoveredFolderPath == nil,
               let globalPoint = target.globalPoint,
               onPin != nil {
                handleInternalPin(providers: providers, globalPoint: globalPoint)
                return
            }

            guard let destinationPath = target.destinationPath else { return }
            handle(providers: providers, destinationPath: destinationPath)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            currentProviders = []
            currentDraggedPaths = []
            isLoadingDraggedPaths = false
            clearCachedLocalMovePaths()
            updateActiveFolder(nil)
        }

        private struct ResolvedDropTarget {
            let destinationPath: String?
            let hoveredFolderPath: String?
            let globalPoint: CGPoint?
        }

        private func resolvedTarget(for session: UIDropSession) -> ResolvedDropTarget {
            let isInternalMove = session.hasItemsConforming(
                toTypeIdentifiers: [medioInternalMovePayloadTypeIdentifier]
            )
            let fallbackPath = nativeDropDefaultDestination(
                isInternalMove: isInternalMove,
                defaultPath: defaultDestinationPath,
                internalMovePath: internalMoveDefaultDestinationPath
            )
            guard let attachedView else {
                updateActiveFolder(fallbackPath)
                return ResolvedDropTarget(
                    destinationPath: fallbackPath,
                    hoveredFolderPath: nil,
                    globalPoint: nil
                )
            }
            let localPoint = session.location(in: attachedView)
            let windowPoint = attachedView.convert(localPoint, to: nil)
            let hoveredFolder = nativeDropDestination(
                at: windowPoint,
                folderFrames: folderFrames,
                defaultPath: nil
            )
            let destinationPath = hoveredFolder ?? fallbackPath
            updateActiveFolder(destinationPath, canSpringLoad: hoveredFolder != nil)
            return ResolvedDropTarget(
                destinationPath: destinationPath,
                hoveredFolderPath: hoveredFolder,
                globalPoint: windowPoint
            )
        }

        private func updateActiveFolder(_ path: String?, canSpringLoad: Bool = false) {
            guard activeFolderPath != path || (springLoadWorkItem != nil) != canSpringLoad else { return }
            activeFolderPath = path
            springLoadWorkItem?.cancel()
            springLoadWorkItem = nil
            onTargetChanged(path)

            guard let path, canSpringLoad else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.activeFolderPath == path else { return }
                self.springLoadWorkItem = nil

                // A SwiftUI navigation push replaces the List and ends its UIKit drop session.
                // Commit a local move before opening the folder so the drag is not discarded.
                if !self.currentDraggedPaths.isEmpty {
                    self.onMove(self.currentDraggedPaths, path)
                }
                self.onSpringLoad(path)
            }
            springLoadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
        }

        private func handle(providers: [NSItemProvider], destinationPath: String) {
            let internalProviders = providers.filter {
                $0.hasItemConformingToTypeIdentifier(medioInternalMovePayloadTypeIdentifier)
            }
            if !internalProviders.isEmpty {
                handleInternalMove(providers: internalProviders, destinationPath: destinationPath)
                return
            }

            // Standard file URL representations are copied from compatible external apps.
            _ = importDroppedFiles(from: providers, toFolder: destinationPath) { [onImport] result in
                DispatchQueue.main.async {
                    onImport(result, destinationPath)
                }
            }
        }

        private func handleInternalMove(providers: [NSItemProvider], destinationPath: String) {
            _ = loadMovePaths(from: providers) { [onMove] paths in
                DispatchQueue.main.async {
                    onMove(paths, destinationPath)
                }
            }
        }

        private func handleInternalPin(providers: [NSItemProvider], globalPoint: CGPoint) {
            guard let onPin else { return }
            _ = loadMovePaths(from: providers) { paths in
                DispatchQueue.main.async {
                    onPin(paths, globalPoint)
                }
            }
        }

        private func cacheDraggedPathsIfNeeded(from providers: [NSItemProvider]) {
            guard currentDraggedPaths.isEmpty, !isLoadingDraggedPaths else { return }
            let cachedPaths = cachedLocalMovePaths(from: providers)
            if !cachedPaths.isEmpty {
                currentDraggedPaths = cachedPaths
                return
            }
            let internalProviders = providers.filter {
                $0.hasItemConformingToTypeIdentifier(medioInternalMovePayloadTypeIdentifier)
            }
            guard !internalProviders.isEmpty else { return }

            isLoadingDraggedPaths = true
            _ = loadMovePaths(from: internalProviders) { [weak self] paths in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.currentDraggedPaths = paths
                    self.isLoadingDraggedPaths = false
                }
            }
        }
    }
}

/// Adds a root move target to the Home tab without competing with folder-row drop targets.
struct NativeHomeTabDropInteractionBridge: UIViewRepresentable {
    let onMoveToHome: ([String]) -> Void
    let onHomeTabReselected: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMoveToHome: onMoveToHome,
            onHomeTabReselected: onHomeTabReselected
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = NativeTabAttachmentView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.onMoveToWindow = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        context.coordinator.attach(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onMoveToHome = onMoveToHome
        context.coordinator.onHomeTabReselected = onHomeTabReselected
        context.coordinator.attach(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var onMoveToHome: ([String]) -> Void
        var onHomeTabReselected: () -> Void

        private weak var tabItemView: UIControl?
        private var dropInteraction: UIDropInteraction?
        private weak var highlightView: UIView?

        init(
            onMoveToHome: @escaping ([String]) -> Void,
            onHomeTabReselected: @escaping () -> Void
        ) {
            self.onMoveToHome = onMoveToHome
            self.onHomeTabReselected = onHomeTabReselected
        }

        func attach(from hostView: UIView) {
            DispatchQueue.main.async { [weak self, weak hostView] in
                guard let self, let hostView, let window = hostView.window else { return }
                guard let homeTabView = window.homeTabDropTargetView() else { return }
                guard let homeTabControl = homeTabView as? UIControl else { return }
                guard self.tabItemView !== homeTabControl || self.dropInteraction == nil else { return }

                self.detach()
                let interaction = UIDropInteraction(delegate: self)
                homeTabControl.addInteraction(interaction)
                homeTabControl.addTarget(self, action: #selector(handleHomeTabReselected), for: .touchUpInside)
                self.dropInteraction = interaction
                self.tabItemView = homeTabControl
            }
        }

        func detach() {
            setHighlighted(false)
            if let dropInteraction {
                tabItemView?.removeInteraction(dropInteraction)
            }
            tabItemView?.removeTarget(self, action: #selector(handleHomeTabReselected), for: .touchUpInside)
            dropInteraction = nil
            tabItemView = nil
        }

        @objc private func handleHomeTabReselected() {
            onHomeTabReselected()
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: [medioInternalMovePayloadTypeIdentifier])
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
            setHighlighted(true)
            return UIDropProposal(operation: .move)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            setHighlighted(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            setHighlighted(false)
            let providers = session.items.map(\.itemProvider)
            _ = loadMovePaths(from: providers) { [weak self] paths in
                DispatchQueue.main.async {
                    self?.onMoveToHome(paths)
                }
            }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            setHighlighted(false)
        }

        private func setHighlighted(_ highlighted: Bool) {
            if highlighted {
                guard highlightView == nil, let tabItemView else { return }
                let highlight = UIView(frame: tabItemView.bounds.insetBy(dx: 3, dy: 3))
                highlight.isUserInteractionEnabled = false
                highlight.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                highlight.backgroundColor = tabItemView.tintColor.withAlphaComponent(0.16)
                highlight.layer.cornerRadius = max(14, highlight.bounds.height / 2)
                highlight.layer.borderWidth = 2
                highlight.layer.borderColor = tabItemView.tintColor.withAlphaComponent(0.72).cgColor
                tabItemView.insertSubview(highlight, at: 0)
                highlightView = highlight
            } else {
                highlightView?.removeFromSuperview()
                highlightView = nil
            }
        }
    }
}

private final class NativeTabAttachmentView: UIView {
    var onMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?()
    }
}

private extension UIView {

    func homeTabDropTargetView() -> UIView? {
        let tabBars = descendants(of: UITabBar.self)
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.window != nil }
        guard let tabBar = tabBars.first else { return nil }

        let controls = tabBar.descendants(of: UIControl.self)
            .filter { control in
                guard !control.isHidden, control.alpha > 0.01, control.isUserInteractionEnabled else {
                    return false
                }
                let frame = control.convert(control.bounds, to: tabBar)
                return frame.width > 36 && frame.height > 30 && tabBar.bounds.intersects(frame)
            }

        if let labeledHome = controls
            .filter({ $0.accessibilityLabel?.localizedCaseInsensitiveCompare("Home") == .orderedSame })
            .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            return labeledHome
        }

        return controls.min {
            $0.convert($0.bounds, to: tabBar).midX < $1.convert($1.bounds, to: tabBar).midX
        }
    }

    func firstSuperview<T: UIView>(of type: T.Type) -> T? {
        var candidate: UIView? = self
        while let view = candidate {
            if let match = view as? T {
                return match
            }
            candidate = view.superview
        }
        return nil
    }

    func visibleScrollViewMatchingOwnFrame() -> UIScrollView? {
        guard let window else { return nil }
        let ownFrame = convert(bounds, to: window)
        guard !ownFrame.isEmpty else { return nil }
        let center = CGPoint(x: ownFrame.midX, y: ownFrame.midY)

        return window.descendants(of: UIScrollView.self)
            .filter { scrollView in
                guard scrollView.window === window,
                      !scrollView.isHidden,
                      scrollView.alpha > 0.01,
                      scrollView.isUserInteractionEnabled else { return false }
                return scrollView.convert(scrollView.bounds, to: window).contains(center)
            }
            .max { lhs, rhs in
                let lhsFrame = lhs.convert(lhs.bounds, to: window)
                let rhsFrame = rhs.convert(rhs.bounds, to: window)
                let lhsIsList = lhs is UICollectionView || lhs is UITableView
                let rhsIsList = rhs is UICollectionView || rhs is UITableView
                if lhsIsList != rhsIsList {
                    return !lhsIsList
                }
                return lhsFrame.width * lhsFrame.height < rhsFrame.width * rhsFrame.height
            }
    }

    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { view in
            let current = (view as? T).map { [$0] } ?? []
            return current + view.descendants(of: type)
        }
    }
}

private struct HomePrioritySlotCard: View {
    let slot: HomePrioritySlot
    let librarySongs: [FileInfo]
    let libraryItems: [FileInfo]
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactChrome
    let isSelecting: Bool
    let isSelected: Bool
    let isMovable: Bool

    var body: some View {
        Group {
            if let imageOnlyArtwork {
                GeometryReader { proxy in
                    Image(uiImage: imageOnlyArtwork)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                .frame(height: textCardHeight)
                .clipShape(RoundedRectangle(cornerRadius: usesCompactChrome ? 14 : 16))
            } else {
                HStack(alignment: .top, spacing: usesCompactChrome ? 8 : 10) {
                    artwork

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(usesCompactChrome ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(subtitle)
                            .font(usesCompactChrome ? .caption2 : .caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                    .layoutPriority(1)
                }
                .padding(usesCompactChrome ? 8 : 12)
                .frame(
                    maxWidth: .infinity,
                    minHeight: textCardHeight,
                    maxHeight: textCardHeight,
                    alignment: .topLeading
                )
                .overlay(alignment: .topTrailing) {
                    if isSelecting && isMovable {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .background(.thinMaterial, in: Circle())
                            .padding(usesCompactChrome ? 6 : 8)
                    }
                }
                .opacity(isSelecting && !isMovable ? 0.62 : 1)
            }
        }
    }

    private var textCardHeight: CGFloat {
        usesCompactChrome
            ? HomePriorityLayoutMetrics.compactTextCardHeight
            : HomePriorityLayoutMetrics.textCardHeight
    }


    private var iconSize: CGFloat {
        usesCompactChrome
            ? HomePriorityLayoutMetrics.compactIconSize
            : HomePriorityLayoutMetrics.iconSize
    }

    private var imageOnlyArtwork: UIImage? {
        let storageSlot: Int
        switch slot.content {
        case .favorites:
            return nil
        case .folder(_, let slot), .empty(let slot):
            storageSlot = slot
        }
        guard settingsStore.isPrioritySlotImageOnly(storageSlot) else { return nil }
        return VisualArtworkOverrideStore.image(at: settingsStore.prioritySlotArtworkPath(at: storageSlot))
    }

    @ViewBuilder
    private var artwork: some View {
        switch slot.content {
        case .favorites:
            FavoritePriorityArtworkView(size: iconSize)
        case .folder(let item, _):
            FolderArtworkView(path: item.id, librarySongs: librarySongs, size: iconSize, cornerRadius: 6)
        case .empty(let storageSlot):
            if let image = VisualArtworkOverrideStore.image(at: settingsStore.prioritySlotArtworkPath(at: storageSlot)) {
                Image(uiImage: image)
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: usesCompactChrome ? 16 : 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize, height: iconSize)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var title: String {
        switch slot.content {
        case .favorites:
            return MedioShadowFolder.favoritesName
        case .folder(let item, _):
            return item.displayName
        case .empty:
            return String(localized: "Choose Folder")
        }
    }

    private var subtitle: String {
        switch slot.content {
        case .favorites:
            return String(localized: "Favorite songs")
        case .folder(let item, _):
            let count = fileCount(in: item.id)
            return String(localized: "\(count) files inside")
        case .empty(let storageSlot):
            return String(localized: "Priority \(storageSlot + 2)")
        }
    }

    private func fileCount(in folderPath: String) -> Int {
        let normalizedFolderPath = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        let prefix = normalizedFolderPath.hasSuffix("/") ? normalizedFolderPath : normalizedFolderPath + "/"
        let indexedCount = libraryItems.filter { item in
            guard !item.isDirectory else { return false }
            return URL(fileURLWithPath: item.id).standardizedFileURL.path.hasPrefix(prefix)
        }.count
        if indexedCount > 0 { return indexedCount }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: normalizedFolderPath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }.count
    }
}

struct LibraryScreen: View {
    @ObservedObject var vm: LibraryViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer
    @State private var artistImageInternetEnabled = false
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isImporting = false
    @State private var importStatusMessage = ""
    @State private var showImportStatus = false
    @State private var isRootTitleCollapsed = false

    var body: some View {
        List {
            if isSelecting {
                Section("Songs") {
                    ForEach(vm.filteredSongs) { song in
                        Button {
                            toggleSelection(for: song)
                        } label: {
                            SelectableMediaItemRow(
                                item: song,
                                isSelected: selectedItemIDs.contains(song.id),
                                isMovable: true
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(song.displayName)
                        .contextMenu {
                            Button(song.medioAboutActionTitle, systemImage: "info.circle") {
                                router.present(.fileAbout(path: song.id))
                            }
                        }
                    }
                }
            } else {
                if !vm.filteredArtists.isEmpty {
                    Section("Artists") {
                        ForEach(vm.filteredArtists) { artist in
                            Button {
                                router.push(.artist(name: artist.name))
                            } label: {
                                ArtistRow(artist: artist, canFetchProfileImage: artistImageInternetEnabled)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(artist.name)
                            .contextMenu {
                                Button("About Artist", systemImage: "person") {
                                    router.present(.artistAbout(name: artist.name))
                                }
                            }
                        }
                    }
                }

                if !vm.filteredAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(vm.filteredAlbums) { album in
                            Button {
                                router.push(.album(name: album.name))
                            } label: {
                                AlbumRow(album: album)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(album.name)
                            .contextMenu {
                                Button("About \(album.name)", systemImage: "rectangle.stack") {
                                    router.present(.albumAbout(name: album.name))
                                }
                            }
                        }
                    }
                }

                if !vm.filteredSongs.isEmpty {
                    Section("Songs") {
                        ForEach(vm.filteredSongs) { song in
                            Button {
                                Task {
                                    await vm.playSong(song)
                                }
                            } label: {
                                MediaItemRow(item: song, librarySongs: container.libraryStore.librarySongs)
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

            if vm.filteredArtists.isEmpty && vm.filteredAlbums.isEmpty && vm.filteredSongs.isEmpty {
                CompatibleContentUnavailableView(
                    vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Library Empty") : String(localized: "No Results"),
                    systemImage: "books.vertical"
                )
            }
        }
        .compactAwareInsetGroupedListStyle()
        .rootChromeCollapseObserver { updateRootTitleCollapsed($0) }
        .searchable(text: $vm.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .compatibleRootPageTitle("Library", isCollapsed: isRootTitleCollapsed)
        .toolbar { libraryToolbar }
        .alert("Import Files", isPresented: $showImportStatus) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importStatusMessage)
        }
        .onAppear {
            artistImageInternetEnabled = container.settingsStore.appCanConnectToInternet
            ArtistProfileDebugLog.write("library screen appeared artistImageInternetEnabled=\(artistImageInternetEnabled)")
        }
        .onReceive(container.settingsStore.$appCanConnectToInternet) { isEnabled in
            artistImageInternetEnabled = isEnabled
            ArtistProfileDebugLog.write("library screen internet flag changed artistImageInternetEnabled=\(isEnabled)")
        }
    }

    private func updateRootTitleCollapsed(_ isCollapsed: Bool) {
        guard isRootTitleCollapsed != isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            isRootTitleCollapsed = isCollapsed
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelecting {
                Button("Move") {
                    router.presentMoveItems(selectedItemIDs.sorted())
                }
                .disabled(selectedItemIDs.isEmpty)

                Button("Done") {
                    isSelecting = false
                    selectedItemIDs.removeAll()
                }
            } else {
                libraryOptionsMenu
            }
        }
    }

    private var libraryOptionsMenu: some View {
        NativeBrowserOptionsMenu(accessibilityLabel: String(localized: "Library Options")) {
            UIMenu(children: [
                BrowserOptionsMenu.section([
                    BrowserOptionsMenu.action("Select", "checkmark.circle", enabled: !vm.filteredSongs.isEmpty) { isSelecting = true },
                    BrowserOptionsMenu.action(String(localized: "New Folder"), "folder.badge.plus") { router.present(.createFolder(parentPath: nil)) },
                    BrowserOptionsMenu.action("Import Files", "square.and.arrow.down", enabled: !isImporting) { Task { await importFilesFromPicker() } },
                    BrowserOptionsMenu.action("Settings", "gearshape") { router.present(.settings) }
                ]),
                BrowserOptionsMenu.sorts(HomeSortBy.menuCases, selected: container.settingsStore.homeSortBy,
                    ascending: container.settingsStore.homeSortAscending, title: { $0.title }, select: applySort)
            ])
        }
    }


    private func toggleSelection(for song: FileInfo) {
        if selectedItemIDs.contains(song.id) {
            selectedItemIDs.remove(song.id)
        } else {
            selectedItemIDs.insert(song.id)
        }
    }

    private func applySort(_ sort: HomeSortBy) {
        container.settingsStore.selectSort(sort)
    }



    private func importFilesFromPicker() async {
        isImporting = true
        defer { isImporting = false }
        do {
            let urls = try await container.documentPickingService.pickFile(
                contentTypes: [.item],
                allowsMultipleSelection: true
            )
            let importedURLs = try await ImportDocumentsUseCase().execute(urls: urls)
            guard !importedURLs.isEmpty else {
                importStatusMessage = String(localized: "No files were imported.")
                showImportStatus = true
                return
            }
            await container.libraryStore.refresh(
                scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository)
            )
        } catch SystemUIError.cancelled {
            return
        } catch {
            importStatusMessage = error.localizedDescription
            showImportStatus = true
        }
    }
}

struct SearchScreen: View {
    @ObservedObject var vm: SearchSongsViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer
    @State private var enabledCategories = Set(SearchResultCategory.allCases)
    @State private var isRootTitleCollapsed = false

    var body: some View {
        List {
            if !hasResults {
                CompatibleContentUnavailableView(
                    emptySearchTitle,
                    systemImage: "magnifyingglass"
                )
            } else {
                if enabledCategories.contains(.artists), !vm.filteredArtists.isEmpty {
                    Section("Artists") {
                        ForEach(vm.filteredArtists) { artist in
                            Button {
                                router.push(.artist(name: artist.name))
                            } label: {
                                ArtistRow(
                                    artist: artist,
                                    canFetchProfileImage: container.settingsStore.appCanConnectToInternet
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(artist.name)
                            .contextMenu {
                                Button("About Artist", systemImage: "person") {
                                    router.present(.artistAbout(name: artist.name))
                                }
                            }
                        }
                    }
                }

                if enabledCategories.contains(.albums), !vm.filteredAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(vm.filteredAlbums) { album in
                            Button {
                                router.push(.album(name: album.name))
                            } label: {
                                AlbumRow(album: album)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(album.name)
                            .contextMenu {
                                Button("About \(album.name)", systemImage: "rectangle.stack") {
                                    router.present(.albumAbout(name: album.name))
                                }
                            }
                        }
                    }
                }

                if enabledCategories.contains(.songs), !vm.filteredSongs.isEmpty {
                    Section("Songs") {
                        ForEach(vm.filteredSongs) { song in
                            Button {
                                Task {
                                    await vm.playSong(song)
                                }
                            } label: {
                                SearchSongResultRow(
                                    song: song,
                                    librarySongs: container.libraryStore.librarySongs,
                                    lyricMatch: vm.lyricMatches[song.id],
                                    query: vm.query
                                )
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
        }
        .compactAwareInsetGroupedListStyle()
        .rootChromeCollapseObserver { updateRootTitleCollapsed($0) }
        .compatibleRootPageTitle("Search", isCollapsed: isRootTitleCollapsed)
        .searchable(text: $vm.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .toolbar {
            CircularTrailingToolbarItem {
                searchOptionsMenu
            }
        }
    }

    private func updateRootTitleCollapsed(_ isCollapsed: Bool) {
        guard isRootTitleCollapsed != isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            isRootTitleCollapsed = isCollapsed
        }
    }

    private var hasResults: Bool {
        (enabledCategories.contains(.artists) && !vm.filteredArtists.isEmpty)
            || (enabledCategories.contains(.albums) && !vm.filteredAlbums.isEmpty)
            || (enabledCategories.contains(.songs) && !vm.filteredSongs.isEmpty)
    }

    private var emptySearchTitle: String {
        if enabledCategories.isEmpty { return String(localized: "No Categories Selected") }
        return vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Search Library") : String(localized: "No Results")
    }

    private var searchOptionsMenu: some View {
        ToolbarGlassMenu(accessibilityLabel: String(localized: "Search Options")) {
            Section("Search Categories") {
                ForEach(SearchResultCategory.allCases) { category in
                    Toggle(category.title, isOn: categoryBinding(category))
                }
            }
            if enabledCategories.count < SearchResultCategory.allCases.count {
                Button("Show All Categories", systemImage: "checkmark.circle") {
                    enabledCategories = Set(SearchResultCategory.allCases)
                }
            }
            Section {
                Button("Settings", systemImage: "gearshape") {
                    router.present(.settings)
                }
            }
        }
    }

    private func categoryBinding(_ category: SearchResultCategory) -> Binding<Bool> {
        Binding(
            get: { enabledCategories.contains(category) },
            set: { isEnabled in
                if isEnabled {
                    enabledCategories.insert(category)
                } else {
                    enabledCategories.remove(category)
                }
            }
        )
    }
}

private enum SearchResultCategory: String, CaseIterable, Identifiable {
    case artists
    case albums
    case songs

    var id: Self { self }

    var title: String {
        switch self {
        case .artists: String(localized: "Artists")
        case .albums: String(localized: "Albums")
        case .songs: String(localized: "Songs")
        }
    }
}

private struct SearchSongResultRow: View {
    let song: FileInfo
    let librarySongs: [FileInfo]
    let lyricMatch: LyricSearchMatch?
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaItemRow(item: song, librarySongs: librarySongs)
            if let lyricMatch, !lyricMatch.line.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("Lyrics")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                    Text(highlightedLyricSnippet(lyricMatch.line, query: query))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.leading, 56)
                .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func highlightedLyricSnippet(_ line: String, query: String) -> AttributedString {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = AttributedString()
        guard !trimmedQuery.isEmpty else { return AttributedString(line) }

        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let range = line.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<line.endIndex
              ) {
            if searchStart < range.lowerBound {
                result += AttributedString(String(line[searchStart..<range.lowerBound]))
            }

            var highlighted = AttributedString(String(line[range]))
            highlighted.foregroundColor = .primary
            highlighted.backgroundColor = Color.yellow.opacity(0.35)
            result += highlighted
            searchStart = range.upperBound
        }

        if searchStart < line.endIndex {
            result += AttributedString(String(line[searchStart..<line.endIndex]))
        }
        return result
    }
}

struct PlaygroundScreen: View {
    @ObservedObject var vm: PlaygroundViewModel
    @EnvironmentObject private var router: AppRouter
    @State private var isRootTitleCollapsed = false

    var body: some View {
        List {
            Section("Library") {
                metricRow("Favorites", value: vm.favoriteCount)
                metricRow("Queue", value: vm.queueCount)
                metricRow("Albums", value: vm.albumCount)
                metricRow("Artists", value: vm.artistCount)
            }
        }
        .compactAwareInsetGroupedListStyle()
        .rootChromeCollapseObserver { updateRootTitleCollapsed($0) }
        .compatibleRootPageTitle("Playground", isCollapsed: isRootTitleCollapsed)
        .toolbar {
            CircularTrailingToolbarItem {
                ToolbarGlassButton(systemImage: "gearshape", accessibilityLabel: String(localized: "Settings")) {
                    router.present(.settings)
                }
            }
        }
    }

    private func metricRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
        }
    }

    private func updateRootTitleCollapsed(_ isCollapsed: Bool) {
        guard isRootTitleCollapsed != isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            isRootTitleCollapsed = isCollapsed
        }
    }
}

struct MiniPlayerBar: View {
    @ObservedObject var playbackStore: PlaybackStore
    let playbackService: PlaybackService
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactRootChrome
    @EnvironmentObject private var router: AppRouter
    @State private var shakeOffset: CGFloat = 0

    private var progress: CGFloat {
        guard let duration = playbackStore.playback.durationMs, duration > 0 else { return 0 }
        return min(max(CGFloat(playbackStore.playback.positionMs) / CGFloat(duration), 0), 1)
    }

    var body: some View {
        Group {
            if usesCompactRootChrome {
                compactPlayer
            } else {
                regularPlayer
            }
        }
        .offset(x: shakeOffset)
        .highPriorityGesture(miniPlayerSwipeGesture)
    }

    private var compactPlayer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .accessibilityHidden(true)

            ZStack(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    compactNowPlayingSummary

                    Button {
                        Task {
                            if playbackStore.playback.isPlaying {
                                await playbackService.pause()
                            } else {
                                await playbackService.play()
                            }
                        }
                    } label: {
                        Image(systemName: playbackStore.playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(playbackStore.nowPlaying == nil)
                    .accessibilityLabel(playbackStore.playback.isPlaying ? "Pause" : "Play")

                    Button {
                        skipNextFromButton()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(playbackStore.canSkipToNextQueueItem ? Color.primary : Color.secondary.opacity(0.55))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(playbackStore.nowPlaying == nil)
                    .accessibilityLabel("Skip Forward")
                    .padding(.trailing, 16)
                }
                .frame(height: 62)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 1)
                .accessibilityLabel("Playback Progress")
                .allowsHitTesting(false)
            }
        }
        .background(.regularMaterial)
        .contentShape(Rectangle())
    }

    private var compactNowPlayingSummary: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(playbackStore.nowPlaying?.title ?? String(localized: "Not Playing"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Text(playbackStore.nowPlaying?.artist ?? String(localized: "Queue ready"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 6)
        }
        .padding(.leading, 20)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            router.push(.nowPlaying)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now Playing")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            router.push(.nowPlaying)
        }
    }

    private var regularPlayer: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    artwork

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackStore.nowPlaying?.title ?? String(localized: "Not Playing"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                        Text(playbackStore.nowPlaying?.artist ?? String(localized: "Queue ready"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 6)
                }
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    router.push(.nowPlaying)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Now Playing")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    router.push(.nowPlaying)
                }

                Button {
                    Task {
                        if playbackStore.playback.isPlaying {
                            await playbackService.pause()
                        } else {
                            await playbackService.play()
                        }
                    }
                } label: {
                    Image(systemName: playbackStore.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(playbackStore.nowPlaying == nil)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 2)
            .accessibilityLabel("Playback Progress")
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
        }
        .frame(height: 54)
        .clipShape(shape)
        .liquidGlassCard(cornerRadius: 18)
        .contentShape(shape)
    }

    private var miniPlayerSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 26)
            .onEnded { value in
                let translation = value.translation
                guard abs(translation.width) > max(54, abs(translation.height) * 1.35) else { return }
                if translation.width < 0 {
                    skipNextFromSwipe()
                } else {
                    skipPreviousFromSwipe()
                }
            }
    }

    private func skipNextFromSwipe() {
        guard playbackStore.nowPlaying != nil else { return }
        guard playbackStore.canSkipToNextQueueItem else {
            signalQueueBoundary(direction: -1)
            return
        }
        Task { await playbackService.skipNext() }
    }

    private func skipNextFromButton() {
        guard playbackStore.nowPlaying != nil else { return }
        guard playbackStore.canSkipToNextQueueItem else {
            signalQueueBoundary(direction: -1)
            return
        }
        Task { await playbackService.skipNext() }
    }

    private func skipPreviousFromSwipe() {
        guard playbackStore.nowPlaying != nil else { return }
        guard playbackStore.canSkipToPreviousQueueItem else {
            signalQueueBoundary(direction: 1)
            return
        }
        Task { await playbackService.skipPrevious() }
    }

    private func signalQueueBoundary(direction: CGFloat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.055)) {
            shakeOffset = 9 * direction
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
            withAnimation(.easeInOut(duration: 0.055)) {
                shakeOffset = -7 * direction
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) {
                shakeOffset = 0
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = playbackStore.nowPlaying?.id {
            SongArtworkView(path: path)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }
}
