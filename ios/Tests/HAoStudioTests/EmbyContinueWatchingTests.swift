// HAo Studio 2.0 — Emby continue-watching tests (build 36, item 16).
//
// The bug (chen 2026-11-24, screenshot): an Emby film watched on
// Emby (《731》) sits in Home "继续观看", but tapping it opened
// the detail page on the CMS loader, which answers nil for Emby
// items — the page showed "暂无可播剧集" with a dead play button.
// These tests drive VideoDetailViewModel through a stub gateway
// with fixture data only, no files except the test host's own
// history store (seeded + cleaned up per test), no network.
//
// Wiring (S7 pattern): Xcode test target HAoStudioTests, host app,
// @testable import HAoStudio. Package.swift untouched.

import XCTest

@testable import HAoStudio

/// VideoDataGateway stub: records which loader the view model
/// calls and answers scripted details. Anything not under test
/// answers empty.
private final class StubVideoGateway: VideoDataGateway {
    var embyConfigured: Bool = true
    var fetchDetailCalls = 0
    var fetchEmbyDetailCalls = 0
    var cmsDetailResult: VideoDetail?
    var embyDetailResults: [VideoDetail?] = []

    func fetchHome(completion: @escaping ([VideoHomeRow]) -> Void) { completion([]) }
    func fetchTypeNames(completion: @escaping ([String]) -> Void) { completion([]) }
    func fetchByType(_ type: String, page: Int, completion: @escaping (VideoItemPage) -> Void) {
        completion(.empty)
    }
    func search(keyword: String, completion: @escaping ([VideoItem]) -> Void) { completion([]) }
    func fetchDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) {
        fetchDetailCalls += 1
        completion(cmsDetailResult)
    }
    func fetchEmbyLibraries(completion: @escaping ([VideoEmbyLibrary]) -> Void) { completion([]) }
    func fetchEmbyGenres(completion: @escaping ([String]) -> Void) { completion([]) }
    func fetchEmbyItems(
        libraryId: String?, genre: String?, page: Int,
        completion: @escaping (VideoItemPage) -> Void
    ) {
        completion(.empty)
    }
    func fetchEmbyDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) {
        fetchEmbyDetailCalls += 1
        if embyDetailResults.isEmpty {
            completion(nil)
            return
        }
        completion(embyDetailResults.removeFirst())
    }
    func searchEmby(keyword: String, completion: @escaping ([VideoItem]) -> Void) { completion([]) }
    func enqueueDownload(
        detail: VideoDetail, episode: PlayEpisode, line: PlayLine,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
}

@MainActor
final class EmbyContinueWatchingTests: XCTestCase {

    // MARK: - Fixtures

    /// An Emby item, as EmbyClient.toVideoItem builds it and as
    /// the player stores it in a history row: the Emby item id in
    /// `id`, no CMS source.
    private func embyMovieItem() -> VideoItem {
        VideoItem(
            id: "emby-731", title: "731", coverURL: nil, year: "2025",
            typeName: "剧情 / 战争", remarks: nil, sourceId: nil)
    }

    private func embySeriesItem() -> VideoItem {
        VideoItem(
            id: "emby-series-1", title: "测试剧集", coverURL: nil, year: "2024",
            typeName: "剧情", remarks: nil, sourceId: nil)
    }

    private func cmsItem() -> VideoItem {
        VideoItem(
            id: "12345", title: "狂飙", coverURL: nil, year: "2023",
            typeName: "电视剧", remarks: nil, sourceId: 7)
    }

    private func episode(_ name: String, index: Int) -> PlayEpisode {
        PlayEpisode(name: name, url: URL(string: "http://example.invalid/\(index).mp4"), index: index)
    }

    /// An Emby film detail: one line ("直链") + one episode ("正片").
    private func embyMovieDetail(item: VideoItem) -> VideoDetail {
        VideoDetail(
            item: item,
            lines: [PlayLine(name: "直链", episodes: [episode("正片", index: 0)])],
            meta: nil)
    }

    /// An Emby series detail: one line per season.
    private func embySeriesDetail(item: VideoItem) -> VideoDetail {
        VideoDetail(
            item: item,
            lines: [
                PlayLine(name: "第 1 季", episodes: [
                    episode("第1集", index: 0),
                    episode("第2集", index: 1),
                    episode("第3集", index: 2),
                ]),
                PlayLine(name: "第 2 季", episodes: [
                    episode("第1集", index: 0),
                    episode("第2集", index: 1),
                    episode("第3集", index: 2),
                ]),
            ],
            meta: nil)
    }

    private func cmsSeriesDetail(item: VideoItem) -> VideoDetail {
        VideoDetail(
            item: item,
            lines: [PlayLine(name: "线路1", episodes: [
                episode("第01集", index: 0),
                episode("第02集", index: 1),
            ])],
            meta: nil)
    }

    // MARK: - Routing: the reported bug

