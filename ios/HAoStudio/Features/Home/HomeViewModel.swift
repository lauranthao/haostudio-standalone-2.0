// HAo Studio 2.0 — home aggregation view model (Home-B leg).
//
// The five home sections, all from LOCAL data only — never a fake
// row, never a network-made room or song:
//
// - Continue watching: VideoLibraryStore.history() as-is, newest
//   first, max 10 — exactly like the video tab
//   (VideoTabViewModel.reload takes history() raw, no filtering;
//   finished rows stay). shouldResume is NOT applied here; it
//   lives only in the detail page's resume point.
// - Continue listening: the music resume map (musicResume,
//   MusicLibraryStore.resumeMap) — the most recently played song
//   with a real resume point (same rule as video: over 10 s in,
//   at least 30 s from the end); no valid resume point falls back
//   to the first recent play; nothing at all is an empty section.
// - Hot live: followed rooms + watched rooms merged and deduped
//   (newest first, max 10). isLive starts false and is only set
//   true when a room-info check confirms the room is on air; an
//   unconfirmed room never shows a LIVE badge.
// - Daily: the same daily-picks computation as
//   MusicDiscoveryViewModel.reloadDaily (cached per day in
//   hao_daily, otherwise MusicRadio.dailyPicks ranked from
//   the listen log + favourites + recent + playlists — no
//   shuffle, no seeded random), max 10.
// - Recent plays: MusicLibraryStore.getRecent(), first 10.
//
// Live status: the per-room check reuses the existing site
// resolvers — LiveSites.resolver(for:) + roomInfo(roomId:) —
// which all five platforms implement. There is NO LiveDataGateway
// implementation in this checkout (the protocol has no conformer;
// the live tab's gateway is nil), so the gateway's fetchRoomDetail
// cannot be used. One reload checks at most the 10 merged rooms,
// each with an 8 s timeout; a failure or timeout leaves isLive
// false (unknown), never blocks reload, never throws to the UI.
//
// The stores are plain value-access layers (not ObservableObject):
// this view model owns the published state and reload() reads them.

import Foundation
import SwiftUI

/// One live room on the home page. The identity is platform|roomId
/// (LiveResumeKey), exactly like the follow / history rows — a room
/// id alone is not unique across the five platforms. Declared here
/// once; no other file declares this type.
struct HomeLiveItem: Equatable, Identifiable {
    /// platform|roomId.
    let id: String
    var platform: String
    var roomId: String
    var title: String
    var nick: String
    var cover: String
    /// True only when a room-info check confirmed the room is on
    /// air. False also means "unknown" — never show a LIVE badge
    /// for an unconfirmed room.
    var isLive: Bool

    init(
        platform: String,
        roomId: String,
        title: String,
        nick: String,
        cover: String,
        isLive: Bool = false
    ) {
        self.id = LiveResumeKey.key(platform: platform, roomId: roomId)
        self.platform = platform
        self.roomId = roomId
        self.title = title
        self.nick = nick
        self.cover = cover
        self.isLive = isLive
    }

    init(follow: LiveFollowedRoom) {
        self.init(
            platform: follow.platform, roomId: follow.roomId,
            title: follow.title, nick: follow.nick, cover: follow.cover)
    }

    init(history: LiveHistoryEntry) {
        self.init(
            platform: history.platform, roomId: history.roomId,
            title: history.title, nick: history.nick, cover: history.cover)
    }
}

/// Live-status check: given one home live item, answer whether the
/// room is on air right now. The completion may fire on any queue;
/// false also covers "unknown / check failed". The view model only
/// ever applies `true` — an unconfirmed room keeps isLive false.
typealias HomeLiveStatusChecker = (HomeLiveItem, @escaping (Bool) -> Void) -> Void

/// One-shot gate so a room-info answer and its timeout cannot both
/// report for the same room.
private final class HomeLiveStatusGate {
    private let lock = NSLock()
    private var done = false

    /// True the first time it is called, false afterwards.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var continueWatching: [VideoHistoryEntry] = []
    @Published private(set) var continueListening: [MusicSong] = []
    @Published private(set) var hotLive: [HomeLiveItem] = []
    @Published private(set) var daily: [MusicSong] = []
    @Published private(set) var recentPlays: [MusicSong] = []

    /// Per-section cap for every home section.
    static let sectionLimit = 10
    /// Per-room ceiling for a live-status check.
    static let liveStatusTimeoutSeconds = 8.0

