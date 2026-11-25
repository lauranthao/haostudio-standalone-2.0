// HAo Studio 2.0 — local radio + daily picks (S2-C leg).
//
// Pure queue builders over LOCAL data only — no login, no account,
// no network:
// - 私人漫游 (personal FM): a seeded shuffle of the local pool
//   (favourites + recent + most-played), minus disliked ids.
// - 心动模式 (heartbeat): the liked songs, seeded-shuffled.
// - 每日推荐 (daily picks): ~20 songs, ranked from the user's
//   own data (listen log + favourites + recent + playlist
//   tracks) — most-played and liked first, then more from the
//   same artists/albums. Deterministic from the data: no
//   Random, no shuffle, no seed. The per-day cache
//   (hao_daily) keeps one day stable; the list changes when
//   the user's data changes, not when the day rolls over.
//   Empty data -> [] (callers show the honest empty state).
// - 私人漫游 / 心动模式 keep their seeded shuffle (FM /
//   heartbeat are meant to shuffle); daily picks must not.
//
// All three are pure functions: the view models supply the inputs
// and play the returned queue. Nothing here invents a song.

import Foundation
import SwiftUI

enum MusicRadio {
    /// Private FM queue: local pool minus disliked, seeded shuffle.
    /// Seed is the day string so today's FM is stable within the day.
    static func fmQueue(
        favourites: [MusicSong],
        recent: [MusicSong],
        listenTop: [MusicSong],
        dislikedIds: Set<String>,
        seed: String,
        limit: Int = 50
    ) -> [MusicSong] {
        var seen = Set<String>()
        var pool: [MusicSong] = []
        for song in favourites + recent + listenTop {
            let key = song.identityKey
            // B4: dislikes are keyed by identityKey (platform|id),
            // not the bare song id — the same id on two platforms
            // used to dislike both. Bare ids stored before this
            // change still match via the songId check below.
            if dislikedIds.contains(song.songId) || dislikedIds.contains(key) { continue }
            if seen.insert(key).inserted { pool.append(song) }
        }
        var rng = MusicSeededRandom(seed: seed)
        return Array(rng.shuffle(pool).prefix(limit))
    }

    /// Heartbeat queue: the liked songs, seeded-shuffled.
    static func heartbeatQueue(
        favourites: [MusicSong],
        seed: String,
        limit: Int = 50
    ) -> [MusicSong] {
        var rng = MusicSeededRandom(seed: seed)
        return Array(rng.shuffle(favourites).prefix(limit))
    }

