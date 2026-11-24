// HAo Studio 2.0 — home aggregation tests (Home-B leg).
//
// The five home sections, driven through HomeViewModel's pure
// aggregation helpers and its injectable reload() overload —
// fixture data only, no files, no network. The public reload()
// itself only reads the local stores; its composition is covered
// here through the overload with the same inputs.
//
// Wiring (S7 pattern): Xcode test target HAoStudioTests, host app,
// @testable import HAoStudio. Package.swift untouched.

import XCTest

@testable import HAoStudio

@MainActor
final class HomeAggregationTests: XCTestCase {

    // MARK: - Fixtures

    private func videoItem(title: String, year: String? = "2024") -> VideoItem {
        VideoItem(
            id: title, title: title, coverURL: nil, year: year,
            typeName: nil, remarks: nil, sourceId: nil)
    }

    private func historyEntry(
        title: String,
        positionSeconds: Double,
        durationSeconds: Double,
        updatedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> VideoHistoryEntry {
        VideoHistoryEntry(
            item: videoItem(title: title), episodeName: "第01集",
            episodeIndex: 0, lineName: "线路1",
            positionSeconds: positionSeconds, durationSeconds: durationSeconds,
            updatedAt: updatedAt)
    }

    private func song(
        songId: String,
        title: String = "歌",
        artist: String = "歌手",
        dur: Int = 300
    ) -> MusicSong {
        MusicSong(
            songId: songId, title: title, artist: artist, cover: "",
            platform: .wy, dur: dur)
    }

    private func event(
        songId: String,
        title: String = "歌",
        artist: String = "歌手",
        totalDur: Int = 300,
        at: Int = 1000
    ) -> ListenEvent {
        ListenEvent(json: [
            "songId": songId, "title": title, "artist": artist,
            "platform": "wy", "cover": "", "dur": totalDur,
            "totalDur": totalDur, "at": at,
        ])
    }

    private func follow(
        platform: String = "bili",
        roomId: String,
        title: String = "直播间",
        followedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> LiveFollowedRoom {
        LiveFollowedRoom(
            platform: platform, roomId: roomId, title: title,
            nick: "主播", cover: "", followedAt: followedAt)
    }

    private func liveEntry(
        platform: String = "bili",
        roomId: String,
        title: String = "直播间",
        watchedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> LiveHistoryEntry {
        LiveHistoryEntry(
            platform: platform, roomId: roomId, title: title,
            nick: "主播", cover: "", watchedAt: watchedAt)
    }

    private func emptyReload(on viewModel: HomeViewModel) {
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [], liveHistory: [], dailyPicks: [])
    }

    // MARK: - HomeLiveItem identity

    func testHomeLiveItemIdIsPlatformPipeRoomId() {
        let item = HomeLiveItem(
            platform: "bili", roomId: "123", title: "间", nick: "播", cover: "")
        XCTAssertEqual(item.id, "bili|123")
    }

    func testSameRoomIdOnTwoPlatformsHasDifferentIds() {
        let bili = HomeLiveItem(
            platform: "bili", roomId: "1", title: "", nick: "", cover: "")
        let douyu = HomeLiveItem(
            platform: "douyu", roomId: "1", title: "", nick: "", cover: "")
        XCTAssertNotEqual(bili.id, douyu.id)
    }

    func testHomeLiveItemFromFollowAndHistoryShareId() {
        let fromFollow = HomeLiveItem(follow: follow(roomId: "7"))
        let fromHistory = HomeLiveItem(history: liveEntry(roomId: "7"))
        XCTAssertEqual(fromFollow.id, fromHistory.id)
        XCTAssertEqual(fromFollow.id, "bili|7")
    }

    // MARK: - Continue watching

    func testContinueWatchingTakesHistoryAsIs() {
        // Same as the video tab: history() raw, no shouldResume
        // filtering — a too-short row and a finished row both stay.
        let history = [
            historyEntry(
                title: "可续", positionSeconds: 120, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 4000)),
            historyEntry(
                title: "太短", positionSeconds: 5, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 3000)),
            historyEntry(
                title: "播完", positionSeconds: 590, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 2000)),
            historyEntry(
                title: "未知时长", positionSeconds: 120, durationSeconds: 0,
                updatedAt: Date(timeIntervalSince1970: 1000)),
        ]
        let kept = HomeViewModel.continueWatchingEntries(from: history)
        XCTAssertEqual(
            kept.map { $0.item.title }, ["可续", "太短", "播完", "未知时长"])
    }

    func testContinueWatchingNewestFirst() {
        let old = historyEntry(
            title: "旧", positionSeconds: 120, durationSeconds: 600,
            updatedAt: Date(timeIntervalSince1970: 1000))
        let new = historyEntry(
            title: "新", positionSeconds: 120, durationSeconds: 600,
            updatedAt: Date(timeIntervalSince1970: 2000))
        let kept = HomeViewModel.continueWatchingEntries(from: [old, new])
        XCTAssertEqual(kept.map { $0.item.title }, ["新", "旧"])
    }

    func testContinueWatchingCapsAtTen() {
        var history: [VideoHistoryEntry] = []
        for index in 0..<12 {
            history.append(historyEntry(
                title: "片\(index)", positionSeconds: 120, durationSeconds: 600,
                updatedAt: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        XCTAssertEqual(HomeViewModel.continueWatchingEntries(from: history).count, 10)
    }

    func testContinueWatchingEmptyWhenNoData() {
        XCTAssertEqual(HomeViewModel.continueWatchingEntries(from: []).count, 0)
    }

    // MARK: - Music resume (continue listening)

    func testIsValidMusicResumeBoundaries() {
        // 10 s or less is not a resume point; 11 s is (unknown duration).
        XCTAssertFalse(HomeViewModel.isValidMusicResume(seconds: 10, durationSeconds: 0))
        XCTAssertTrue(HomeViewModel.isValidMusicResume(seconds: 11, durationSeconds: 0))
        // Within 30 s of the end is finished, not resumable.
        XCTAssertFalse(HomeViewModel.isValidMusicResume(seconds: 270, durationSeconds: 300))
        XCTAssertTrue(HomeViewModel.isValidMusicResume(seconds: 269, durationSeconds: 300))
    }

    func testResumeSongPrefersMostRecentValidResume() {
        let recent = [song(songId: "1"), song(songId: "2")]
        let resumeMap = ["wy|1": 120, "wy|2": 150]
        XCTAssertEqual(
            HomeViewModel.resumeSong(recent: recent, listenLog: [], resumeMap: resumeMap)?.songId,
            "1")
    }

    func testResumeSongIgnoresTooShortResume() {
        let recent = [song(songId: "1"), song(songId: "2")]
        // 5 s is not a resume point; nothing else has one either.
        let resumeMap = ["wy|1": 5]
        XCTAssertNil(
            HomeViewModel.resumeSong(recent: recent, listenLog: [], resumeMap: resumeMap))
    }

    func testResumeSongIgnoresFinishedResume() {
        let recent = [song(songId: "1", dur: 300)]
        // 290 s into a 300 s song is finished, not resumable.
        let resumeMap = ["wy|1": 290]
        XCTAssertNil(
            HomeViewModel.resumeSong(recent: recent, listenLog: [], resumeMap: resumeMap))
    }

    func testResumeSongFallsBackToListenLog() {
        // No valid resume in recent; the listen log's newest song has one.
        let recent = [song(songId: "1")]
        let log = [event(songId: "9", totalDur: 300, at: 1000)]
        let resumeMap = ["wy|9": 120]
        XCTAssertEqual(
            HomeViewModel.resumeSong(recent: recent, listenLog: log, resumeMap: resumeMap)?.songId,
            "9")
    }

    func testResumeSongNilWhenNothing() {
        XCTAssertNil(
            HomeViewModel.resumeSong(recent: [], listenLog: [], resumeMap: [:]))
    }

    // MARK: - Continue listening resume seconds (H1)

    /// The reload exposes the checkpoint behind the resume song,
    /// so the card label and the tap's seek read the same value.
    func testContinueListeningResumeSecondsExposed() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        let recent = [song(songId: "1"), song(songId: "2")]
        viewModel.reload(
            videoHistory: [], recent: recent, listenLog: [],
            resumeMap: ["wy|1": 120, "wy|2": 150],
            follows: [], liveHistory: [], dailyPicks: [])
        XCTAssertEqual(viewModel.continueListening.map { $0.songId }, ["1"])
        XCTAssertEqual(viewModel.continueListeningResumeSeconds, 120)
    }

    /// No valid resume point: the card falls back to the first
    /// recent play and carries no seconds — no "上次听到" label,
    /// and the tap plays from 0.
    func testContinueListeningResumeSecondsNilOnFallback() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        let recent = [song(songId: "1")]
        viewModel.reload(
            videoHistory: [], recent: recent, listenLog: [],
            resumeMap: ["wy|1": 5],
            follows: [], liveHistory: [], dailyPicks: [])
        XCTAssertEqual(viewModel.continueListening.map { $0.songId }, ["1"])
        XCTAssertNil(viewModel.continueListeningResumeSeconds)
    }

    /// Nothing at all: no card, no seconds.
    func testContinueListeningResumeSecondsNilWhenEmpty() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        emptyReload(on: viewModel)
        XCTAssertTrue(viewModel.continueListening.isEmpty)
        XCTAssertNil(viewModel.continueListeningResumeSeconds)
    }

    // MARK: - Hot live

    func testHotLiveMergesFollowsAndHistoryDeduped() {
        let follows = [follow(roomId: "1", title: "关注标题")]
        let history = [
            liveEntry(roomId: "1", title: "历史标题",
                      watchedAt: Date(timeIntervalSince1970: 2000)),
            liveEntry(roomId: "2"),
        ]
        let items = HomeViewModel.hotLiveItems(follows: follows, history: history)
        XCTAssertEqual(items.count, 2)
        // Same room in both lists: one row, the newer record wins.
        XCTAssertEqual(items[0].id, "bili|1")
        XCTAssertEqual(items[0].title, "历史标题")
        XCTAssertEqual(items[1].id, "bili|2")
        // Nothing confirmed live yet: no LIVE badge.
        XCTAssertFalse(items[0].isLive)
        XCTAssertFalse(items[1].isLive)
    }

    func testHotLiveNewestFirstAcrossLists() {
        let follows = [follow(
            roomId: "1", followedAt: Date(timeIntervalSince1970: 1000))]
        let history = [liveEntry(
            roomId: "2", watchedAt: Date(timeIntervalSince1970: 3000))]
        let items = HomeViewModel.hotLiveItems(follows: follows, history: history)
        XCTAssertEqual(items.map { $0.roomId }, ["2", "1"])
    }

    func testHotLiveCapsAtTen() {
        var follows: [LiveFollowedRoom] = []
        for index in 0..<12 {
            follows.append(follow(
                roomId: "\(index)",
                followedAt: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        XCTAssertEqual(HomeViewModel.hotLiveItems(follows: follows, history: []).count, 10)
    }

    func testHotLiveEmptyWhenNoData() {
        XCTAssertEqual(HomeViewModel.hotLiveItems(follows: [], history: []).count, 0)
    }

    // MARK: - Daily picks (reused logic)

    func testDailyPicksReuseExistingLogic() {
        // Most-played song (3 plays) leads; the discovery half comes
        // from the top artist's other songs; same day = same list.
        let log = [
            event(songId: "1", artist: "甲", at: 1000),
            event(songId: "1", artist: "甲", at: 1001),
            event(songId: "1", artist: "甲", at: 1002),
            event(songId: "2", artist: "甲", at: 1003),
            event(songId: "3", artist: "乙", at: 1004),
        ]
        let first = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-23")
        let second = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.songId, "1")
        XCTAssertTrue(first.contains { $0.songId == "2" })
    }

    func testDailyPicksRankedByPlaysNotShuffled() {
        // 12 plays beats 1 play by score (130 vs 15), and the list
        // does NOT change just because the day rolled over — only
        // the data moves it (freshness is 0 for these 1970 events
        // on either day key).
        var log: [ListenEvent] = []
        for _ in 0..<12 { log.append(event(songId: "1", artist: "甲")) }
        log.append(event(songId: "9", artist: "乙"))
        let day23 = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-23")
        let day24 = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-24")
        XCTAssertEqual(day23.map { $0.songId }, ["1", "9"])
        XCTAssertEqual(day23, day24)
    }

    func testDailyPicksChangeWhenHistoryChanges() {
        // Same inputs, then one more song overtakes the leader.
        let base = [
            event(songId: "a", artist: "甲", at: 1000),
            event(songId: "a", artist: "甲", at: 1001),
            event(songId: "a", artist: "甲", at: 1002),
            event(songId: "b", artist: "乙", at: 1003),
        ]
        let before = HomeViewModel.computeDailyPicks(
            listenLog: base, favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(before.first?.songId, "a")
        let grown = base + [
            event(songId: "b", artist: "乙", at: 1004),
            event(songId: "b", artist: "乙", at: 1005),
            event(songId: "b", artist: "乙", at: 1006),
        ]
        let after = HomeViewModel.computeDailyPicks(
            listenLog: grown, favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(after.first?.songId, "b")
        XCTAssertNotEqual(before, after)
    }

    func testDailyPicksLikesOutrankFewPlays() {
        // Liked (30) beats a single full play (10 + 5 heard) and a
        // newest-recent bonus (15); the 1-play song beats the
        // recent-only song on the plays tie-break.
        let log = [event(songId: "p1", artist: "甲", at: 1000)]
        let picks = HomeViewModel.computeDailyPicks(
            listenLog: log,
            favourites: [song(songId: "f1", artist: "乙")],
            recent: [song(songId: "r1", artist: "丙")],
            dayKey: "2026-11-23")
        XCTAssertEqual(picks.map { $0.songId }, ["f1", "p1", "r1"])
    }

    func testDailyPicksDiscoveryRankedFromTopArtist() {
        // Second half is ranked, not shuffled: artist 甲's other
        // songs come in play-count order, then the most recently
        // played 1-play songs (乙's 7 before 6, 甲's 5 last).
        // Scores: 1:60, 2:50, 3:40, 4:30, 5/6/7:15.
        var log: [ListenEvent] = []
        for index in 0..<5 { log.append(event(songId: "1", artist: "甲", at: 1000 + index)) }
        for index in 0..<4 { log.append(event(songId: "2", artist: "甲", at: 1010 + index)) }
        for index in 0..<3 { log.append(event(songId: "3", artist: "甲", at: 1020 + index)) }
        for index in 0..<2 { log.append(event(songId: "4", artist: "甲", at: 1030 + index)) }
        log.append(event(songId: "5", artist: "甲", at: 1040))
        log.append(event(songId: "6", artist: "乙", at: 1050))
        log.append(event(songId: "7", artist: "乙", at: 1060))
        let picks = MusicRadio.dailyPicks(
            listenLog: log, favourites: [], recent: [],
            dayKey: "2026-11-23", total: 6)
        XCTAssertEqual(picks.map { $0.songId }, ["1", "2", "3", "4", "7", "6"])
    }

    func testDailyPicksSameAlbumFillsSecondHalf() {
        // B is played twice AND liked with album 专辑X (the album
        // merges from the favourite copy onto the log song), so it
        // leads (60); F shares B's album and fills the second
        // half before the unrelated liked song H.
        let log = [
            event(songId: "a", artist: "甲", at: 1000),
            event(songId: "a", artist: "甲", at: 1001),
            event(songId: "a", artist: "甲", at: 1002),
            event(songId: "b", artist: "乙", at: 1010),
            event(songId: "b", artist: "乙", at: 1011),
        ]
        let favB = MusicSong(
            songId: "b", title: "歌", artist: "乙", album: "专辑X",
            cover: "", platform: .wy, dur: 300)
        let favF = MusicSong(
            songId: "f", title: "歌", artist: "丙", album: "专辑X",
            cover: "", platform: .wy, dur: 300)
        let favH = MusicSong(
            songId: "h", title: "歌", artist: "戊", album: "专辑Y",
            cover: "", platform: .wy, dur: 300)
        let picks = MusicRadio.dailyPicks(
            listenLog: log, favourites: [favB, favF, favH], recent: [],
            dayKey: "2026-11-23", total: 4)
        XCTAssertEqual(picks.map { $0.songId }, ["b", "a", "f", "h"])
        XCTAssertEqual(picks.first?.album, "专辑X")
    }

    func testDailyPicksSecondHalfCapsOneArtist() {
        // 31 songs by 甲, 1 by 乙: without a cap the single 乙
        // song (played once, long ago) would fall out of the 20.
        // The second-half cap lets it in while the list still
        // fills to 20 from ranked songs.
        var log: [ListenEvent] = []
        for _ in 0..<12 { log.append(event(songId: "1", artist: "甲")) }
        log.append(event(songId: "9", artist: "乙"))
        for index in 0..<30 {
            log.append(event(songId: "f\(index)", artist: "甲", at: 2000 + index))
        }
        let picks = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(picks.count, 20)
        XCTAssertEqual(picks.first?.songId, "1")
        XCTAssertTrue(picks.contains { $0.songId == "9" })
    }

    func testDailyPicksExcludesDisliked() {
        // Both dislike forms work (identityKey and bare songId);
        // a song that is not disliked still picks normally.
        let picks = HomeViewModel.computeDailyPicks(
            listenLog: [event(songId: "a", artist: "甲", at: 1000)],
            favourites: [song(songId: "x", artist: "乙"), song(songId: "y", artist: "丙")],
            recent: [],
            dayKey: "2026-11-23",
            dislikedIds: ["wy|x", "y"])
        XCTAssertEqual(picks.map { $0.songId }, ["a"])
    }

    func testDailyPicksFreshnessBonus() {
        // Same play count (1 full play = 15 each); the song played
        // yesterday gets +10 freshness, the one from 40 days ago
        // gets nothing — so the recent one leads.
        let ref = MusicRadio.dayReferenceMs(for: "2026-11-23") ?? 0
        let log = [
            event(songId: "old", artist: "甲", at: ref - 40 * 86_400_000),
            event(songId: "new", artist: "乙", at: ref - 86_400_000),
        ]
        let picks = HomeViewModel.computeDailyPicks(
            listenLog: log, favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(picks.map { $0.songId }, ["new", "old"])
    }

    func testDailyPicksPlaylistTracksAreCandidates() {
        // A song that only exists in a user playlist (never played
        // or liked) is still a real, playable candidate.
        let picks = HomeViewModel.computeDailyPicks(
            listenLog: [], favourites: [], recent: [], dayKey: "2026-11-23",
            playlistTracks: [song(songId: "p", artist: "甲")])
        XCTAssertEqual(picks.map { $0.songId }, ["p"])
    }

    func testDailyPicksEmptyWhenNoData() {
        let picks = HomeViewModel.computeDailyPicks(
            listenLog: [], favourites: [], recent: [], dayKey: "2026-11-23")
        XCTAssertEqual(picks.count, 0)
    }

    // MARK: - reload() composition

    func testReloadWithEmptyInputsYieldsEmptySections() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        emptyReload(on: viewModel)
        XCTAssertEqual(viewModel.continueWatching.count, 0)
        XCTAssertEqual(viewModel.continueListening.count, 0)
        XCTAssertEqual(viewModel.hotLive.count, 0)
        XCTAssertEqual(viewModel.daily.count, 0)
        XCTAssertEqual(viewModel.recentPlays.count, 0)
        XCTAssertEqual(viewModel.allRecentPlays.count, 0)
    }

    func testReloadFillsSectionsFromFixtures() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        let recent = (0..<12).map { song(songId: "\($0)") }
        viewModel.reload(
            videoHistory: [
                historyEntry(
                    title: "可续", positionSeconds: 120, durationSeconds: 600,
                    updatedAt: Date(timeIntervalSince1970: 2000)),
                historyEntry(
                    title: "太短", positionSeconds: 5, durationSeconds: 600,
                    updatedAt: Date(timeIntervalSince1970: 1000)),
            ],
            recent: recent,
            listenLog: [],
            resumeMap: ["wy|3": 120],
            follows: [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))],
            liveHistory: [liveEntry(roomId: "2", watchedAt: Date(timeIntervalSince1970: 1000))],
            dailyPicks: (0..<12).map { song(songId: "d\($0)") })
        // Continue watching: history as-is (video tab rule) — the
        // too-short row stays too, newest first.
        XCTAssertEqual(
            viewModel.continueWatching.map { $0.item.title }, ["可续", "太短"])
        // Continue listening: the resume song (recent #3), exactly one.
        XCTAssertEqual(viewModel.continueListening.map { $0.songId }, ["3"])
        // Hot live: follow + history, deduped.
        XCTAssertEqual(viewModel.hotLive.map { $0.roomId }, ["1", "2"])
        // Recent plays and daily: first 10, order kept.
        XCTAssertEqual(viewModel.recentPlays.count, 10)
        XCTAssertEqual(viewModel.recentPlays.first?.songId, "0")
        XCTAssertEqual(viewModel.daily.count, 10)
        XCTAssertEqual(viewModel.daily.first?.songId, "d0")
        // The full list behind "全部" is NOT capped: the section
        // shows 10, the page shows all 12.
        XCTAssertEqual(viewModel.allRecentPlays.count, 12)
        XCTAssertEqual(viewModel.allRecentPlays.first?.songId, "0")
        XCTAssertEqual(viewModel.allRecentPlays.last?.songId, "11")
    }

    func testReloadFallsBackToFirstRecentWithoutResume() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        let recent = [song(songId: "1"), song(songId: "2")]
        viewModel.reload(
            videoHistory: [], recent: recent, listenLog: [], resumeMap: [:],
            follows: [], liveHistory: [], dailyPicks: [])
        XCTAssertEqual(viewModel.continueListening.map { $0.songId }, ["1"])
    }

    func testReloadWithNoRecentHasEmptyContinueListening() {
        let viewModel = HomeViewModel(liveStatusChecker: nil)
        emptyReload(on: viewModel)
        XCTAssertEqual(viewModel.continueListening.count, 0)
    }

    func testReloadDoesNotCallCheckerWhenNoLiveRooms() {
        var calls = 0
        let viewModel = HomeViewModel(liveStatusChecker: { _, completion in
            calls += 1
            completion(.live)
        })
        emptyReload(on: viewModel)
        XCTAssertEqual(calls, 0)
    }

    func testReloadAppliesConfirmedLiveStatus() {
        let viewModel = HomeViewModel(liveStatusChecker: { item, completion in
            // Only room "1" is on air; room "2" is unknown.
            completion(item.roomId == "1" ? .live : .unknown)
        })
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))],
            liveHistory: [liveEntry(roomId: "2", watchedAt: Date(timeIntervalSince1970: 1000))],
            dailyPicks: [])
        // The checker answers synchronously; the view model applies
        // it on the next main-queue turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(viewModel.hotLive.map { $0.roomId }, ["1", "2"])
        XCTAssertEqual(viewModel.hotLive.map { $0.isLive }, [true, false])
    }

    func testLiveBadgeSurvivesReloadWhenCheckIsUnknown() {
        // The old code rebuilt hotLive with isLive false on every
        // reload, so every LIVE badge blinked off until the
        // room-info answers came back — on every tab switch and
        // every favourite tap. A failed / timed-out check must
        // keep the last confirmed value.
        var answerLive = true
        let viewModel = HomeViewModel(liveStatusChecker: { _, completion in
            completion(answerLive ? .live : .unknown)
        })
        let follows = [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))]
        let inputs = (
            videoHistory: [VideoHistoryEntry](), recent: [MusicSong](),
            listenLog: [ListenEvent](), resumeMap: [String: Int](),
            follows: follows, liveHistory: [LiveHistoryEntry](),
            dailyPicks: [MusicSong]())
        viewModel.reload(
            videoHistory: inputs.videoHistory, recent: inputs.recent,
            listenLog: inputs.listenLog, resumeMap: inputs.resumeMap,
            follows: inputs.follows, liveHistory: inputs.liveHistory,
            dailyPicks: inputs.dailyPicks)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(viewModel.hotLive.map { $0.isLive }, [true])
        answerLive = false
        // Second reload with a CHANGED room set (a new follow):
        // a same-set reload inside the 5-min throttle window
        // does not re-check, so the unknown answer below would
        // never be consulted without the new room. The new room
        // forces a fresh round; its `.unknown` answer must leave
        // room "1"'s confirmed badge alone (room "9" is newest
        // first, so it sorts ahead).
        viewModel.reload(
            videoHistory: inputs.videoHistory, recent: inputs.recent,
            listenLog: inputs.listenLog, resumeMap: inputs.resumeMap,
            follows: inputs.follows + [follow(roomId: "9", followedAt: Date(timeIntervalSince1970: 3000))],
            liveHistory: inputs.liveHistory,
            dailyPicks: inputs.dailyPicks)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(viewModel.hotLive.map { $0.roomId }, ["9", "1"])
        XCTAssertEqual(viewModel.hotLive.map { $0.isLive }, [false, true])
    }

    func testLiveBadgeClearsWhenRoomGoesOffline() {
        // The flip side of the test above: a successful "off air"
        // answer must clear the badge — preservation alone would
        // leave a stale LIVE badge on a room that ended its stream.
        var answerLive = true
        let viewModel = HomeViewModel(liveStatusChecker: { _, completion in
            completion(answerLive ? .live : .offline)
        })
        let follows = [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))]
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: follows, liveHistory: [], dailyPicks: [])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(viewModel.hotLive.map { $0.isLive }, [true])
        answerLive = false
        // Changed room set (a new follow), as in the test above:
        // a same-set reload inside the throttle window does not
        // re-check, so the offline answer needs a fresh round.
        // Room "9" is newest first, so it sorts ahead of "1".
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: follows + [follow(roomId: "9", followedAt: Date(timeIntervalSince1970: 3000))],
            liveHistory: [], dailyPicks: [])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(viewModel.hotLive.map { $0.roomId }, ["9", "1"])
        XCTAssertEqual(viewModel.hotLive.map { $0.isLive }, [false, false])
    }

    // MARK: - Live-status throttle / dedup (build 36, item 10)

    func testLiveStatusNotRecheckedWithinThrottleWindow() {
        // Same room set, second reload seconds later: the check
        // round fires once, not once per reload — a tab switch
        // or a pop back inside the window costs zero requests.
        var calls = 0
        let viewModel = HomeViewModel(liveStatusChecker: { _, completion in
            calls += 1
            completion(.live)
        })
        let follows = [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))]
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: follows, liveHistory: [], dailyPicks: [])
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: follows, liveHistory: [], dailyPicks: [])
        XCTAssertEqual(calls, 1)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(viewModel.hotLive.map { $0.isLive }, [true])
    }

    func testLiveStatusRecheckedWhenRoomSetChanges() {
        // A new room in the set defeats the throttle: the fresh
        // round checks the whole set again.
        var calls = 0
        let viewModel = HomeViewModel(liveStatusChecker: { _, completion in
            calls += 1
            completion(.live)
        })
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))],
            liveHistory: [], dailyPicks: [])
        // Flush the first round's main-queue turn, or room "1"
        // still counts as in flight for the second reload.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(calls, 1)
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [
                follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000)),
                follow(roomId: "2", followedAt: Date(timeIntervalSince1970: 3000)),
            ],
            liveHistory: [], dailyPicks: [])
        XCTAssertEqual(calls, 3)
    }

    func testLiveStatusRecheckedAfterThrottleWindowExpires() {
        var calls = 0
        var clock = Date(timeIntervalSince1970: 1000)
        let viewModel = HomeViewModel(
            liveStatusChecker: { _, completion in
                calls += 1
                completion(.live)
            },
            now: { clock })
        let follows = [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))]
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: follows, liveHistory: [], dailyPicks: [])
        XCTAssertEqual(calls, 1)
        // Flush the first round's main-queue turn, or room "1"
        // still counts as in flight after the window expires.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        clock = Date(timeIntervalSince1970: 1000 + 121)
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: follows, liveHistory: [], dailyPicks: [])
        XCTAssertEqual(calls, 2)
    }

    func testLiveStatusInFlightRequestsAreDeduped() {
        // The stub never answers, so room "1" is still in flight
        // when the second reload arrives with a changed set
        // (which defeats the throttle). Only the new room is
        // fired — no duplicate request for the room already
        // being checked.
        var calls = 0
        var held: [(HomeLiveItem, (HomeLiveStatus) -> Void)] = []
        let viewModel = HomeViewModel(liveStatusChecker: { item, completion in
            calls += 1
            held.append((item, completion))
        })
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))],
            liveHistory: [], dailyPicks: [])
        XCTAssertEqual(calls, 1)
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [
                follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000)),
                follow(roomId: "2", followedAt: Date(timeIntervalSince1970: 3000)),
            ],
            liveHistory: [], dailyPicks: [])
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(held.map { $0.0.roomId }, ["1", "2"])
    }

    func testAppearanceReloadCoalescedWithinWindow() {
        // An appearance trigger right after any reload is the
        // same "back at home" event: no second full reload, no
        // second live-status round.
        var calls = 0
        let viewModel = HomeViewModel(liveStatusChecker: { _, completion in
            calls += 1
            completion(.live)
        })
        viewModel.reload(
            videoHistory: [], recent: [], listenLog: [], resumeMap: [:],
            follows: [follow(roomId: "1", followedAt: Date(timeIntervalSince1970: 2000))],
            liveHistory: [], dailyPicks: [])
        XCTAssertEqual(calls, 1)
        viewModel.reloadForAppearance()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(viewModel.hotLive.map { $0.roomId }, ["1"])
    }
}
