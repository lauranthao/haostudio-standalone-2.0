// HAo Studio 2.0 — video browse view-model tests (build 36, item 18).
//
// Pure logic, no network: a fake gateway records every fetch and
// answers only when the test completes a pending page, so the
// pagination / generation state machine is observable step by step.
//
// Wiring (S7 pattern, same as EmbyContinueWatchingTests): Xcode
// test target HAoStudioTests, host app, @testable import HAoStudio.
// NOT Tests/VideoFeaturesTests: that SwiftPM target imports AppCore,
// which does not include VideoBrowseViewModel or VideoDataGateway
// (both live in Features/Video; only VideoLibraryStore.swift from
// that directory is in AppCore), so the view-model is invisible
// there. Package.swift is untouched.

import XCTest

@testable import HAoStudio

/// VideoDataGateway stub: records which query the view-model
/// issues and answers only when a test completes the pending page.
/// Anything not under test answers empty.
private final class FakeBrowseGateway: VideoDataGateway {
    var embyConfigured: Bool = true
    var typeNames: [String] = ["电影", "电视剧"]
    var libraries: [VideoEmbyLibrary] = []
    var genres: [String] = []

    struct ByTypeCall: Equatable {
        let type: String
        let page: Int
        let area: String
        let year: String
        let by: String
    }
    var byTypeCalls: [ByTypeCall] = []
    private var pendingByType: [(Result<VideoItemPage, VideoFetchError>) -> Void] = []
    var pendingByTypeCount: Int { pendingByType.count }

    struct EmbyCall: Equatable {
        let libraryId: String?
        let genre: String?
        let page: Int
    }
    var embyCalls: [EmbyCall] = []
    private var pendingEmby: [(Result<VideoItemPage, EmbyError>) -> Void] = []
    var pendingEmbyCount: Int { pendingEmby.count }

    func fetchHome(completion: @escaping ([VideoHomeRow]) -> Void) { completion([]) }
    func fetchTypeNames(completion: @escaping ([String]) -> Void) { completion(typeNames) }
    func fetchByType(_ type: String, page: Int, area: String, year: String, by: String, completion: @escaping (Result<VideoItemPage, VideoFetchError>) -> Void) {
        byTypeCalls.append(ByTypeCall(type: type, page: page, area: area, year: year, by: by))
        pendingByType.append(completion)
    }
    func search(keyword: String, completion: @escaping ([VideoItem]) -> Void) { completion([]) }
    func fetchDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) { completion(nil) }
    func fetchEmbyLibraries(completion: @escaping ([VideoEmbyLibrary]) -> Void) { completion(libraries) }
    func fetchEmbyGenres(completion: @escaping ([String]) -> Void) { completion(genres) }
    func fetchEmbyItems(
        libraryId: String?,
        genre: String?,
        page: Int,
        completion: @escaping (Result<VideoItemPage, EmbyError>) -> Void
    ) {
        embyCalls.append(EmbyCall(libraryId: libraryId, genre: genre, page: page))
        pendingEmby.append(completion)
    }
    func fetchEmbyDetail(item: VideoItem, completion: @escaping (Result<VideoDetail, EmbyError>) -> Void) { completion(.failure(.unreachable())) }
    /// Hold the Emby search completion when `holdSearchEmby` is
    /// set, so a test can observe the spinner while Emby is still
    /// in flight (V9: it must not clear on the CMS answer alone).
    var holdSearchEmby = false
    private var pendingSearchEmby: [(Result<[VideoItem], EmbyError>) -> Void] = []
    func searchEmby(keyword: String, completion: @escaping (Result<[VideoItem], EmbyError>) -> Void) {
        if holdSearchEmby {
            pendingSearchEmby.append(completion)
        } else {
            completion(.success([]))
        }
    }
    func completeSearchEmbyNext(with result: Result<[VideoItem], EmbyError>) {
        guard !pendingSearchEmby.isEmpty else { return }
        pendingSearchEmby.removeFirst()(result)
    }
    func enqueueDownload(
        detail: VideoDetail, episode: PlayEpisode, line: PlayLine,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }

    func completeByTypeNext(with page: VideoItemPage) {
        guard !pendingByType.isEmpty else { return }
        pendingByType.removeFirst()(.success(page))
    }

    func completeByTypeFailure() {
        guard !pendingByType.isEmpty else { return }
        pendingByType.removeFirst()(.failure(.unreachable))
    }

    func completeEmbyNext(with page: VideoItemPage) {
        guard !pendingEmby.isEmpty else { return }
        pendingEmby.removeFirst()(.success(page))
    }

    func completeEmbyFailure(with error: EmbyError) {
        guard !pendingEmby.isEmpty else { return }
        pendingEmby.removeFirst()(.failure(error))
    }
}