    /// Daily picks: ~20 songs, ranked from the user's own data —
    /// never shuffled, never seeded-random.
    ///
    /// Every candidate is a real song from local data only
    /// (listen log + favourites + recent + playlist tracks), so
    /// every pick is playable through the normal music path.
    /// Ranking score per song (all integer, deterministic):
    ///   plays x 10  (a listen event needs >= 5 s heard, so a
    ///                play is a real listen, not a tap-through)
    ///   + 30 when liked (favourite)
    ///   + recent bonus 15..1 for the 15 newest recent plays
    ///   + freshness 10 (last played within 7 days of `dayKey`)
    ///     or 5 (within 30 days)
    ///   + heard bonus min(total heard seconds / 60, 10)
    /// Ties break by plays, then last-played time, then
    /// identityKey — a total order, so the same data always
    /// yields the same list.
    ///
    /// Composition (total = 20 by default):
    ///   - first half: the top-ranked songs overall;
    ///   - second half: more from the same artists/albums —
    ///     first songs by the 5 most-listened artists not
    ///     already picked, then songs sharing an album with a
    ///     first-half song (album only exists on favourites /
    ///     recent / playlist copies — the listen log carries no
    ///     album), then the next-ranked songs, so a thin library
    ///     still fills the list from ranked songs instead of
    ///     random ones. The second half also caps each artist
    ///     at 4 picks while other artists' ranked songs are
    ///     still available, so one artist cannot take the whole
    ///     list; a fill pass ignores the cap, so a one-artist
    ///     library still fills the list.
    /// Disliked songs (FM dislikes, identityKey or bare songId)
    /// are excluded from both halves — a song the user
    /// explicitly disliked must never be recommended.
    /// Empty pool -> []: callers show the honest empty state.
    static func dailyPicks(
        listenLog: [ListenEvent],
        favourites: [MusicSong],
        recent: [MusicSong],
        playlistTracks: [MusicSong] = [],
        dislikedIds: Set<String> = [],
        dayKey: String,
        total: Int = 20
    ) -> [MusicSong] {
        // 1. Aggregate the listen log per song.
        struct LogStats {
            var song: MusicSong
            var plays: Int
            var lastAt: Int
            var heardSeconds: Int
        }
        var stats: [String: LogStats] = [:]
        var logOrder: [String] = []
        for event in listenLog {
            let song = MusicSong(
                songId: event.songId, title: event.title, artist: event.artist,
                cover: event.cover, platform: event.platform, dur: event.totalDur)
            let key = song.identityKey
            if var existing = stats[key] {
                existing.plays += 1
                existing.lastAt = max(existing.lastAt, event.at)
                existing.heardSeconds += event.dur
                if existing.song.cover.isEmpty, !song.cover.isEmpty {
                    existing.song.cover = song.cover
                }
                stats[key] = existing
            } else {
                stats[key] = LogStats(
                    song: song, plays: 1, lastAt: event.at, heardSeconds: event.dur)
                logOrder.append(key)
            }
        }
        // 2. Candidate pool: union of log + favourites + recent +
        //    playlist tracks. Favourites first so their fuller
        //    metadata (album, cover) wins the merge.
        var pool: [String: MusicSong] = [:]
        var poolOrder: [String] = []
        func addToPool(_ song: MusicSong) {
            let key = song.identityKey
            if var kept = pool[key] {
                if kept.cover.isEmpty, !song.cover.isEmpty { kept.cover = song.cover }
                if kept.album.isEmpty, !song.album.isEmpty { kept.album = song.album }
                pool[key] = kept
            } else {
                pool[key] = song
                poolOrder.append(key)
            }
        }
        for song in favourites { addToPool(song) }
        for song in recent { addToPool(song) }
        for song in playlistTracks { addToPool(song) }
        for key in logOrder {
            // b49sweep P2-15: no force unwrap — the key was
            // inserted in the same loop today, but one edit away
            // from a crash.
            guard let entry = stats[key] else { continue }
            addToPool(entry.song)
        }
        // 3. Score every candidate.
        let favKeys = Set(favourites.map { $0.identityKey })
        var recentIndex: [String: Int] = [:]
        for (index, song) in recent.enumerated() {
            if recentIndex[song.identityKey] == nil {
                recentIndex[song.identityKey] = index
            }
        }
        let referenceMs = Self.dayReferenceMs(for: dayKey)
        struct Scored {
            var song: MusicSong
            var score: Int
            var plays: Int
            var lastAt: Int
        }
        var scored: [Scored] = []
        for key in poolOrder {
            guard let song = pool[key] else { continue }
            if dislikedIds.contains(song.songId) || dislikedIds.contains(key) { continue }
            if song.songId.isEmpty && song.title.isEmpty { continue }
            let stat = stats[key]
            let plays = stat?.plays ?? 0
            let lastAt = stat?.lastAt ?? 0
            var score = plays * 10
            if favKeys.contains(key) { score += 30 }
            if let index = recentIndex[key] { score += max(0, 15 - index) }
            if let ref = referenceMs {
                if lastAt >= ref - 7 * 24 * 3600 * 1000 { score += 10 }
                else if lastAt >= ref - 30 * 24 * 3600 * 1000 { score += 5 }
            }
            score += min((stat?.heardSeconds ?? 0) / 60, 10)
            scored.append(Scored(song: song, score: score, plays: plays, lastAt: lastAt))
        }
        guard !scored.isEmpty else { return [] }
        // Total order: score, plays, last-played, identityKey.
        let ranked = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            if $0.lastAt != $1.lastAt { return $0.lastAt > $1.lastAt }
            return $0.song.identityKey < $1.song.identityKey
        }
        // 4. First half: the top-ranked songs overall.
        let half = total / 2
        var picked: [MusicSong] = []
        var seen = Set<String>()
        for entry in ranked.prefix(half) {
            if seen.insert(entry.song.identityKey).inserted { picked.append(entry.song) }
        }
        // 5. Second half: same artists, then same albums, then
        //    the next-ranked songs — with a per-artist cap so one
        //    artist cannot take the whole list while other
        //    artists' ranked songs are still available (max 4
        //    per artist); a fill pass ignores the cap so a
        //    one-artist library still fills the list.
        let artistSet = Set(topArtists(from: listenLog, limit: 5))
        let firstHalfAlbums = Set(picked.map { $0.album }.filter { !$0.isEmpty })
        var artistPool: [Scored] = []
        var albumPool: [Scored] = []
        var restPool: [Scored] = []
        for entry in ranked {
            if seen.contains(entry.song.identityKey) { continue }
            if artistSet.contains(entry.song.artist) { artistPool.append(entry) }
            else if !entry.song.album.isEmpty && firstHalfAlbums.contains(entry.song.album) {
                albumPool.append(entry)
            } else {
                restPool.append(entry)
            }
        }
        let maxPerArtist = 4
        var artistCounts: [String: Int] = [:]
        for song in picked where !song.artist.isEmpty {
            artistCounts[song.artist, default: 0] += 1
        }
        func underCap(_ song: MusicSong) -> Bool {
            guard !song.artist.isEmpty else { return true }
            return (artistCounts[song.artist] ?? 0) < maxPerArtist
        }
        for entry in artistPool + albumPool + restPool {
            if picked.count >= total { break }
            guard underCap(entry.song) else { continue }
            if seen.insert(entry.song.identityKey).inserted {
                picked.append(entry.song)
                if !entry.song.artist.isEmpty {
                    artistCounts[entry.song.artist, default: 0] += 1
                }
            }
        }
        if picked.count < total {
            for entry in artistPool + albumPool + restPool {
                if picked.count >= total { break }
                if seen.insert(entry.song.identityKey).inserted { picked.append(entry.song) }
            }
        }
        return picked
    }

    /// Start-of-day instant (epoch ms) for a `YYYY-MM-DD` day key,
    /// in the device calendar — the same calendar musicDayKey
    /// uses. Nil when the key does not parse, in which case daily
    /// picks simply skip the freshness bonus.
    static func dayReferenceMs(for dayKey: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayKey) else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    /// Most-played songs from the listen log (by event count), with
    /// full song lengths from totalDur. Mirrors Flutter
    /// ListenReport.compute's bySong aggregation.
    static func mostPlayedSongs(from events: [ListenEvent], limit: Int) -> [MusicSong] {
        var counts: [String: (song: MusicSong, plays: Int)] = [:]
        var order: [String] = []
        for event in events {
            let key = "\(event.platform.rawValue)|\(event.songId)"
            let song = MusicSong(
                songId: event.songId, title: event.title, artist: event.artist,
                cover: event.cover, platform: event.platform, dur: event.totalDur
            )
            if let existing = counts[key] {
                counts[key] = (song: existing.song, plays: existing.plays + 1)
            } else {
                counts[key] = (song: song, plays: 1)
                order.append(key)
            }
        }
        // b49sweep P2-15: no force unwraps — the keys were
        // inserted in the same loop today, but one edit away
        // from a crash.
        let ranked = order.sorted { (counts[$0]?.plays ?? 0) > (counts[$1]?.plays ?? 0) }
        return ranked.prefix(limit).compactMap { counts[$0]?.song }
    }

    /// Top artists by listen count, most first.
    static func topArtists(from events: [ListenEvent], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for event in events {
            let artist = event.artist.isEmpty ? "—" : event.artist
            counts[artist] = (counts[artist] ?? 0) + 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }
}

