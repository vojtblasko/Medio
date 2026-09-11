import SwiftUI
import UIKit

@MainActor
private final class RouteViewModelCache: ObservableObject {
    private let container: AppContainer
    private var albumViewModels: [String: AlbumViewModel] = [:]
    private var artistViewModels: [String: ArtistViewModel] = [:]
    private var folderViewModels: [String: FolderViewModel] = [:]
    private var queueViewModel: QueueViewModel?
    private var settingsViewModel: SettingsViewModel?
    private var favoritesViewModel: FavoritesViewModel?

    init(container: AppContainer) {
        self.container = container
    }

    func album(named name: String, artistName: String? = nil) -> AlbumViewModel {
        let key = albumCacheKey(name: name, artistName: artistName)
        if let vm = albumViewModels[key] {
            return vm
        }
        let vm = AlbumViewModel(
            name: name,
            artistName: artistName,
            libraryStore: container.libraryStore,
            playbackService: container.playbackService
        )
        albumViewModels[key] = vm
        return vm
    }

    private func albumCacheKey(name: String, artistName: String?) -> String {
        if let artistName {
            return "artist:\(artistName)|album:\(name)"
        }
        return "album:\(name)"
    }

    func artist(named name: String) -> ArtistViewModel {
        if let vm = artistViewModels[name] {
            return vm
        }
        let vm = ArtistViewModel(
            name: name,
            libraryStore: container.libraryStore,
            playbackService: container.playbackService,
            settingsStore: container.settingsStore,
            listeningHistoryRepository: container.listeningHistoryRepository
        )
        artistViewModels[name] = vm
        return vm
    }

    func folder(at path: String) -> FolderViewModel {
        if let vm = folderViewModels[path] {
            return vm
        }
        let vm = FolderViewModel(
            path: path,
            libraryStore: container.libraryStore,
            playbackService: container.playbackService,
            favoritesRepository: container.favoritesRepository,
            settingsStore: container.settingsStore
        )
        folderViewModels[path] = vm
        return vm
    }

    func queue() -> QueueViewModel {
        if let queueViewModel {
            return queueViewModel
        }
        let vm = QueueViewModel(
            playbackStore: container.playbackStore,
            playbackService: container.playbackService,
            lyricsRepository: container.lyricsRepository
        )
        queueViewModel = vm
        return vm
    }

    func settings() -> SettingsViewModel {
        if let settingsViewModel {
            return settingsViewModel
        }
        let vm = SettingsViewModel(
            settingsStore: container.settingsStore,
            preferencesRepository: container.preferencesRepository
        )
        settingsViewModel = vm
        return vm
    }

    func favorites() -> FavoritesViewModel {
        if let favoritesViewModel {
            return favoritesViewModel
        }
        let vm = FavoritesViewModel(
            libraryStore: container.libraryStore,
            playbackService: container.playbackService,
            settingsStore: container.settingsStore
        )
        favoritesViewModel = vm
        return vm
    }
}

private enum AppLaunchOptions {
    static var initialTab: AppTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let tabName = argument(after: "-medioInitialTab", in: arguments) else {
            return .home
        }

        switch tabName.lowercased() {
        case "library":
            return .library
        case "playground":
            return .playground
        case "search":
            return .search
        default:
            return .home
        }
    }

    static var initialRoute: SheetRoute? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let route = argument(after: "-medioInitialRoute", in: arguments) else { return nil }
        let normalizedRoute = route.lowercased()

        switch normalizedRoute {
        case "nowplaying", "now-playing":
            return .nowPlaying
        case "queue":
            return .queue
        case "settings":
            return .settings
        case "favorites":
            return .favorites
        case "folder":
            guard let path = argument(after: "-medioInitialPath", in: arguments) else { return nil }
            return .folder(path: path)
        case "folderbrowser", "folder-browser":
            guard let path = argument(after: "-medioInitialPath", in: arguments) else { return nil }
            return .folderBrowser(path: path)
        default:
            if normalizedRoute.hasPrefix("folder:") {
                return .folder(path: String(route.dropFirst("folder:".count)))
            }
            if normalizedRoute.hasPrefix("folderbrowser:") {
                return .folderBrowser(path: String(route.dropFirst("folderbrowser:".count)))
            }
            if normalizedRoute.hasPrefix("fileabout:") {
                return .fileAbout(path: String(route.dropFirst("fileabout:".count)))
            }
            return nil
        }
    }

    static var shouldStartFirstPlayable: Bool {
        ProcessInfo.processInfo.arguments.contains("-medioStartFirstPlayable")
    }

    private static func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