@MainActor
final class VideoBrowseViewModelTests: XCTestCase {
    private var savedPrefs: VideoCategoryPrefs = .empty
    private var savedTabMode = "cms"

    override func setUp() {
        super.setUp()
        savedPrefs = VideoLibraryStore.categoryPrefs()
        savedTabMode = VideoLibraryStore.tabMode()
        VideoLibraryStore.saveCategoryPrefs(.empty)
        VideoLibraryStore.setTabMode("cms")
    }

    override func tearDown() {
        VideoLibraryStore.saveCategoryPrefs(savedPrefs)
        VideoLibraryStore.setTabMode(savedTabMode)
        super.tearDown()
    }

    private func item(_ id: String, title: String, sourceId: Int? = 1) -> VideoItem {
        VideoItem(id: id, title: title, coverURL: nil, year: "2024",
                  typeName: "电影", remarks: nil, sourceId: sourceId)
    }

    private func page(_ items: [VideoItem], hasMore: Bool) -> VideoItemPage {
        VideoItemPage(items: items, hasMore: hasMore)
    }

    // MARK: - Entry default

    func testEntryDefaultSelectsFirstVisibleCategoryAndLoads() {
        let gateway = FakeBrowseGateway()
        gateway.typeNames = ["电影", "综艺", "电视剧"]
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)