// MARK: - FM local view (Coda §3.7, b45-b)

/// FM mode: personal FM (seeded local pool) or heartbeat
/// (liked songs, seeded). Both are local-only — no login.
enum MusicFMMode: Hashable {
    case fm
    case heartbeat

    var title: String {
        switch self {
        case .fm: return "私人漫游"
        case .heartbeat: return "心动模式"
        }
    }
}

@MainActor
final class MusicFMViewModel: ObservableObject {
    @Published private(set) var queue: [MusicSong] = []
    @Published private(set) var refillFailed = false

    private let mode: MusicFMMode

    init(mode: MusicFMMode) {
        self.mode = mode
    }

    var title: String { mode.title }

    func buildQueue() {
        refillFailed = false
        queue = Self.queueFor(mode: mode)
    }

    static func queueFor(mode: MusicFMMode) -> [MusicSong] {
        queueFor(mode: mode, seed: musicDayKey(of: Date()))
    }

    /// A fresh batch for the same mode with an explicit seed
    /// (b49sweep P1-6: the mid-session refill). The base
    /// queueFor(mode:) keeps the day seed, so a refill with the
    /// same seed would return the same songs.
    static func queueFor(mode: MusicFMMode, seed: String) -> [MusicSong] {
        switch mode {
        case .fm:
            return MusicRadio.fmQueue(
                favourites: MusicLibraryStore.favSongs(),
                recent: MusicLibraryStore.getRecent(),
                listenTop: MusicRadio.mostPlayedSongs(from: MusicLibraryStore.getListenLog(), limit: 20),
                dislikedIds: MusicLibraryStore.fmDislikedIds(),
                seed: seed
            )
        case .heartbeat:
            return MusicRadio.heartbeatQueue(
                favourites: MusicLibraryStore.favSongs(), seed: seed
            )
        }
    }

