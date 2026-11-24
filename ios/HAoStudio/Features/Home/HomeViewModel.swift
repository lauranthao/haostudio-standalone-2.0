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
// each with an 8 s timeout; a failure or timeout leaves the
// previous badge value alone (unknown), never blocks reload, never
// throws to the UI — only a successful "off air" answer clears a
// badge. The check is throttled (build 36, item 10): a room set
// checked less than 5 min ago is not checked again, and a room
// with a check already in flight is never fired twice — so a tab
// switch, a pop back, or a favourite tap does not re-fire up to
// 10 room-info requests per reload.
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
    /// air. False means "not confirmed live" — off air, or the
    /// check never ran / failed. A confirmed-true value survives a
    /// reload until a later check positively reports the room off
    /// air (see HomeLiveStatus), so the badge does not flicker off
    /// on every reload while the check is still in flight.
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

/// Live-status answer for one room. The old Bool conflated
/// "room-info succeeded and the room is off air" with "the check
/// failed / timed out", so a failed check and a real switch-off
/// looked identical — the view model could only ever clear the
/// badge by rebuilding the list, which flickered every reload.
/// Tri-state now: `.live` sets the badge, `.offline` clears it,
/// `.unknown` keeps whatever the UI already shows.
enum HomeLiveStatus {
    case live
    case offline
    case unknown
}