    private let liveStatusChecker: HomeLiveStatusChecker?
    /// Bump on every reload; late status answers from an older
    /// reload are dropped.
    private var liveStatusGeneration = 0

    /// `liveStatusChecker` nil = never confirm live status (all
    /// rooms stay isLive false). Tests pass nil or a stub; the app
    /// uses the default room-info checker.
    init(liveStatusChecker: HomeLiveStatusChecker? = HomeViewModel.defaultLiveStatusChecker) {
        self.liveStatusChecker = liveStatusChecker
    }

    /// Synchronous local reads for all five sections. Live-status
    /// confirmation runs after, through the injected checker, and
    /// only ever flips isLive to true.
    func reload() {
        let videoHistory = VideoLibraryStore.history()
        let recent = MusicLibraryStore.getRecent()
        let listenLog = MusicLibraryStore.getListenLog()
        let resumeMap = MusicLibraryStore.resumeMap()
        let dailyPicks = Self.loadDailyPicks(listenLog: listenLog)
        reload(
            videoHistory: videoHistory,
            recent: recent,
            listenLog: listenLog,
            resumeMap: resumeMap,
            follows: LiveLibraryStore.follows(),
            liveHistory: LiveLibraryStore.history(),
            dailyPicks: dailyPicks)
    }

    /// reload() with the inputs supplied (same composition, no
    /// disk reads) so tests can drive it with fixture data.
    func reload(
        videoHistory: [VideoHistoryEntry],
        recent: [MusicSong],
        listenLog: [ListenEvent],
        resumeMap: [String: Int],
        follows: [LiveFollowedRoom],
        liveHistory: [LiveHistoryEntry],
        dailyPicks: [MusicSong]
    ) {
        continueWatching = Self.continueWatchingEntries(from: videoHistory)
        recentPlays = Array(recent.prefix(Self.sectionLimit))
        if let song = Self.resumeSong(recent: recent, listenLog: listenLog, resumeMap: resumeMap) {
            continueListening = [song]
        } else {
            continueListening = Array(recent.prefix(1))
        }
        hotLive = Self.hotLiveItems(follows: follows, history: liveHistory)
        daily = Array(dailyPicks.prefix(Self.sectionLimit))
        refreshLiveStatus()
    }

    // MARK: - Pure aggregation (unit-tested, no I/O)

    /// Continue watching: history() as-is, newest first, capped —
    /// the same as the video tab (VideoTabViewModel.reload). No
    /// shouldResume filtering here: a finished row still shows,
    /// like the video tab. The store's history() is already
    /// newest-first, but a migrated file is not guaranteed
    /// ordered, so sort here.
    static func continueWatchingEntries(
        from history: [VideoHistoryEntry],
        limit: Int = sectionLimit
    ) -> [VideoHistoryEntry] {
        let newestFirst = history.sorted { $0.updatedAt > $1.updatedAt }
        return Array(newestFirst.prefix(limit))
    }

    /// Whether a music resume point is real: the same rule as
    /// video shouldResume (over 10 s in, at least 30 s from the
    /// end; unknown duration counts as resumable).
    static func isValidMusicResume(seconds: Int, durationSeconds: Int) -> Bool {
        guard seconds > Int(VideoLibraryStore.minResumeSeconds) else { return false }
        guard durationSeconds > 0 else { return true }
        return seconds < durationSeconds - Int(VideoLibraryStore.finishMarginSeconds)
    }

    /// The断点续播 song: the most recently played song with a valid
    /// resume point. Recent plays are scanned newest-first; songs
    /// that fell out of recent (cap 100) are then found through
    /// the listen log, newest-first. Nil when no stored resume
    /// point is valid.
    static func resumeSong(
        recent: [MusicSong],
        listenLog: [ListenEvent],
        resumeMap: [String: Int]
    ) -> MusicSong? {
        for song in recent {
            let seconds = resumeMap[song.identityKey] ?? 0
            if isValidMusicResume(seconds: seconds, durationSeconds: song.dur) {
                return song
            }
        }
        var seen = Set(recent.map { $0.identityKey })
        for event in listenLog.reversed() {
            let song = MusicSong(
                songId: event.songId, title: event.title, artist: event.artist,
                cover: event.cover, platform: event.platform, dur: event.totalDur)
            if !seen.insert(song.identityKey).inserted { continue }
            let seconds = resumeMap[song.identityKey] ?? 0
            if isValidMusicResume(seconds: seconds, durationSeconds: song.dur) {
                return song
            }
        }
        return nil
    }

