// HAo Studio 2.0 — music search (S2-C leg).
//
// Streaming search (Flutter SongSearchPage): results appear as each
// platform leg settles — no waiting for the slowest leg, NetEase +
// QQ first. One query searches ALL platforms by default; there is
// NO platform selector in this UI. Rows reveal as legs arrive, so
// scrolling further down is the "infinite scroll" — no page API
// exists in the LX contract, so no page requests are invented.
// History (max 20) sits above the results when idle.

import SwiftUI

struct MusicSearchView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var searchVM = MusicSearchViewModel()
    @State private var query = ""

    @Environment(\.haoTheme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 20)
                .padding(.top, 8)
            if !searchVM.hasSearched {
                historySection
            } else {
                resultsSection
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("搜歌")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            TextField("搜索歌曲、歌手", text: $query)
                .font(.system(size: 16))
                .foregroundStyle(theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchVM.search(query) }
            if !query.isEmpty {
                Button(action: {
                    query = ""
                    searchVM.clear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var historySection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !searchVM.history.isEmpty {
                    HStack {
                        Text("搜索历史")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Button("清除") { searchVM.clearHistory() }
                            .font(.system(size: 14))
                            .foregroundStyle(theme.accent)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
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
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.textMuted)
                                    Text(item)
                                        .font(.system(size: 15))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(action: { searchVM.removeHistoryItem(item) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.textMuted)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除搜索记录")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                } else {
                    MusicEmptyState(
                        icon: "magnifyingglass", title: "搜你想听的歌",
                        note: "默认搜索全部平台，网易云和 QQ 的结果排在前面。"
                    )
                    .padding(.top, 40)
                }
            }
        }
        .haoBottomChromePadding()
    }

    private var resultsSection: some View {
        List {
            ForEach(Array(searchVM.results.enumerated()), id: \.element.id) { index, song in
                MusicSongRow(
                    song: song,
                    isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                    onTap: {
                        playerVM.play(song: song, in: searchVM.results, startAt: index)
                    }
                )
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparatorTint(theme.hairline)
            }
            if searchVM.isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("搜索中…")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(theme.scaffoldBackground)
                .listRowSeparator(.hidden)
            } else if searchVM.results.isEmpty {
                MusicEmptyState(icon: "magnifyingglass", title: "没有找到相关歌曲", note: "换个关键词试试。")
                    .listRowBackground(theme.scaffoldBackground)
                    .listRowSeparator(.hidden)
            }
        }
        .haoBottomChromePadding()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                }
                Section("新建歌单") {
                    HStack {
                        TextField("歌单名", text: $newListName)
                        Button("创建并加入") {
                            guard !newListName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            let list = MusicLibraryStore.createList(named: newListName)
                            _ = libraryVM.addToPlaylist([song], listId: list.id)
                            resultText = "已新建并加入「\(list.name)」"
                            libraryVM.reload()
                        }
                        .foregroundStyle(theme.accent)
                    }
                }
                if let resultText = resultText {
                    Section {
                        Text(resultText)
                            .font(.system(size: 14))
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
