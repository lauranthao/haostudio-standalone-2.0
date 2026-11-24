// HAo Studio 2.0 — video detail page (S3-C leg).
//
// Infuse style (Flutter video_detail_page.dart):
// - The top is a clean COVER: large backdrop with a gradient
//   fade-in animation. There is NO centre play button on the
//   cover — the old vodBigPlay is deleted, not hidden.
// - Playback starts from the big play button BELOW the cover
//   ("第01集" with a play.fill glyph, or "继续播放 · 第N集 · mm:ss" when a resume
//   position exists) and from the episode grid.
// - Cover + title appear instantly from the tapped item; play
//   lines fill in when the detail fetch resolves.
// - Douban is the sole metadata source (rating / cast /
//   synopsis). The synopsis is shown as returned; dedupe of a
//   repeated synopsis is the service leg's job.
// - The download button calls the gateway (B-leg DownloadEngine
//   at merge); favourites and resume are local (VideoLibraryStore).
//
// The play button uses the theme accent fill (the "big blue
// button" in the Flutter build is its theme accent; Swift themes
// carry black / gold / mint accents by design — no hardcoded blue).

import SwiftUI

/// Where a detail comes from: CMS detail (lines + Douban meta)
/// or Emby detail (streams as lines). The view model switches
/// its loader on this; the layout is identical.
enum VideoDetailSource {
    case cms
    case emby
}

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published private(set) var detail: VideoDetail?
    @Published private(set) var isLoading = true
    @Published private(set) var isFavourite = false
    @Published private(set) var resume: ResumeInfo?
    /// Whether this title has any watch history (S7 wiring: the
    /// spoiler blur never applies to watched titles). Refreshed
    /// on every load, so returning from the player un-blurs the
    /// cover without reopening the page.
    @Published private(set) var isWatched = false
    @Published var selectedLineIndex = 0
    @Published var selectedEpisodeIndex = 0
    @Published private(set) var downloadNote: String?

    let item: VideoItem
    private let gateway: VideoDataGateway
    private let source: VideoDetailSource

    init(
        item: VideoItem,
        source: VideoDetailSource = .cms,
        gateway: VideoDataGateway = VideoServices.makeGateway()
    ) {
        self.item = item
        self.source = source
        self.gateway = gateway
        self.isFavourite = VideoLibraryStore.isFavourite(item: item)
        self.resume = VideoLibraryStore.resumeInfo(title: item.title, year: item.year)
        self.isWatched = VideoLibraryStore.historyEntry(title: item.title, year: item.year) != nil
    }

    var lines: [PlayLine] { detail?.lines ?? [] }

    var selectedLine: PlayLine? {
        guard lines.indices.contains(selectedLineIndex) else { return nil }
        return lines[selectedLineIndex]
    }

    var selectedEpisode: PlayEpisode? {
        selectedLine?.episode(at: selectedEpisodeIndex)
    }

    /// The episode the play button opens: the resume episode when
    /// one exists on the current lines, else the first episode.
    var playEpisodeIndex: Int {
        guard let resume = resume, let line = selectedLine else { return 0 }
        if let index = line.episodes.firstIndex(where: { $0.name == resume.episodeName }) {
            return index
        }
        return 0
    }

    var playButtonLabel: String {
        guard let line = selectedLine, let episode = line.episode(at: playEpisodeIndex) else {
            return isLoading ? "加载中…" : "暂无可播剧集"
        }
        if let resume = resume, resume.episodeName == episode.name {
            return "继续播放 · \(episode.name) · \(videoTimeText(seconds: resume.positionSeconds))"
        }
        return episode.displayName
    }

    var canPlay: Bool { selectedEpisode != nil }

    func load() {
        isLoading = true
        let completion: (VideoDetail?) -> Void = { [weak self] loaded in
            guard let self = self else { return }
            self.isLoading = false
            self.detail = loaded
            self.isWatched = VideoLibraryStore.historyEntry(title: self.item.title, year: self.item.year) != nil
            if let resume = self.resume, let line = loaded?.firstPlayableLine {
                self.selectedLineIndex = loaded?.lines.firstIndex(where: { $0.id == line.id }) ?? 0
                if let index = line.episodes.firstIndex(where: { $0.name == resume.episodeName }) {
                    self.selectedEpisodeIndex = index
                }
            }
        }
        switch source {
        case .cms:
            gateway.fetchDetail(item: item, completion: completion)
        case .emby:
            gateway.fetchEmbyDetail(item: item, completion: completion)
        }
    }

    func toggleFavourite() {
        isFavourite = VideoLibraryStore.toggleFavourite(item: item)
        // Emby (build 36, item 13): mirror the tap to the server.
        // An explicit user action — never gated by the 数据上报
        // switch. Local state stays the source of truth for the
        // UI; a failed server call leaves it unchanged, and no
        // favourite state is ever faked. Non-Emby titles, an
        // empty id, and unconfigured servers no-op.
        if source == .emby, !item.id.isEmpty,
           let config = EmbyConfigStore.load(), config.isConfigured {
            EmbyClient(config: config).setFavorite(itemId: item.id, favorite: isFavourite) { _ in }
        }
    }

    /// Queue the selected episode for download. The result is a
    /// note, never a silent no-op.
    func downloadSelected() {
        guard let detail = detail, let line = selectedLine,
              let episode = selectedEpisode else { return }
        gateway.enqueueDownload(detail: detail, episode: episode, line: line) { [weak self] ok in
            self?.downloadNote = ok ? "已加入下载" : "下载暂不可用"
        }
    }

    func clearDownloadNote() {
        downloadNote = nil
    }
}