/// Live-status check: given one home live item, answer whether the
/// room is on air right now. The completion may fire on any queue.
typealias HomeLiveStatusChecker = (HomeLiveItem, @escaping (HomeLiveStatus) -> Void) -> Void

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
    /// The full recent list (up to MusicLibraryStore.maxRecent),
    /// for the "全部" page. `recentPlays` stays capped at the
    /// section limit for the home section itself — the two used to
    /// be the same array, so "全部" showed the same 10 rows.
    @Published private(set) var allRecentPlays: [MusicSong] = []

    /// Per-section cap for every home section.
    static let sectionLimit = 10
    /// Per-room ceiling for a live-status check.
    static let liveStatusTimeoutSeconds = 8.0

    private let liveStatusChecker: HomeLiveStatusChecker?
    /// Bump on every reload; late status answers from an older
    /// reload are dropped.
    private var liveStatusGeneration = 0
    /// Live-status throttle (build 36, item 10): the room set
    /// (platform|roomId ids) of the last check round, and when
    /// it was fired. A reload whose hotLive set matches and
    /// falls inside `liveStatusThrottleSeconds` skips the check
    /// — the carried badges are the last confirmed answers, so
    /// nothing flickers and no request is wasted.
    static let liveStatusThrottleSeconds = 300.0
    private var liveStatusLastCheckAt: Date?
    private var liveStatusLastCheckedRoomIDs: Set<String> = []
    /// Room ids with a check currently in flight. A reload
    /// while a round is still out never fires a duplicate
    /// request for the same room; the in-flight answer still
    /// lands (it writes by room id, not by reload round).
    private var liveStatusInFlightIDs: Set<String> = []
    /// Appearance-reload coalescing (build 36, item 10):
    /// HomeView's onAppear (tab switch back) and its
    /// path-empty change (pop back from a detail) are
    /// different triggers for the same "back at home" event,
    /// and one return trip can fire both. A reload that ran
    /// less than this long ago makes the second one a
    /// duplicate — skip it. An explicit reload (pull-to-refresh)
    /// always runs and resets the clock.
    static let appearanceReloadCoalesceSeconds = 1.0
    private var lastReloadAt: Date?
    /// Clock, injectable so tests can move time past the
    /// throttle / coalescing windows. Defaults to the wall
    /// clock; the app never passes one.
    private let now: () -> Date

    /// `liveStatusChecker` nil = never confirm live status (all
    /// rooms stay isLive false). Tests pass nil or a stub; the app
    /// uses the default room-info checker.
    init(
        liveStatusChecker: HomeLiveStatusChecker? = HomeViewModel.defaultLiveStatusChecker,
        now: @escaping () -> Date = Date.init
    ) {
        self.liveStatusChecker = liveStatusChecker
        self.now = now
    }

    /// Reload for an appearance trigger (HomeView onAppear /
    /// path-empty, and the "全部" page's onAppear). Coalesced:
    /// if any reload ran inside the window, the data is already
    /// fresh and this one is skipped — one return trip never
    /// pays for two full reloads. Pull-to-refresh calls
    /// reload() directly and always runs.
    func reloadForAppearance() {
        if let last = lastReloadAt,
           now().timeIntervalSince(last) < Self.appearanceReloadCoalesceSeconds {
            return
        }
        reload()
    }

    /// Synchronous local reads for all five sections. Live-status
    /// confirmation runs after, through the injected checker: a
    /// confirmed-live room keeps its badge across the rebuild, a
    /// positively-offline answer clears it, and a failed / timed-out
    /// check leaves the previous value alone.
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
        // Every reload — local or appearance — resets the
        // coalescing clock, so a second appearance trigger
        // right after it is recognised as the same event.
        lastReloadAt = now()
        continueWatching = Self.continueWatchingEntries(from: videoHistory)
        recentPlays = Array(recent.prefix(Self.sectionLimit))
        allRecentPlays = recent
        if let song = Self.resumeSong(recent: recent, listenLog: listenLog, resumeMap: resumeMap) {
            continueListening = [song]
        } else {
            continueListening = Array(recent.prefix(1))
        }
        // Carry a confirmed-live badge across the rebuild: the
        // merged list is rebuilt fresh on every reload, and
        // resetting isLive to false here made every LIVE badge
        // blink off until the room-info answers came back (up to
        // 8 s per room — visible on every tab switch and every
        // favourite tap). A room that went off air loses the badge
        // when its fresh check answers `.offline` below, not here.
        let previouslyLive = Set(hotLive.filter { $0.isLive }.map { $0.id })
        hotLive = Self.hotLiveItems(follows: follows, history: liveHistory)
        for index in hotLive.indices where previouslyLive.contains(hotLive[index].id) {
            hotLive[index].isLive = true
        }
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
    /// through the injected checker. Throttled: the same room set
    /// inside 5 min is not checked again, and a room with a check
    /// already in flight is never fired twice. A late answer
    /// (older reload) is dropped; `.unknown` (failed / timed out)
    /// changes nothing, so a transient network failure never
    /// blinks a good badge off — only a successful `.offline`
    /// clears one.
    private func refreshLiveStatus() {
        guard let checker = liveStatusChecker, !hotLive.isEmpty else { return }
        let roomIDs = Set(hotLive.map { $0.id })
        // Same room set, checked inside the window — reuse the
        // last answers (badges were carried across the rebuild
        // above). A changed set, or an expired window, re-checks
        // — minus rooms already in flight.
        if roomIDs == liveStatusLastCheckedRoomIDs,
           let lastCheckAt = liveStatusLastCheckAt,
           now().timeIntervalSince(lastCheckAt) < Self.liveStatusThrottleSeconds {
            return
        }
        let pending = hotLive.filter { !liveStatusInFlightIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        liveStatusLastCheckAt = now()
        liveStatusLastCheckedRoomIDs = roomIDs
        liveStatusGeneration += 1
        let generation = liveStatusGeneration
        for item in pending {
            liveStatusInFlightIDs.insert(item.id)
            checker(item) { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.liveStatusInFlightIDs.remove(item.id)
                    guard status != .unknown else { return }
                    guard self.liveStatusGeneration == generation else { return }
                    if let index = self.hotLive.firstIndex(where: { $0.id == item.id }) {
                        self.hotLive[index].isLive = (status == .live)
                    }
                }
            }
        }
    }

    /// Default checker: the existing per-platform room-info call
    /// (LiveSites.resolver(for:) + roomInfo), one call per room,
    /// 8 s timeout. Unknown platform strings never hit the
    /// network; failures and timeouts answer `.unknown`. A
    /// successful room-info answer reports the room's real state
    /// (`.live` / `.offline`) — only that positively clears a
    /// badge, never a failed check.
    static func defaultLiveStatusChecker(
        item: HomeLiveItem,
        completion: @escaping (HomeLiveStatus) -> Void
    ) {
        guard let platform = LivePlatform(rawValue: item.platform) else {
            completion(.unknown)
            return
        }
        let resolver = LiveSites.resolver(for: platform)
        let gate = HomeLiveStatusGate()
        let timeout = DispatchWorkItem {
            if gate.claim() { completion(.unknown) }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + liveStatusTimeoutSeconds, execute: timeout)
        resolver.roomInfo(roomId: item.roomId) { result in
            timeout.cancel()
            guard gate.claim() else { return }
            switch result {
            case .success(let room):
                completion(room.isLive ? .live : .offline)
            case .failure:
                completion(.unknown)
            }
        }
    }
}
