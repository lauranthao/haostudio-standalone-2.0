// HAo Studio 2.0 — video service contracts (S3 seam).
//
// The two protocols the three S3 legs build against. Leg A (player)
// consumes them, Leg B (services) implements them, Leg C (UI) injects
// the implementations at app startup. None of the three legs may
// change these signatures — if a signature proves wrong, stop and
// report to the coordinator instead of inventing a parallel one.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

/// Resolves a playable URL for one episode on one line.
/// Implemented by CmsClient (Leg B); consumed by VideoDriver (Leg A).
/// Serial, fastest first; the FIRST playable URL wins. `excluding`
/// lists URLs that already failed for this request — never hand out
/// an excluded URL twice (S2 gap: the music driver dropped this list
/// and retried the same dead URL).
protocol VideoPlayURLResolver {
    func resolvePlayURL(
        detail: VideoDetail,
        episode: PlayEpisode,
        line: PlayLine,
        excluding: [URL],
        completion: @escaping (URL?) -> Void
    )
}

/// One danmaku line for a VOD episode.
struct DanmakuItem: Equatable {
    let text: String
    /// Position in the episode, seconds.
    let timeSeconds: Double
    /// "rrggbb" hex without '#'; empty means the default colour.
    let colorHex: String
    /// Top (fixed) danmaku vs scrolling danmaku.
    let isTop: Bool
}

/// Fetches danmaku for a VOD episode. Implemented by Leg B as a port
/// of the Flutter `vod_danmaku_client.dart`; consumed by
/// VodDanmakuLayer (Leg A). Read-only: the app never sends danmaku.
protocol VodDanmakuProvider {
    /// Fetch danmaku for one episode. The Bool is `failed`:
    /// true when the danmaku server could not be reached at
    /// all (transport failure in either hop) — as opposed to
    /// "this title has no danmaku", which answers [] + false.
    /// The layer surfaces a visible failure state from it
    /// (sweep-4 P2-9): a silent [] used to read exactly like
    /// "no danmaku for this episode".
    func fetchDanmaku(for episode: PlayEpisode, completion: @escaping ([DanmakuItem], Bool) -> Void)
}
