// HAo Studio 2.0 — video detail page (S3-C leg).
//
// VidHub style (Flutter video_detail_page.dart):
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
    @Published var selectedLineIndex = 0 {
        didSet { refreshDownloadAvailability() }
    }
    @Published var selectedEpisodeIndex = 0 {
        didSet { refreshDownloadAvailability() }
    }
    @Published private(set) var downloadNote: String?
    /// Whether the selected episode can be downloaded (b49 sweep
    /// #8). nil = the resolve is still in flight (button disabled,
    /// not hidden — it pops in, never vanishes mid-tap); false =
    /// HLS / no URL / Emby (button hidden, page says HLS
    /// download is deferred instead of letting the tap fail).
    @Published private(set) var downloadAvailable: Bool?
    /// Key of the episode the last downloadability check ran for:
    /// selection churn during load() must not re-resolve the same
    /// episode twice.
    private var downloadCheckKey: String?
    /// Debounce work for the downloadability resolve (sweep-4
    /// P2-49): every line/episode tap fired a resolve and greyed
    /// the download button while it ran; rapid taps now settle
    /// for 0.35 s first and fire a single resolve.
    private var downloadResolveWork: DispatchWorkItem?
    /// Alternate CMS sources carrying this same title (sweep-2
    /// P1-8): the empty state used to say "换个片源试试" with
    /// nowhere to switch to. Loaded lazily when a CMS detail
    /// lands with no lines (or fails outright); empty = no other
    /// source has it.
    @Published private(set) var altSources: [AltVideoSource] = []
    /// The alternate-source search is in flight. While true the
    /// empty state says it is looking, instead of claiming no
    /// other source exists.
    @Published private(set) var altSourcesLoading = false
    /// Whether the resume selection has been applied for the
    /// current load (sweep-4 P1-23): the gateway publishes twice
    /// (CMS detail, then the Douban-merged detail), and the
    /// completion re-applied the resume selection on every
    /// publish — a user who changed episode/line between the
    /// two publishes was snapped back to the resume episode.
    /// Reset in load(); set only when a selection is actually
    /// applied, so a first publish with no lines at all retries
    /// on the second publish instead of giving up.
    private var didApplyResumeSelection = false

    /// The item this detail is for. `var`, not `let` (sweep-2
    /// P1-8): switching to an alternate source rebuilds it on
    /// the other source's vod id and reloads. Title/year/cover
    /// carry over, so the resume bookmark (keyed by title +
    /// year) still applies on the new source.
    private(set) var item: VideoItem
    private let gateway: VideoDataGateway
    /// Resolved in init: an explicit source wins, otherwise the
    /// item decides (VideoItem.detailSource — Emby items carry no
    /// CMS source id). Internal so the view's empty state can use
    /// source-aware copy.
    let source: VideoDetailSource

    init(
        item: VideoItem,
        source: VideoDetailSource? = nil,
        gateway: VideoDataGateway = VideoServices.makeGateway()
    ) {
        self.item = item
        self.source = source ?? item.detailSource
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
            if isLoading { return "加载中…" }
            // A film has no episodes: never show the series copy
            // ("剧集") for an Emby title that failed to load.
            return source == .emby ? "暂无可播内容" : "暂无可播剧集"
        }
        if let resume = resume, resume.episodeName == episode.name {
            // A single-episode line is a film (or a one-episode
            // item): the entry point is play, not an episode name.
            if line.episodes.count == 1 {
                return "继续播放 · \(videoTimeText(seconds: resume.positionSeconds))"
            }
            return "继续播放 · \(episode.name) · \(videoTimeText(seconds: resume.positionSeconds))"
        }
        if line.episodes.count == 1 {
            return "播放"
        }
        return episode.displayName
    }

    var canPlay: Bool { selectedEpisode != nil }

    /// Re-resolve the detail from the source, every time. The
    /// previous detail is dropped first, so a retry visibly
    /// re-fetches (loading state, then the fresh result) instead
    /// of re-rendering the same empty state — and a failed retry
    /// cannot leave a stale successful detail on screen.
    func load() {
        isLoading = true
        detail = nil
        downloadCheckKey = nil
        downloadAvailable = nil
        downloadResolveWork?.cancel()
        altSources = []
        altSourcesLoading = false
        didApplyResumeSelection = false
        let completion: (VideoDetail?) -> Void = { [weak self] loaded in
            guard let self = self else { return }
            self.isLoading = false
            self.detail = loaded
            let entry = VideoLibraryStore.historyEntry(title: self.item.title, year: self.item.year)
            self.isWatched = entry != nil
            // sweep-4 P1-23: apply the resume selection only on
            // the first publish that can actually apply one. The
            // gateway publishes twice; the second publish must
            // not snap a user-changed selection back.
            if !self.didApplyResumeSelection, let resume = self.resume, let loaded = loaded {
                // The resume episode may live on a later line
                // (Emby lines are seasons) — search all lines,
                // not just the first playable one. The recorded
                // line name disambiguates same-name episodes
                // across seasons.
                if let selection = VideoDetailRouting.resumeSelection(
                    lines: loaded.lines, resume: resume, lineName: entry?.lineName) {
                    self.selectedLineIndex = selection.lineIndex
                    self.selectedEpisodeIndex = selection.episodeIndex
                    self.didApplyResumeSelection = true
                } else if let line = loaded.firstPlayableLine {
                    self.selectedLineIndex = loaded.lines.firstIndex(where: { $0.id == line.id }) ?? 0
                    if let index = line.episodes.firstIndex(where: { $0.name == resume.episodeName }) {
                        self.selectedEpisodeIndex = index
                    }
                    self.didApplyResumeSelection = true
                }
            }
            // b49 sweep #8: resolve downloadability for the
            // selected episode (no-op when the selection didSet
            // already checked this exact episode — the key guard).
            self.refreshDownloadAvailability()
            // sweep-2 P1-8: no playable lines on a CMS title —
            // look for the same title on other sources, so the
            // "换个片源试试" line has somewhere to go.
            if self.source == .cms, loaded?.lines.isEmpty != false {
                self.loadAltSources()
            }
        }
        switch source {
        case .cms:
            gateway.fetchDetail(item: item, completion: completion)
        case .emby:
            gateway.fetchEmbyDetail(item: item, completion: completion)
        }
    }

    /// Re-read the local state only (favourite / resume / watched)
    /// without re-fetching the detail. Returning from the player
    /// only needs this: the old onAppear re-ran load(), which
    /// drops `detail` first — the episode grid vanished and the
    /// scroll position jumped to the top on every return. The
    /// resume re-read is what flips the play button to
    /// "继续播放 · …" after watching; isWatched re-read is what
    /// un-blurs a cover that was watched.
    func refreshLocalState() {
        isFavourite = VideoLibraryStore.isFavourite(item: item)
        resume = VideoLibraryStore.resumeInfo(title: item.title, year: item.year)
        isWatched = VideoLibraryStore.historyEntry(title: item.title, year: item.year) != nil
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

    /// Resolve whether the selected episode is downloadable and
    /// publish it (b49 sweep #8). Called when the detail lands
    /// and whenever the selection changes (didSet above). Emby
    /// never downloads (see downloadSelected) — no resolve is
    /// issued for it. The resolve is debounced (sweep-4 P2-49):
    /// rapid line/episode taps settle for 0.35 s first, so the
    /// button greys once instead of once per tap.
    func refreshDownloadAvailability() {
        downloadResolveWork?.cancel()
        guard source != .emby, let detail = detail,
              let line = selectedLine, let episode = selectedEpisode else {
            downloadAvailable = false
            return
        }
        let key = "\(detail.item.title)|\(line.name)|\(episode.name)"
        guard key != downloadCheckKey else { return }
        downloadCheckKey = key
        downloadAvailable = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.gateway.checkDownloadable(detail: detail, episode: episode, line: line) { [weak self] ok in
                guard let self = self, self.downloadCheckKey == key else { return }
                self.downloadAvailable = ok
            }
        }
        downloadResolveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Search other CMS sources for this same title (sweep-2
    /// P1-8). Runs only when the detail landed with no playable
    /// lines (or failed outright) — a title that plays needs no
    /// switcher. Guarded by the loading flag so the gateway's
    /// second publish does not start a second search.
    private func loadAltSources() {
        guard !altSourcesLoading else { return }
        altSourcesLoading = true
        gateway.altSources(title: item.title, year: item.year ?? "", excludeSourceId: item.sourceId ?? -1) { [weak self] alts in
            guard let self = self else { return }
            self.altSources = alts
            self.altSourcesLoading = false
        }
    }

    /// Switch the detail to an alternate source (sweep-2 P1-8):
    /// rebuild the item on the other source's vod id and reload.
    /// Title/year/cover carry over, so the resume bookmark
    /// (keyed by title + year) still applies on the new source.
    func switchToAltSource(_ alt: AltVideoSource) {
        item = VideoItem(
            id: alt.vodId, title: item.title, coverURL: item.coverURL,
            year: item.year, typeName: item.typeName, remarks: item.remarks,
            sourceId: alt.source)
        selectedLineIndex = 0
        selectedEpisodeIndex = 0
        load()
    }

    /// Queue the selected episode for download. The result is a
    /// note, never a silent no-op.
    func downloadSelected() {
        // Emby: video offline download is not built (no downloads
        // list, no offline playback — a downloaded file would sit
        // orphaned on disk), and the Emby stream URL carries the
        // server credential, which the download task index would
        // persist in cleartext. Say so honestly instead of
        // enqueueing a download that goes nowhere.
        if source == .emby {
            downloadNote = "Emby 影片暂不支持下载"
            return
        }
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
    /// Resolved from the item when omitted (VideoItem.detailSource),
    /// so an Emby entry opened from home / history / favourites /
    /// search loads the Emby detail instead of the CMS one.
    var source: VideoDetailSource

    @StateObject private var viewModel: VideoDetailViewModel
    @EnvironmentObject private var videoPlayer: VideoPlayerViewModel
    @State private var showingPlayer = false

    @Environment(\.haoTheme) private var theme

    init(item: VideoItem, source: VideoDetailSource? = nil) {
        self.item = item
        // StateObject's wrappedValue is an escaping autoclosure:
        // it must not capture self — bind the resolved source to
        // a local first, then hand the local to both assignments.
        let resolvedSource = source ?? item.detailSource
        self.source = resolvedSource
        _viewModel = StateObject(wrappedValue: VideoDetailViewModel(item: item, source: resolvedSource))
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
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .haoDarkGlassCapsule(darkness: 0.7)
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
        .onAppear {
            // First appearance (or a failed load left detail nil):
            // fetch. Any later appearance — e.g. back from the
            // player — only refreshes the local state, so the grid
            // stays put instead of flashing empty and scrolling
            // back to the top.
            if viewModel.detail == nil {
                viewModel.load()
            } else {
                viewModel.refreshLocalState()
            }
        }
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
    /// Width of the episode grid's container, measured on layout
    /// (sweep-4 B13): 4 columns on phones, 6 once the content is
    /// 600pt or wider, so iPad episode buttons stay tappable
    /// instead of stretching to ~180pt. 0 until the first pass —
    /// 4 columns, the phone layout.

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
                        // A film has no episodes to choose from: the
                        // line picker only appears with > 1 line
                        // (a CMS film with several sources) and the
                        // episode grid only with > 1 episode on the
                        // selected line. A single line + single
                        // episode (every Emby film) shows neither —
                        // the big play button is the whole entry.
                        if viewModel.lines.count > 1 {
                            linePicker
                        }
                        if (viewModel.selectedLine?.episodes.count ?? 0) > 1 {
                            episodeGrid
                        }
                    } else if !viewModel.isLoading {
                        MusicEmptyState(
                            icon: "film",
                            title: viewModel.source == .emby ? "暂无可播内容" : "暂无可播剧集",
                            note: viewModel.source == .emby
                                ? "Emby 没有返回这部影片的播放地址，检查服务器连接后重试。"
                                : viewModel.altSources.isEmpty && !viewModel.altSourcesLoading
                                    ? "该片源没有返回播放线路，其他片源也没有这部影片。"
                                    : "该片源没有返回播放线路，换个片源试试。"
                        )
                        // A failed detail fetch used to leave this
                        // state with no way back except leaving the
                        // page (load() only runs on appear).
                        // The retry button lives in the bottom
                        // safe-area inset (see below), not here: in
                        // flow it sits below the cover + title +
                        // play button, and on a short phone — or
                        // whenever the mini player is showing — it
                        // lands under the floating mini / tab bar
                        // until the user discovers the scroll.
                        // sweep-2 P1-8: the alternate sources for
                        // this title, as real rows — the empty state
                        // used to say "换个片源试试" with nowhere
                        // to switch to. Hidden when the search
                        // found nothing (the note says so instead).
                        if viewModel.source == .cms {
                            if viewModel.altSourcesLoading {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("正在查找其他片源…")
                                        .font(.haoFootnote)
                                        .foregroundStyle(theme.textMuted)
                                }
                                .padding(.top, 4)
                            } else if !viewModel.altSources.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("其他片源")
                                        .font(.haoFootnoteMedium)
                                        .foregroundStyle(theme.textSecondary)
                                    ForEach(viewModel.altSources, id: \.source) { alt in
                                        Button(action: { viewModel.switchToAltSource(alt) }) {
                                            HStack {
                                                Text(alt.name)
                                                    .font(.haoDenseBody)
                                                    .foregroundStyle(theme.textPrimary)
                                                Spacer()
                                                Text("切换")
                                                    .font(.haoFootnote)
                                                    .foregroundStyle(theme.accentText)
                                                Image(systemName: "chevron.right")
                                                    .font(.haoFootnote)
                                                    .foregroundStyle(theme.textMuted)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                            .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("切换到片源\(alt.name)")
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Pinned retry for the failed-load state: always above
            // the floating mini / tab bar (the inset sits inside
            // the bottom-chrome clearance), so it never needs a
            // scroll to be found. Hidden while loading and once
            // lines arrive.
            if viewModel.lines.isEmpty && !viewModel.isLoading {
                retryButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .haoBottomChromePadding()
        .background(theme.scaffoldBackground)
        .navigationTitle(viewModel.item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(HaoLayout.settleSpring) { coverRevealed = true }
        }
    }
    /// Retry the detail fetch. A failed detail fetch used to leave
    /// the page with no way back except leaving it (load() only
    /// runs on appear).
    private var retryButton: some View {
        Button(action: { viewModel.load() }) {
            Text("重试")
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Cover (VidHub style, no play button on it)

    private var coverHeader: some View {
        ZStack(alignment: .bottomLeading) {
            // b49 sweep #36: the 2:3 poster used to be hard-cropped
            // into the 264pt strip, cutting faces and title text.
            // The strip is now a blur of the whole poster, with the
            // sharp poster on top at full height (fit, never
            // cropped) — VidHub's backdrop treatment, since CMS
            // supplies no landscape art.
            Group {
                coverBackdrop
                coverPoster
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
                            .font(.haoDenseTitle)
                        Text("点按查看海报")
                            .font(.haoDenseTitle)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .haoDarkGlassCapsule(darkness: 0.6)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Blurred full-poster backdrop for the cover strip (b49
    /// sweep #36): the whole poster, fill + heavy blur, so the
    /// strip reads as the title's own art instead of a cropped
    /// band of it.
    private var coverBackdrop: some View {
        Group {
            // Emby covers need the server token in the request
            // header (EmbyPosterImage); plain AsyncImage sends
            // none, so every Emby cover 401'd into the
            // placeholder tile.
            if viewModel.source == .emby {
                EmbyPosterImage(urlString: viewModel.item.coverURL?.absoluteString ?? "", cornerRadius: 0)
            } else if let url = viewModel.item.coverURL {
                // Shared loader (build 36 item 10 leg 6):
                // full-width x 264pt header, downsampled to
                // screen width — the old AsyncImage decoded
                // the full original.
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: UIScreen.main.bounds.width,
                    targetHeight: 264
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    coverPlaceholder
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 264)
        .blur(radius: 24)
        .clipped()
    }

    /// Sharp poster on top of the blurred backdrop (b49 sweep
    /// #36): full height, aspect-fit, so no face or title text is
    /// ever cropped.
    private var coverPoster: some View {
        Group {
            if viewModel.source == .emby {
                // Emby posters are 2:3 — a 2:3 frame shows the
                // whole poster with no crop (EmbyPosterImage only
                // renders fill).
                EmbyPosterImage(urlString: viewModel.item.coverURL?.absoluteString ?? "", cornerRadius: 0)
                    .frame(width: 264 * 2 / 3, height: 264)
            } else if let url = viewModel.item.coverURL {
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: 264 * 2 / 3,
                    targetHeight: 264
                ) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    coverPlaceholder
                }
                .frame(height: 264)
            } else {
                coverPlaceholder
                    .frame(height: 264)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 264)
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
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 8) {
                if let year = viewModel.item.year, !year.isEmpty {
                    Text(year)
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.textSecondary)
                }
                if let type = viewModel.item.typeName, !type.isEmpty {
                    Text(type)
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.textSecondary)
                }
                if let remarks = viewModel.item.remarks, !remarks.isEmpty {
                    Text(remarks)
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            if let rating = viewModel.detail?.meta?.rating {
                // VidHub-style rating row: star + number, accent,
                // with the source named honestly — Douban is the
                // sole metadata source, so no other rating is shown.
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.haoFootnoteStrong)
                    Text(String(format: "%.1f", rating))
                        .font(.haoCalloutStrong)
                    Text("豆瓣评分")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textMuted)
                }
                .foregroundStyle(theme.accentText)
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
                    .font(.haoSubheadStrong)
                Text(viewModel.playButtonLabel)
                    .font(.haoBodyStrong)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: { viewModel.toggleFavourite() }) {
                    Label(
                        viewModel.isFavourite ? "已收藏" : "收藏",
                        systemImage: viewModel.isFavourite ? "heart.fill" : "heart"
                    )
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isFavourite ? "已收藏，点击取消收藏" : "收藏")
                .haoSensoryFeedback(.selection, trigger: viewModel.isFavourite)
            // b49 sweep #8: hidden when the selected episode
            // cannot download (HLS — the resolve said m3u8 — or
            // Emby); disabled while the resolve is still in
            // flight, so the button never vanishes mid-tap.
            if viewModel.downloadAvailable != false {
                Button(action: { viewModel.downloadSelected() }) {
                    Label("下载", systemImage: "arrow.down.circle")
                        .font(.haoDenseBody)
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下载本集")
                .disabled(!viewModel.canPlay || viewModel.downloadAvailable == nil)
                .opacity(viewModel.canPlay && viewModel.downloadAvailable != nil ? 1 : 0.5)
            }
            Spacer()
        }
        // b49 sweep #8: HLS download is deferred (segment
        // download not built) — say so where the button was,
        // instead of leaving a dead tap or a silent absence.
        if viewModel.downloadAvailable == false, viewModel.source != .emby, viewModel.canPlay {
            Text("该集为 HLS 流，暂不支持下载")
                .font(.haoFootnote)
                .foregroundStyle(theme.textMuted)
                .padding(.top, 8)
        }
        }
    }

    private func metaBlock(_ meta: VideoMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !meta.cast.isEmpty {
                Text(meta.cast.joined(separator: " / "))
                    .font(.haoSubhead)
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
                                .font(.haoRowSubtitle)
                            Text("简介已隐藏（防剧透），点按查看")
                                .font(.haoRowSubtitle)
                        }
                        .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(synopsis)
                        .font(.haoSubhead)
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
            // Emby lines are seasons, not sources: "选季" says
            // what the row does; "线路" is CMS vocabulary.
            Text(viewModel.source == .emby ? "选季" : "线路")
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.lines.enumerated()), id: \.element.id) { index, line in
                        Button(action: {
                            viewModel.selectedLineIndex = index
                            // The highlight must follow the episode
                            // the play button will actually open:
                            // playEpisodeIndex is the resume episode
                            // on the new line (or 0). Resetting to
                            // 0 highlighted episode 1 while the big
                            // button said "继续播放 · 第N集".
                            viewModel.selectedEpisodeIndex = viewModel.playEpisodeIndex
                        }) {
                            Text(line.name)
                                .font(.haoDenseBody)
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

    /// Episode columns (sweep-4 B13): 4 on phones, 6 once the
    /// content is 600pt or wider (iPad). See gridWidth above.
    private var episodeColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10),
              count: gridWidth >= 600 ? 6 : 4)
    }

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选集")
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            LazyVGrid(
                columns: episodeColumns,
                spacing: 10
            ) {
                ForEach(Array((viewModel.selectedLine?.episodes ?? []).enumerated()), id: \.element.id) { index, episode in
                    Button(action: { onPlay(viewModel.selectedLineIndex, index) }) {
                        Text(episode.displayName)
                            .font(.haoFootnoteMedium)
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
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { gridWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in
                            gridWidth = width
                        }
                }
            )
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
