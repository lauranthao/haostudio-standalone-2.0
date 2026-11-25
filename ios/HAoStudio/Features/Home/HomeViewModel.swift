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
// checked less than 2 min ago is not checked again, and a room
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
    /// on every reload while the check is still in flight. A badge
    /// confirmed more than 30 min ago is dropped instead of carried
    /// (liveStatusBadgeTTLSeconds) and forces a fresh check —
    /// without the TTL a room that went off air kept its badge
    /// for hours.
    var isLive: Bool
    /// Last confirmed watching count (room-info `online`). 0 =
    /// unknown / never confirmed — the card hides the count then,
    /// exactly like a room that reports no audience. Carried
    /// across rebuilds with the badge (see carryLiveInfo), never
    /// invented: only a room-info answer writes it.
    var onlineCount: Int

    init(
        platform: String,
        roomId: String,
        title: String,
        nick: String,
        cover: String,
        isLive: Bool = false,
        onlineCount: Int = 0
    ) {
        self.id = LiveResumeKey.key(platform: platform, roomId: roomId)
        self.platform = platform
        self.roomId = roomId
        self.title = title
        self.nick = nick
        self.cover = cover
        self.isLive = isLive
        self.onlineCount = onlineCount
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
/// `.unknown` keeps whatever the UI already shows. `.liveDetail`
/// is the same confirmed-live answer plus the fresh room detail
/// (watching count / title / cover) the room-info call returned —
/// the badge alone never carried those, so home cards showed the
/// stale follow-time title/cover and a zero count. `.live` stays
/// for checkers that confirm liveness without detail (stubs,
/// tests); the default checker always answers `.liveDetail`.
enum HomeLiveStatus {
    case live
    case liveDetail(onlineCount: Int, title: String, cover: String)
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
    /// The stored resume point (seconds) behind the "继续听" card:
    /// resumeMap[resumeSong.identityKey]. Nil when the card is the
    /// recent-play fallback (no valid resume point) — the card
    /// shows no "上次听到" label then, and the tap plays from 0.
    /// The value is the same one the tap passes to the player as
    /// resumeFrom, so the label and the seek can never disagree.
    @Published private(set) var continueListeningResumeSeconds: Int?
    @Published private(set) var hotLive: [HomeLiveItem] = []
    @Published private(set) var daily: [MusicSong] = []
    /// The full daily list (up to 20, MusicRadio.dailyPicks
    /// total) behind the section's first 10 — the "全部" page
    /// plays / replaces from this, not from the capped section.
    @Published private(set) var allDailyPicks: [MusicSong] = []
    /// Spare picks behind today's daily list (the same ranked
    /// pool past the first 20), so "换一首" on home replaces a
    /// song in place exactly like the discovery daily page.
    /// Empty = no replacement left (the button hides).
    @Published private(set) var dailySpares: [MusicSong] = []
    /// The day key the current daily list was loaded under
    /// (b49fix4 P2-31): replaceDailySong saves under THIS key,
    /// not a fresh Date() — an app open across midnight would
    /// otherwise write yesterday's list under today's key.
    /// Set by the publish overload of reload(); empty until the
    /// first reload (the fallback then is today's key, as before).
    private var dailyDayKey = ""
    /// The full recent list (up to MusicLibraryStore.maxRecent).
    /// Feeds the 继续听 resume queue (the resume song first,
    /// then the rest of recent plays). b49fix2 A7: the home
    /// 最近播放 shelf is gone, so the capped `recentPlays`
    /// section array went with it — nothing reads it any more.
    @Published private(set) var allRecentPlays: [MusicSong] = []

    /// b49fix3 P1-3: true until the first reload has published —
    /// the first frame shows the title only, not the welcome
    /// card + four empty states (which are wrong for a user
    /// with content, and flash for everyone). Only the first
    /// load hides content; later reloads (notifications,
    /// pull-to-refresh) publish over the old content.
    @Published private(set) var isLoading = true
    private var hasLoadedOnce = false
    /// b49fix3 P1-9: true when the last live-status round
    /// answered `.unknown` for EVERY room it checked (with at
    /// least one room checked) — the section cannot tell
    /// "all offline" from "the check failed", so the retry
    /// button shows only in this case. Any successful answer
    /// clears it. The four sections read local data only, so
    /// they cannot fail — a retry on their empty states would
    /// be a dead control.
    @Published private(set) var liveStatusFailed = false
    /// Whether any room in the current status round answered
    /// with a real state (`.live` / `.offline` / `.liveDetail`).
    private var liveStatusRoundAnswered = false

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
    static let liveStatusThrottleSeconds = 120.0
    private var liveStatusLastCheckAt: Date?
    private var liveStatusLastCheckedRoomIDs: Set<String> = []
    /// When each live badge was last confirmed (room id ->
    /// answer time). A confirmed-live badge is only carried
    /// across rebuilds while it is younger than
    /// `liveStatusBadgeTTLSeconds` — without this a badge
    /// confirmed hours ago survived every rebuild and the 120 s
    /// throttle kept re-checks away, so a room that went off air
    /// kept its LIVE badge until the room set changed. An expired
    /// badge is dropped and forces a fresh check (see
    /// liveStatusRecheckNeeded).
    static let liveStatusBadgeTTLSeconds: TimeInterval = 1800
    private var liveStatusConfirmedAt: [String: Date] = [:]
    /// A badge expired (or pull-to-refresh asked for a re-check)
    /// since the last status round: the next refreshLiveStatus
    /// bypasses the 120 s throttle once, then clears.
    private var liveStatusRecheckNeeded = false
    /// Pull-to-refresh asked for a live re-check: same bypass as
    /// an expired badge, consumed by the next status round.
    private var forceLiveRecheck = false
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
    /// Background-reload generation: the no-arg reload() reads
    /// the stores off the main thread, so a newer reload that
    /// starts while an older read is still out drops the older
    /// result when it lands instead of publishing stale data.
    private var backgroundReloadGeneration = 0
    /// Pending debounced notification reload (see
    /// reloadForNotification): at most one is ever scheduled.
    private var notificationReloadWork: DispatchWorkItem?

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

    /// Reload for the store-change notifications (music recent /
    /// video history / live history). The data really changed, so
    /// this must not be coalesced away — but three notifications
    /// can fire in one burst (one user action posts several), and
    /// each used to pay for a full synchronous reload. Debounced
    /// 0.3 s: a burst collapses into one reload, a lone change
    /// still lands promptly (well inside the "最近播放实时更新"
    /// expectation — 0.3 s is not visible).
    static let notificationReloadDebounceSeconds: TimeInterval = 0.3

    func reloadForNotification() {
        notificationReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        notificationReloadWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.notificationReloadDebounceSeconds, execute: work)
    }

    /// Synchronous local reads for all five sections — but not on
    /// the main thread: every appearance / notification used to
    /// read video history, recent, listen log, resume map, daily
    /// (incl. favourites + all playlist tracks) and the live
    /// stores synchronously on main, so a tab switch paid for six
    /// disk reads before the first frame. The reads run on a
    /// background queue now; only the published assignment (the
    /// overload below) runs on main. Live-status confirmation
    /// runs after, through the injected checker: a confirmed-live
    /// room keeps its badge across the rebuild, a positively-
    /// offline answer clears it, and a failed / timed-out check
    /// leaves the previous value alone.
    /// `forceLiveRecheck` (pull-to-refresh) bypasses the 120 s
    /// live-status throttle once — a refresh the throttle used
    /// to swallow silently now really re-checks.
    func reload(forceLiveRecheck: Bool = false) {
        // Every reload — local or appearance — resets the
        // coalescing clock here, synchronously, so a second
        // appearance trigger right after it is recognised as
        // the same event even while the background read is
        // still out (the overload sets it again on publish).
        lastReloadAt = now()
        if forceLiveRecheck { self.forceLiveRecheck = true }
        backgroundReloadGeneration += 1
        let generation = backgroundReloadGeneration
        // b49fix3 P2-15: one Date() for the whole reload — the
        // day key is taken once and passed through the daily
        // computation, so a midnight crossing between two
        // Date() calls can no longer split picks and spares
        // across two days.
        let today = Date()
        let dayKey = musicDayKey(of: today)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let videoHistory = VideoLibraryStore.history()
            let recent = MusicLibraryStore.getRecent()
            let listenLog = MusicLibraryStore.getListenLog()
            let resumeMap = MusicLibraryStore.resumeMap()
            let dailyResult = Self.loadDailyPicksAndSpares(
                listenLog: listenLog, recent: recent, dayKey: dayKey)
            let follows = LiveLibraryStore.follows()
            let liveHistory = LiveLibraryStore.history()
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      generation == self.backgroundReloadGeneration else { return }
                // b49fix5 P2-4: the save happens here, on the main
                // thread under the generation guard — never in the
                // background block (the old code saved there
                // unconditionally, so a superseded reload still
                // wrote its stale table back). The compare-and-swap
                // also guards against a replaceDailySong that
                // landed while this reload was computing: the disk
                // already holds a complete newer list, so this
                // stale write is skipped instead of undoing the
                // replacement.
                if let saveTracks = dailyResult.saveTracks {
                    MusicLibraryStore.saveDailyTracksIfUnchanged(
                        saveTracks, for: dayKey,
                        expectedKeys: dailyResult.expectedDiskKeys)
                }
                self.reload(
                    videoHistory: videoHistory,
                    recent: recent,
                    listenLog: listenLog,
                    resumeMap: resumeMap,
                    follows: follows,
                    liveHistory: liveHistory,
                    dailyPicks: dailyResult.picks,
                    dailySpares: dailyResult.spares,
                    dayKey: dayKey)
            }
        }
    }

    /// reload() with the inputs supplied (same composition, no
    /// disk reads) so tests can drive it with fixture data.
    /// `dayKey` is the day the daily list was loaded under —
    /// the background reload passes the same key it ranked with,
    /// so replaceDailySong saves under it (P2-31); tests that
    /// omit it leave dailyDayKey untouched (fallback: today).
    func reload(
        videoHistory: [VideoHistoryEntry],
        recent: [MusicSong],
        listenLog: [ListenEvent],
        resumeMap: [String: Int],
        follows: [LiveFollowedRoom],
        liveHistory: [LiveHistoryEntry],
        dailyPicks: [MusicSong],
        dailySpares: [MusicSong] = [],
        dayKey: String = ""
    ) {
        // Every reload — local or appearance — resets the
        // coalescing clock, so a second appearance trigger
        // right after it is recognised as the same event.
        lastReloadAt = now()
        if !dayKey.isEmpty { dailyDayKey = dayKey }
        continueWatching = Self.continueWatchingEntries(from: videoHistory)
        allRecentPlays = recent
        if let song = Self.resumeSong(recent: recent, listenLog: listenLog, resumeMap: resumeMap) {
            continueListening = [song]
            // resumeSong only returns a song with a valid map
            // entry (isValidMusicResume needs seconds > 10), so
            // this is always non-nil here.
            continueListeningResumeSeconds = resumeMap[song.identityKey]
        } else {
            continueListening = Array(recent.prefix(1))
            continueListeningResumeSeconds = nil
        }
        // Carry the confirmed-live state across the rebuild (see
        // carryLiveInfo): a fresh badge + watching count + fresh
        // title/cover ride along, an expired badge is dropped and
        // forces a fresh check instead of lingering for hours.
        let previousLive = hotLive
        hotLive = Self.hotLiveItems(follows: follows, history: liveHistory)
        let badgeExpired = carryLiveInfo(from: previousLive, into: &hotLive)
        daily = Array(dailyPicks.prefix(Self.sectionLimit))
        allDailyPicks = dailyPicks
        self.dailySpares = dailySpares
        let forceRecheck = badgeExpired || liveStatusRecheckNeeded || forceLiveRecheck
        liveStatusRecheckNeeded = false
        forceLiveRecheck = false
        refreshLiveStatus(forceRecheck: forceRecheck)
        // b49fix3 P1-3: the first publish ends the first-frame
        // loading state (see isLoading above).
        hasLoadedOnce = true
        isLoading = false
    }

    /// Carry the last confirmed live state from the previous hot
    /// list into a freshly rebuilt one. A badge is carried only
    /// while its confirmation is younger than the TTL — and the
    /// watching count + fresh title/cover ride along with it, so
    /// a rebuild never reverts a card to the stale follow-time
    /// title/cover or a zero count. Returns true when a badge
    /// expired and was dropped: the caller must force a fresh
    /// status check for that room instead of waiting out the
    /// throttle. Confirmations for rooms that dropped out of the
    /// list are pruned.
    private func carryLiveInfo(from old: [HomeLiveItem], into new: inout [HomeLiveItem]) -> Bool {
        var expired = false
        let oldById = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newIDs = Set(new.map { $0.id })
        liveStatusConfirmedAt = liveStatusConfirmedAt.filter { newIDs.contains($0.key) }
        for index in new.indices {
            guard let previous = oldById[new[index].id], previous.isLive else { continue }
            if let confirmedAt = liveStatusConfirmedAt[previous.id],
               now().timeIntervalSince(confirmedAt) <= Self.liveStatusBadgeTTLSeconds {
                new[index].isLive = true
                new[index].onlineCount = previous.onlineCount
                if !previous.title.isEmpty { new[index].title = previous.title }
                if !previous.cover.isEmpty { new[index].cover = previous.cover }
            } else {
                expired = true
            }
        }
        return expired
    }

    // MARK: - Follow-list change (haoLiveFollowChanged)

    /// Rebuild hot live after a follow toggle, from the stores'
    /// current follows + history. The store is already updated
    /// when the notification posts (saveFollows runs before
    /// post), so the list can be rebuilt from local data alone:
    /// a room that was only followed drops out, a room that is
    /// also watched stays, a room followed elsewhere appears.
    /// No network — refreshLiveStatus is deliberately NOT called,
    /// so a toggle never pays for up to 10 room-info requests —
    /// and lastReloadAt is untouched, so appearance coalescing
    /// is unaffected. A rebuilt list identical to the current
    /// one is not assigned, so a duplicate notification neither
    /// flickers the section nor refreshes it twice. In-flight
    /// status answers still land by room id on survivors; a
    /// removed room simply has no index to write to.
    func refreshHotLiveForFollowChange() {
        refreshHotLiveForFollowChange(
            follows: LiveLibraryStore.follows(),
            liveHistory: LiveLibraryStore.history())
    }

    /// Same rebuild with the inputs supplied, so tests can drive
    /// it with fixture data (same seam as reload's overload).
    func refreshHotLiveForFollowChange(
        follows: [LiveFollowedRoom],
        liveHistory: [LiveHistoryEntry]
    ) {
        var rebuilt = Self.hotLiveItems(follows: follows, history: liveHistory)
        // Same carry as reload: a fresh badge + count + fresh
        // title/cover survive the toggle rebuild, an expired
        // badge is dropped — and the drop is remembered so the
        // next reload forces a fresh check instead of waiting
        // out the throttle. No network is spent here.
        if carryLiveInfo(from: hotLive, into: &rebuilt) {
            liveStatusRecheckNeeded = true
        }
        guard rebuilt != hotLive else { return }
        hotLive = rebuilt
    }

    // MARK: - Pure aggregation (unit-tested, no I/O)

    /// Continue watching: history() as-is, newest first, capped —
    /// the same as the video tab (VideoTabViewModel.reload). No
    /// shouldResume filtering here: a finished row still shows,
    /// like the video tab. The store's history() is already
    /// newest-first, but a migrated file is not guaranteed
    /// ordered, so sort here.
    nonisolated static func continueWatchingEntries(
        from history: [VideoHistoryEntry],
        limit: Int = sectionLimit
    ) -> [VideoHistoryEntry] {
        let newestFirst = history.sorted { $0.updatedAt > $1.updatedAt }
        return Array(newestFirst.prefix(limit))
    }

    /// Whether a music resume point is real: the same rule as
    /// video shouldResume (over 10 s in, at least 30 s from the
    /// end; unknown duration counts as resumable).
    nonisolated static func isValidMusicResume(seconds: Int, durationSeconds: Int) -> Bool {
        guard seconds > Int(VideoLibraryStore.minResumeSeconds) else { return false }
        guard durationSeconds > 0 else { return true }
        return seconds < durationSeconds - Int(VideoLibraryStore.finishMarginSeconds)
    }

    /// The断点续播 song: the most recently played song with a valid
    /// resume point. Recent plays are scanned newest-first; songs
    /// that fell out of recent (cap 100) are then found through
    /// the listen log, newest-first. Nil when no stored resume
    /// point is valid.
    nonisolated static func resumeSong(
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
    nonisolated static func hotLiveItems(
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
    /// cache in loadDailyPicksAndSpares keeps one day stable
    /// even as the user keeps listening. Nonisolated (pure,
    /// store reads only). Kept as the direct entry point for
    /// the tests (HomeAggregationTests calls it) — the reload
    /// path itself uses loadDailyPicksAndSpares (one total-40
    /// run for picks + spares). b49fix4 P2-29: `total` defaults
    /// to 40, the live composition — the old default-20 entry
    /// drifted from what both pages actually show.
    nonisolated static func computeDailyPicks(
        listenLog: [ListenEvent],
        favourites: [MusicSong],
        recent: [MusicSong],
        dayKey: String,
        playlistTracks: [MusicSong] = [],
        dislikedIds: Set<String> = [],
        total: Int = 40
    ) -> [MusicSong] {
        return MusicRadio.dailyPicks(
            listenLog: listenLog,
            favourites: favourites,
            recent: recent,
            playlistTracks: playlistTracks,
            dislikedIds: dislikedIds,
            dayKey: dayKey,
            total: total)
    }

    /// Daily picks + spares from ONE ranked run (b49fix3
    /// P2-15): the day key is taken once by the caller and
    /// passed in (see reload), and the ranking
    /// (MusicRadio.dailyPicks, total 40) runs once — picks are
    /// its first 20, spares the rest. The old code ran the
    /// ranking twice per reload (a total-20 run for picks, a
    /// total-40 run for spares) with three separate Date()
    /// calls.
    ///
    /// Cache contract (b49fix4 P1-2 / P2-30): `hao_daily` stores
    /// the FULL total-40 list, so home (first 20) and discovery
    /// (first 20) read the same composition — whichever page
    /// loads first no longer decides the other page's content.
    /// A cache hit with 40 entries needs NO ranking run (picks
    /// = first 20, spares = rest). A hit with fewer (an old
    /// 20-only entry, or entries filtered out as disliked —
    /// P2-32) runs one total-40 ranking for spares only, keeps
    /// the cached picks as the day's list, and re-saves all 40
    /// so the next reload skips the run. `force` bypasses the
    /// cache entirely (pull-to-refresh / "刷新今日推荐").
    ///
    /// Selection note: the old picks were a total-20 run
    /// (top-10 ranked + affinity-10 same-artist/album fills);
    /// the combined run's first 20 are the top-20 ranked, so
    /// the affinity fills now land in the spares (positions
    /// 21–40) and surface through "换一首" instead of the
    /// list's second half. The list stays a pure ranked list;
    /// the cache rule is unchanged (only today's key, non-empty,
    /// every row with a real song id — see validatedDailyTracks).
    /// Nonisolated: the background reload calls it off the
    /// main thread.
    /// Result of a daily load: the picks/spares to show, plus the
    /// write-back the CALLER performs (b49fix5 P2-4 — the load
    /// itself no longer saves, so a superseded background reload
    /// cannot write its stale table back).
    struct DailyLoadResult {
        var picks: [MusicSong]
        var spares: [MusicSong]
        /// Full list (picks + spares, ≤ 40) to persist, or nil
        /// when the cache-hit branch needed no write.
        var saveTracks: [MusicSong]?
        /// identityKeys of the on-disk list as read at the start
        /// of this load — the save is a compare-and-swap against
        /// it (MusicLibraryStore.saveDailyTracksIfUnchanged).
        var expectedDiskKeys: [String]
    }

    nonisolated static func loadDailyPicksAndSpares(
        listenLog: [ListenEvent],
        recent: [MusicSong],
        dayKey: String,
        force: Bool = false
    ) -> DailyLoadResult {
        let favourites = MusicLibraryStore.favSongs()
        let playlistTracks = MusicLibraryStore.getLists().flatMap { $0.tracks }
        let dislikedIds = MusicLibraryStore.fmDislikedIds()
        // The on-disk list as read NOW — the CAS baseline for the
        // caller's save (b49fix5 P2-4). Read once: the validation
        // below and the save guard must agree on the same bytes.
        let diskTracks = MusicLibraryStore.dailyTracks(for: dayKey)
        let expectedDiskKeys = (diskTracks ?? []).map { $0.identityKey }
        if !force, let cached = validatedDailyTracks(
            diskTracks, dayKey: dayKey, todayKey: dayKey
        ) {
            // Cache hit: filter out songs disliked since the list
            // was saved (P2-32 — FM "不喜欢" must clear them from
            // today's recommendations, not just from FM itself).
            let filtered = cached.filter {
                !dislikedIds.contains($0.identityKey) && !dislikedIds.contains($0.songId)
            }
            if !filtered.isEmpty {
                if filtered.count >= 40 {
                    return DailyLoadResult(
                        picks: Array(filtered.prefix(20)),
                        spares: Array(filtered.dropFirst(20).prefix(20)),
                        saveTracks: nil, expectedDiskKeys: expectedDiskKeys)
                }
                // Old 20-only cache, or filtered below 40: one
                // total-40 run for the spares only. The cached
                // picks stay the day's list (no mid-day change);
                // the re-save migrates the cache to 40.
                // b49fix5 P2-3: the picks are BACKFILLED, not left
                // short — the surviving cached picks keep their
                // order, and the fresh ranking fills the missing
                // slots to 20 (deduped by identityKey). A disliked
                // pick is therefore replaced by the next-ranked
                // song on the next reload, exactly as the P2-32
                // comment above already promised for the ≥ 20
                // case; without the fill the list showed 12 picks
                // and the NEXT reload promoted 8 spares into picks,
                // changing the day's list with no user action.
                // The re-save keeps the picks/spares boundary, so
                // the next reload reads back the same first 20.
                // Thin library (< 20 unique songs): there is no
                // meaningful boundary — picks stay short and the
                // same fill runs again next time (deterministic:
                // dailyPicks is never shuffled).
                let ranked = MusicRadio.dailyPicks(
                    listenLog: listenLog, favourites: favourites, recent: recent,
                    playlistTracks: playlistTracks, dislikedIds: dislikedIds,
                    dayKey: dayKey, total: 40)
                let surviving = Array(filtered.prefix(20))
                let survivingKeys = Set(surviving.map { $0.identityKey })
                let fills = ranked.filter { !survivingKeys.contains($0.identityKey) }
                let picks = Array((surviving + fills).prefix(20))
                let pickKeys = Set(picks.map { $0.identityKey })
                let spares = ranked.filter { !pickKeys.contains($0.identityKey) }
                let all = picks + spares
                return DailyLoadResult(
                    picks: picks,
                    spares: Array(all.dropFirst(picks.count).prefix(20)),
                    saveTracks: all.isEmpty ? nil : Array(all.prefix(40)),
                    expectedDiskKeys: expectedDiskKeys)
            }
            // Every cached song was disliked away — fall through
            // and recompute instead of showing an empty day.
        }
        let ranked = MusicRadio.dailyPicks(
            listenLog: listenLog, favourites: favourites, recent: recent,
            playlistTracks: playlistTracks, dislikedIds: dislikedIds,
            dayKey: dayKey, total: 40)
        let picks = Array(ranked.prefix(20))
        return DailyLoadResult(
            picks: picks,
            spares: Array(ranked.dropFirst(picks.count)),
            saveTracks: ranked.isEmpty ? nil : ranked,
            expectedDiskKeys: expectedDiskKeys)
    }

    /// Load-side validation for a hao_daily entry. Returns the
    /// usable tracks, or nil when the entry must be recomputed:
    /// a day key that is not today (only today's key is ever
    /// valid on load — older keys are pruned on save by
    /// MusicLibraryStore), a missing / empty list, or a list
    /// whose usable tracks are empty after dropping rows with
    /// no song id (an identity-less row can never play). Shared
    /// with MusicDiscoveryViewModel.reloadDaily — one rule for
    /// both readers of the same cache. Nonisolated (pure).
    nonisolated static func validatedDailyTracks(
        _ cached: [MusicSong]?,
        dayKey: String,
        todayKey: String = musicDayKey(of: Date())
    ) -> [MusicSong]? {
        guard dayKey == todayKey else { return nil }
        guard let cached = cached, !cached.isEmpty else { return nil }
        let valid = cached.filter { !$0.songId.isEmpty }
        guard !valid.isEmpty else { return nil }
        return valid
    }

    /// "不喜欢换一首" on home (same as the discovery daily
    /// page): replace the song in place with the next spare,
    /// record the dislike so it never comes back, and persist
    /// the full day's list. The section (first 10) is re-derived
    /// from the full list, so the row and the "全部" page can
    /// never disagree. b49fix4 P2-31: the dislike is recorded
    /// BEFORE the spares-empty guard (the old order silently
    /// dropped the dislike when the spares ran out at that
    /// instant), and the save uses the reload's dayKey
    /// (dailyDayKey) and the full 40 (picks + spares) — saving
    /// only the 20 picks shrank the cache back to 20 and lost
    /// the spares.
    func replaceDailySong(_ song: MusicSong) {
        guard let index = allDailyPicks.firstIndex(where: { $0.identityKey == song.identityKey }) else { return }
        MusicLibraryStore.addFMDisliked(key: song.identityKey)
        guard !dailySpares.isEmpty else { return }
        allDailyPicks[index] = dailySpares.removeFirst()
        daily = Array(allDailyPicks.prefix(Self.sectionLimit))
        let key = dailyDayKey.isEmpty ? musicDayKey(of: Date()) : dailyDayKey
        MusicLibraryStore.saveDailyTracks(allDailyPicks + dailySpares, for: key)
    }

    // MARK: - Live status

    /// Confirm live status for the rooms in hotLive (at most 10),
    /// through the injected checker. Throttled: the same room set
    /// inside 2 min is not checked again, and a room with a check
    /// already in flight is never fired twice. A late answer
    /// (older reload) is dropped; `.unknown` (failed / timed out)
    /// changes nothing, so a transient network failure never
    /// blinks a good badge off — only a successful `.offline`
    /// clears one. `forceRecheck` (expired badge / pull-to-
    /// refresh) bypasses the throttle once: without it a badge
    /// confirmed hours ago and a throttle that never expired
    /// left the section stale with no way to refresh it.
    private func refreshLiveStatus(forceRecheck: Bool = false) {
        guard let checker = liveStatusChecker, !hotLive.isEmpty else { return }
        let roomIDs = Set(hotLive.map { $0.id })
        // Same room set, checked inside the window — reuse the
        // last answers (badges were carried across the rebuild
        // above). A changed set, an expired window, or a forced
        // re-check re-checks — minus rooms already in flight.
        if !forceRecheck,
           roomIDs == liveStatusLastCheckedRoomIDs,
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
        // b49fix3 P1-9: a new round starts unanswered — the
        // failure flag below is set only when the round ends
        // with every answer `.unknown`.
        liveStatusRoundAnswered = false
        for item in pending {
            liveStatusInFlightIDs.insert(item.id)
            checker(item) { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.liveStatusInFlightIDs.remove(item.id)
                    guard self.liveStatusGeneration == generation else { return }
                    guard let index = self.hotLive.firstIndex(where: { $0.id == item.id }) else { return }
                    // b49fix3 P1-9: a real answer clears the
                    // failure flag; an `.unknown` answer sets it
                    // only when it was the round's last answer
                    // and nothing in the round answered for real.
                    if case .unknown = status {
                        if self.liveStatusInFlightIDs.isEmpty,
                           !self.liveStatusRoundAnswered {
                            self.liveStatusFailed = true
                        }
                    } else {
                        self.liveStatusRoundAnswered = true
                        self.liveStatusFailed = false
                    }
                    switch status {
                    case .unknown:
                        return
                    case .offline:
                        self.hotLive[index].isLive = false
                        self.hotLive[index].onlineCount = 0
                        self.liveStatusConfirmedAt.removeValue(forKey: item.id)
                    case .live:
                        self.hotLive[index].isLive = true
                        self.liveStatusConfirmedAt[item.id] = self.now()
                    case .liveDetail(let onlineCount, let title, let cover):
                        self.hotLive[index].isLive = true
                        self.hotLive[index].onlineCount = onlineCount
                        if !title.isEmpty { self.hotLive[index].title = title }
                        if !cover.isEmpty { self.hotLive[index].cover = cover }
                        self.liveStatusConfirmedAt[item.id] = self.now()
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
    /// (`.liveDetail` with the fresh watching count / title /
    /// cover, or `.offline`) — only that positively clears a
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
                if room.isLive {
                    completion(.liveDetail(
                        onlineCount: room.onlineCount, title: room.title, cover: room.cover))
                } else {
                    completion(.offline)
                }
            case .failure:
                completion(.unknown)
            }
        }
    }
}
