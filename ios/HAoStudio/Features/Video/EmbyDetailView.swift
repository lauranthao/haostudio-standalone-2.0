// HAo Studio 2.0 — Emby detail page (S3-C leg).
//
// The Emby detail layout is the same VidHub-style detail as CMS
// (cover top, big play button below, lines + episode grid) —
// Emby streams arrive as play lines through the gateway, so the
// page is the shared VideoDetailContentView with an Emby loader
// (VideoDetailSource.emby). No second layout is kept.
//
// Server-side actions: the favourite toggle mirrors to the
// server (VideoDetailViewModel.toggleFavourite); playback
// reporting + played marking run in the VOD driver
// (EmbyPlaybackReporter). The local favourite / resume in the
// shared detail view remain the UI source of truth — nothing
// here is faked from the server.

import SwiftUI

struct EmbyDetailView: View {
    var item: VideoItem

    var body: some View {
        VideoDetailView(item: item, source: .emby)
    }
}