    /// Hot live: follows + watched rooms merged, deduped by
    /// platform|roomId, newest first (follow time vs watch time),
    /// capped. When a room is both followed and watched, the newer
    /// record's title / cover wins.
    static func hotLiveItems(
        follows: [LiveFollowedRoom],
        history: [LiveHistoryEntry],
        limit: Int = sectionLimit
    ) -> [HomeLiveItem] {
        var merged: [(item: HomeLiveItem, at: Date)] = []
        for follow in follows {
            merged.append((item: HomeLiveItem(follow: follow), at: follow.followedAt))
        }
        for entry in history {
            merged.append((item: HomeLiveItem(history: entry), at: entry.watchedAt))
        }
        let newestFirst = merged.sorted { $0.at > $1.at }
        var seen = Set<String>()
        var out: [HomeLiveItem] = []
        for pair in newestFirst {
            if seen.insert(pair.item.id).inserted {
                out.append(pair.item)
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// Daily picks — the same computation as
    /// MusicDiscoveryViewModel.reloadDaily: ranked from the
    /// listen log + favourites + recent + playlist tracks
    /// (MusicRadio.dailyPicks), no shuffle, no seeded random.
    /// The same data always yields the same list; the per-day
    /// cache in loadDailyPicks keeps one day stable even as
    /// the user keeps listening.
    static func computeDailyPicks(
        listenLog: [ListenEvent],
        favourites: [MusicSong],
        recent: [MusicSong],
        dayKey: String,
        playlistTracks: [MusicSong] = [],
        dislikedIds: Set<String> = []
    ) -> [MusicSong] {
        return MusicRadio.dailyPicks(
            listenLog: listenLog,
            favourites: favourites,
            recent: recent,
            playlistTracks: playlistTracks,
            dislikedIds: dislikedIds,
            dayKey: dayKey)
    }

    /// Daily picks with the per-day cache (hao_daily), exactly
    /// like MusicDiscoveryViewModel.reloadDaily: a cached day is
    /// returned as-is; a missing day is computed and saved when
    /// non-empty.
    static func loadDailyPicks(
        listenLog: [ListenEvent],
        dayKey: String = musicDayKey(of: Date())
    ) -> [MusicSong] {
        if let cached = MusicLibraryStore.dailyTracks(for: dayKey) {
            return cached
        }
        let picks = computeDailyPicks(
            listenLog: listenLog,
            favourites: MusicLibraryStore.favSongs(),
            recent: MusicLibraryStore.getRecent(),
            dayKey: dayKey,
            playlistTracks: MusicLibraryStore.getLists().flatMap { $0.tracks },
            dislikedIds: MusicLibraryStore.fmDislikedIds())
        if !picks.isEmpty {
            MusicLibraryStore.saveDailyTracks(picks, for: dayKey)
        }
        return picks
    }

    // MARK: - Live status

    /// Confirm live status for the rooms in hotLive (at most 10),
    /// through the injected checker. A late answer (older reload)
    /// is dropped; `false` (unknown / failed) changes nothing.
    private func refreshLiveStatus() {
        guard let checker = liveStatusChecker, !hotLive.isEmpty else { return }
        liveStatusGeneration += 1
        let generation = liveStatusGeneration
        for item in hotLive {
            checker(item) { [weak self] isLive in
                guard isLive else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    guard self.liveStatusGeneration == generation else { return }
                    if let index = self.hotLive.firstIndex(where: { $0.id == item.id }) {
                        self.hotLive[index].isLive = true
                    }
                }
            }
        }
    }

    /// Default checker: the existing per-platform room-info call
    /// (LiveSites.resolver(for:) + roomInfo), one call per room,
    /// 8 s timeout. Unknown platform strings never hit the
    /// network; failures and timeouts answer false (unknown).
    static func defaultLiveStatusChecker(
        item: HomeLiveItem,
        completion: @escaping (Bool) -> Void
    ) {
        guard let platform = LivePlatform(rawValue: item.platform) else {
            completion(false)
            return
        }
        let resolver = LiveSites.resolver(for: platform)
        let gate = HomeLiveStatusGate()
        let timeout = DispatchWorkItem {
            if gate.claim() { completion(false) }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + liveStatusTimeoutSeconds, execute: timeout)
        resolver.roomInfo(roomId: item.roomId) { result in
            timeout.cancel()
            guard gate.claim() else { return }
            switch result {
            case .success(let room):
                completion(room.isLive)
            case .failure:
                completion(false)
            }
        }
    }
}