        XCTAssertEqual(viewModel.categories, ["电影", "综艺", "电视剧"])
        XCTAssertEqual(viewModel.selectedType, "电影")
        // Never sits empty: the first page is already requested.
        XCTAssertEqual(gateway.byTypeCalls, [
            FakeBrowseGateway.ByTypeCall(type: "电影", page: 0, area: "all", year: "all", by: ""),
        ])
        gateway.completeByTypeNext(with: page([item("1", title: "A"), item("2", title: "B")], hasMore: true))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A", "B"])
        XCTAssertTrue(viewModel.hasMore)
    }

    func testUnknownInitialTypeFallsBackToFirstCategory() {
        let gateway = FakeBrowseGateway()
        gateway.typeNames = ["电影", "电视剧"]
        let viewModel = VideoBrowseViewModel(initialType: "不存在", gateway: gateway)

        XCTAssertEqual(viewModel.selectedType, "电影")
        XCTAssertEqual(gateway.byTypeCalls.first?.type, "电影")
    }

    func testKnownInitialTypeIsPreselected() {
        let gateway = FakeBrowseGateway()
        gateway.typeNames = ["电影", "电视剧"]
        let viewModel = VideoBrowseViewModel(initialType: "电视剧", gateway: gateway)

        XCTAssertEqual(viewModel.selectedType, "电视剧")
        XCTAssertEqual(gateway.byTypeCalls.first?.type, "电视剧")
    }

    func testHiddenCategoryPrefsApplyToBrowseTypes() {
        VideoLibraryStore.saveCategoryPrefs(VideoCategoryPrefs(hidden: ["电影"], order: []))
        let gateway = FakeBrowseGateway()
        gateway.typeNames = ["电影", "电视剧"]
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)

        XCTAssertEqual(viewModel.categories, ["电视剧"])
        XCTAssertEqual(viewModel.selectedType, "电视剧")
        XCTAssertEqual(gateway.byTypeCalls.first?.type, "电视剧")
    }

    // MARK: - Filter change resets pagination

    func testFilterChangeResetsPagination() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)
        gateway.completeByTypeNext(with: page([item("1", title: "A"), item("2", title: "B")], hasMore: true))
        viewModel.loadMore()
        gateway.completeByTypeNext(with: page([item("3", title: "C")], hasMore: false))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A", "B", "C"])
        XCTAssertFalse(viewModel.hasMore)

        viewModel.area = "香港"
        // Reset, before the fresh page lands: empty items, page 0
        // re-requested with the new filter, hasMore back to true.
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertEqual(gateway.byTypeCalls.last, FakeBrowseGateway.ByTypeCall(
            type: "电影", page: 0, area: "香港", year: "all", by: ""))
        gateway.completeByTypeNext(with: page([item("4", title: "D")], hasMore: true))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["D"])

        viewModel.year = "2024"
        XCTAssertEqual(gateway.byTypeCalls.last?.year, "2024")
        XCTAssertEqual(gateway.byTypeCalls.last?.page, 0)
        gateway.completeByTypeNext(with: page([item("5", title: "E")], hasMore: true))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["E"])

        viewModel.sort = "hits"
        XCTAssertEqual(gateway.byTypeCalls.last?.by, "hits")
        XCTAssertEqual(gateway.byTypeCalls.last?.page, 0)
    }

    // MARK: - Pagination state machine

    func testPaginationAppendsWithoutDuplicatesAndEndsOnEmptyPage() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)
        gateway.completeByTypeNext(with: page(
            [item("1", title: "A", sourceId: 1), item("2", title: "B", sourceId: 1)], hasMore: true))
        viewModel.loadMore()
        // Overlapping item (same sourceId|id) must not duplicate.
        gateway.completeByTypeNext(with: page(
            [item("2", title: "B", sourceId: 1), item("3", title: "C", sourceId: 2)], hasMore: true))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A", "B", "C"])

        viewModel.loadMore()
        // An empty page ends the list only when the service says
        // there is nothing after it: empty + hasMore advances to
        // the next page (a filtered window can come back empty
        // while later windows still hold matches).
        gateway.completeByTypeNext(with: page([], hasMore: true))
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertEqual(gateway.byTypeCalls.last?.page, 3)
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A", "B", "C"])

        gateway.completeByTypeNext(with: page([], hasMore: false))
        XCTAssertFalse(viewModel.hasMore)

        let callsBefore = gateway.byTypeCalls.count
        viewModel.loadMore()
        XCTAssertEqual(gateway.byTypeCalls.count, callsBefore)
    }

    /// An empty first page with more pages behind it must not end
    /// the list: the grid advances instead of showing "这个分类下
    /// 没有内容" for a list that is not empty.
    func testEmptyPageWithMoreAdvancesToNextPage() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)
        gateway.completeByTypeNext(with: page([], hasMore: true))
        XCTAssertEqual(gateway.byTypeCalls.last?.page, 1)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.hasMore)
        gateway.completeByTypeNext(with: page([item("1", title: "A")], hasMore: false))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A"])
        XCTAssertFalse(viewModel.hasMore)
    }

    // MARK: - Category view-model: generation guard + load-once

    /// A reload issued while a page is in flight must not let the
    /// stale page append its (wrong-page) items: the stale
    /// completion is dropped and the fresh query re-issued.
    func testCategoryReloadDuringFlightDropsStalePage() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoCategoryViewModel(type: "电影", gateway: gateway)
        viewModel.loadIfNeeded()
        XCTAssertEqual(gateway.byTypeCalls.count, 1)

        viewModel.reload()
        // The reload's loadMore is dropped by the loadingMore
        // guard while the first page is still in flight.
        XCTAssertEqual(gateway.byTypeCalls.count, 1)

        gateway.completeByTypeNext(with: page([item("9", title: "STALE")], hasMore: true))
        XCTAssertEqual(gateway.byTypeCalls.count, 2)
        XCTAssertEqual(gateway.byTypeCalls.last?.page, 0)
        XCTAssertTrue(viewModel.items.isEmpty)

        gateway.completeByTypeNext(with: page([item("1", title: "FRESH")], hasMore: false))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["FRESH"])
    }

    /// Returning to the category page must not re-fetch: items
    /// already loaded stay put (scroll position preserved).
    func testCategoryLoadIfNeededDoesNotRefetch() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoCategoryViewModel(type: "电影", gateway: gateway)
        viewModel.loadIfNeeded()
        gateway.completeByTypeNext(with: page([item("1", title: "A")], hasMore: false))
        let callsBefore = gateway.byTypeCalls.count
        viewModel.loadIfNeeded()
        XCTAssertEqual(gateway.byTypeCalls.count, callsBefore)
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A"])
    }

    // MARK: - CMS failure: retain previous results (§4.1)

    /// A same-query reload (pull-to-refresh) that fails must keep
    /// the last good grid on screen and show the error, not empty
    /// the grid into "这个分类下没有内容".
    func testRefreshFailureKeepsPreviousResultsAndShowsError() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)
        gateway.completeByTypeNext(with: page([item("1", title: "A"), item("2", title: "B")], hasMore: true))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A", "B"])

        viewModel.refresh()
        gateway.completeByTypeFailure()
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A", "B"])
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// A filter change that fails has nothing valid to keep: the
    /// grid stays empty and the error shows instead of the
    /// empty-category copy.
    func testFilterChangeFailureShowsErrorWithoutOldResults() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)
        gateway.completeByTypeNext(with: page([item("1", title: "A")], hasMore: false))

        viewModel.area = "香港"
        XCTAssertTrue(viewModel.items.isEmpty)
        gateway.completeByTypeFailure()
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// First load failing shows the error, not the empty-category copy.
    func testFirstLoadFailureShowsError() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)
        gateway.completeByTypeFailure()
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// Same rule on the category page: a pull-to-refresh failure
    /// keeps the loaded posters.
    func testCategoryRefreshFailureKeepsPreviousResults() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoCategoryViewModel(type: "电影", gateway: gateway)
        viewModel.loadIfNeeded()
        gateway.completeByTypeNext(with: page([item("1", title: "A")], hasMore: false))
        viewModel.reload()
        gateway.completeByTypeFailure()
        XCTAssertEqual(viewModel.items.map { $0.title }, ["A"])
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Search: spinner waits for both requests

    /// CMS answering empty must not clear the spinner while the
    /// Emby request is still in flight — otherwise the page
    /// flashes "没有找到相关影片" before the Emby results land.
    func testSearchSpinnerWaitsForEmby() {
        let gateway = FakeBrowseGateway()
        gateway.embyConfigured = true
        gateway.holdSearchEmby = true
        let viewModel = VideoSearchViewModel(gateway: gateway)
        viewModel.search("b36-test-query")
        defer { VideoLibraryStore.removeSearchHistory(term: "b36-test-query") }
        XCTAssertTrue(viewModel.isSearching)
        XCTAssertTrue(viewModel.results.isEmpty)
        gateway.completeSearchEmbyNext(with: .success([]))
        XCTAssertFalse(viewModel.isSearching)
    }

    // MARK: - Stale-page drop

    func testStalePageIsDroppedAndFreshQueryReissued() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)
        XCTAssertEqual(gateway.pendingByTypeCount, 1)

        viewModel.reload()
        // The reload's loadMore is dropped by the loadingMore guard
        // while the first page is still in flight.
        XCTAssertEqual(gateway.byTypeCalls.count, 1)

        // The stale page lands: its items must never appear, and
        // the fresh query is re-issued because items is empty.
        gateway.completeByTypeNext(with: page([item("9", title: "STALE")], hasMore: true))
        XCTAssertEqual(gateway.byTypeCalls.count, 2)
        XCTAssertEqual(gateway.byTypeCalls.last?.page, 0)
        XCTAssertTrue(viewModel.items.isEmpty)

        gateway.completeByTypeNext(with: page([item("1", title: "FRESH")], hasMore: true))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["FRESH"])
    }

    // MARK: - Emby mode

    func testEmbyModeLoadsLibrariesGenresAndItems() {
        let gateway = FakeBrowseGateway()
        gateway.libraries = [VideoEmbyLibrary(id: "lib1", name: "电影库")]
        gateway.genres = ["动作"]
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)

        viewModel.mode = "emby"
        XCTAssertEqual(viewModel.libraries.map { $0.name }, ["电影库"])
        XCTAssertEqual(viewModel.genres, ["动作"])
        XCTAssertEqual(gateway.embyCalls, [
            FakeBrowseGateway.EmbyCall(libraryId: nil, genre: nil, page: 0),
        ])
        gateway.completeEmbyNext(with: page([item("e1", title: "E1", sourceId: nil)], hasMore: true))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["E1"])

        viewModel.selectedGenre = "动作"
        XCTAssertEqual(gateway.embyCalls.last, FakeBrowseGateway.EmbyCall(
            libraryId: nil, genre: "动作", page: 0))
        gateway.completeEmbyNext(with: page([item("e2", title: "E2", sourceId: nil)], hasMore: false))
        XCTAssertEqual(viewModel.items.map { $0.title }, ["E2"])

        viewModel.selectedLibraryId = "lib1"
        XCTAssertEqual(gateway.embyCalls.last, FakeBrowseGateway.EmbyCall(
            libraryId: "lib1", genre: "动作", page: 0))
    }

    func testEmbyNotConfiguredLoadsNothing() {
        let gateway = FakeBrowseGateway()
        gateway.embyConfigured = false
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)

        viewModel.mode = "emby"
        XCTAssertTrue(gateway.embyCalls.isEmpty)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testEmbyItemsFailureSurfacesHonestErrorAndRetries() {
        let gateway = FakeBrowseGateway()
        let viewModel = VideoBrowseViewModel(initialType: nil, gateway: gateway)

        viewModel.mode = "emby"
        gateway.completeEmbyFailure(with: .unreachable())
        XCTAssertEqual(viewModel.errorMessage, "连不上 Emby 服务器，检查地址和网络")
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertTrue(viewModel.items.isEmpty)

        // Retry re-issues the fetch; a success clears the error.
        viewModel.reload()
        gateway.completeEmbyNext(with: page([item("e1", title: "E1", sourceId: nil)], hasMore: false))
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.items.map { $0.title }, ["E1"])
    }
}
