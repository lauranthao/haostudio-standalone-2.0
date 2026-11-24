// HAo Studio 2.0 — video favourites (S3-C leg).
//
// Flutter video_favs_page.dart: poster grid, tap opens the detail
// page, unfavourite from the detail page (the grid itself has no
// hidden delete gesture — the detail page owns the toggle).

import SwiftUI

struct VideoFavsView: View {
    @State private var items: [VideoItem] = VideoLibraryStore.favourites()
    @State private var selectedItem: VideoItem?

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if items.isEmpty {
                MusicEmptyState(
                    icon: "heart",
                    title: "还没有收藏的影片",
                    note: "在详情页点收藏，影片会出现在这里。"
                )
            } else {
                ScrollView {
                    VideoPosterGrid(items: items) { item in
                        selectedItem = item
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer(minLength: 16)
                }
                .haoBottomChromePadding()
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedItem) { item in
            VideoDetailView(item: item)
        }
        .onAppear { items = VideoLibraryStore.favourites() }
    }
}