struct VideoDetailView: View {
    var item: VideoItem
    var source: VideoDetailSource = .cms

    @StateObject private var viewModel: VideoDetailViewModel
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel
    @State private var showingPlayer = false

    @Environment(\.haoTheme) private var theme

    init(item: VideoItem, source: VideoDetailSource = .cms) {
        self.item = item
        self.source = source
        _viewModel = StateObject(wrappedValue: VideoDetailViewModel(item: item, source: source))
    }

    var body: some View {
        ZStack {
            VideoDetailContentView(
                viewModel: viewModel,
                onPlay: { lineIndex, episodeIndex in
                    play(lineIndex: lineIndex, episodeIndex: episodeIndex)
                }
            )
            if let note = viewModel.downloadNote {
                VStack {
                    Spacer()
                    Text(note)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(.bottom, 90)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                viewModel.clearDownloadNote()
                            }
                        }
                }
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            VideoPlayerView()
        }
        .onAppear { viewModel.load() }
    }

    private func play(lineIndex: Int, episodeIndex: Int) {
        guard let detail = viewModel.detail else { return }
        // Keep the grid highlight on the episode actually played:
        // a grid tap used to open the episode without updating the
        // selection, so the highlight stayed on the old cell.
        viewModel.selectedLineIndex = lineIndex
        viewModel.selectedEpisodeIndex = episodeIndex
        videoPlayer.open(detail: detail, lineIndex: lineIndex, episodeIndex: episodeIndex)
        showingPlayer = true
    }
}

/// The detail layout, shared by the CMS detail page and the Emby
/// detail page (same cover, same button, same episode grid).
struct VideoDetailContentView: View {
    @ObservedObject var viewModel: VideoDetailViewModel
    var onPlay: (Int, Int) -> Void

    @Environment(\.haoTheme) private var theme
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var coverRevealed = false
    /// Spoiler reveals (S7 wiring): per detail load, never
    /// persisted — the next visit hides again (Flutter parity).
    @State private var spoilerSynopsisRevealed = false
    @State private var spoilerCoverRevealed = false