// MARK: - RootView
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router: AppRouter
    @StateObject private var container: AppContainer
    @StateObject private var batterySaver = BatterySaverService()
    @ObservedObject private var diagnostics = DiagnosticsCenter.shared

    // Tab-scoped view models
    @StateObject private var homeVM: HomeViewModel
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var searchVM: SearchSongsViewModel
    @StateObject private var playgroundVM: PlaygroundViewModel
    @StateObject private var playbackEventsVM: PlaybackEventsViewModel
    @StateObject private var nowPlayingSyncVM: NowPlayingSyncViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @StateObject private var routeViewModelCache: RouteViewModelCache
    @State private var appliedLaunchRoute = false

    init() {
        AppRuntime.prepareUITestStateIfNeeded()
        let container = AppContainer()
        _router = StateObject(wrappedValue: AppRouter(initialTab: AppLaunchOptions.initialTab))
        _container = StateObject(wrappedValue: container)
        _homeVM = StateObject(wrappedValue: HomeViewModel(libraryStore: container.libraryStore, playbackService: container.playbackService, settingsStore: container.settingsStore))
        _libraryVM = StateObject(wrappedValue: LibraryViewModel(
            libraryStore: container.libraryStore,
            playbackService: container.playbackService,
            settingsStore: container.settingsStore
        ))
        _searchVM = StateObject(wrappedValue: SearchSongsViewModel(
            libraryStore: container.libraryStore,
            playbackService: container.playbackService,
            lyricsRepository: container.lyricsRepository,
            settingsStore: container.settingsStore
        ))
        _playgroundVM = StateObject(wrappedValue: PlaygroundViewModel(libraryStore: container.libraryStore, playbackStore: container.playbackStore))
        _playbackEventsVM = StateObject(wrappedValue: PlaybackEventsViewModel(
            playbackStore: container.playbackStore,
            libraryStore: container.libraryStore,
            notificationsService: container.notificationsService,
            listeningHistoryRepository: container.listeningHistoryRepository,
            settingsStore: container.settingsStore
        ))
        _nowPlayingSyncVM = StateObject(wrappedValue: NowPlayingSyncViewModel(playbackStore: container.playbackStore, nowPlayingService: container.nowPlayingService))
        _nowPlayingVM = StateObject(wrappedValue: NowPlayingViewModel(playbackStore: container.playbackStore, playbackService: container.playbackService, lyricsRepository: container.lyricsRepository))
        _routeViewModelCache = StateObject(wrappedValue: RouteViewModelCache(container: container))
    }

    var body: some View {
        GeometryReader { proxy in
            rootContent
                .environment(\.medioUsesCompactRootChrome, usesCompactRootChrome(for: proxy.size))
        }
    }

    private var rootContent: some View {
        TabView(selection: $router.selectedTab) {
            tabNavigation(for: .home) {
                tabContentWithMiniPlayer {
                    HomeScreen(vm: homeVM)
                }
            }
                .tag(AppTab.home)
                .tabItem { Label("Home", systemImage: "house") }
            tabNavigation(for: .library) {
                tabContentWithMiniPlayer {
                    LibraryScreen(vm: libraryVM)
                }
            }
                .tag(AppTab.library)
                .tabItem { Label("Library", systemImage: "books.vertical") }
            tabNavigation(for: .playground) {
                tabContentWithMiniPlayer {
                    PlaygroundScreen(vm: playgroundVM)
                }
            }
                .tag(AppTab.playground)
                .tabItem { Label("Playground", systemImage: "slider.horizontal.3") }
            tabNavigation(for: .search) {
                tabContentWithMiniPlayer {
                    SearchScreen(vm: searchVM)
                }
            }
                .tag(AppTab.search)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .compatibleGlobalTapLogger(enabled: diagnostics.interactionEnabled) { point in
            let location = "x=\(Int(point.x)), y=\(Int(point.y))"
            let context = router.currentSheetRoute?.id ?? "tab:\(String(describing: router.selectedTab))"
            DiagnosticsCenter.recordInteraction("Tap | \(context) | \(location)")
        }
        .background {
            NativeHomeTabDropInteractionBridge { paths in
                Task { @MainActor in
                    await moveToHome(paths)
                }
            } onHomeTabReselected: {
                if router.selectedTab == .home {
                    router.reselectHomeTab()
                }
            }
        }
        .environmentObject(router)
        .environmentObject(container)
        .environmentObject(container.playbackStore)
        .environmentObject(batterySaver)
        .fullScreenCover(item: $router.fullScreenCover) { route in
            fullScreenCoverContent(for: route)
                .background(SystemSheetHost(presenter: container.systemUIPresenter))
                .environmentObject(router)
                .environmentObject(container)
                .environmentObject(container.playbackStore)
                .environmentObject(batterySaver)
        }
        .background(SystemSheetHost(
            presenter: container.systemUIPresenter,
            isActive: router.sheet == nil && router.fullScreenCover == nil
        ))
        .sheet(item: $router.sheet, onDismiss: {
            router.resetSheetStack()
        }) { route in
            CompatibleNavigationPathStack(path: $router.sheetPath) {
                sheetNavigationContent(for: route, isRoot: true)
                    .navigationBarTitleDisplayMode(.large)
            } destination: { destination in
                sheetNavigationContent(for: destination, isRoot: false)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .background(SystemSheetHost(
                presenter: container.systemUIPresenter,
                isActive: router.fullScreenCover == nil
            ))
            .environmentObject(router)
            .environmentObject(container)
            .environmentObject(container.playbackStore)
            .environmentObject(batterySaver)
            .interactiveDismissDisabled(router.canGoBackInSheet)
        }
        .task {
            await container.startupCoordinator.prepareFileSystem()
            await container.libraryStore.loadFavoritesOnLaunch(favoritesRepository: container.favoritesRepository)
            let launchScanUseCase = ScanLibraryUseCase(dataSource: container.mediaLibraryRepository)
            await container.libraryStore.loadOnLaunch(
                dataSource: container.mediaLibraryRepository,
                scanUseCase: launchScanUseCase
            )
            if container.libraryStore.loadedCachedSnapshotOnLaunch {
                Task(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    await container.libraryStore.refresh(scanUseCase: launchScanUseCase)
                }
            }
            container.remoteCommandsService.connect(playbackService: container.playbackService, playbackStore: container.playbackStore)
            nowPlayingSyncVM.syncNow()
            await applyLaunchRouteIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .background else { return }
            Task {
                await container.settingsStore.flushPersistence()
                await playbackEventsVM.flushListeningHistory()
            }
        }
    }

    private func usesCompactRootChrome(for size: CGSize) -> Bool {
        min(size.width, size.height) <= 340 || max(size.width, size.height) <= 568
    }

    @MainActor
    private func applyLaunchRouteIfNeeded() async {
        guard !appliedLaunchRoute else { return }
        appliedLaunchRoute = true

        if AppLaunchOptions.shouldStartFirstPlayable,
           let firstPlayable = firstLaunchPlayableItem() {
            let queueItems = launchPlayableItems()
            await PlayMediaUseCase().execute(
                selected: firstPlayable,
                context: .explicit(files: queueItems),
                libraryStore: container.libraryStore,
                playbackService: container.playbackService
            )
            nowPlayingSyncVM.syncNow()
        }

        guard let route = AppLaunchOptions.initialRoute else { return }
        switch route {
        case .settings:
            router.present(route)
        default:
            router.push(route)
        }
    }

    private func firstLaunchPlayableItem() -> FileInfo? {
        launchPlayableItems().first
    }

    private func launchPlayableItems() -> [FileInfo] {
        let songs = container.libraryStore.librarySongs
        let candidates = songs.isEmpty ? container.libraryStore.allItems : songs
        return candidates.filter { item in
            !item.isDirectory && FileMetadataReader.isSupportedMediaFile(
                url: URL(fileURLWithPath: item.id),
                typeIdentifier: item.typeIdentifier
            )
        }
    }

    private func moveToHome(_ paths: [String]) async {
        guard let documentsPath = AppFileRoot.documentsPath else { return }
        do {
            let result = try await FileMoveService().moveBatch(paths: paths, toFolder: documentsPath)
            guard !result.completed.isEmpty else {
                if let failure = result.failures.first {
                    AppLog.files.error("Dropped files could not be moved to Home: \(failure.message, privacy: .public)")
                }
                return
            }
            await container.libraryStore.refresh(
                scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository)
            )
            router.selectTab(.home)
            router.setPushPath([], for: .home)
            if let failure = result.failures.first {
                AppLog.files.error("Some dropped files were not moved to Home: \(failure.message, privacy: .public)")
            }
        } catch {
            AppLog.files.error("Dropped files could not be moved to Home: \(error.localizedDescription, privacy: .public)")
        }
    }

    @ViewBuilder
    private func tabNavigation<Content: View>(
        for tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        CompatibleNavigationPathStack(path: router.pushPathBinding(for: tab)) {
            content()
                .navigationBarTitleDisplayMode(.large)
        } destination: { destination in
            inTabNavigationContent(for: destination)
        }
    }

    private func importDroppedFile(_ fileURL: URL) async {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        guard AppFilePathPolicy.isValidLeafName(fileURL.lastPathComponent) else { return }
        let scanUseCase = ScanLibraryUseCase(dataSource: container.mediaLibraryRepository)
        let destinationFolder = router.selectedTab == .library
            ? getBrowsingFolderPath().map { URL(fileURLWithPath: $0, isDirectory: true) } ?? docsURL
            : docsURL
        do {
            let policy = try AppFilePathPolicy.documents(fileManager: fileManager)
            let folder = try policy.validatedDirectory(destinationFolder)
            let destination = try policy.destination(in: folder, named: fileURL.lastPathComponent, isDirectory: false)
            try await AppFileMutationCoordinator.shared.copyReplacingItem(at: fileURL, to: destination)
            await container.libraryStore.refresh(scanUseCase: scanUseCase)
        } catch {
            AppLog.files.error("Dropped file import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func getBrowsingFolderPath() -> String? {
        if case .folderBrowser(let path) = router.currentSheetRoute {
            return path
        }
        return nil
    }

    @ViewBuilder
    private func inTabNavigationContent(for route: SheetRoute) -> some View {
        rightSidePanelContent(for: route)
            .navigationBarTitleDisplayMode(.inline)
            .swipeDownToCloseWindow(isActive: {
                router.pushPath.last == route
            }) {
                router.pop()
            }
    }

    @ViewBuilder
    private func sheetNavigationContent(for route: SheetRoute, isRoot: Bool) -> some View {
        if isRoot {
            if route == .nowPlaying {
                rightSidePanelContent(for: route)
            } else {
                rightSidePanelContent(for: route)
                    .toolbar { sheetCloseToolbar }
            }
        } else {
            rightSidePanelContent(for: route)
                .swipeDownToCloseWindow(isActive: {
                    router.sheetPath.last == route
                }) {
                    router.dismissSheet()
                }
        }
    }

    @ToolbarContentBuilder
    private var sheetCloseToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                router.dismissSheet()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("sheet_close")
        }
    }

    @ViewBuilder
    private func folderPanel(for path: String) -> some View {
        FolderPanel(
            vm: routeViewModelCache.folder(at: path),
            path: path
        )
    }

    @ViewBuilder
    private func fullScreenCoverContent(for route: SheetRoute) -> some View {
        switch route {
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func rightSidePanelContent(for route: SheetRoute) -> some View {
        switch route {
        case .nowPlaying:
            NowPlayingPanel(
                vm: nowPlayingVM,
                settingsStore: container.settingsStore,
                libraryStore: container.libraryStore,
                favoritesRepository: container.favoritesRepository
            )
        case .queue:
            panelWithMiniPlayer {
                QueuePanel(
                    vm: routeViewModelCache.queue()
                )
            }
        case .settings:
            panelWithMiniPlayer {
                SettingsPanel(
                    vm: routeViewModelCache.settings(),
                    container: container
                )
            }
        case .lyricsSettings:
            panelWithMiniPlayer {
                LyricsSettingsPanel(container: container)
            }
        case .crashReportManager:
            panelWithMiniPlayer {
                CrashReportManagerPanel(container: container)
            }
        case .favorites:
            panelWithMiniPlayer {
                FavoritesPanel(
                    vm: routeViewModelCache.favorites()
                )
            }
        case .favoritesAbout:
            panelWithMiniPlayer {
                FavoritesAboutPanel(libraryStore: container.libraryStore)
            }
        case .fileAbout(let path):
            panelWithMiniPlayer {
                FileAboutPanel(
                    path: path,
                    item: container.libraryStore.allItems.first { $0.id == path }
                        ?? container.libraryStore.librarySongs.first { $0.id == path }
                        ?? container.libraryStore.homeItems.first { $0.id == path },
                    container: container,
                    nowPlayingVM: nowPlayingVM
                )
            }
        case .priorityFolderAbout(let path):
            panelWithMiniPlayer {
                FileAboutPanel(
                    path: path,
                    item: container.libraryStore.allItems.first { $0.id == path }
                        ?? container.libraryStore.homeItems.first { $0.id == path },
                    container: container,
                    nowPlayingVM: nowPlayingVM,
                    titleOverride: "About Priority Folder"
                )
            }
        case .prioritySlotAbout(let slot):
            panelWithMiniPlayer {
                PrioritySlotAboutPanel(slot: slot)
            }
        case .folder(let path):
            panelWithMiniPlayer {
                folderPanel(for: path)
            }
        case .priorityFolderPicker(let slot):
            panelWithMiniPlayer {
                PriorityFolderPickerPanel(slot: slot)
            }
        case .moveItem(let path):
            panelWithMiniPlayer {
                MoveItemPanel(paths: [path])
            }
        case .moveItems:
            panelWithMiniPlayer {
                MoveItemPanel(paths: router.moveItemPaths)
            }
        case .createFolder(let parentPath):
            panelWithMiniPlayer {
                CreateFolderScreen(parentPath: parentPath)
            }
        case .album(let name):
            panelWithMiniPlayer {
                AlbumPanel(
                    vm: routeViewModelCache.album(named: name),
                    name: name,
                    artistName: nil
                )
            }
        case .artistAlbum(let artistName, let albumName):
            panelWithMiniPlayer {
                AlbumPanel(
                    vm: routeViewModelCache.album(named: albumName, artistName: artistName),
                    name: albumName,
                    artistName: artistName
                )
            }
        case .albumAbout(let name):
            panelWithMiniPlayer {
                AlbumAboutPanel(
                    vm: routeViewModelCache.album(named: name),
                    name: name
                )
            }
        case .artistAlbumAbout(let artistName, let albumName):
            panelWithMiniPlayer {
                AlbumAboutPanel(
                    vm: routeViewModelCache.album(named: albumName, artistName: artistName),
                    name: albumName
                )
            }
        case .artist(let name):
            panelWithMiniPlayer {
                ArtistPanel(
                    vm: routeViewModelCache.artist(named: name),
                    name: name
                )
            }
        case .artistAbout(let name):
            panelWithMiniPlayer {
                ArtistAboutPanel(
                    vm: routeViewModelCache.artist(named: name),
                    name: name
                )
            }
        case .folderBrowser(path: let path):
            panelWithMiniPlayer {
                FolderBrowserScreen(path: path, router: router, container: container)
            }
        }
    }

    @ViewBuilder
    private func tabContentWithMiniPlayer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        MiniPlayerInsetHost(
            playbackStore: container.playbackStore,
            playbackService: container.playbackService,
            content: content
        )
    }

    @ViewBuilder
    private func panelWithMiniPlayer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        MiniPlayerInsetHost(
            playbackStore: container.playbackStore,
            playbackService: container.playbackService,
            content: content
        )
    }
}

