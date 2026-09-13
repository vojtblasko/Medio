import SwiftUI
import Foundation
import UIKit

struct DiagnosticEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let message: String

    init(date: Date = Date(), message: String) {
        self.id = UUID()
        self.date = date
        self.message = message
    }
}

@MainActor
final class DiagnosticsCenter: ObservableObject {
    static let shared = DiagnosticsCenter()

    private enum Key {
        static let storageEnabled = "medio.diagnostics.storage.enabled"
        static let internetEnabled = "medio.diagnostics.internet.enabled"
        static let interactionEnabled = "medio.diagnostics.interaction.enabled"
        static let internetEntries = "medio.diagnostics.internet.entries"
        static let interactionEntries = "medio.diagnostics.interaction.entries"
        static let storageReport = "medio.diagnostics.storage.report"
    }

    @Published var storageEnabled = false {
        didSet { defaults.set(storageEnabled, forKey: Key.storageEnabled) }
    }
    @Published var internetEnabled = false {
        didSet { defaults.set(internetEnabled, forKey: Key.internetEnabled) }
    }
    @Published var interactionEnabled = false {
        didSet { defaults.set(interactionEnabled, forKey: Key.interactionEnabled) }
    }
    @Published private(set) var internetEntries: [DiagnosticEntry] = []
    @Published private(set) var interactionEntries: [DiagnosticEntry] = []
    @Published private(set) var storageReport = ""

    var allEnabled: Bool {
        storageEnabled && internetEnabled && interactionEnabled
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maximumEntryCount = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storageEnabled = defaults.bool(forKey: Key.storageEnabled)
        internetEnabled = defaults.bool(forKey: Key.internetEnabled)
        interactionEnabled = defaults.bool(forKey: Key.interactionEnabled)
        internetEntries = Self.decodeEntries(defaults.data(forKey: Key.internetEntries), decoder: decoder)
        interactionEntries = Self.decodeEntries(defaults.data(forKey: Key.interactionEntries), decoder: decoder)
        storageReport = defaults.string(forKey: Key.storageReport) ?? ""
    }

    func setAllEnabled(_ enabled: Bool) {
        storageEnabled = enabled
        internetEnabled = enabled
        interactionEnabled = enabled
    }

    func replaceStorageReport(_ report: String) {
        guard storageEnabled else { return }
        storageReport = report
        defaults.set(report, forKey: Key.storageReport)
    }

    func clearStorageReport() {
        storageReport = ""
        defaults.removeObject(forKey: Key.storageReport)
    }

    func clearInternetEntries() {
        internetEntries = []
        defaults.removeObject(forKey: Key.internetEntries)
    }

    func clearInteractionEntries() {
        interactionEntries = []
        defaults.removeObject(forKey: Key.interactionEntries)
    }

    func appendInternet(_ message: String) {
        guard internetEnabled else { return }
        append(DiagnosticEntry(message: message), to: &internetEntries, key: Key.internetEntries)
    }

    func appendInteraction(_ message: String) {
        guard interactionEnabled else { return }
        append(DiagnosticEntry(message: message), to: &interactionEntries, key: Key.interactionEntries)
    }

    nonisolated static func recordInternet(_ message: String) {
        guard UserDefaults.standard.bool(forKey: Key.internetEnabled) else { return }
        Task { @MainActor in shared.appendInternet(message) }
    }

    nonisolated static func recordInteraction(_ message: String) {
        guard UserDefaults.standard.bool(forKey: Key.interactionEnabled) else { return }
        Task { @MainActor in shared.appendInteraction(message) }
    }

    private func append(_ entry: DiagnosticEntry, to entries: inout [DiagnosticEntry], key: String) {
        entries.append(entry)
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        defaults.set(try? encoder.encode(entries), forKey: key)
    }

    private static func decodeEntries(_ data: Data?, decoder: JSONDecoder) -> [DiagnosticEntry] {
        guard let data else { return [] }
        return (try? decoder.decode([DiagnosticEntry].self, from: data)) ?? []
    }
}

// MARK: - Settings
struct SettingsPanel: View {
    @ObservedObject var vm: SettingsViewModel
    @ObservedObject var container: AppContainer
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var onlineAccess = OnlineAccessStore.shared

    init(vm: SettingsViewModel, container: AppContainer) {
        self.vm = vm
        self.container = container
        self.settingsStore = container.settingsStore
    }
    @EnvironmentObject var batterySaver: BatterySaverService
    @EnvironmentObject private var router: AppRouter

    @State private var showCacheAlert = false
    @State private var isExportingMedioReCapped = false
    @State private var medioReCappedExportStatus = ""
    @State private var showMedioReCappedAlert = false
    @State private var persistenceErrorMessage = ""
    @State private var showPersistenceError = false
    @State private var showMedioReCappedDisableWarning = false
    @State private var cacheUsageText = String(localized: "Calculating...")
    @State private var showInternetDisableWarning = false
    @State private var internetDisableArtistImageCount = 0
    @State private var isMakingLivied = false
    @State private var liviedStatus = ""
    @State private var showLiviedAlert = false
    private let priorityFolderOptions = [0, 2, 4, 6, 8, 10]

