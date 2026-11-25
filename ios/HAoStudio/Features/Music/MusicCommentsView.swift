// HAo Studio 2.0 — music comments, READ-ONLY (S3-C leg).
//
// S2 left the entry point wired (MusicPlayerView "查看评论（只读）"
// opens MusicCommentsView()) and the API built
// (MusicCommentsAPI: the song's own platform first, then the same
// song found on up to 3 other platforms, hot top 15, latest paged
// 30 at a time). This file is the page.
//
// Read-only is an iron law, not a missing feature: posting or
// liking a comment needs a platform login, and this app has no
// login interface — so there is no post/like UI here at all, and
// the page says so.

import SwiftUI

@MainActor
final class MusicCommentsViewModel: ObservableObject {
    @Published private(set) var hot: [CommentItem] = []
    @Published private(set) var latest: [CommentItem] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    // b49fix2 P1-19: a failed load-more used to leave the spinner
    // spinning forever with no error and no retry (the nil-page
    // branch only set `failed` for offset 0).
    @Published private(set) var loadMoreFailed = false
    @Published private(set) var songTitle = ""

    private var song: MusicSong?
    private var offset = 0
    private var loadingMore = false

    /// `force` is the pull-to-refresh path — the same-song guard
    /// below would otherwise swallow a refresh entirely.
    func load(song: MusicSong, force: Bool = false) {
        if !force, self.song?.identityKey == song.identityKey && !latest.isEmpty { return }
        self.song = song
        songTitle = song.title
        offset = 0
        hot = []
        latest = []
        hasMore = false
        failed = false
        loadMoreFailed = false
        isLoading = true
        fetch(offset: 0)
    }

    func loadMore() {
        guard !loadingMore, hasMore, let song = song else { return }
        loadingMore = true
        fetch(offset: offset)
    }

    private func fetch(offset: Int) {
        guard let song = song else { return }
        if offset > 0 { loadMoreFailed = false }
        MusicCommentsAPI.shared.comments(
            songId: song.songId, platform: song.platform,
            title: song.title, artist: song.artist, offset: offset
        ) { [weak self] page in
            guard let self = self else { return }
            self.isLoading = false
            self.loadingMore = false
            guard let page = page else {
                if offset == 0 { self.failed = true } else { self.loadMoreFailed = true }
                return
            }
            if offset == 0 {
                self.hot = page.hot
                self.latest = page.latest
            } else {
                self.latest.append(contentsOf: page.latest)
            }
            self.offset = offset + MusicCommentsAPI.pageSize
            self.hasMore = page.hasMore
        }
    }
}