    /// Refill an empty queue (b49sweep P1-9): one synchronous
    /// attempt. queueFor is a pure function of local data + the
    /// day seed, so rebuilding 1 s later returns the same empty
    /// queue — the old 3×/1 s retry (Coda §9.2 PersonalFMRefill)
    /// could never succeed and only delayed the honest empty
    /// state. A later data change (a new favourite / recent
    /// play) re-runs this from the view's store-change
    /// observers; exhaustion sets refillFailed so the view can
    /// toast.
    func refillIfEmpty() {
        refillFailed = false
        guard queue.isEmpty else { return }
        queue = Self.queueFor(mode: mode)
        if queue.isEmpty {
            refillFailed = true
        }
    }
}

/// Local FM page (Coda FMView layout, local data): cover phone
/// 240 / other 300 (min 110, max min(width−48, height×0.38)),
/// r16, shadow black 0.35 / r28 / y14, paused scale 0.94
/// bouncy; title detailTitle (small screen cardTitle), artist
/// secondary; controls spacing 24 — centre play 64 circle
/// accentGradient (shadow accent 0.4 / r12 / y4, icon 24 bold),
/// sides (dislike trash / next forward.fill) 48 circle primary
/// 6% (icon 17 medium secondary), like 16pt in a 48 circle.
/// Start button "开始漫游": capsule, white body semibold,
/// padding 24×12, accentGradient, shadow accent 0.35 / r10 /
/// y3. No login anywhere.
struct MusicFMView: View {
    var mode: MusicFMMode

    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var fmVM: MusicFMViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.haoTheme) private var theme
    @State private var isFavCurrent = false

    init(mode: MusicFMMode) {
        self.mode = mode
        _fmVM = StateObject(wrappedValue: MusicFMViewModel(mode: mode))
    }

    /// The FM/heartbeat source for this mode (b49sweep P1-7):
    /// the old code always used .fm/"fm", so a heartbeat session
    /// recorded the wrong place (its context rebuilt as FM) and
    /// the view's toasts/buttons said 漫游 in 心动模式.
    private var fmSource: PlaySource {
        PlaySource(kind: mode == .heartbeat ? .heartbeat : .fm,
                   id: mode == .heartbeat ? "heartbeat" : "fm")
    }

    /// The song this page's controls act on (b49sweep P1-7):
    /// only the current song when its play context matches this
    /// mode. Any other playing song (a playlist/search song, or
    /// the other FM mode) renders the start state instead of
    /// wearing this mode's cover and controls — the old code
    /// showed whatever was playing, and the trash button then
    /// disliked a song that had nothing to do with FM.
    private var fmSong: MusicSong? {
        guard let song = playerVM.currentSong,
              playerVM.currentPlayContext?.source.kind == fmSource.kind else { return nil }
        return song
    }

    var body: some View {
        GeometryReader { geo in
            let coverSize = fmCoverSize(width: geo.size.width, height: geo.size.height)
            VStack(spacing: 0) {
                Spacer()
                if let song = fmSong {
                    MusicCoverView(urlString: song.cover, size: coverSize, cornerRadius: HaoLayout.cornerLarge)
                        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
                        .scaleEffect(playerVM.isPlaying ? 1.0 : 0.94)
                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: playerVM.isPlaying)
                    Text(song.title.isEmpty ? "未知歌曲" : song.title)
                        .font(horizontalSizeClass == .compact ? .haoBodyStrong : .haoDetailTitle)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .padding(.top, 24)
                    Text(song.artist.isEmpty ? "未知艺人" : song.artist)
                        .font(.haoSubhead)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .padding(.top, 4)
                    controlsRow(song: song)
                        .padding(.top, 24)
                } else {
                    startState
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        }
        .background(theme.scaffoldBackground)
        .navigationTitle(fmVM.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            fmVM.buildQueue()
            if !fmVM.queue.isEmpty, playerVM.currentSong == nil {
                // b46: FM queue is a reloadable place.
                playerVM.playAll(fmVM.queue, source: fmSource, sourceDisplayName: fmVM.title)
            }
            refreshFav()
            fmVM.refillIfEmpty()
        }
        .onChange(of: playerVM.currentSong?.identityKey) { _, _ in refreshFav() }
        .onReceive(NotificationCenter.default.publisher(for: .haoMusicFavChanged)) { _ in
            refreshFav()
            // b49sweep P1-9: the pool changed — a previously empty
            // FM queue may have songs now.
            fmVM.refillIfEmpty()
        }
        .onReceive(NotificationCenter.default.publisher(for: .haoMusicRecentChanged)) { _ in
            // b49sweep P1-9: same data-driven retry as favourites.
            fmVM.refillIfEmpty()
        }
        .onChange(of: fmVM.refillFailed) { _, failed in
            if failed { playerVM.showToast("\(fmVM.title)暂时不可用") }
        }
    }

    private func fmCoverSize(width: CGFloat, height: CGFloat) -> CGFloat {
        let target: CGFloat = horizontalSizeClass == .compact ? 240 : 300
        let capped = min(target, width - 48, height * 0.38)
        return max(110, capped)
    }

    private var startState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(theme.textMuted)
            Text(mode == .fm ? "开始漫游" : "心动模式")
                .font(.haoDetailTitle)
                .foregroundStyle(theme.textPrimary)
            Text("从你收藏和常听的歌里出发。")
                .font(.haoSubhead)
                .foregroundStyle(theme.textSecondary)
            Button(action: startPlayback) {
                Text(mode == .fm ? "开始漫游" : "开始心动模式")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [theme.accent, theme.accent.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: theme.accent.opacity(0.35), radius: 10, y: 3)
            }
            .buttonStyle(MusicPressScaleStyle())
        }
    }

    private func startPlayback() {
        fmVM.buildQueue()
        if fmVM.queue.isEmpty {
            fmVM.refillIfEmpty()
            return
        }
        // b46: FM queue is a reloadable place.
        playerVM.playAll(fmVM.queue, source: fmSource, sourceDisplayName: fmVM.title)
    }

    private func controlsRow(song: MusicSong) -> some View {
        HStack(spacing: 24) {
            Button(action: {
                MusicLibraryStore.addFMDisliked(key: song.identityKey)
                playerVM.next()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel("不喜欢，下一首")
            Button(action: {
                isFavCurrent = MusicLibraryStore.toggleFav(song)
            }) {
                Image(systemName: isFavCurrent ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFavCurrent ? theme.liveRed : theme.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel(isFavCurrent ? "取消收藏" : "收藏")
            Button(action: { playerVM.togglePlayPause() }) {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        LinearGradient(
                            colors: [theme.accent, theme.accent.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        in: Circle()
                    )
                    .shadow(color: theme.accent.opacity(0.4), radius: 12, y: 4)
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel(playerVM.isPlaying ? "暂停" : "播放")
            Button(action: { playerVM.next() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(MusicPressScaleStyle())
            .accessibilityLabel("下一首")
        }
    }

    private func refreshFav() {
        if let song = playerVM.currentSong {
            isFavCurrent = MusicLibraryStore.isFav(song)
        } else {
            isFavCurrent = false
        }
    }
}
