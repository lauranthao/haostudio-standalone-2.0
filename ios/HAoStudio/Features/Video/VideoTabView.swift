// HAo Studio 2.0 — video tab (S3-C leg).
//
// Home tab for 影视: CMS home rows + categories + search entry +
// continue watching, with a CMS / Emby mode switch (persisted in
// `hao_video_tab_mode`, Flutter parity). Mirrors Flutter
// video_tab_page.dart (_CmsHomePage): cached rows first, then a
// fresh fetch; pull to refresh; section headers with a "全部"
// button into the browse page, and a "浏览全部" chip first in the
// category strip (build 36 item 18).
//
// The tab never invents rows: when the gateway answers empty
// (placeholder, or no source reachable) the page says so honestly.

import SwiftUI

/// Video tab navigation destinations.
enum VideoDestination: Hashable {
    case search
    case embySearch
    case category(String)
    case history
    case favourites
    case detail(VideoItem)
    case embyDetail(VideoItem)
    case embyGenre(String)
    /// Browse page (build 36 item 18). nil = no type pre-selected
    /// (first visible category); non-nil = pre-selected type.
    /// The "每日推荐" row passes nil: daily picks have no single
    /// type, and no fake "daily" type is invented.
    case browse(String?)
}

@MainActor
final class VideoTabViewModel: ObservableObject {
    @Published private(set) var rows: [VideoHomeRow] = []
    @Published private(set) var categories: [String] = []
    @Published private(set) var continueWatching: [VideoHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    private let gateway: VideoDataGateway

    init(gateway: VideoDataGateway = VideoServices.makeGateway()) {
        self.gateway = gateway
    }

    var watchedKeys: Set<String> {
        Set(continueWatching.map { $0.id })
    }

    /// Throttle for `loadFresh()` on tab re-entry (build 36 item 10):
    /// returning to the tab re-reads the local cache, but only
    /// re-fetches when there is nothing cached or the last
    /// successful fetch is older than this. Pull-to-refresh
    /// calls `loadFresh()` directly and bypasses the throttle.
    private static let freshInterval: TimeInterval = 5 * 60

    /// Set when a home fetch completes without failing
    /// (see `loadFresh()`); nil = never fetched successfully.
    private var lastFreshFetch: Date?

    func reload() {
        rows = VideoLibraryStore.cachedHome()
        continueWatching = VideoLibraryStore.history()
        reloadIfNeeded()
    }

    /// Local rows always refresh; the network fetch only runs
    /// when there is nothing cached or the last successful fetch
    /// is older than `freshInterval` (mirrors
    /// `LiveTabViewModel.loadIfNeeded`).
    func reloadIfNeeded() {
        guard rows.isEmpty || isFreshFetchStale else { return }
        loadFresh()
    }

    private var isFreshFetchStale: Bool {
        guard let last = lastFreshFetch else { return true }
        return Date().timeIntervalSince(last) >= Self.freshInterval
    }

    func loadFresh() {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        gateway.fetchHome { [weak self] fresh in
            guard let self = self else { return }
            self.isLoading = false
            if fresh.isEmpty && self.rows.isEmpty {
                self.loadFailed = true
            } else {
                if !fresh.isEmpty {
                    self.rows = fresh
                    VideoLibraryStore.saveHomeCache(fresh)
                }
                self.lastFreshFetch = Date()
            }
        }
        gateway.fetchTypeNames { [weak self] names in
            guard let self = self else { return }
            self.categories = VideoLibraryStore.visibleCategories(
                names, prefs: VideoLibraryStore.categoryPrefs())
        }
    }
}

struct VideoTabView: View {
    @StateObject private var viewModel = VideoTabViewModel()
    @State private var path: [VideoDestination] = []
    @State private var mode: String = VideoLibraryStore.tabMode()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("片源", selection: $mode) {
                    Text("影视").tag("cms")
                    Text("Emby").tag("emby")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onChange(of: mode) { newMode in
                    VideoLibraryStore.setTabMode(newMode)
                }
                .haoSensoryFeedback(.selection, trigger: mode)
                if mode == "emby" {
                    EmbyTabView(
                        onSelect: { path.append(.embyDetail($0)) },
                        onSelectGenre: { path.append(.embyGenre($0)) },
                        onSearch: { path.append(.embySearch) }
                    )
                } else {
                    cmsHome
                }
            }
            .background(theme.scaffoldBackground)
            .navigationTitle("影视")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: VideoDestination.self) { destination in
                switch destination {
                case .search:
                    VideoSearchView(onSelect: { path.append(.detail($0)) })
                case .embySearch:
                    EmbySearchView(onSelect: { path.append(.embyDetail($0)) })
                case .category(let type):
                    VideoCategoryView(type: type, onSelect: { path.append(.detail($0)) })
                case .history:
                    VideoHistoryView()
                case .favourites:
                    VideoFavsView()
                case .detail(let item):
                    VideoDetailView(item: item)
                case .embyDetail(let item):
                    EmbyDetailView(item: item)
                case .embyGenre(let genre):
                    EmbyCategoryView(genre: genre, onSelect: { path.append(.embyDetail($0)) })
                case .browse(let type):
                    VideoBrowseView(
                        initialType: type,
                        onSelectCMS: { path.append(.detail($0)) },
                        onSelectEmby: { path.append(.embyDetail($0)) },
                        onOpenHistory: { path.append(.history) },
                        onOpenFavourites: { path.append(.favourites) }
                    )
                }
            }
            .onAppear {
                // The browse page can change the persisted tab mode
                // (its 影视/Emby switch writes hao_video_tab_mode);
                // re-read it when switching back to this tab so the
                // picker shows the mode the user left the browse
                // page in.
                mode = VideoLibraryStore.tabMode()
                viewModel.reload()
            }
            .onChange(of: path) { _, newPath in
                // Popping back from a pushed page does NOT re-trigger
                // onAppear (the tab root never disappeared), so a mode
                // change made in the browse page is re-read here when
                // the stack returns to its root.
                if newPath.isEmpty {
                    mode = VideoLibraryStore.tabMode()
                }
            }
        }
    }

    // MARK: - CMS home

    private var cmsHome: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Scroll anchor for the bottom chrome (b35 tab-bar
                    // link): drives minimize / restore as this tab scrolls.
                    HaoChromeScrollAnchor()
                        .id(HaoTabScrollTop.id(for: .movies))
                    searchEntry
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    categoryStrip
                        .padding(.top, 12)
                    libraryRow
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    if !viewModel.continueWatching.isEmpty {
                        continueSection
                            .padding(.top, 16)
                    }
                    if viewModel.isLoading && viewModel.rows.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else if viewModel.rows.isEmpty {
                        MusicEmptyState(
                            icon: "film",
                            title: viewModel.loadFailed ? "片源暂不可用" : "还没有内容",
                            note: viewModel.loadFailed
                                ? "影视源没有返回数据，下拉重试或检查源设置。"
                                : "影视源返回了空列表。"
                        )
                        .padding(.horizontal, 24)
                    } else {
                        ForEach(viewModel.rows) { row in
                            homeRowSection(row)
                                .padding(.top, 16)
                        }
                    }
                    Spacer(minLength: 16)
                }
            }
            .haoBottomChromePadding()
            .haoChromeScrollTracking()
            .haoReselectScrollToTop(tab: .movies, proxy: proxy)
            .refreshable { viewModel.loadFresh() }
        }
    }

    private var searchEntry: some View {
        Button(action: { path.append(.search) }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.haoSubheadStrong)
                    .foregroundStyle(theme.textMuted)
                Text("搜索影片、剧集")
                    .font(.haoSubhead)
                    .foregroundStyle(theme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // First chip, never scrolled out of sight: the
                // browse page (build 36 item 18), first visible
                // category pre-selected.
                Button(action: { path.append(.browse(type: nil)) }) {
                    Label("浏览全部", systemImage: "square.grid.2x2")
                        .font(.haoDenseBody)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                ForEach(viewModel.categories, id: \.self) { type in
                    Button(action: { path.append(.category(type)) }) {
                        Text(type)
                            .font(.haoDenseBody)
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(theme.surface, in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var libraryRow: some View {
        HStack(spacing: 12) {
            Button(action: { path.append(.history) }) {
                Label("观看历史", systemImage: "clock")
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(theme.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: { path.append(.favourites) }) {
                Label("我的收藏", systemImage: "heart")
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(theme.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("继续观看")
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button("全部") { path.append(.history) }
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.continueWatching) { entry in
                        VideoContinueCard(entry: entry) {
                            path.append(.detail(entry.item))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func homeRowSection(_ row: VideoHomeRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(row.title)
                    .font(.haoSectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // Same 14pt medium accent style as the continue
                // section's "全部". The daily row passes nil (first
                // visible category); every other row passes its own
                // type.
                Button("全部") { path.append(.browse(type: row.id == "daily" ? nil : row.title)) }
                    .font(.haoDenseBody)
                    .foregroundStyle(theme.accentText)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(row.items) { item in
                        VideoPosterCard(item: item, isWatched: viewModel.watchedKeys.contains(
                            VideoResumeKey.key(title: item.title, year: item.year)
                        )) {
                            path.append(.detail(item))
                        }
                        .frame(width: 120)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// One continue-watching card: small poster + title + episode +
/// progress bar (Flutter _ContinueCard).
struct VideoContinueCard: View {
    var entry: VideoHistoryEntry
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VideoPosterCardImage(item: entry.item, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.title)
                        .font(.haoSubheadStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(entry.episodeName.isEmpty ? "正片" : entry.episodeName)
                        .font(.haoCaption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    if entry.durationSeconds > 0 {
                        ProgressView(value: entry.progress)
                            .tint(theme.accent)
                            // Full text-column width (was a fixed
                            // 120pt, so the bar stopped well short
                            // of the title above it and read as an
                            // orphaned stub — build-35 polish).
                            .frame(maxWidth: .infinity)
                        Text(videoTimeText(seconds: entry.positionSeconds))
                            .font(.haoCaption2)
                            .foregroundStyle(theme.textMuted)
                    } else {
                        Text("上次看到这里")
                            .font(.haoCaption2)
                            .foregroundStyle(theme.textMuted)
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 260, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(MusicPressScaleStyle())
    }
}

/// Small square-ish poster thumb used by the continue card (the
/// full VideoPosterCard carries its own title/meta lines, which
/// the card does not want).
struct VideoPosterCardImage: View {
    var item: VideoItem
    var size: CGFloat

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            // Emby thumbs need the server token in the request
            // header (EmbyPosterImage); plain AsyncImage sends
            // none, so continue-watching cards and history rows
            // showed placeholder tiles for every Emby title.
            if item.detailSource == .emby {
                EmbyPosterImage(urlString: item.coverURL?.absoluteString ?? "", cornerRadius: 8)
            } else if let url = item.coverURL {
                // Shared loader (build 36 item 10 leg 6): thumb is
                // size x 2/3 wide — decode that, not the original.
                HaoCachedImage(
                    urlString: url.absoluteString,
                    targetWidth: size * 2 / 3,
                    targetHeight: size
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size * 2 / 3, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "film")
                    .font(.haoCallout)
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// mm:ss / h:mm:ss for video positions (shared by the video pages).
func videoTimeText(seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
