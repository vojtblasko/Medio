import SwiftUI
import Foundation
import UIKit
@preconcurrency import AVKit
@preconcurrency import AVFoundation
import QuartzCore

// MARK: - NowPlayingSeekBar with preview
struct NowPlayingSeekBar: View {
    let progress: CGFloat
    let durationMs: Int?
    let onSeek: (CGFloat) -> Void
    let onDragChanged: ((Bool, Int) -> Void)?

    @State private var isDragging = false
    @State private var dragProgress: CGFloat = 0
    @State private var dragPreviewMs: Int = 0

    var body: some View {
        GeometryReader { geo in
            let clampedProgress = min(max(progress, 0), 1)
            let effectiveProgress = isDragging ? dragProgress : clampedProgress
            let barHeight: CGFloat = isDragging ? 16 : 8
            let filledWidth = geo.size.width * effectiveProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: barHeight)

                if filledWidth > 0 {
                    LeadingRoundedProgressShape(cornerRadius: barHeight / 2)
                        .fill(Color.white)
                        .frame(width: filledWidth, height: barHeight)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragProgress = min(1, max(0, value.location.x / geo.size.width))
                        if let durationMs, durationMs > 0 {
                            dragPreviewMs = Int(dragProgress * CGFloat(durationMs))
                        }
                        onDragChanged?(true, dragPreviewMs)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onSeek(dragProgress)
                        onDragChanged?(false, dragPreviewMs)
                    }
            )
        }
        .frame(height: 18)
        .accessibilityLabel("Playback Position")
    }
}

private struct LeadingRoundedProgressShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private enum LyricsDisplayMode: Equatable {
    case compact
    case expanded
}