    /// A history row saved by Emby playback, opened the way Home
    /// "继续观看" opens it (VideoDetailView(item:), no explicit
    /// source): the Emby loader must run, not the CMS one, and
    /// the film must be playable with a play entry — not
    /// "暂无可播剧集".
    func testEmbyHistoryEntryLoadsEmbyDetailAndPlays() {
        let item = embyMovieItem()
        let entry = VideoHistoryEntry(
            item: item, episodeName: "正片", episodeIndex: 0,
            lineName: "直链", positionSeconds: 600, durationSeconds: 7200,
            updatedAt: Date())
        let gateway = StubVideoGateway()
        gateway.embyDetailResults = [embyMovieDetail(item: item)]

        // The Home path builds the detail view from the entry's
        // item with no explicit source — the item must decide.
        let view = VideoDetailView(item: entry.item)
        XCTAssertEqual(view.source, .emby)

        let viewModel = VideoDetailViewModel(item: entry.item, gateway: gateway)
        XCTAssertEqual(viewModel.source, .emby)
        viewModel.load()
        XCTAssertEqual(gateway.fetchEmbyDetailCalls, 1)
        XCTAssertEqual(gateway.fetchDetailCalls, 0)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.canPlay)
        XCTAssertEqual(viewModel.playButtonLabel, "播放")
        XCTAssertEqual(viewModel.selectedLine?.episodes.count, 1)
    }

    /// An explicit source still wins (EmbyDetailView passes
    /// .emby; nothing passes .cms for an Emby item today).
    func testExplicitSourceWinsOverItem() {
        let gateway = StubVideoGateway()
        gateway.cmsDetailResult = cmsSeriesDetail(item: embyMovieItem())
        let viewModel = VideoDetailViewModel(item: embyMovieItem(), source: .cms, gateway: gateway)
        viewModel.load()
        XCTAssertEqual(gateway.fetchDetailCalls, 1)
        XCTAssertEqual(gateway.fetchEmbyDetailCalls, 0)
    }

    /// A CMS history entry keeps resolving through the CMS loader
    /// exactly as before (no regression on the CMS path).
    func testCmsHistoryEntryStillLoadsCmsDetail() {
        let item = cmsItem()
        let gateway = StubVideoGateway()
        gateway.cmsDetailResult = cmsSeriesDetail(item: item)
        let viewModel = VideoDetailViewModel(item: item, gateway: gateway)
        XCTAssertEqual(viewModel.source, .cms)
        viewModel.load()
        XCTAssertEqual(gateway.fetchDetailCalls, 1)
        XCTAssertEqual(gateway.fetchEmbyDetailCalls, 0)
        XCTAssertTrue(viewModel.canPlay)
        XCTAssertEqual(viewModel.playButtonLabel, "第01集")
    }

    // MARK: - Film copy: no "剧集" wording

    /// A failed Emby load never shows the series copy: the play
    /// button reads "暂无可播内容", not "暂无可播剧集".
    func testEmbyLoadFailureHasNoEpisodeCopy() {
        let gateway = StubVideoGateway()
        gateway.embyDetailResults = [nil]
        let viewModel = VideoDetailViewModel(item: embyMovieItem(), gateway: gateway)
        viewModel.load()
        XCTAssertFalse(viewModel.canPlay)
        XCTAssertEqual(viewModel.playButtonLabel, "暂无可播内容")
    }

    /// A watched Emby film resumes with a play entry, not an
    /// episode name: "继续播放 · mm:ss".
    func testEmbyMovieResumeLabelIsPlayNotEpisode() {
        let item = embyMovieItem()
        VideoLibraryStore.savePosition(
            item: item, episodeName: "正片", episodeIndex: 0,
            lineName: "直链", positionSeconds: 600, durationSeconds: 7200)
        defer { VideoLibraryStore.removeHistory(title: item.title, year: item.year) }
        let gateway = StubVideoGateway()
        gateway.embyDetailResults = [embyMovieDetail(item: item)]
        let viewModel = VideoDetailViewModel(item: item, gateway: gateway)
        viewModel.load()
        XCTAssertTrue(viewModel.canPlay)
        XCTAssertEqual(viewModel.playButtonLabel, "继续播放 · 10:00")
    }

    // MARK: - Series: same routing bug, plus cross-season resume

    /// An Emby series from Continue Watching loads its seasons
    /// and resumes in the season that was playing — not season 1.
    func testEmbySeriesResumeFindsLaterSeason() {
        let item = embySeriesItem()
        VideoLibraryStore.savePosition(
            item: item, episodeName: "第2集", episodeIndex: 1,
            lineName: "第 2 季", positionSeconds: 300, durationSeconds: 2700)
        defer { VideoLibraryStore.removeHistory(title: item.title, year: item.year) }
        let gateway = StubVideoGateway()
        gateway.embyDetailResults = [embySeriesDetail(item: item)]
        let viewModel = VideoDetailViewModel(item: item, gateway: gateway)
        viewModel.load()
        XCTAssertEqual(gateway.fetchEmbyDetailCalls, 1)
        XCTAssertTrue(viewModel.canPlay)
        XCTAssertEqual(viewModel.selectedLineIndex, 1)
        XCTAssertEqual(viewModel.selectedEpisodeIndex, 1)
        XCTAssertEqual(viewModel.playButtonLabel, "继续播放 · 第2集 · 5:00")
    }

    // MARK: - Retry really re-resolves

    /// A first load that answers nil, then a retry that answers a
    /// detail: the retry must re-call the loader and land on a
    /// playable detail — not re-render the same empty state.
    func testRetryRefetchesAndRecovers() {
        let item = embyMovieItem()
        let gateway = StubVideoGateway()
        gateway.embyDetailResults = [nil, embyMovieDetail(item: item)]
        let viewModel = VideoDetailViewModel(item: item, gateway: gateway)
        viewModel.load()
        XCTAssertEqual(gateway.fetchEmbyDetailCalls, 1)
        XCTAssertFalse(viewModel.canPlay)
        XCTAssertEqual(viewModel.playButtonLabel, "暂无可播内容")
        viewModel.load()
        XCTAssertEqual(gateway.fetchEmbyDetailCalls, 2)
        XCTAssertTrue(viewModel.canPlay)
        XCTAssertEqual(viewModel.playButtonLabel, "播放")
    }
}
