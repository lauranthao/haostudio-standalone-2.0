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
                    // b49fix19 P2-10: was a literal 16 — every
                    // other pushed page uses pushedPageMargin
                    // (20) for this grid.
                    .padding(.horizontal, HaoLayout.pushedPageMargin)
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
        .onReceive(NotificationCenter.default.publisher(for: .haoVideoFavChanged)) { _ in
            // A poster long-press unfavourite (or a detail-page
            // toggle) must drop the card at once, not on the next
            // appear.
            items = VideoLibraryStore.favourites()
        }
        .onAppear { items = VideoLibraryStore.favourites() }
    }
}