private struct NowPlayingScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NowPlayingLyricsScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - NowPlayingPanel
struct NowPlayingPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.medioUsesCompactRootChrome) private var usesCompactRootChrome
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var batterySaver: BatterySaverService

    @ObservedObject var vm: NowPlayingViewModel
    let settingsStore: SettingsStore
    @ObservedObject var libraryStore: LibraryStore
    let favoritesRepository: FavoritesRepository
    private let artworkCache: ArtworkCache = .shared
    @StateObject private var videoBackdropSampler = VideoFrameBackdropSampler()

    @State private var lyricsAutoScrollEnabled = true
    @State private var isLyricDropTargeted = false
    @State private var pendingMovedLyricURL: URL?
    @State private var pendingLyricTargetSongID: String?
    @State private var showLyricDropChoice = false
    @State private var lyricDropInfoMessage: String?
    @State private var showLyricDropInfo = false
    @State private var seekPreviewMs: Int?
    @State private var scrollOffsetY: CGFloat = 0
    @State private var lyricsScrollOffsetY: CGFloat = 0
    @State private var isLyricsExpanded = false
    @State private var showFullscreenVideo = false
    @State private var artworkRevision = 0

    @ScaledMetric(relativeTo: .largeTitle) private var activeLyricFontSize: CGFloat = 36
    @ScaledMetric(relativeTo: .largeTitle) private var inactiveLyricFontSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title3) private var compactLyricFontSize: CGFloat = 21

    private var progress: CGFloat {
        guard let dur = vm.playback.durationMs, dur > 0 else { return 0 }
        return CGFloat(vm.playback.positionMs) / CGFloat(dur)
    }

    private var elapsedText: String { formattedTime(ms: vm.playback.positionMs) }
    private var remainingText: String {
        guard let duration = vm.playback.durationMs else { return "-0:00" }
        return "-\(formattedTime(ms: max(0, duration - vm.playback.positionMs)))"
    }
    private var totalDurationText: String {
        guard let duration = vm.playback.durationMs else { return "0:00" }
        return formattedTime(ms: duration)
    }
    private var rightTimeText: String {
        settingsStore.nowPlayingShowsTotalDuration ? totalDurationText : remainingText
    }
    private var seekPreviewText: String? {
        guard let seekPreviewMs else { return nil }
        return formattedTime(ms: seekPreviewMs)
    }
    private var isCurrentFavorite: Bool {
        guard let path = vm.item?.id else { return false }
        return libraryStore.isFavorite(path)
    }
    private var videoPlayer: AVPlayer? {
        guard vm.item?.isVideo == true else { return nil }
        return (container.playbackService as? PlaybackVideoProviding)?.videoPlayer
    }

    private var backdropColors: [Color] {
        let videoPalette = videoBackdropSampler.colors.map { Color(uiColor: $0) }
        if vm.item?.isVideo == true, !videoPalette.isEmpty {
            return videoPalette
        }

        let palette = vm.artworkBackgroundColors.map { Color(uiColor: $0) }
        if palette.isEmpty {
            return colorScheme == .dark
                ? [Color(red: 0.13, green: 0.13, blue: 0.16), Color.black]
                : [Color(red: 0.25, green: 0.21, blue: 0.24), Color.black.opacity(0.96)]
        }
        return palette
    }

    var body: some View {
        ZStack {
            NowPlayingBackdrop(colors: backdropColors, scrollOffset: scrollOffsetY).ignoresSafeArea()

            GeometryReader { proxy in
                let topPadding: CGFloat = 66
                let bottomPadding: CGFloat = usesCompactRootChrome ? 18 : 24
                let mainSectionMinHeight = max(0, proxy.size.height - topPadding - bottomPadding)
                let horizontalPadding: CGFloat = usesCompactRootChrome ? 18 : 24

                ZStack {
                    ScrollView(showsIndicators: false) {
                        GeometryReader { markerProxy in
                            Color.clear.preference(
                                key: NowPlayingScrollOffsetPreferenceKey.self,
                                value: markerProxy.frame(in: .named("now-playing-scroll")).minY
                            )
                        }
                        .frame(height: 0)

                        VStack(spacing: 18) {
                            nowPlayingControls
                                .frame(maxWidth: .infinity)
                                .frame(
                                    minHeight: usesCompactRootChrome ? nil : mainSectionMinHeight,
                                    alignment: .top
                                )

                            if !vm.lyricsLines.isEmpty {
                                lyricsPreviewWindow
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, topPadding)
                        .padding(.bottom, bottomPadding)
                    }
                    .coordinateSpace(name: "now-playing-scroll")
                    .onPreferenceChange(NowPlayingScrollOffsetPreferenceKey.self) { offset in
                        scrollOffsetY = offset
                    }

                }
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button(action: closeNowPlaying) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Close Now Playing")
                .accessibilityIdentifier("now_playing_close")

                Spacer()

                Button(action: openQueue) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Queue")
                .accessibilityIdentifier("now_playing_queue")
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
        .onDrop(of: [.fileURL], isTargeted: $isLyricDropTargeted) { providers in
            for provider in providers {
                provider.loadFileRepresentation(forTypeIdentifier: "public.file-url") { url, error in
                    guard let url = url, error == nil else { return }
                    Task { await handleDroppedLyricFile(url) }
                }
            }
            return true
        }
        .fullScreenCover(isPresented: $showFullscreenVideo) {
            if let player = videoPlayer {
                FullscreenVideoPlayer(player: player)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .compatibleHiddenDarkNavigationChrome()
        .compatibleNavigationDestination(isPresented: $isLyricsExpanded) {
            expandedLyricsPage
        }
        .animation(.easeInOut(duration: 0.7), value: videoBackdropSampler.paletteVersion)
        .confirmationDialog("Lyrics Dropped", isPresented: $showLyricDropChoice, presenting: pendingMovedLyricURL) { _ in
            Button("Leave in Lyrics Folder") { pendingMovedLyricURL = nil; pendingLyricTargetSongID = nil }
            Button("Assign to Current Song") { Task { await assignPendingLyricToCurrentSong() } }
            Button("Cancel", role: .cancel) { pendingMovedLyricURL = nil; pendingLyricTargetSongID = nil }
        } message: { _ in Text("The lyric file was moved to the Lyrics folder. Choose whether to attach it to the currently playing song.") }
        .alert("Lyrics", isPresented: $showLyricDropInfo) {
            Button("OK", role: .cancel) { }
        } message: { Text(lyricDropInfoMessage ?? "") }
        .onAppear {
            updateVideoBackdropSampler()
        }
        .onDisappear {
            videoBackdropSampler.stop()
        }
        .onChange(of: vm.item?.id) { _ in
            isLyricsExpanded = false
            showFullscreenVideo = false
            lyricsAutoScrollEnabled = true
            lyricsScrollOffsetY = 0
            updateVideoBackdropSampler()
        }
        .onChange(of: vm.playback.isPlaying) { _ in
            updateVideoBackdropSampler()
        }
        .onChange(of: batterySaver.effectiveSaver) { _ in
            updateVideoBackdropSampler()
        }
        .onChange(of: vm.lyricsLines.isEmpty) { isEmpty in
            if isEmpty {
                isLyricsExpanded = false
                lyricsAutoScrollEnabled = true
            }
        }
    }

    private func closeNowPlaying() {
        if router.sheet != nil {
            router.dismissSheet()
        } else {
            router.pop()
        }
    }

    private func openQueue() {
        if router.sheet != nil {
            router.present(.queue)
        } else {
            router.push(.queue)
        }
    }

    private func updateVideoBackdropSampler() {
        videoBackdropSampler.configure(
            player: videoPlayer,
            itemID: vm.item?.id,
            isVideo: vm.item?.isVideo == true,
            isEnabled: vm.playback.isPlaying && !batterySaver.effectiveSaver
        )
    }

    @ViewBuilder
    private var nowPlayingControls: some View {
        if usesCompactRootChrome {
            VStack(spacing: 18) {
                mediaCover
                nowPlayingDetails
            }
            .frame(maxWidth: .infinity, alignment: .top)
        } else {
            VStack(spacing: 24) {
                mediaCover
                nowPlayingDetails
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var nowPlayingDetails: some View {
        let detailSpacing: CGFloat = usesCompactRootChrome ? 18 : 24
        let controlSpacing: CGFloat = usesCompactRootChrome ? 20 : 30
        let secondaryButtonSize: CGFloat = usesCompactRootChrome ? 32 : 36
        let primaryButtonSize: CGFloat = usesCompactRootChrome ? 62 : 72
        let primaryIconSize: CGFloat = usesCompactRootChrome ? 27 : 30

        return VStack(spacing: detailSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.item?.title ?? (vm.playback.isPlaying ? "" : "Not Playing"))
                    .font((usesCompactRootChrome ? Font.title3 : Font.title2).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let artist = vm.item?.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
                    let artistNames = displayArtistNames(for: artist)
                    InlineArtistLinks(artistNames: artistNames) { name in
                        router.push(.artist(name: name))
                    }
                }
            }
            .padding(.trailing, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if vm.item != nil {
                    Button {
                        Task { await toggleCurrentFavorite() }
                    } label: {
                        Image(systemName: isCurrentFavorite ? "star.fill" : "star")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(isCurrentFavorite ? .yellow : .white.opacity(0.84))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCurrentFavorite ? "Remove Favorite" : "Add Favorite")
                }
            }

            VStack(spacing: 0) {
                NowPlayingSeekBar(
                    progress: progress,
                    durationMs: vm.playback.durationMs,
                    onSeek: { newProgress in
                        if let duration = vm.playback.durationMs {
                            Task { await vm.seek(toMs: Int(newProgress * CGFloat(duration))) }
                        }
                    },
                    onDragChanged: { dragging, previewMs in
                        seekPreviewMs = dragging ? previewMs : nil
                    }
                )
                HStack {
                    Text(seekPreviewText ?? elapsedText)
                    Spacer()
                    Button {
                        toggleRightTimeDisplay()
                    } label: {
                        Text(rightTimeText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settingsStore.nowPlayingShowsTotalDuration ? "Show remaining time" : "Show total duration")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.top, 0)

            HStack(spacing: controlSpacing) {
                NowPlayingSecondaryControlButton(systemName: "shuffle", frameSize: secondaryButtonSize, isActive: vm.playback.shuffleEnabled) {
                    Task { await vm.toggleShuffle() }
                }
                NowPlayingSecondaryControlButton(systemName: "backward.fill", size: usesCompactRootChrome ? 23 : 25, frameSize: secondaryButtonSize) {
                    Task { await vm.prev() }
                }
                Button {
                    Task { await vm.playPause() }
                } label: {
                    Image(systemName: vm.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: primaryIconSize, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: primaryButtonSize, height: primaryButtonSize)
                }
                .buttonStyle(.plain)
                NowPlayingSecondaryControlButton(systemName: "forward.fill", size: usesCompactRootChrome ? 23 : 25, frameSize: secondaryButtonSize) {
                    Task { await vm.next() }
                }
                NowPlayingSecondaryControlButton(systemName: vm.playback.repeatMode == .one ? "repeat.1" : "repeat", frameSize: secondaryButtonSize, isActive: vm.playback.repeatMode != .off) {
                    Task { await vm.toggleRepeat() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, usesCompactRootChrome ? 2 : 6)
        }
    }

    @ViewBuilder
    private var mediaCover: some View {
        Group {
            if vm.item?.isVideo == true {
                ZStack {
                    Color.black
                    if let player = videoPlayer {
                        InlineVideoPlayer(player: player)
                    } else {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 54, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .onTapGesture(count: 2) {
                    if videoPlayer != nil {
                        showFullscreenVideo = true
                    }
                }
                .accessibilityLabel("Fullscreen Video")
                .accessibilityAddTraits(.isButton)
            } else if let image = vm.artwork {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
            } else if let path = vm.item?.id, let cached = artworkCache.image(for: path) {
                Image(uiImage: cached)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.14))
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.24), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 16)
        .frame(maxWidth: usesCompactRootChrome ? 200 : 340, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
        .onReceive(NotificationCenter.default.publisher(for: .medioArtworkCacheDidChange)) { notification in
            guard notification.userInfo?["path"] as? String == vm.item?.id else { return }
            artworkRevision &+= 1
        }
    }

    private var compactLyricsWindowHeight: CGFloat {
        max(230, compactLyricFontSize * 10.6)
    }

    private var lyricsPreviewWindow: some View {
        lyricsScroller(mode: .compact)
            .frame(height: compactLyricsWindowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .ultraThinMaterial,
                in: .rect(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
            .accessibilityLabel("Lyrics Preview")
    }

    private var expandedLyricsPage: some View {
        ZStack {
            NowPlayingBackdrop(colors: backdropColors, scrollOffset: lyricsScrollOffsetY)
                .ignoresSafeArea()

            Color.black.opacity(0.28)
                .ignoresSafeArea()

            lyricsScroller(mode: .expanded)
                .padding(.top, 8)
                .padding(.horizontal, 0)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .compatibleHiddenDarkNavigationChrome()
        .onDisappear {
            lyricsAutoScrollEnabled = true
        }
    }

    private func lyricsScroller(mode: LyricsDisplayMode) -> some View {
        let coordinateSpaceName = mode == .expanded ? "expanded-lyrics-scroll" : "compact-lyrics-scroll"
        return ScrollViewReader { lyricsProxy in
            ScrollView(showsIndicators: mode == .expanded) {
                if mode == .expanded {
                    GeometryReader { markerProxy in
                        Color.clear.preference(
                            key: NowPlayingLyricsScrollOffsetPreferenceKey.self,
                            value: markerProxy.frame(in: .named(coordinateSpaceName)).minY
                        )
                    }
                    .frame(height: 0)
                }

                LazyVStack(alignment: .leading, spacing: mode == .compact ? 5 : 10) {
                    lyricRows(lyricsProxy: lyricsProxy, mode: mode)
                }
                .padding(.horizontal, mode == .compact ? 14 : 0)
                .padding(.vertical, mode == .compact ? 16 : 10)
            }
            .coordinateSpace(name: coordinateSpaceName)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in
                        if mode == .compact {
                            expandLyricsFromPreview()
                        } else {
                            lyricsAutoScrollEnabled = false
                        }
                    }
            )
            .onAppear { centerActiveLyric(in: lyricsProxy, animated: false) }
            .onChange(of: vm.activeLyricLineIndex) { _ in centerActiveLyric(in: lyricsProxy, animated: true) }
            .onChange(of: vm.lyricsLines) { _ in centerActiveLyric(in: lyricsProxy, animated: false) }
            .onPreferenceChange(NowPlayingLyricsScrollOffsetPreferenceKey.self) { offset in
                if mode == .expanded {
                    lyricsScrollOffsetY = offset
                }
            }
        }
    }

    @ViewBuilder
    private func lyricRows(lyricsProxy: ScrollViewProxy, mode: LyricsDisplayMode) -> some View {
        ForEach(Array(vm.lyricsLines.enumerated()), id: \.offset) { index, line in
            let isActiveLine = vm.activeLyricLineIndex == index
            let hasTimestamp = vm.timestampForLyricLine(index) != nil
            let hasExplicitEnd = vm.lyricLineHasExplicitEnd(index)
            let lineProgress = isActiveLine ? vm.lyricProgressForLine(index) : 0

            if let gapMs = parsePauseMs(line) {
                let noteCount = pauseNoteCount(for: gapMs)
                SmoothTimedPauseNotes(
                    symbols: (0..<noteCount).map { pauseNoteSymbol(lineIndex: index, noteIndex: $0) },
                    progress: isActiveLine ? lineProgress : 0,
                    fontSize: mode == .compact ? 19 : 24
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, mode == .compact ? 12 : 22)
                .padding(.vertical, mode == .compact ? 8 : 12)
                .id(index)
            } else {
                lyricLineView(
                    line: line,
                    isActiveLine: isActiveLine,
                    hasExplicitEnd: hasExplicitEnd,
                    lineProgress: lineProgress,
                    mode: mode
                )
                .padding(.horizontal, mode == .compact ? 12 : 22)
                .padding(.vertical, lyricRowVerticalPadding(isActiveLine: isActiveLine, hasExplicitEnd: hasExplicitEnd, mode: mode))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .id(index)
                .animation(.interactiveSpring(response: 0.56, dampingFraction: 0.86, blendDuration: 0.08), value: isActiveLine)
                .onTapGesture {
                    if hasTimestamp, let timestamp = vm.timestampForLyricLine(index) {
                        Task { await vm.seek(toMs: timestamp) }
                        lyricsAutoScrollEnabled = true
                    } else if isActiveLine {
                        lyricsAutoScrollEnabled = true
                        centerActiveLyric(in: lyricsProxy, animated: true)
                    }
                }
            }
        }
    }

    private func lyricRowVerticalPadding(isActiveLine: Bool, hasExplicitEnd: Bool, mode: LyricsDisplayMode) -> CGFloat {
        if isActiveLine {
            if mode == .compact {
                return hasExplicitEnd ? 14 : 10
            }
            return hasExplicitEnd ? 18 : 14
        }
        return mode == .compact ? 4 : 7
    }

    @ViewBuilder
    private func lyricLineView(line: String, isActiveLine: Bool, hasExplicitEnd: Bool, lineProgress: CGFloat, mode: LyricsDisplayMode) -> some View {
        let fontSize = mode == .compact ? compactLyricFontSize : (isActiveLine ? activeLyricFontSize : inactiveLyricFontSize)
        WrappingProgressiveLyricLine(
            line: line,
            progress: isActiveLine ? lineProgress : 0,
            fontSize: fontSize,
            isActiveLine: isActiveLine,
            inactiveOpacity: mode == .compact ? 0.42 : 0.30,
            blurRadius: isActiveLine ? 0 : (mode == .compact ? 0 : 0.45),
            scale: isActiveLine ? 1 : (mode == .compact ? 0.98 : 0.95),
            animationKey: isActiveLine,
            usesTimedSpacing: hasExplicitEnd
        )
    }

    private func expandLyricsFromPreview() {
        guard !isLyricsExpanded, !vm.lyricsLines.isEmpty else { return }
        lyricsAutoScrollEnabled = true
        withAnimation(.interactiveSpring(response: 0.48, dampingFraction: 0.9, blendDuration: 0.08)) {
            isLyricsExpanded = true
        }
    }

    private func formattedTime(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(seconds < 10 ? "0\(seconds)" : "\(seconds)")"
    }

    private func displayArtistNames(for artist: String) -> [String] {
        let splitNames = BuildLibraryIndexUseCase.splitArtistNames(artist)
        guard splitNames.count > 1 else { return splitNames.isEmpty ? [artist] : splitNames }
        if libraryStore.artists.contains(where: { $0.name.caseInsensitiveCompare(artist) == .orderedSame }) {
            return [artist]
        }
        return splitNames
    }

    private func centerActiveLyric(in proxy: ScrollViewProxy, animated: Bool) {
        guard lyricsAutoScrollEnabled, let activeIndex = vm.activeLyricLineIndex else { return }
        if animated {
            withAnimation(.interactiveSpring(response: 0.62, dampingFraction: 0.86, blendDuration: 0.12)) {
                proxy.scrollTo(activeIndex, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    private func toggleCurrentFavorite() async {
        guard let path = vm.item?.id else { return }
        await libraryStore.toggleFavorite(path, favoritesRepository: favoritesRepository)
    }

    private func toggleRightTimeDisplay() {
        settingsStore.nowPlayingShowsTotalDuration.toggle()
    }

    private func handleDroppedLyricFile(_ sourceURL: URL) async {
        let ext = sourceURL.pathExtension.lowercased()
        let supported = ["lrc", "srt", "ttml", "ttlm", "txt", "xml"]
        guard supported.contains(ext) else { return }
        do {
            let movedURL = try await moveLyricsFileToManagedFolder(from: sourceURL)
            await MainActor.run {
                pendingMovedLyricURL = movedURL
                pendingLyricTargetSongID = vm.item?.id
                if pendingLyricTargetSongID != nil {
                    showLyricDropChoice = true
                } else {
                    pendingMovedLyricURL = nil
                    pendingLyricTargetSongID = nil
                }
            }
        } catch {
            await MainActor.run {
                lyricDropInfoMessage = "Failed to move lyrics: \(error.localizedDescription)"
                showLyricDropInfo = true
                pendingMovedLyricURL = nil
                pendingLyricTargetSongID = nil
            }
        }
    }

    private func assignPendingLyricToCurrentSong() async {
        guard let movedURL = pendingMovedLyricURL, let targetSongID = pendingLyricTargetSongID else {
            await MainActor.run { pendingMovedLyricURL = nil; pendingLyricTargetSongID = nil }
            return
        }
        let existing = container.lyricsFileAssociationRepository.getAssociatedLyricsFile(forMediaPath: targetSongID)
        guard existing == nil else {
            await MainActor.run {
                lyricDropInfoMessage = "Files support only one lyric file. Your file was moved to Documents/Medio/Lyrics."
                showLyricDropInfo = true
                pendingMovedLyricURL = nil
                pendingLyricTargetSongID = nil
            }
            return
        }
        do {
            try await container.lyricsFileAssociationRepository.setAssociatedLyricsFile(movedURL.path, forMediaPath: targetSongID)
            await MainActor.run {
                vm.refreshLyrics()
                pendingMovedLyricURL = nil
                pendingLyricTargetSongID = nil
            }
        } catch {
            await MainActor.run {
                lyricDropInfoMessage = "Failed to assign lyrics: \(error.localizedDescription)"
                showLyricDropInfo = true
                pendingMovedLyricURL = nil
                pendingLyricTargetSongID = nil
            }
        }
    }
}

private struct WrappingProgressiveLyricLine: View {
    let line: String
    let progress: CGFloat
    let fontSize: CGFloat
    let isActiveLine: Bool
    let inactiveOpacity: Double
    let blurRadius: CGFloat
    let scale: CGFloat
    let animationKey: Bool
    let usesTimedSpacing: Bool

    private var clampedProgress: CGFloat {
        min(max(progress, 0), 1)
    }

    private var estimatedLineHeight: CGFloat {
        fontSize * (usesTimedSpacing ? 1.18 : 1.16) + 2
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            lyricText(opacity: isActiveLine ? 0.30 : inactiveOpacity)
            if isActiveLine {
                lyricText(opacity: 1)
                    .mask {
                        MultilineLyricProgressMask(progress: clampedProgress, estimatedLineHeight: estimatedLineHeight)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.interactiveSpring(response: 0.42, dampingFraction: 0.9, blendDuration: 0.08), value: clampedProgress)
        .blur(radius: blurRadius)
        .scaleEffect(scale, anchor: .leading)
        .animation(.interactiveSpring(response: 0.56, dampingFraction: 0.86, blendDuration: 0.08), value: animationKey)
    }

    private func lyricText(opacity: Double) -> some View {
        Text(line)
            .font(.system(size: fontSize, weight: .heavy))
            .foregroundStyle(.white.opacity(opacity))
            .lineSpacing(2)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmoothTimedPauseNotes: View {
    let symbols: [String]
    let progress: CGFloat
    var fontSize: CGFloat = 18

    private var clampedProgress: CGFloat {
        min(max(progress, 0), 1)
    }

    var body: some View {
        noteStack(opacity: 0.35)
            .overlay {
                noteStack(opacity: 1)
                    .mask {
                        SmoothLyricProgressMask(progress: clampedProgress)
                    }
            }
            .animation(.interactiveSpring(response: 0.42, dampingFraction: 0.9, blendDuration: 0.08), value: clampedProgress)
    }

    private func noteStack(opacity: Double) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Image(systemName: symbol)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(opacity))
            }
        }
    }
}

private struct SmoothLyricProgressMask: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width)
            let clamped = min(max(progress, 0), 1)
            let fadeWidth = min(72, max(24, width * 0.18))
            let progressWidth = width * clamped
            let solidWidth = min(max(progressWidth - fadeWidth * 0.45, 0), width)
            let remainingWidth = max(width - solidWidth, 0)
            let actualFadeWidth = min(fadeWidth, remainingWidth)

            if clamped <= 0.001 {
                Color.clear
            } else if clamped >= 0.999 {
                Color.white
            } else {
                HStack(spacing: 0) {
                    Color.white
                        .frame(width: solidWidth)
                    LinearGradient(
                        colors: [.white, .white.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: actualFadeWidth)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct MultilineLyricProgressMask: View {
    let progress: CGFloat
    let estimatedLineHeight: CGFloat

    private var clampedProgress: CGFloat {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let lineHeight = max(1, estimatedLineHeight)
            let rowCount = max(1, Int(ceil(max(geo.size.height, lineHeight) / lineHeight)))
            let progressedRows = clampedProgress * CGFloat(rowCount)
            let fullRows = min(rowCount, Int(floor(progressedRows)))
            let activeRowProgress = min(max(progressedRows - CGFloat(fullRows), 0), 1)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { row in
                    rowMask(row: row, fullRows: fullRows, activeRowProgress: activeRowProgress, width: geo.size.width)
                        .frame(height: rowHeight(row: row, totalHeight: geo.size.height, lineHeight: lineHeight))
                }
            }
        }
    }

    @ViewBuilder
    private func rowMask(row: Int, fullRows: Int, activeRowProgress: CGFloat, width: CGFloat) -> some View {
        if row < fullRows {
            Color.white
        } else if row == fullRows, activeRowProgress > 0 {
            HStack(spacing: 0) {
                Color.white
                    .frame(width: max(0, width * activeRowProgress))
                Spacer(minLength: 0)
            }
        } else {
            Color.clear
        }
    }

    private func rowHeight(row: Int, totalHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let consumed = CGFloat(row) * lineHeight
        return min(lineHeight, max(0, totalHeight - consumed))
    }
}

private final class PlayerLayerHostingView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }
}

private struct InlineVideoPlayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostingView {
        let view = PlayerLayerHostingView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHostingView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspect
        uiView.backgroundColor = .black
    }
}

@MainActor
private final class VideoFrameBackdropSampler: ObservableObject {
    @Published private(set) var colors: [UIColor] = []
    @Published private(set) var paletteVersion = 0

    private weak var player: AVPlayer?
    private weak var observedItem: AVPlayerItem?
    private var itemID: String?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var samplingTask: Task<Void, Never>?
    private var lastSignature: VideoFrameColorSignature?

    func configure(player: AVPlayer?, itemID: String?, isVideo: Bool, isEnabled: Bool) {
        guard isEnabled, isVideo, let player, let itemID else {
            stop()
            return
        }

        if let currentPlayer = self.player,
           currentPlayer === player,
           self.itemID == itemID,
           samplingTask != nil {
            return
        }

        stop(clearColors: false)
        self.player = player
        self.itemID = itemID
        colors = []
        paletteVersion += 1
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    self.sampleCurrentFrame()
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        stop(clearColors: true)
    }

    deinit {
        samplingTask?.cancel()
    }

    private func stop(clearColors: Bool) {
        samplingTask?.cancel()
        samplingTask = nil
        detachVideoOutput()
        player = nil
        itemID = nil
        lastSignature = nil
        if clearColors, !colors.isEmpty {
            colors = []
            paletteVersion += 1
        }
    }

    private func sampleCurrentFrame() {
        guard let player else {
            stop()
            return
        }
        guard let currentItem = player.currentItem else {
            detachVideoOutput()
            return
        }

        if observedItem !== currentItem {
            attachVideoOutput(to: currentItem)
        }

        guard let videoOutput else { return }
        let hostTime = CACurrentMediaTime()
        let outputTime = videoOutput.itemTime(forHostTime: hostTime)
        let sampleTime = outputTime.isNumeric ? outputTime : player.currentTime()
        guard sampleTime.isNumeric,
              videoOutput.hasNewPixelBuffer(forItemTime: sampleTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: sampleTime, itemTimeForDisplay: nil),
              let palette = Self.palette(from: pixelBuffer) else {
            return
        }

        apply(palette)
    }

    private func attachVideoOutput(to item: AVPlayerItem) {
        detachVideoOutput()
        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
        observedItem = item
        videoOutput = output
        lastSignature = nil
    }

    private func detachVideoOutput() {
        if let videoOutput, let observedItem {
            observedItem.remove(videoOutput)
        }
        videoOutput = nil
        observedItem = nil
    }

    private func apply(_ palette: VideoFramePalette) {
        if let lastSignature,
           palette.signature.distance(to: lastSignature) < 0.18 {
            return
        }
        lastSignature = palette.signature
        colors = palette.colors
        paletteVersion += 1
    }

    private static func palette(from pixelBuffer: CVPixelBuffer) -> VideoFramePalette? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let sampleColumns = min(width, 18)
        let sampleRows = min(height, 18)
        var buckets: [Int: VideoPaletteBucket] = [:]

        for row in 0..<sampleRows {
            let y = min(height - 1, Int((CGFloat(row) + 0.5) * CGFloat(height) / CGFloat(sampleRows)))
            let rowPointer = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)

            for column in 0..<sampleColumns {
                let x = min(width - 1, Int((CGFloat(column) + 0.5) * CGFloat(width) / CGFloat(sampleColumns)))
                let offset = x * 4
                let blue = CGFloat(rowPointer[offset]) / 255.0
                let green = CGFloat(rowPointer[offset + 1]) / 255.0
                let red = CGFloat(rowPointer[offset + 2]) / 255.0
                let alpha = CGFloat(rowPointer[offset + 3]) / 255.0
                guard alpha > 0.2 else { continue }

                let maxComponent = max(red, green, blue)
                let minComponent = min(red, green, blue)
                let brightness = maxComponent
                let saturation = maxComponent == 0 ? 0 : (maxComponent - minComponent) / maxComponent
                let bucketRed = min(7, max(0, Int((red * 7).rounded())))
                let bucketGreen = min(7, max(0, Int((green * 7).rounded())))
                let bucketBlue = min(7, max(0, Int((blue * 7).rounded())))
                let key = (bucketRed << 8) | (bucketGreen << 4) | bucketBlue
                var bucket = buckets[key] ?? VideoPaletteBucket()
                let weight = 0.3 + saturation + (1 - abs(brightness - 0.52))
                bucket.red += red * weight
                bucket.green += green * weight
                bucket.blue += blue * weight
                bucket.weight += weight
                bucket.score += weight * (0.55 + saturation)
                buckets[key] = bucket
            }
        }

        guard let bestBucket = buckets.values.max(by: { $0.score < $1.score }),
              bestBucket.weight > 0 else {
            return nil
        }

        let red = bestBucket.red / bestBucket.weight
        let green = bestBucket.green / bestBucket.weight
        let blue = bestBucket.blue / bestBucket.weight
        return VideoFramePalette(
            colors: backdropColors(red: red, green: green, blue: blue),
            signature: VideoFrameColorSignature(red: red, green: green, blue: blue)
        )
    }

    private static func backdropColors(red: CGFloat, green: CGFloat, blue: CGFloat) -> [UIColor] {
        let dominant = UIColor(red: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        guard dominant.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return [
                UIColor(red: red, green: green, blue: blue, alpha: 1),
                UIColor(red: red * 0.72, green: green * 0.72, blue: blue * 0.72, alpha: 1),
                UIColor(red: red * 0.48, green: green * 0.48, blue: blue * 0.48, alpha: 1)
            ]
        }

        let backdropSaturation = saturation < 0.08 ? saturation : max(saturation, 0.22)
        let backdropBrightness = min(max(brightness, 0.16), 0.72)
        let base = UIColor(hue: hue, saturation: backdropSaturation, brightness: backdropBrightness, alpha: 1)
        return [
            adjustedColor(base, brightnessDelta: 0.08),
            adjustedColor(base, brightnessDelta: -0.18),
            adjustedColor(base, brightnessDelta: -0.42)
        ]
    }

    private static func adjustedColor(_ color: UIColor, brightnessDelta: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return color
        }
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: min(max(brightness + brightnessDelta, 0), 1),
            alpha: alpha
        )
    }
}

private struct VideoFramePalette {
    let colors: [UIColor]
    let signature: VideoFrameColorSignature
}

private struct VideoFrameColorSignature {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    func distance(to other: VideoFrameColorSignature) -> CGFloat {
        let redDelta = red - other.red
        let greenDelta = green - other.green
        let blueDelta = blue - other.blue
        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }
}

private struct VideoPaletteBucket {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var weight: CGFloat = 0
    var score: CGFloat = 0
}

private struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
    }
}

private struct FullscreenVideoPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let player: AVPlayer

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SystemVideoPlayer(player: player)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Fullscreen Video")
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct InlineArtistLinks: View {
    let artistNames: [String]
    let onSelect: (String) -> Void

    var body: some View {
        Text(attributedArtistLine)
            .font(.headline.weight(.regular))
            .foregroundStyle(.white.opacity(0.82))
            .tint(.white.opacity(0.82))
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard let artistName = artistName(from: url) else { return .systemAction }
                onSelect(artistName)
                return .handled
            })
    }

    private var attributedArtistLine: AttributedString {
        var result = AttributedString()
        for (index, name) in artistNames.enumerated() {
            var chunk = AttributedString(index < artistNames.count - 1 ? "\(name), " : name)
            chunk.link = artistURL(for: name)
            result += chunk
        }
        return result
    }

    private func artistURL(for name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "medio-artist"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    private func artistName(from url: URL) -> String? {
        guard url.scheme == "medio-artist",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }
}

private struct NowPlayingBackdrop: View {
    let colors: [Color]
    var scrollOffset: CGFloat = 0
    private var first: Color { colors.first ?? Color(red: 0.18, green: 0.18, blue: 0.22) }
    private var second: Color { colors.dropFirst().first ?? Color.black }
    private var third: Color { colors.dropFirst(2).first ?? second }

    private var scrollDistance: CGFloat {
        min(max(-scrollOffset, 0), 1_000)
    }

    private var pullDistance: CGFloat {
        min(max(scrollOffset, 0), 220)
    }

    private var scrollProgress: CGFloat {
        min(scrollDistance / 360, 1)
    }

    private var pullProgress: CGFloat {
        min(pullDistance / 180, 1)
    }

    var body: some View {
        let progress = scrollProgress
        let pull = pullProgress
        ZStack {
            LinearGradient(
                colors: [first, second, Color.black.opacity(0.95)],
                startPoint: UnitPoint(x: 0.02 + progress * 0.34 - pull * 0.08, y: 0),
                endPoint: UnitPoint(x: 1 - progress * 0.2 + pull * 0.05, y: 1 - progress * 0.28)
            )
            LinearGradient(
                colors: [third.opacity(0.58), first.opacity(0.18), .clear],
                startPoint: UnitPoint(x: 0.1 + progress * 0.48, y: -0.08 + pull * 0.08),
                endPoint: UnitPoint(x: 0.94 - progress * 0.28, y: 1.04)
            )
            .blendMode(.screen)
            .opacity(0.34 + progress * 0.26)
            .offset(y: -scrollDistance * 0.18 + pullDistance * 0.08)
            .scaleEffect(1 + progress * 0.08 + pull * 0.04)
            RadialGradient(
                colors: [third.opacity(0.48 + progress * 0.18), .clear],
                center: UnitPoint(x: 0.88 - progress * 0.32 + pull * 0.08, y: 0.08 + progress * 0.44),
                startRadius: 24,
                endRadius: 460 + progress * 140
            )
            .offset(x: -scrollDistance * 0.05, y: scrollOffset * 0.22)
            LinearGradient(
                colors: [.black.opacity(0.08 + progress * 0.12), .black.opacity(0.5 + progress * 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .hueRotation(.degrees(Double((scrollDistance - pullDistance) * 0.012)))
        .saturation(1 + progress * 0.16)
    }
}

private struct NowPlayingSecondaryControlButton: View {
    let systemName: String
    var size: CGFloat = 20
    var frameSize: CGFloat = 36
    var isActive: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? .pink : Color.white.opacity(0.9))
                .frame(width: frameSize, height: frameSize)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
    }
}

// Helper function used in NowPlayingPanel
private func moveLyricsFileToManagedFolder(from sourceURL: URL) async throws -> URL {
    let ext = sourceURL.pathExtension.lowercased()
    let supported = ["lrc", "srt", "ttml", "ttlm", "txt", "xml"]
    guard supported.contains(ext) else {
        throw NSError(domain: "LyricsImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported lyrics format"])
    }
    let fileManager = FileManager.default
    let lyricsDir = try LyricsManagedStorage.ensureLyricsDirectoryExists(fileManager: fileManager)
    let destName = sourceURL.lastPathComponent.isEmpty ? "lyrics.\(ext)" : sourceURL.lastPathComponent
    let destURL = lyricsDir.appendingPathComponent(destName)
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
    try await AppFileMutationCoordinator.shared.copyReplacingItem(at: sourceURL, to: destURL)
    return destURL
}

private func parsePauseMs(_ line: String) -> Int? {
    let prefix = "⟪pause:"
    let suffix = "⟫"
    guard line.hasPrefix(prefix) && line.hasSuffix(suffix) else { return nil }
    let inner = line.dropFirst(prefix.count).dropLast(suffix.count)
    return Int(inner)
}

private func pauseNoteCount(for gapMs: Int) -> Int {
    min(6, max(4, 4 + max(0, gapMs - 12_000) / 8_000))
}

private func pauseNoteSymbol(lineIndex: Int, noteIndex: Int) -> String {
    let seed = (lineIndex + 1) * 1_103_515_245 + (noteIndex + 7) * 12_345
    return seed.isMultiple(of: 2) ? "music.note" : "music.quarternote.3"
}