/// Comments for the currently playing song. Zero-arg on purpose:
/// S2's player sheet constructs MusicCommentsView() and the song
/// comes from the shared player view model.
struct MusicCommentsView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var viewModel = MusicCommentsViewModel()
    // b49fix2 P2-21: hot / latest segmented switch (Coda §9.5).
    @State private var commentTab: CommentTab = .hot
    // b49fix3 P2-9: the default tab is re-evaluated once per song
    // (see the onChange below) — a song with no hot comments but
    // with latest ones opens on 最新 instead of "暂无热门评论".
    @State private var latestDefaultAppliedForSong: String? = nil

    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if playerVM.currentSong == nil {
                    MusicEmptyState(
                        icon: "text.bubble",
                        title: "没有正在播放的歌曲",
                        note: "播一首歌，再从播放器里查看它的评论。"
                    )
                } else if viewModel.isLoading && viewModel.latest.isEmpty && viewModel.hot.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.failed {
                    MusicEmptyState(
                        icon: "text.bubble",
                        title: "评论加载失败",
                        note: "各平台都没有返回评论，稍后再试。",
                        onRetry: {
                            if let song = playerVM.currentSong {
                                viewModel.load(song: song)
                            }
                        }
                    )
                } else if viewModel.hot.isEmpty && viewModel.latest.isEmpty {
                    MusicEmptyState(
                        icon: "text.bubble",
                        title: "暂无评论",
                        note: "这首歌在各平台都没有评论。"
                    )
                } else {
                    // b49fix2 P2-21: hot / latest segmented switch
                    // (Coda §9.5) + pull-to-refresh. The API loads
                    // both lists in one call; the switch only
                    // chooses which one is shown.
                    VStack(spacing: 0) {
                        Picker("评论", selection: $commentTab) {
                            Text("热门").tag(CommentTab.hot)
                            Text("最新").tag(CommentTab.latest)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        List {
                            // b49fix2 A14: the read-only note sits
                            // at the TOP of the list now — it used
                            // to be the last section, where nobody
                            // saw it before scrolling past every
                            // comment.
                            Section {
                                Text("评论只读 — 发表评论需要平台登录，本应用没有登录入口。")
                                    .font(.haoCaption)
                                    .foregroundStyle(theme.textMuted)
                            }
                            if commentTab == .hot {
                                if !viewModel.hot.isEmpty {
                                    Section("热门评论") {
                                        // A10: id was the comment text — two
                                        // identical comments ("好听") collided
                                        // and dropped a row. Offset is stable
                                        // for a loaded page.
                                        ForEach(Array(viewModel.hot.enumerated()), id: \.offset) { _, comment in
                                            MusicCommentRow(comment: comment)
                                                .listRowBackground(theme.scaffoldBackground)
                                                .listRowSeparatorTint(theme.hairline)
                                        }
                                    }
                                } else {
                                    Section {
                                        Text("暂无热门评论")
                                            .font(.haoFootnote)
                                            .foregroundStyle(theme.textSecondary)
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .padding(.vertical, 8)
                                            .listRowBackground(theme.scaffoldBackground)
                                    }
                                }
                            } else {
                                Section("最新评论") {
                                    ForEach(Array(viewModel.latest.enumerated()), id: \.offset) { _, comment in
                                        MusicCommentRow(comment: comment)
                                            .listRowBackground(theme.scaffoldBackground)
                                            .listRowSeparatorTint(theme.hairline)
                                    }
                                    // b49fix2 P1-19: a failed
                                    // load-more offers a retry
                                    // instead of a permanent spinner.
                                    if viewModel.loadMoreFailed {
                                        Button("加载失败，点按重试") {
                                            viewModel.loadMore()
                                        }
                                        .font(.haoFootnoteStrong)
                                        .foregroundStyle(theme.accentText)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .listRowBackground(theme.scaffoldBackground)
                                    } else if viewModel.hasMore {
                                        ProgressView()
                                            .frame(maxWidth: .infinity)
                                            .listRowBackground(theme.scaffoldBackground)
                                            .onAppear { viewModel.loadMore() }
                                    }
                                }
                            }
                        }
                        .haoBottomChromePadding()
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .refreshable {
                            if let song = playerVM.currentSong {
                                viewModel.load(song: song, force: true)
                            }
                        }
                    }
                }
            }
            .background(theme.scaffoldBackground)
            .navigationTitle(viewModel.songTitle.isEmpty ? "评论" : "评论 · \(viewModel.songTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let song = playerVM.currentSong {
                    viewModel.load(song: song)
                }
            }
            .onChange(of: playerVM.currentSong?.identityKey) { _ in
                if let song = playerVM.currentSong {
                    viewModel.load(song: song)
                }
            }
            // b49fix3 P2-9: default to 最新 when the song has no
            // hot comments but has latest ones — otherwise the page
            // opens on "暂无热门评论" while comments exist. Once
            // per song: a manual tap back to 热门 is never yanked
            // by a later refresh of the same song.
            .onChange(of: viewModel.hot.isEmpty && !viewModel.latest.isEmpty) { _, shouldPreferLatest in
                guard shouldPreferLatest,
                      let key = playerVM.currentSong?.identityKey,
                      latestDefaultAppliedForSong != key else { return }
                latestDefaultAppliedForSong = key
                commentTab = .latest
            }
        }
    }
}

/// Hot / latest switch for the comments page (b49fix2 P2-21,
/// Coda §9.5).
private enum CommentTab {
    case hot
    case latest
}

struct MusicCommentRow: View {
    var comment: CommentItem

    @Environment(\.haoTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MusicCoverView(urlString: comment.avatar, size: 36, cornerRadius: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.nick.isEmpty ? "匿名" : comment.nick)
                        .font(.haoFootnoteStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(comment.platform.badgeName)
                        .font(.haoBadge)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(theme.hairline, lineWidth: 0.5)
                        }
                    Spacer()
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart")
                            .font(.haoCaption)
                            .foregroundStyle(theme.textMuted)
                    }
                }
                Text(comment.content)
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textPrimary)
                // b49fix2 P2-21: nested replies (wy beReplied only
                // — tx / kg / kw carry no reply data). beReplied is
                // the comment THIS comment replied to, so it renders
                // as a quote under the comment.
                if !comment.replies.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(comment.replies.enumerated()), id: \.offset) { _, reply in
                            Text("回复 \(reply.nick)：\(reply.content)")
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(8)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(musicCommentDateText(milliseconds: comment.time))
                    .font(.haoCaption2)
                    .foregroundStyle(theme.textMuted)
            }
        }
        .padding(.vertical, 6)
    }
}

/// "yyyy-MM-dd HH:mm" for a comment timestamp (milliseconds).
func musicCommentDateText(milliseconds: Int) -> String {
    guard milliseconds > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    return musicCommentDateFormatter.string(from: date)
}

private let musicCommentDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    // B12: pin the locale — without it, non-Gregorian calendars
    // change the year in the rendered date.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()