    var body: some View {
        Group {
            List {
                Section("Language") {
                    Button("App Language") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("Uses your device language by default. English, Czech, German, and French are available in iOS app settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Playback") {
                    Toggle("Battery Saver Mode (Mimic)", isOn: $batterySaver.manualSaverEnabled)
                        .onChange(of: batterySaver.manualSaverEnabled) { _ in
                            batterySaver.updateEffectiveMode()
                        }
                    if batterySaver.isLowPowerModeActive {
                        Text("System Low Power Mode is ON")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                PlaybackIndicatorSettingsSection()

                AudioSharingSettingsSection(sharing: container.audioSharing)

                Section("Online Access") {
                    Toggle("App Can Connect to the Internet", isOn: internetAccessBinding)
                        .accessibilityIdentifier("settings_internet_access")

                    ForEach(OnlineFeature.allCases) { feature in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title)
                            Text("Transferred: \(ByteCountFormatter.string(fromByteCount: onlineAccess.transferredBytes[feature.rawValue, default: 0], countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings_online_\(feature.rawValue)")
                    }
                    Text("Usage since \(onlineAccess.trackingSince.formatted(date: .abbreviated, time: .omitted)). Includes sent and received HTTP data; excludes cached responses and connection overhead.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(localized: "These internet functions fetch artist pictures. Local audio sharing has its own switch and usage counter above. GitHub reports open in your browser, whose usage is not counted here."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset Internet Usage") { onlineAccess.resetUsage() }
                }

                Section("Library") {
                    Toggle("Show Unknown Artists", isOn: $vm.showUnknownArtists)
                        .accessibilityIdentifier("settings_show_unknown_artists")
                    Toggle("Show Unknown Albums", isOn: $vm.showUnknownAlbums)
                        .accessibilityIdentifier("settings_show_unknown_albums")
                    Text("Hides or shows the generic Unknown Artist and Unknown Album buckets in Library and Search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Home") {
                    Picker("Priority Folders", selection: $vm.priorityFoldersCount) {
                        ForEach(priorityFolderOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }

                    Toggle("Show Favorites in Home", isOn: $settingsStore.favoritesHomeFolderEnabled)
                        .accessibilityIdentifier("settings_home_favorites")
                    Toggle("Use Favorites as Priority 1", isOn: $settingsStore.favoritesPriorityFolderEnabled)
                        .accessibilityIdentifier("settings_priority_favorites")
                    Text("When pinned as Priority 1, Favorites appears there instead of in the folder list. Your favorite songs are kept when either switch is off.")
                        .font(.caption).foregroundStyle(.secondary)
                    if vm.priorityFoldersCount == 0 {
                        Text(container.settingsStore.favoritesHomeFolderEnabled
                            ? "Favorites appears with normal folders after you favorite a song."
                            : "Favorites is hidden from Home. Increase Priority Folders to configure Priority 1 as a normal folder or image.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        if container.settingsStore.favoritesPriorityFolderEnabled {
                            Menu {
                                Button("About Favorites", systemImage: "info.circle") {
                                    router.present(.favoritesAbout)
                                }
                            } label: {
                                priorityFolderLabel(
                                    title: String(localized: "Favorites"),
                                    systemImage: "star.fill",
                                    priorityNumber: 1
                                )
                            }
                            .contextMenu {
                                Button("About Favorites", systemImage: "info.circle") {
                                    router.present(.favoritesAbout)
                                }
                            }
                        } else {
                            priorityFolderMenu(slot: -1, priorityNumber: 1)
                        }
                        ForEach(0..<max(0, vm.priorityFoldersCount - 1), id: \.self) { slot in
                            priorityFolderMenu(slot: slot, priorityNumber: slot + 2)
                        }
                    }
                }

                Section("Medio ReCapped") {
                    Toggle("Medio ReCapped", isOn: medioReCappedBinding)
                        .accessibilityIdentifier("settings_medio_recapped")

                    Text("Medio ReCapped doesn’t send your data to any servers. All is stored locally on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(action: exportMedioReCappedReports) {
                        HStack {
                            Label("Export Medio ReCapped Text Files", systemImage: "doc.plaintext")
                            Spacer()
                            if isExportingMedioReCapped {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExportingMedioReCapped)
                    if !medioReCappedExportStatus.isEmpty {
                        Text(medioReCappedExportStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Library Snapshot") {
                    LibrarySnapshotStatusRow(libraryStore: container.libraryStore)

                    Button(action: makeMeLiviedIt) {
                        HStack {
                            Label("Make Me Livied It", systemImage: "wand.and.stars")
                            Spacer()
                            if isMakingLivied {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isMakingLivied)

                    Text("Refreshes the saved library snapshot, clears stale cover-art misses, retries embedded artwork for every song, and organizes loose SRT/LRC/TXT lyrics so reopened sessions do not get stuck on unassigned files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !liviedStatus.isEmpty {
                        Text(liviedStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Cache") {
                    Button("Clear All Caches") {
                        do {
                            try clearAllCaches()
                            Task { await refreshCacheUsage() }
                            showCacheAlert = true
                        } catch {
                            AppLog.persistence.error("Caches could not be cleared: \(error.localizedDescription, privacy: .public)")
                            persistenceErrorMessage = String(localized: "Some cache files could not be cleared. Try again.")
                            showPersistenceError = true
                        }
                    }
                    .foregroundStyle(.red)
                    Text("Cache is using \(cacheUsageText) on disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        router.present(.lyricsSettings)
                    } label: {
                        HStack {
                            Label("Lyrics", systemImage: "music.note.list")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("settings_lyrics")
                }

                Section {
                    Button {
                        router.present(.crashReportManager)
                    } label: {
                        Label("Crash Report & Bugs Manager", systemImage: "ladybug")
                    }
                    .accessibilityIdentifier("settings_crash_report_manager")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .alert("Caches Cleared", isPresented: $showCacheAlert) {
                Button("OK") { }
            } message: {
                Text("Artwork cache and library cache have been cleared.")
            }
            .alert("Medio ReCapped Export", isPresented: $showMedioReCappedAlert) {
                Button("OK") { }
            } message: {
                Text(medioReCappedExportStatus)
            }
            .alert("Operation Failed", isPresented: $showPersistenceError) {
                Button("OK") { }
            } message: {
                Text(persistenceErrorMessage)
            }
            .alert("Turn Off Medio ReCapped?", isPresented: $showMedioReCappedDisableWarning) {
                Button("Keep Data", role: .cancel) {
                    vm.medioReCappedEnabled = false
                }
                Button("Delete Data and Turn Off", role: .destructive) {
                    disableMedioReCapped(deleteCollectedData: true)
                }
            } message: {
                Text("Turning this off stops new listening history from being recorded. If you delete the collected data, the saved listening history and generated ReCapped files will be removed from this device.")
            }
            .alert("Make Me Livied It", isPresented: $showLiviedAlert) {
                Button("OK") { }
            } message: {
                Text(liviedStatus)
            }
            .alert("Turn Off Internet Access?", isPresented: $showInternetDisableWarning) {
                Button("Keep Internet On", role: .cancel) {
                    vm.appCanConnectToInternet = true
                }
                Button("Disable and Delete", role: .destructive) {
                    disableInternetAccess(deleteDownloadedArtistImages: true)
                }
            } message: {
                Text(internetDisableWarningMessage)
            }
            .task {
                await refreshCacheUsage()
            }
        }
    }

    private var internetAccessBinding: Binding<Bool> {
        Binding(
            get: { vm.appCanConnectToInternet },
            set: { newValue in
                if newValue {
                    vm.appCanConnectToInternet = true
                } else {
                    requestDisableInternetAccess()
                }
            }
        )
    }

    private var medioReCappedBinding: Binding<Bool> {
        Binding(
            get: { vm.medioReCappedEnabled },
            set: { newValue in
                if newValue {
                    vm.medioReCappedEnabled = true
                } else {
                    requestDisableMedioReCapped()
                }
            }
        )
    }

    private var internetDisableWarningMessage: String {
        return String(localized: "Medio will stop MusicBrainz and Wikimedia artist-picture lookups. Downloaded artist pictures to delete: \(internetDisableArtistImageCount). Artist pages will use the default person icon until you enable internet access again.")
    }

    private func requestDisableInternetAccess() {
        let cachedCount = UserDefaultsArtistProfileRepository.shared.cachedImageCount()
        guard cachedCount > 0 else {
            disableInternetAccess(deleteDownloadedArtistImages: false)
            return
        }
        internetDisableArtistImageCount = cachedCount
        vm.appCanConnectToInternet = true
        showInternetDisableWarning = true
    }

    private func disableInternetAccess(deleteDownloadedArtistImages: Bool) {
        if deleteDownloadedArtistImages {
            UserDefaultsArtistProfileRepository.shared.clearAllImages()
        }
        vm.appCanConnectToInternet = false
    }

    private func requestDisableMedioReCapped() {
        vm.medioReCappedEnabled = true
        showMedioReCappedDisableWarning = true
    }

    private func disableMedioReCapped(deleteCollectedData: Bool) {
        vm.medioReCappedEnabled = false
        guard deleteCollectedData else { return }
        Task {
            do {
                if let repository = container.listeningHistoryRepository as? SQLiteListeningHistoryRepository {
                    try await repository.deleteStoredData()
                } else {
                    try await container.listeningHistoryRepository.clearSessions()
                }
                try deleteMedioReCappedReports()
            } catch {
                AppLog.persistence.error("ReCapped data could not be deleted: \(error.localizedDescription, privacy: .public)")
                persistenceErrorMessage = String(localized: "Some ReCapped data could not be deleted. Try again.")
                showPersistenceError = true
            }
        }
    }

    private func deleteMedioReCappedReports() throws {
        let fileManager = FileManager.default
        let roots = [
            "Medio ReCapped",
            ["Medio", "Wrap" + "ped"].joined(separator: " ")
        ]
        guard let documentsURL = AppFileRoot.documentsURL else { return }
        for root in roots {
            let url = documentsURL.appendingPathComponent(root, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func priorityFolderName(at slot: Int) -> String {
        guard let path = container.settingsStore.priorityFolderPath(at: slot) else {
            return String(localized: "Choose Folder")
        }
        if let folder = container.libraryStore.allItems.first(where: { $0.id == path }) {
            return folder.displayName
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func priorityFolderMenu(slot: Int, priorityNumber: Int) -> some View {
        Menu {
            priorityFolderActions(slot: slot)
        } label: {
            priorityFolderLabel(
                title: priorityFolderName(at: slot),
                systemImage: container.settingsStore.isPrioritySlotImageOnly(slot) ? "photo.fill" : "folder",
                priorityNumber: priorityNumber
            )
        }
        .contextMenu {
            priorityFolderActions(slot: slot)
        }
    }

    private func priorityFolderLabel(title: String, systemImage: String, priorityNumber: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
            Spacer()
            Text("Priority \(priorityNumber)")
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func priorityFolderActions(slot: Int) -> some View {
        if let path = container.settingsStore.priorityFolderPath(at: slot) {
            Button("About", systemImage: "info.circle") {
                router.present(.fileAbout(path: path))
            }
        }
        Button("Change Folder", systemImage: "folder") {
            router.present(.priorityFolderPicker(slot: slot))
        }
        Button("Make Image", systemImage: "photo") {
            router.present(.prioritySlotAbout(slot: slot))
        }
        if container.settingsStore.isPrioritySlotImageOnly(slot) {
            Button("Show Folder Card", systemImage: "folder") {
                container.settingsStore.setPrioritySlotImageOnly(false, at: slot)
            }
        }
        if container.settingsStore.priorityFolderPath(at: slot) != nil
            || container.settingsStore.prioritySlotArtworkPath(at: slot) != nil {
            Button("Remove", systemImage: "pin.slash", role: .destructive) {
                container.settingsStore.resetPrioritySlot(at: slot)
            }
        }
    }

    private func clearAllCaches() throws {
        ArtworkCache.shared.clear()
        if let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheFiles = try FileManager.default.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: nil)
            for cacheFile in cacheFiles where cacheFile.lastPathComponent.hasPrefix("medio-library-cache") {
                try FileManager.default.removeItem(at: cacheFile)
            }
        }
    }

    private func makeMeLiviedIt() {
        guard !isMakingLivied else { return }
        isMakingLivied = true
        liviedStatus = String(localized: "Refreshing library snapshot...")

        Task {
            let scanUseCase = ScanLibraryUseCase(dataSource: container.mediaLibraryRepository)
            do {
                ArtworkCache.shared.clear()
                await container.libraryStore.refresh(scanUseCase: scanUseCase)

                liviedStatus = String(localized: "Organizing loose lyrics files...")
                let organizedCount = try await organizeLyricsFiles { processed, total in
                    if total == 0 {
                        liviedStatus = String(localized: "No loose lyrics files found.")
                    } else {
                        liviedStatus = String(localized: "Organizing loose lyrics files \(processed)/\(total)...")
                    }
                }

                if organizedCount > 0 {
                    liviedStatus = String(localized: "Refreshing snapshot after lyrics organization...")
                    await container.libraryStore.refresh(scanUseCase: scanUseCase)
                }

                ArtworkCache.shared.clear()
                let songs = container.libraryStore.librarySongs
                let songIDs = songs.map(\.id)
                ArtworkCache.shared.retry(songIDs)
                await refreshCacheUsage()

                isMakingLivied = false
                liviedStatus = String(localized: "Snapshot refreshed: \(lastSnapshotText). Lyrics files organized: \(organizedCount). Songs queued for cover art retry: \(songIDs.count).")
                showLiviedAlert = true
            } catch {
                isMakingLivied = false
                liviedStatus = String(localized: "Make Me Livied It failed: \(error.localizedDescription)")
                showLiviedAlert = true
            }
        }
    }

    @MainActor
    private func refreshCacheUsage() async {
        let bytes = await Self.cacheUsageBytes()
        cacheUsageText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func cacheUsageBytes() async -> Int64 {
        await Task.detached(priority: .utility) {
            guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let cacheFiles = try? FileManager.default.contentsOfDirectory(
                    at: cachesURL,
                    includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]
                  ) else {
                return 0
            }
            return cacheFiles
                .filter { $0.lastPathComponent.hasPrefix("medio-library-cache") }
                .reduce(Int64(0)) { total, url in
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
                    let allocatedSize = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
                    return total + Int64(allocatedSize)
                }
        }.value
    }

    private func exportMedioReCappedReports() {
        isExportingMedioReCapped = true
        medioReCappedExportStatus = String(localized: "Exporting Medio ReCapped text files...")
        Task {
            do {
                let exporter = MedioReCappedReportExporter(historyRepository: container.listeningHistoryRepository)
                let directory = try await exporter.export(libraryStore: container.libraryStore)
                await MainActor.run {
                    isExportingMedioReCapped = false
                    medioReCappedExportStatus = String(localized: "Saved to \(directory.path.appRelativeDisplayPath)")
                    showMedioReCappedAlert = true
                }
            } catch {
                await MainActor.run {
                    isExportingMedioReCapped = false
                    medioReCappedExportStatus = String(localized: "Export failed: \(error.localizedDescription)")
                    showMedioReCappedAlert = true
                }
            }
        }
    }

    private func organizeLyricsFiles(
        progress: @escaping LyricsOrganizationService.ProgressHandler = { _, _ in }
    ) async throws -> Int {
        let service = LyricsOrganizationService(
            associationRepository: container.lyricsFileAssociationRepository
        )
        return try await service.organize(progress: progress)
    }

    private var lastSnapshotText: String {
        guard let date = container.libraryStore.lastStorageScanSummary?.refreshedAt else {
            return String(localized: "No snapshot yet")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct LyricsSettingsPanel: View {
    @ObservedObject var container: AppContainer
    @EnvironmentObject private var router: AppRouter

    @State private var speechlessMusicPolicy: SpeechlessMusicPolicy = .include
    @State private var missingLyricsReport: MissingLyricsScanReport?
    @State private var missingLyricsProgress: MissingLyricsScanProgress?
    @State private var isScanningMissingLyrics = false
    @State private var missingLyricsStatus = ""
    @State private var searchText = ""
    @State private var isOrganizingLyrics = false
    @State private var organizingStatus = ""
    @State private var organizingProgress = 0
    @State private var organizingTotal = 0
    @State private var showOrganizingAlert = false

    var body: some View {
        List {
            Section("Maintenance") {
                Button(action: organizeLyrics) {
                    HStack {
                        Label("Organize Lyrics", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if isOrganizingLyrics {
                            if organizingTotal > 0 {
                                ProgressView(value: Double(organizingProgress), total: Double(organizingTotal))
                                    .frame(width: 80)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                }
                .disabled(isOrganizingLyrics || isScanningMissingLyrics)

                if !organizingStatus.isEmpty {
                    Text(organizingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Music Without Speech")
                        .font(.subheadline.weight(.semibold))
                    Picker("Music Without Speech", selection: $speechlessMusicPolicy) {
                        ForEach(SpeechlessMusicPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(isScanningMissingLyrics)
                    .accessibilityIdentifier("lyrics_speechless_music_policy")
                }
                .padding(.vertical, 2)

                Text(speechlessMusicPolicy == .include
                    ? "Lists every playable file without lyrics. Audio is not analyzed."
                    : "Analyzes music on this device for speech and vocals, then excludes files where neither is detected. Videos and files that cannot be analyzed remain in the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: scanForMissingLyrics) {
                    HStack {
                        Label(
                            missingLyricsReport == nil ? "List Files Without Lyrics" : "Refresh Missing Lyrics List",
                            systemImage: "text.badge.xmark"
                        )
                        Spacer()
                        if isScanningMissingLyrics {
                            ProgressView()
                        }
                    }
                }
                .disabled(isScanningMissingLyrics || isOrganizingLyrics)
                .accessibilityIdentifier("lyrics_list_missing")

                if let progress = missingLyricsProgress, isScanningMissingLyrics {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        Text(progress.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !missingLyricsStatus.isEmpty {
                    Text(missingLyricsStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Files Without Lyrics")
            } footer: {
                Text("Speech detection uses Apple’s on-device sound classifier. No audio leaves this device.")
            }

            if missingLyricsReport != nil {
                Section("Results (\(filteredMissingLyricsFiles.count))") {
                    if filteredMissingLyricsFiles.isEmpty {
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No matching files without lyrics were found.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No results match your search.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(filteredMissingLyricsFiles) { file in
                            Button {
                                router.present(.fileAbout(path: file.song.id))
                            } label: {
                                missingLyricsRow(file)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search files without lyrics")
        .onChange(of: speechlessMusicPolicy) { _ in
            missingLyricsReport = nil
            missingLyricsProgress = nil
            missingLyricsStatus = String(localized: "Choose List Files Without Lyrics to apply this option.")
        }
        .alert("Lyrics Organization Complete", isPresented: $showOrganizingAlert) {
            Button("OK") { }
        } message: {
            Text(organizingStatus)
        }
    }

    private var filteredMissingLyricsFiles: [MissingLyricsFile] {
        guard let files = missingLyricsReport?.files else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return files }
        return files.filter { file in
            [file.song.displayName, file.song.author, file.song.album, file.song.id.appRelativeDisplayPath]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder
    private func missingLyricsRow(_ file: MissingLyricsFile) -> some View {
        HStack(spacing: 12) {
            SongArtworkView(
                path: file.song.id,
                size: 44,
                cornerRadius: 7,
                fallbackSystemImage: file.song.fileType == .video ? "film" : "music.note"
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.song.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(file.song.author ?? file.song.id.appRelativeDisplayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if file.speechAnalysis == .analysisUnavailable {
                    Text("Speech check unavailable — included")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func scanForMissingLyrics() {
        guard !isScanningMissingLyrics else { return }
        let songs = container.libraryStore.librarySongs
        let selectedPolicy = speechlessMusicPolicy
        isScanningMissingLyrics = true
        missingLyricsReport = nil
        missingLyricsStatus = songs.isEmpty ? String(localized: "The library has no playable files.") : String(localized: "Preparing scan…")
        missingLyricsProgress = nil

        Task {
            do {
                let scanner = MissingLyricsScanner(lyricsRepository: container.lyricsRepository)
                let report = try await scanner.scan(
                    songs: songs,
                    speechlessMusicPolicy: selectedPolicy
                ) { progress in
                    missingLyricsProgress = progress
                }
                missingLyricsReport = report
                missingLyricsStatus = missingLyricsSummary(report)
            } catch is CancellationError {
                missingLyricsStatus = String(localized: "Scan cancelled.")
            } catch {
                missingLyricsStatus = String(localized: "Scan failed: \(error.localizedDescription)")
            }
            isScanningMissingLyrics = false
            missingLyricsProgress = nil
        }
    }

    private func missingLyricsSummary(_ report: MissingLyricsScanReport) -> String {
        var parts = ["Found \(report.files.count) file\(report.files.count == 1 ? "" : "s") without lyrics."]
        if report.speechlessMusicExcludedCount > 0 {
            parts.append("Excluded \(report.speechlessMusicExcludedCount) without detected speech or vocals.")
        }
        if report.lyricsReadFailureCount > 0 {
            parts.append("Could not read lyrics for \(report.lyricsReadFailureCount) file\(report.lyricsReadFailureCount == 1 ? "" : "s").")
        }
        if report.speechAnalysisFailureCount > 0 {
            parts.append("Included \(report.speechAnalysisFailureCount) file\(report.speechAnalysisFailureCount == 1 ? "" : "s") whose audio could not be analyzed.")
        }
        return parts.joined(separator: " ")
    }

    private func organizeLyrics() {
        guard !isOrganizingLyrics else { return }
        isOrganizingLyrics = true
        organizingStatus = String(localized: "Scanning for lyrics files…")
        organizingProgress = 0
        organizingTotal = 0

        Task {
            do {
                let service = LyricsOrganizationService(
                    associationRepository: container.lyricsFileAssociationRepository
                )
                let result = try await service.organize { processed, total in
                    organizingProgress = processed
                    organizingTotal = total
                }
                organizingStatus = String(localized: "Successfully organized \(result) lyrics files.")
            } catch {
                organizingStatus = String(localized: "Error: \(error.localizedDescription)")
            }
            isOrganizingLyrics = false
            showOrganizingAlert = true
        }
    }
}

struct CrashReportManagerPanel: View {
    @ObservedObject var container: AppContainer
    @StateObject private var diagnostics = DiagnosticsCenter.shared
    @State private var searchText = ""
    @State private var storageExpanded = false
    @State private var internetExpanded = false
    @State private var interactionExpanded = false
    @State private var isRefreshingStorage = false
    @State private var copiedMessage = ""
    @State private var showCopiedAlert = false

    var body: some View {
        List {
            Section {
                Text("Everything Medio collects for debugging is listed here and visible when you open each category. Nothing is shared automatically. You choose which categories to include when reporting a bug.")
                Text("Review the data before sharing it. For the best chance of fixing an issue, sharing all relevant categories is recommended.")
                    .foregroundStyle(.secondary)
            }

            if matchesCategory("all diagnostics collectors privacy collection") {
                Section {
                    Toggle("Turn On All Diagnostics Collectors", isOn: allCollectorsBinding)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("diagnostics_enable_all")
                    Text("All collectors are off by default. Turning them off stops new collection but keeps existing entries visible until you clear them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsStorageSection {
                Section {
                    DisclosureGroup(isExpanded: $storageExpanded) {
                        Toggle("Collect Storage Diagnostics", isOn: $diagnostics.storageEnabled)
                            .accessibilityIdentifier("diagnostics_storage_enabled")

                        Text("Share this when files, folders, artwork, lyrics, imports, or the media library are missing, stale, duplicated, or failing to load. It contains device storage paths, file names, types, sizes, library counts, and the latest scan result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            refreshStorageDiagnostics()
                        } label: {
                            HStack {
                                Label("Refresh Storage Diagnostics", systemImage: "arrow.clockwise")
                                Spacer()
                                if isRefreshingStorage { ProgressView() }
                            }
                        }
                        .disabled(isRefreshingStorage)

                        diagnosticText(diagnostics.storageReport, emptyMessage: storageEmptyMessage)

                        if !diagnostics.storageReport.isEmpty {
                            Button("Copy Storage Diagnostics", systemImage: "doc.on.doc") {
                                copy(diagnostics.storageReport, category: String(localized: "Storage diagnostics"))
                            }
                            Button("Clear Storage Diagnostics", systemImage: "trash", role: .destructive) {
                                diagnostics.clearStorageReport()
                            }
                        }
                    } label: {
                        diagnosticLabel(
                            title: String(localized: "Storage Diagnostics"),
                            icon: "externaldrive.badge.questionmark",
                            isEnabled: diagnostics.storageEnabled,
                            count: diagnostics.storageReport.isEmpty ? 0 : diagnostics.storageReport.components(separatedBy: "\n").count
                        )
                    }
                }
            }

            if showsInternetSection {
                Section {
                    DisclosureGroup(isExpanded: $internetExpanded) {
                        Toggle("Collect Internet Diagnostics", isOn: $diagnostics.internetEnabled)
                            .accessibilityIdentifier("diagnostics_internet_enabled")

                        Text("Share this when an online artist search, license check, or image download fails. It records the search steps, services and URLs contacted, response status, downloaded byte counts, and errors. Downloaded image payloads are not duplicated in this log.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        diagnosticEntries(filteredInternetEntries, emptyMessage: internetEmptyMessage)

                        if !diagnostics.internetEntries.isEmpty {
                            Button("Copy Internet Diagnostics", systemImage: "doc.on.doc") {
                                copy(formatted(diagnostics.internetEntries), category: String(localized: "Internet diagnostics"))
                            }
                            Button("Clear Internet Diagnostics", systemImage: "trash", role: .destructive) {
                                diagnostics.clearInternetEntries()
                            }
                        }
                    } label: {
                        diagnosticLabel(
                            title: String(localized: "Internet Diagnostics"),
                            icon: "network",
                            isEnabled: diagnostics.internetEnabled,
                            count: diagnostics.internetEntries.count
                        )
                    }
                }
            }

            if showsInteractionSection {
                Section {
                    DisclosureGroup(isExpanded: $interactionExpanded) {
                        Toggle("Collect Click-Through Diagnostics", isOn: $diagnostics.interactionEnabled)
                            .accessibilityIdentifier("diagnostics_interaction_enabled")

                        Text("Share this after a crash, freeze, wrong screen, or navigation problem. It records dated app navigation and interaction steps so the sequence leading to the issue can be reproduced. It does not record taps outside Medio, keystrokes, or screen contents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        diagnosticEntries(filteredInteractionEntries, emptyMessage: interactionEmptyMessage)

                        if !diagnostics.interactionEntries.isEmpty {
                            Button("Copy Click-Through Diagnostics", systemImage: "doc.on.doc") {
                                copy(formatted(diagnostics.interactionEntries), category: String(localized: "Click-through diagnostics"))
                            }
                            Button("Clear Click-Through Diagnostics", systemImage: "trash", role: .destructive) {
                                diagnostics.clearInteractionEntries()
                            }
                        }
                    } label: {
                        diagnosticLabel(
                            title: String(localized: "Click-Through Diagnostics"),
                            icon: "hand.tap",
                            isEnabled: diagnostics.interactionEnabled,
                            count: diagnostics.interactionEntries.count
                        )
                    }
                }
            }

            if matchesCategory("report bug github feedback contact ive got a feedback") {
                Section {
                    Link(destination: URL(string: "https://github.com/vojtblasko/Medio/issues/new")!) {
                        Label("Report a Bug on GitHub", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("diagnostics_feedback")
                    Text("Opens a new GitHub issue. You can copy diagnostics above and include them in your report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Crash Report & Bugs Manager")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search diagnostics")
        .onChange(of: diagnostics.storageEnabled) { enabled in
            if enabled && diagnostics.storageReport.isEmpty {
                refreshStorageDiagnostics()
            }
        }
        .alert("Copied", isPresented: $showCopiedAlert) {
            Button("OK") { }
        } message: {
            Text(copiedMessage)
        }
    }

    private var allCollectorsBinding: Binding<Bool> {
        Binding(
            get: { diagnostics.allEnabled },
            set: { enabled in
                diagnostics.setAllEnabled(enabled)
                if enabled && diagnostics.storageReport.isEmpty {
                    refreshStorageDiagnostics()
                }
            }
        )
    }

    private var showsStorageSection: Bool {
        matchesCategory("storage files folders library artwork lyrics scan \(diagnostics.storageReport)")
    }

    private var showsInternetSection: Bool {
        matchesCategory("internet online network search sites visited downloads musicbrainz wikimedia \(diagnostics.internetEntries.map(\.message).joined(separator: " "))")
    }

    private var showsInteractionSection: Bool {
        matchesCategory("click through interaction buttons navigation crash debug log \(diagnostics.interactionEntries.map(\.message).joined(separator: " "))")
    }

    private var filteredInternetEntries: [DiagnosticEntry] {
        filtered(diagnostics.internetEntries)
    }

    private var filteredInteractionEntries: [DiagnosticEntry] {
        filtered(diagnostics.interactionEntries)
    }

    private var storageEmptyMessage: String {
        diagnostics.storageEnabled
            ? String(localized: "No storage snapshot has been collected yet.")
            : String(localized: "Storage collection is off. Turn it on to create a visible snapshot.")
    }

    private var internetEmptyMessage: String {
        diagnostics.internetEnabled
            ? String(localized: "No internet activity has been collected yet.")
            : String(localized: "Internet collection is off. Turn it on before reproducing the issue.")
    }

    private var interactionEmptyMessage: String {
        diagnostics.interactionEnabled
            ? String(localized: "No click-through activity has been collected yet.")
            : String(localized: "Click-through collection is off. Turn it on before reproducing the issue.")
    }

    private func matchesCategory(_ text: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    private func filtered(_ entries: [DiagnosticEntry]) -> [DiagnosticEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.message.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private func diagnosticLabel(title: String, icon: String, isEnabled: Bool, count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(isEnabled ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? .green : .secondary)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func diagnosticEntries(_ entries: [DiagnosticEntry], emptyMessage: String) -> some View {
        if entries.isEmpty {
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func diagnosticText(_ report: String, emptyMessage: String) -> some View {
        if report.isEmpty {
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(report)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func refreshStorageDiagnostics() {
        guard diagnostics.storageEnabled, !isRefreshingStorage else { return }
        isRefreshingStorage = true
        Task {
            await container.libraryStore.refresh(
                scanUseCase: ScanLibraryUseCase(dataSource: container.mediaLibraryRepository)
            )
            diagnostics.replaceStorageReport(makeStorageDiagnosticsReport())
            isRefreshingStorage = false
        }
    }

    private func makeStorageDiagnosticsReport() -> String {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL
        var lines = [
            "Medio Storage Diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Bundle identifier: \(Bundle.main.bundleIdentifier ?? "nil")",
            "Documents path: \(documentsURL?.path ?? "nil")"
        ]

        if let documentsURL {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .typeIdentifierKey, .contentModificationDateKey]
            do {
                let items = try fileManager.contentsOfDirectory(
                    at: documentsURL,
                    includingPropertiesForKeys: Array(keys),
                    options: []
                ).sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                lines.append("Documents item count: \(items.count)")
                for item in items.prefix(100) {
                    let values = try? item.resourceValues(forKeys: keys)
                    lines.append("- \(item.lastPathComponent) | \(values?.isDirectory == true ? "directory" : "file") | bytes=\(values?.fileSize.map(String.init) ?? "nil") | type=\(values?.typeIdentifier ?? "nil") | modified=\(values?.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil")")
                }
                if items.count > 100 { lines.append("... \(items.count - 100) more item(s)") }
            } catch {
                lines.append("Documents read error: \(error.localizedDescription)")
            }
        }

        lines.append("Library allItems count: \(container.libraryStore.allItems.count)")
        lines.append("Library homeItems count: \(container.libraryStore.homeItems.count)")
        lines.append("Library songs count: \(container.libraryStore.librarySongs.count)")
        if let summary = container.libraryStore.lastStorageScanSummary {
            lines.append("Last scan path: \(summary.documentsPath)")
            lines.append("Last scan item count: \(summary.scannedItemCount)")
            lines.append("Last scan visible home count: \(summary.visibleHomeItemCount)")
            lines.append("Last scan media count: \(summary.mediaItemCount)")
            lines.append("Last scan time: \(ISO8601DateFormatter().string(from: summary.refreshedAt))")
        } else {
            lines.append("Last scan: none")
        }
        lines.append("Last scan error: \(container.libraryStore.lastStorageScanError ?? "nil")")
        return lines.joined(separator: "\n")
    }

    private func formatted(_ entries: [DiagnosticEntry]) -> String {
        entries.map {
            "\(ISO8601DateFormatter().string(from: $0.date)) | \($0.message)"
        }.joined(separator: "\n")
    }

    private func copy(_ text: String, category: String) {
        UIPasteboard.general.string = text
        copiedMessage = "\(category) copied to the clipboard. No other category was included."
        showCopiedAlert = true
    }
}

private struct LibrarySnapshotStatusRow: View {
    @ObservedObject var libraryStore: LibraryStore

    var body: some View {
        CompatibleLabeledContent(String(localized: "Last Snapshot"), value: lastSnapshotText)
    }

    private var lastSnapshotText: String {
        guard let date = libraryStore.lastStorageScanSummary?.refreshedAt else {
            return String(localized: "No snapshot yet")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
