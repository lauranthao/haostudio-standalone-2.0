// HAo Studio 2.0 — music search (S2-C leg + b45-d tabs).
//
// Streaming search (Flutter SongSearchPage): results appear as each
// platform leg settles — no waiting for the slowest leg, NetEase +
// QQ first. One query searches ALL platforms by default; there is
// NO platform selector in this UI. Rows reveal as legs arrive.
//
// b45-d (Coda P4, §5): five tabs — 综合 / 单曲 / 歌手 / 专辑 / 歌单.
// Songs still stream first (~1s); artists / albums / playlists
// arrive afterwards in horizontal shelves on 综合 and as grids on
// their own tabs, each with its own paging (extra song pages reuse
// the existing legs, 20/20/15/15 = 70/page, capped at 5 extra
// pages; cards 50/page on single-kind tabs, 10/page on 综合) and
// its own error state with in-section retry. Suggestion / hot-word
// chips sit under the search field. History (max 20) sits above
// the results when idle — kept as-is (Coda has none; that is a gap,
// not a feature).
//
// Search still only fires on submit; there is no type-to-search
// debounce. Tab switches restore snapshots instead of re-fetching.

import SwiftUI

struct MusicSearchView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var searchVM = MusicSearchViewModel()
    @State private var query = ""
    /// "清除" history confirmation: history deletion is
    /// destructive with no undo, so it asks first.
    @State private var showClearHistoryConfirm = false

    @Environment(\.haoTheme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                // b49fix3 P1-18: the search page keeps its 20pt
                // margin (pushed page) — the brief's 20→24 is NOT
                // applied to this line alone: the page's inner
                // sections are all built on 20, and changing only
                // the outer padding would misalign them. Sweep 6
                // ruled the same way (search pages 20, EmbyTabView
                // excepted at 24 as a tab root).
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 8)
            suggestionChips
            if !searchVM.hasSearched {
                historySection
            } else {
                tabPicker
                tabContent
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("搜歌")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { newValue in
            searchVM.refreshSuggestions(for: newValue)
        }
        .onAppear {
            searchVM.refreshSuggestions(for: query)
        }
    }

    // MARK: - Search field (Coda §5.4)

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.haoSubheadStrong)
                .foregroundStyle(theme.textSecondary)
            TextField("搜索歌曲、歌手、专辑、歌单", text: $query)
                .font(.haoCallout)
                .foregroundStyle(theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .onSubmit {
                    searchFocused = false
                    searchVM.search(query)
                }
            if !query.isEmpty {
                Button(action: {
                    query = ""
                    searchVM.clear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, query.isEmpty ? 16 : 4)
        .frame(height: HaoLayout.searchFieldHeight)
        // b49fix4 P2-4: the input keeps surfaceStrong (a real
        // editable field reads stronger than a tappable entry,
        // which is surface) — the hairline is the shared entry
        // grammar, so it gets one like every other entry.
        .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        }
    }

    // MARK: - Suggestion / hot-word chips (Coda §5.3)

    /// Chips show while typing (suggestions) or while idle (hot
    /// words). Hidden after a submitted search until the field is
    /// focused again — the results, not the chips, own that space.
    /// A chip tap resigns the keyboard first, then searches the word
    /// (Coda §5.3: resign before swapping the term, so the input
    /// session never swallows it).
    @ViewBuilder
    private var suggestionChips: some View {
        if (searchFocused || !searchVM.hasSearched) && !searchVM.suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(searchVM.suggestions, id: \.self) { word in
                        Button(action: {
                            searchFocused = false
                            query = word
                            searchVM.search(word)
                        }) {
                            Text(word)
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .overlay {
                                    RoundedRectangle(cornerRadius: HaoLayout.cornerMedium, style: .continuous)
                                        .strokeBorder(theme.hairline, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 12)
            }
            .accessibilityLabel(query.isEmpty ? "热搜" : "搜索建议")
        }
    }

    // MARK: - Tabs (Coda §5.2 / §5.4)

    private var tabPicker: some View {
        Picker(
            "分类",
            selection: Binding(get: { searchVM.tab }, set: { searchVM.selectTab($0) })
        ) {
            ForEach(searchVM.supportedTabs) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, HaoLayout.pushedPageMargin)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch searchVM.tab {
        case .all:
            allTabView
        case .songs:
            songsTabView
        case .artists:
            artistsGrid
        case .albums:
            albumsGrid
        case .playlists:
            playlistsGrid
        }
    }

    // MARK: - 综合 tab

    /// Everything empty + nothing loading = the whole-tab empty
    /// state (Coda §5.3: 综合 requires songs AND artists empty).
    private var allIsEmpty: Bool {
        !searchVM.isSearching
            && searchVM.results.isEmpty
            && searchVM.artists.isEmpty
            && searchVM.albums.isEmpty
            && searchVM.playlists.isEmpty
            && searchVM.loadingCards.isEmpty
    }

    private var allTabView: some View {
        ScrollView {
            if allIsEmpty {
                // b49fix2 P2-4: when the songs stream failed (and
                // nothing else answered either), say so with a
                // retry — "没有找到" would blame the keyword for a
                // network failure.
                if searchVM.songsFailed {
                    MusicEmptyState(icon: "wifi.exclamationmark", title: "搜索失败", note: "网络似乎出了问题，检查后重试。", onRetry: { searchVM.retrySongs() })
                        .frame(minHeight: 300)
                } else {
                    MusicEmptyState(icon: "magnifyingglass", title: "没有找到相关结果", note: "换个关键词试试。")
                        .frame(minHeight: 300)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: HaoLayout.sectionTopSpacing) {
                    songsSection
                    artistShelf
                    albumShelf
                    playlistShelf
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 12)
            }
        }
        .haoBottomChromePadding()
    }

    @ViewBuilder
    private var songsSection: some View {
        sectionHeader(title: "歌曲", showAll: !searchVM.results.isEmpty) {
            searchVM.selectTab(.songs)
        }
        if searchVM.results.isEmpty && searchVM.isSearching {
            songSkeletonRows
        } else if searchVM.results.isEmpty {
            // b49fix2 P2-4: a failed stream offers a retry, not a
            // "没有找到" that blames the keyword.
            if searchVM.songsFailed {
                Button("搜索失败，点按重试") {
                    searchVM.retrySongs()
                }
                .font(.haoFootnoteMedium)
                .foregroundStyle(theme.accentText)
                .padding(.top, 12)
            } else {
                Text("没有找到相关歌曲")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 4)
            }
        } else {
            ForEach(Array(searchVM.results.enumerated()), id: \.element.id) { index, song in
                MusicSongRow(
                    song: song,
                    isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                    onTap: {
                        // b46: search results are a reloadable place
                        // now — switching tracks after a search play
                        // can reload the list instead of losing it.
                        playerVM.play(song: song, in: searchVM.results, startAt: index, source: PlaySource(kind: .search, id: "search"), sourceDisplayName: "搜索")
                    }
                )
            }
            if searchVM.isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("搜索中…")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            }
        }
    }

    /// 7 skeleton rows while the first song batch is still in
    /// flight (Coda §5.4: 歌曲/综合骨架 7 行).
    private var songSkeletonRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: HaoLayout.chipCornerRadius, style: .continuous)
                        .fill(theme.surfaceStrong)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.surfaceStrong)
                            .frame(width: 140, height: 14)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.surfaceStrong)
                            .frame(width: 90, height: 12)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var artistShelf: some View {
        sectionHeader(title: "歌手", showAll: !searchVM.artists.isEmpty) {
            searchVM.selectTab(.artists)
        }
        if searchVM.loadingCards.contains(.artists) && searchVM.artists.isEmpty {
            shelfSkeletonCards(count: 3, size: 128, cornerRadius: 64)
        } else if searchVM.cardErrors[.artists] == true && searchVM.artists.isEmpty {
            categoryErrorRow(kind: .artists)
        } else if searchVM.artists.isEmpty {
            // b49fix5 P2-28: the true-empty shelf also offers a
            // retry (re-issues the kind's first page) — the user
            // re-checking this kind no longer has to leave for the
            // single-kind tab or re-search.
            Button("没有找到相关歌手，点击重试") {
                searchVM.retryCategory(.artists)
            }
            .font(.haoFootnoteMedium)
            .foregroundStyle(theme.accentText)
            .padding(.top, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(searchVM.artists.enumerated()), id: \.element.id) { index, artist in
                        artistCard(artist)
                            .onAppear {
                                if index == searchVM.artists.count - 1 {
                                    searchVM.loadMoreCards(.artists)
                                }
                            }
                    }
                }
            }
            // b49fix9 P2-1: the guard can close a kind on the
            // 综合 shelves too (loadMoreCards runs here) — the
            // same footer as the single-kind grids, so a closed
            // kind shows "没有更多，点击重试" here instead of
            // ending silently. The footer renders nothing in
            // the normal state (not loading, no error, not
            // closed), so this adds no spacing then.
            cardFooter(kind: .artists)
        }
    }

    @ViewBuilder
    private var albumShelf: some View {
        sectionHeader(title: "专辑", showAll: !searchVM.albums.isEmpty) {
            searchVM.selectTab(.albums)
        }
        if searchVM.loadingCards.contains(.albums) && searchVM.albums.isEmpty {
            shelfSkeletonCards(count: 3, size: 178, cornerRadius: HaoLayout.cornerMedium)
        } else if searchVM.cardErrors[.albums] == true && searchVM.albums.isEmpty {
            categoryErrorRow(kind: .albums)
        } else if searchVM.albums.isEmpty {
            // b49fix5 P2-28: same retry entry as the artists shelf.
            Button("没有找到相关专辑，点击重试") {
                searchVM.retryCategory(.albums)
            }
            .font(.haoFootnoteMedium)
            .foregroundStyle(theme.accentText)
            .padding(.top, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(searchVM.albums.enumerated()), id: \.element.id) { index, album in
                        albumCard(album)
                            .onAppear {
                                if index == searchVM.albums.count - 1 {
                                    searchVM.loadMoreCards(.albums)
                                }
                            }
                    }
                }
            }
            // b49fix9 P2-1: same footer as the artists shelf.
            cardFooter(kind: .albums)
        }
    }

    @ViewBuilder
    private var playlistShelf: some View {
        sectionHeader(title: "歌单", showAll: !searchVM.playlists.isEmpty) {
            searchVM.selectTab(.playlists)
        }
        if searchVM.loadingCards.contains(.playlists) && searchVM.playlists.isEmpty {
            shelfSkeletonCards(count: 3, size: 178, cornerRadius: HaoLayout.cornerMedium)
        } else if searchVM.cardErrors[.playlists] == true && searchVM.playlists.isEmpty {
            categoryErrorRow(kind: .playlists)
        } else if searchVM.playlists.isEmpty {
            // b49fix5 P2-28: same retry entry as the artists shelf.
            Button("没有找到相关歌单，点击重试") {
                searchVM.retryCategory(.playlists)
            }
            .font(.haoFootnoteMedium)
            .foregroundStyle(theme.accentText)
            .padding(.top, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(searchVM.playlists.enumerated()), id: \.element.id) { index, summary in
                        playlistCard(summary)
                            .onAppear {
                                if index == searchVM.playlists.count - 1 {
                                    searchVM.loadMoreCards(.playlists)
                                }
                            }
                    }
                }
            }
            // b49fix9 P2-1: same footer as the artists shelf.
            cardFooter(kind: .playlists)
        }
    }

    private func sectionHeader(title: String, showAll: Bool, onShowAll: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                // b49fix3 P1-19: section headers are 20 semibold
                // everywhere, not 17 — the search page's four
                // section titles were the odd ones out.
                .font(.haoSectionTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if showAll {
                Button(action: onShowAll) {
                    HStack(spacing: 2) {
                        Text("查看全部")
                            .font(.haoFootnote)
                            .foregroundStyle(theme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.accentText)
                    }
                }
                .buttonStyle(.plain)
                // b49fix3 P2-8: four identical "查看全部" buttons
                // read identically to VoiceOver — the label carries
                // the section so they are distinguishable.
                .accessibilityLabel("查看全部\(title)")
            }
        }
    }

    private func shelfSkeletonCards(count: Int, size: CGFloat, cornerRadius: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(theme.surfaceStrong)
                        .frame(width: size, height: size)
                }
            }
        }
    }

    private func categoryErrorRow(kind: MusicSearchAPI.MusicSearchCategoryKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.haoFootnote)
                .foregroundStyle(theme.textSecondary)
            Text("加载失败")
                .font(.haoFootnote)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Button("重试") { searchVM.retryCategory(kind) }
                .font(.haoFootnoteMedium)
                .foregroundStyle(theme.accentText)
                .buttonStyle(.plain)
        }
        .padding(.top, 12)
    }

    // MARK: - Cards (Coda §5.4)

    /// Artist card: 128×128 circle, name body strong 1 line, 140 frame.
    private func artistCard(_ artist: ArtistSummary) -> some View {
        NavigationLink(destination: MusicArtistDetailView(artist: artist)) {
            VStack(spacing: 8) {
                MusicCoverView(urlString: artist.cover, size: 128, cornerRadius: 64)
                Text(artist.name.isEmpty ? "未知歌手" : artist.name)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    /// Album / playlist card: 178 cover (CoverCardBody size), name
    /// body strong up to 2 lines, subtitle secondary 1 line.
    private func albumCard(_ album: AlbumSummary) -> some View {
        NavigationLink(destination: MusicAlbumDetailView(album: album)) {
            VStack(alignment: .leading, spacing: 8) {
                MusicCoverView(urlString: album.cover, size: 178, cornerRadius: HaoLayout.cornerMedium)
                Text(album.name.isEmpty ? "未知专辑" : album.name)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                Text(album.artist.isEmpty ? "未知艺人" : album.artist)
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 178, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func playlistCard(_ summary: PlaylistSummary) -> some View {
        NavigationLink(destination: MusicPlazaDetailView(summary: summary)) {
            VStack(alignment: .leading, spacing: 8) {
                MusicCoverView(urlString: summary.cover, size: 178, cornerRadius: HaoLayout.cornerMedium)
                Text(summary.name.isEmpty ? "未知歌单" : summary.name)
                    .font(.haoBodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                Text(playlistSubtitle(summary))
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 178, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func playlistSubtitle(_ summary: PlaylistSummary) -> String {
        var parts: [String] = []
        if !summary.creator.isEmpty { parts.append(summary.creator) }
        let plays = plazaPlayCountText(summary.playCount)
        if !plays.isEmpty { parts.append(plays) }
        if summary.trackCount > 0 { parts.append("\(summary.trackCount) 首") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 单曲 tab (stream + explicit paging)

    private var songsTabView: some View {
        List {
            ForEach(Array(searchVM.results.enumerated()), id: \.element.id) { index, song in
                MusicSongRow(
                    song: song,
                    isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                    onTap: {
                        // b46: same search context as the merged list.
                        playerVM.play(song: song, in: searchVM.results, startAt: index, source: PlaySource(kind: .search, id: "search"), sourceDisplayName: "搜索")
                    }
                )
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparatorTint(theme.hairline)
                .onAppear {
                    // Last row visible = request the next page.
                    if index == searchVM.results.count - 1 {
                        searchVM.loadMoreSongs()
                    }
                }
            }
            if searchVM.isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("搜索中…")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparator(.hidden)
            } else if searchVM.isLoadingMoreSongs {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("加载更多…")
                        .font(.haoFootnote)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparator(.hidden)
            } else if searchVM.songPageError {
                Button("加载更多失败，点击重试") {
                    searchVM.retrySongsPage()
                }
                // b49fix4 P2-6: inline text retries are 13 medium
                // site-wide (was 13 regular here).
                .font(.haoFootnoteMedium)
                .foregroundStyle(theme.accentText)
                // b49fix5 P2-23: List rows carry their own top 12
                // (the standard top spacing for inline retries).
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparator(.hidden)
            } else if searchVM.results.isEmpty {
                // b49fix2 P2-4: same failed-stream retry as the
                // 综合 shelf (see songsSection).
                if searchVM.songsFailed {
                    MusicEmptyState(icon: "wifi.exclamationmark", title: "搜索失败", note: "网络似乎出了问题，检查后重试。", onRetry: { searchVM.retrySongs() })
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparator(.hidden)
                } else {
                    MusicEmptyState(icon: "magnifyingglass", title: "没有找到相关歌曲", note: "换个关键词试试。")
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .haoBottomChromePadding()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Single-kind grids

    private var artistsGrid: some View {
        ScrollView {
            if searchVM.loadingCards.contains(.artists) && searchVM.artists.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if searchVM.cardErrors[.artists] == true && searchVM.artists.isEmpty {
                MusicEmptyState(icon: "wifi.exclamationmark", title: "加载失败", note: "检查网络后重试。", onRetry: { searchVM.retryCategory(.artists) })
                    .frame(minHeight: 300)
            } else if searchVM.artists.isEmpty {
                // b49fix4 P1-3 (backstop): this branch used to be a
                // dead end — a tab switched to while its kind was
                // still in flight under 综合 landed here with no
                // retry. The retry re-issues the kind's first page.
                MusicEmptyState(icon: "magnifyingglass", title: "没有找到相关结果", note: "换个关键词试试。", onRetry: { searchVM.retryCategory(.artists) })
                    .frame(minHeight: 300)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 24) {
                    ForEach(Array(searchVM.artists.enumerated()), id: \.element.id) { index, artist in
                        artistCard(artist)
                            .onAppear {
                                if index == searchVM.artists.count - 1 {
                                    searchVM.loadMoreCards(.artists)
                                }
                            }
                    }
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 12)
                cardFooter(kind: .artists)
            }
        }
        .haoBottomChromePadding()
    }

    private var albumsGrid: some View {
        ScrollView {
            if searchVM.loadingCards.contains(.albums) && searchVM.albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if searchVM.cardErrors[.albums] == true && searchVM.albums.isEmpty {
                MusicEmptyState(icon: "wifi.exclamationmark", title: "加载失败", note: "检查网络后重试。", onRetry: { searchVM.retryCategory(.albums) })
                    .frame(minHeight: 300)
            } else if searchVM.albums.isEmpty {
                // b49fix4 P1-3 (backstop): same dead end as the
                // artists grid — the retry re-issues the kind's
                // first page.
                MusicEmptyState(icon: "magnifyingglass", title: "没有找到相关结果", note: "换个关键词试试。", onRetry: { searchVM.retryCategory(.albums) })
                    .frame(minHeight: 300)
            } else {
                // b49fix2 B14: the adaptive minimum must be the card
                // width (178) — at 160 a 390pt phone squeezed two
                // 167pt columns and the 178pt card overflowed its
                // cell into the next column.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 16)], spacing: 24) {
                    ForEach(Array(searchVM.albums.enumerated()), id: \.element.id) { index, album in
                        albumCard(album)
                            .onAppear {
                                if index == searchVM.albums.count - 1 {
                                    searchVM.loadMoreCards(.albums)
                                }
                            }
                    }
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 12)
                cardFooter(kind: .albums)
            }
        }
        .haoBottomChromePadding()
    }

    private var playlistsGrid: some View {
        ScrollView {
            if searchVM.loadingCards.contains(.playlists) && searchVM.playlists.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if searchVM.cardErrors[.playlists] == true && searchVM.playlists.isEmpty {
                MusicEmptyState(icon: "wifi.exclamationmark", title: "加载失败", note: "检查网络后重试。", onRetry: { searchVM.retryCategory(.playlists) })
                    .frame(minHeight: 300)
            } else if searchVM.playlists.isEmpty {
                // b49fix4 P1-3 (backstop): same dead end as the
                // artists grid — the retry re-issues the kind's
                // first page.
                MusicEmptyState(icon: "magnifyingglass", title: "没有找到相关结果", note: "换个关键词试试。", onRetry: { searchVM.retryCategory(.playlists) })
                    .frame(minHeight: 300)
            } else {
                // b49fix2 B14: same as albumsGrid — the minimum must
                // be the card width (178), not 160.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 16)], spacing: 24) {
                    ForEach(Array(searchVM.playlists.enumerated()), id: \.element.id) { index, summary in
                        playlistCard(summary)
                            .onAppear {
                                if index == searchVM.playlists.count - 1 {
                                    searchVM.loadMoreCards(.playlists)
                                }
                            }
                    }
                }
                .padding(.horizontal, HaoLayout.pushedPageMargin)
                .padding(.top, 12)
                cardFooter(kind: .playlists)
            }
        }
        .haoBottomChromePadding()
    }

    /// Grid footer: loading spinner while a next page is in flight,
    /// retry button when the last page failed with rows kept.
    @ViewBuilder
    private func cardFooter(kind: MusicSearchAPI.MusicSearchCategoryKind) -> some View {
        if searchVM.loadingCards.contains(kind) {
            HStack(spacing: 8) {
                ProgressView()
                Text("加载更多…")
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
        } else if searchVM.cardErrors[kind] == true {
            Button("加载失败，点击重试") {
                searchVM.retryCategory(kind)
            }
            // b49fix4 P2-6: inline text retries are 13 medium
            // site-wide (was 13 regular here).
            .font(.haoFootnoteMedium)
            .foregroundStyle(theme.accentText)
            .frame(maxWidth: .infinity, alignment: .center)
            // b49fix5 P2-23: inline text retries carry top 12
            // (was vertical 16 — the bottom is the container's).
            .padding(.top, 12)
        } else if searchVM.cardClosedByGuard[kind] == true {
            // b49fix7 P2-6: the zero-growth guard closed this
            // kind (the source answered two identical next-page
            // requests with the same page) — show the end state
            // instead of silently dropping the load-more button.
            // A fresh first page re-opens the kind. The footer
            // is rendered on the single-kind grids AND under the
            // 综合 shelves (b49fix9 P2-1: the guard can close a
            // kind on 综合 too, since the shelves call
            // loadMoreCards — the "only single-kind pages can
            // close a kind" claim was wrong).
            // b49fix8 P2-6: the end state is also the way back
            // in — it is a light retry, not a dead label. Tapping
            // re-issues a first page under the current tab's
            // limit (reopenClosedKind). Same inline-text-retry
            // treatment as the error retry above (13 medium,
            // accent text, top 12).
            Button("没有更多，点击重试") {
                searchVM.reopenClosedKind(kind)
            }
            .font(.haoFootnoteMedium)
            .foregroundStyle(theme.accentText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)
        }
    }

    private var historySection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !searchVM.history.isEmpty {
                    HStack {
                        // b49fix4 P2-5: 20 semibold, like the
                        // video / live history titles (was 17).
                        Text("搜索历史")
                            .font(.haoSectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Button("清除") { showClearHistoryConfirm = true }
                            .font(.haoRowSubtitle)
                            .foregroundStyle(theme.accentText)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, HaoLayout.pushedPageMargin)
                    // b49fix5 P2-29: history top spacing is 12
                    // site-wide (was 20 here; live 16, video 12).
                    .padding(.top, 12)
                    ForEach(searchVM.history, id: \.self) { item in
                        // Sibling buttons, NOT a Button inside a
                        // Button (fix 2026-11-24, build 35): a
                        // nested Button also fires the outer tap,
                        // so deleting a history term would search
                        // for it at the same time. Same rule as
                        // MiniPlayerBar's sibling buttons.
                        HStack(spacing: 10) {
                            Button(action: {
                                query = item
                                searchVM.search(item)
                            }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "clock")
                                        .font(.haoFootnote)
                                        .foregroundStyle(theme.textMuted)
                                    Text(item)
                                        .font(.haoSubhead)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(action: { searchVM.removeHistoryItem(item) }) {
                                Image(systemName: "xmark")
                                    .font(.haoCaption2Strong)
                                    .foregroundStyle(theme.textMuted)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            // b49fix3 P2-8: the delete label carries
                            // the term — "删除搜索记录" alone does
                            // not say which one.
                            .accessibilityLabel("删除搜索记录：\(item)")
                        }
                        .padding(.horizontal, HaoLayout.pushedPageMargin)
                        .padding(.vertical, 12)
                    }
                } else {
                    MusicEmptyState(
                        icon: "magnifyingglass", title: "搜你想听的歌",
                        note: "默认搜索全部平台，网易云和 QQ 的结果排在前面。"
                    )
                    // b49fix4 P2-19: empty-state top offset 0
                    // site-wide (was 40 here) — the container
                    // spacing decides, not the state itself.
                }
            }
        }
        .haoBottomChromePadding()
        .confirmationDialog("清除搜索历史？", isPresented: $showClearHistoryConfirm, titleVisibility: .visible) {
            Button("清除全部历史", role: .destructive) { searchVM.clearHistory() }
            Button("取消", role: .cancel) {}
        }
    }

}

// MARK: - Add to playlist sheet

/// Add-to-playlist sheet: existing playlists + create new. The
/// result (added / dupes / dropped) is reported in the sheet itself
/// so the user sees what happened.
struct MusicAddToPlaylistSheet: View {
    var song: MusicSong
    var onDone: () -> Void

    @StateObject private var libraryVM = MusicLibraryViewModel()
    @State private var newListName = ""
    @State private var resultText: String?

    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            List {
                Section("添加到歌单") {
                    ForEach(libraryVM.playlists) { list in
                        Button(action: {
                            let result = libraryVM.addToPlaylist([song], listId: list.id)
                            if result.added > 0 {
                                resultText = "已加入「\(list.name)」"
                            } else if result.dupes > 0 {
                                resultText = "「\(list.name)」里已经有了"
                            } else {
                                resultText = "歌单已满（1000 首上限）"
                            }
                        }) {
                            HStack {
                                Text(list.name)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text("\(list.trackCount) 首")
                                    .font(.haoFootnote)
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                }
                Section("新建歌单") {
                    HStack {
                        TextField("歌单名", text: $newListName)
                        Button("创建并加入") {
                            let trimmed = newListName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            let list = MusicLibraryStore.createList(named: trimmed)
                            _ = libraryVM.addToPlaylist([song], listId: list.id)
                            resultText = "已新建并加入「\(list.name)」"
                            // Build 36, item 8: the name used to stay
                            // in the field, so a second tap built a
                            // duplicate list with the same name.
                            newListName = ""
                            libraryVM.reload()
                        }
                        .foregroundStyle(theme.accentText)
                    }
                }
                if let resultText = resultText {
                    Section {
                        Text(resultText)
                            .font(.haoRowSubtitle)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成", action: onDone)
                }
            }
            .onAppear { libraryVM.reload() }
        }
    }
}

// MusicSong is already Identifiable (id = identityKey), so it can
// be used directly as a sheet item.