    /// Spoiler blur for this title's cover (Flutter detail-page
    /// parity: unwatched + switch on + not yet tapped).
    private var isCoverBlurred: Bool {
        spoilerCoverBlurred(blurUnwatched: settingsStore.blurUnwatchedPosters, watched: viewModel.isWatched, revealed: spoilerCoverRevealed)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                coverHeader
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    playButton
                    actionRow
                    if let meta = viewModel.detail?.meta {
                        metaBlock(meta)
                    }
                    if !viewModel.lines.isEmpty {
                        linePicker
                        episodeGrid
                    } else if !viewModel.isLoading {
                        MusicEmptyState(
                            icon: "film",
                            title: "暂无可播剧集",
                            note: "该片源没有返回播放线路，换个片源试试。"
                        )
                        // A failed detail fetch used to leave this
                        // state with no way back except leaving the
                        // page (load() only runs on appear).
                        Button(action: { viewModel.load() }) {
                            Text("重试")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.onAccent)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .haoBottomChromePadding()
        .background(theme.scaffoldBackground)
        .navigationTitle(viewModel.item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { coverRevealed = true }
        }
    }

    // MARK: - Cover (Infuse style, no play button on it)

    private var coverHeader: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = viewModel.item.coverURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure, .empty:
                            coverPlaceholder
                        @unknown default:
                            coverPlaceholder
                        }
                    }
                } else {
                    coverPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 264)
            .clipped()
            .opacity(coverRevealed ? 1 : 0)
            .blur(radius: isCoverBlurred ? 18 : 0)
            LinearGradient(
                colors: [
                    theme.scaffoldBackground.opacity(0),
                    theme.scaffoldBackground.opacity(0.55),
                    theme.scaffoldBackground,
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 264)
            // S7 wiring: spoiler blur — an unwatched title's cover
            // is blurred until tapped (watched titles are never
            // blurred; the cover is the only thumbnail that
            // exists to blur).
            if isCoverBlurred {
                Button(action: { spoilerCoverRevealed = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.system(size: 14, weight: .semibold))
                        Text("点按查看海报")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var coverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: 40))
                    .foregroundStyle(theme.textMuted)
            }
    }

    // MARK: - Title / meta

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.item.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 8) {
                if let year = viewModel.item.year, !year.isEmpty {
                    Text(year)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }
                if let type = viewModel.item.typeName, !type.isEmpty {
                    Text(type)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }
                if let remarks = viewModel.item.remarks, !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            if let rating = viewModel.detail?.meta?.rating {
                // VidHub-style rating row: star + number, accent,
                // with the source named honestly — Douban is the
                // sole metadata source, so no other rating is shown.
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 16, weight: .bold))
                    Text("豆瓣评分")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textMuted)
                }
                .foregroundStyle(theme.accent)
            }
        }
    }

    // MARK: - Big play button (below the cover, never on it)

    private var playButton: some View {
        Button(action: {
            onPlay(viewModel.selectedLineIndex, viewModel.playEpisodeIndex)
        }) {
            HStack(spacing: 8) {
                Spacer()
                // SF Symbol, not the "▶" text glyph (build-35
                // polish: unicode glyphs are not an icon system).
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(viewModel.playButtonLabel)
                    .font(.system(size: 17, weight: .bold))
                Spacer()
            }
            .foregroundStyle(theme.onAccent)
            .padding(.vertical, 16)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPlay)
        .opacity(viewModel.canPlay ? 1 : 0.5)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.toggleFavourite() }) {
                Label(
                    viewModel.isFavourite ? "已收藏" : "收藏",
                    systemImage: viewModel.isFavourite ? "heart.fill" : "heart"
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: { viewModel.downloadSelected() }) {
                Label("下载", systemImage: "arrow.down.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(theme.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPlay)
            .opacity(viewModel.canPlay ? 1 : 0.5)
            Spacer()
        }
    }

    private func metaBlock(_ meta: VideoMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !meta.cast.isEmpty {
                Text(meta.cast.joined(separator: " / "))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
            if let synopsis = meta.synopsis, !synopsis.isEmpty {
                // S7 wiring: spoiler hide — the synopsis is
                // replaced by a placeholder until tapped (per
                // detail load; the reveal never persists).
                if spoilerSynopsisHidden(hideSynopsis: settingsStore.hideSynopsis, revealed: spoilerSynopsisRevealed) {
                    Button(action: { spoilerSynopsisRevealed = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 14))
                            Text("简介已隐藏（防剧透），点按查看")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(synopsis)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                        .lineSpacing(4)
                        .lineLimit(6)
                }
            }
        }
    }

    // MARK: - Lines + episodes

    private var linePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.lines.enumerated()), id: \.element.id) { index, line in
                        Button(action: {
                            viewModel.selectedLineIndex = index
                            viewModel.selectedEpisodeIndex = 0
                        }) {
                            Text(line.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(
                                    index == viewModel.selectedLineIndex
                                        ? theme.onAccent : theme.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    index == viewModel.selectedLineIndex
                                        ? theme.accent : theme.surface,
                                    in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选集")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                ForEach(Array((viewModel.selectedLine?.episodes ?? []).enumerated()), id: \.element.id) { index, episode in
                    Button(action: { onPlay(viewModel.selectedLineIndex, index) }) {
                        Text(episode.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                index == viewModel.selectedEpisodeIndex
                                    ? theme.onAccent : theme.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                index == viewModel.selectedEpisodeIndex
                                    ? theme.accent : theme.surface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(theme.hairline, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

extension PlayEpisode {
    /// Display name: the source name, or "正片" when empty
    /// (Flutter cms_client.dart), or "第N集" when there is no name
    /// at all.
    var displayName: String {
        if !name.isEmpty { return name }
        return "第\(index + 1)集"
    }
}