private struct MiniPlayerInsetHost<Content: View>: View {
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactRootChrome
    @ObservedObject var playbackStore: PlaybackStore
    let playbackService: PlaybackService
    let content: Content

    init(
        playbackStore: PlaybackStore,
        playbackService: PlaybackService,
        @ViewBuilder content: () -> Content
    ) {
        self.playbackStore = playbackStore
        self.playbackService = playbackService
        self.content = content()
    }

    var body: some View {
        content
            .compatibleTopScrollContentMargin(0)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                miniPlayerInset
            }
            .animation(.easeInOut(duration: 0.18), value: playbackStore.nowPlaying?.id)
    }

    @ViewBuilder
    private var miniPlayerInset: some View {
        if playbackStore.nowPlaying != nil {
            if usesCompactRootChrome {
                MiniPlayerBar(
                    playbackStore: playbackStore,
                    playbackService: playbackService
                )
                .frame(maxWidth: .infinity)
            } else {
                MiniPlayerBar(
                    playbackStore: playbackStore,
                    playbackService: playbackService
                )
                .padding(.horizontal, MedioLayoutMetrics.pageControlHorizontalInset)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
        }
    }
}

private struct SwipeDownToCloseWindowModifier: ViewModifier {
    let isActive: () -> Bool
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.background(TopAwareSwipeDownCloseBridge(isActive: isActive, onClose: onClose))
    }
}

private struct TopAwareSwipeDownCloseBridge: UIViewRepresentable {
    let isActive: () -> Bool
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onClose: onClose)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        DispatchQueue.main.async {
            _ = context.coordinator.attachIfNeeded()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hostView = uiView
        context.coordinator.isActive = isActive
        context.coordinator.onClose = onClose
        if !context.coordinator.attachIfNeeded() {
            DispatchQueue.main.async {
                _ = context.coordinator.attachIfNeeded()
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var hostView: UIView?
        private weak var attachedWindow: UIWindow?
        private var startedAtScrollableTop = false
        var isActive: () -> Bool
        var onClose: () -> Void

        private lazy var panGesture: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            recognizer.minimumNumberOfTouches = 1
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        init(isActive: @escaping () -> Bool, onClose: @escaping () -> Void) {
            self.isActive = isActive
            self.onClose = onClose
            super.init()
        }

        @discardableResult
        func attachIfNeeded() -> Bool {
            guard let window = hostView?.window else { return false }
            guard attachedWindow !== window else { return true }
            detach()
            attachedWindow = window
            window.addGestureRecognizer(panGesture)
            return true
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(panGesture)
            attachedWindow = nil
            startedAtScrollableTop = false
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === panGesture, let window = attachedWindow else { return true }
            guard isActive() else { return false }
            let velocity = panGesture.velocity(in: window)
            guard velocity.y > 0 else { return false }
            return abs(velocity.x) < max(90, abs(velocity.y) * 0.65)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let window = attachedWindow else { return }
            switch recognizer.state {
            case .began:
                startedAtScrollableTop = isActive() && (scrollViewAtGestureStart(in: window, recognizer: recognizer)?.isScrolledToTopForDismiss ?? true)
            case .ended:
                defer { startedAtScrollableTop = false }
                guard startedAtScrollableTop else { return }
                let translation = recognizer.translation(in: window)
                let velocity = recognizer.velocity(in: window)
                let horizontalDistance = abs(translation.x)
                let isDownward = translation.y > 130 || velocity.y > 1450
                let isMostlyVertical = horizontalDistance < max(80, abs(translation.y) * 0.55)
                guard isDownward, isMostlyVertical else { return }
                onClose()
            case .cancelled, .failed:
                startedAtScrollableTop = false
            default:
                break
            }
        }

        private func scrollViewAtGestureStart(in window: UIWindow, recognizer: UIPanGestureRecognizer) -> UIScrollView? {
            let location = recognizer.location(in: window)
            return window.hitTest(location, with: nil)?.nearestSuperview(of: UIScrollView.self)
        }
    }
}

private extension View {
    func swipeDownToCloseWindow(
        isActive: @escaping () -> Bool = { true },
        onClose: @escaping () -> Void
    ) -> some View {
        modifier(SwipeDownToCloseWindowModifier(isActive: isActive, onClose: onClose))
    }
}

private extension UIScrollView {
    var isScrolledToTopForDismiss: Bool {
        contentOffset.y <= -adjustedContentInset.top + 2
    }
}

private extension UIView {
    func nearestSuperview<T: UIView>(of type: T.Type) -> T? {
        var view: UIView? = self
        while let current = view {
            if let match = current as? T {
                return match
            }
            view = current.superview
        }
        return nil
    }
}
