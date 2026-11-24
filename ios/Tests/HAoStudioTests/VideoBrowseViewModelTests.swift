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
    private var pendingByType: [(VideoItemPage) -> Void] = []
    var pendingByTypeCount: Int { pendingByType.count }

    struct EmbyCall: Equatable {
        let libraryId: String?
        let genre: String?
        let page: Int
    }
    var embyCalls: [EmbyCall] = []
    private var pendingEmby: [(VideoItemPage) -> Void] = []
    var pendingEmbyCount: Int { pendingEmby.count }

    func fetchHome(completion: @escaping ([VideoHomeRow]) -> Void) { completion([]) }
    func fetchTypeNames(completion: @escaping ([String]) -> Void) { completion(typeNames) }
    func fetchByType(_ type: String, page: Int, area: String, year: String, by: String, completion: @escaping (VideoItemPage) -> Void) {
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
        completion: @escaping (VideoItemPage) -> Void
    ) {
        embyCalls.append(EmbyCall(libraryId: libraryId, genre: genre, page: page))
        pendingEmby.append(completion)
    }
    func fetchEmbyDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) { completion(nil) }
    func searchEmby(keyword: String, completion: @escaping ([VideoItem]) -> Void) { completion([]) }
    func enqueueDownload(
        detail: VideoDetail, episode: PlayEpisode, line: PlayLine,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }

    func completeByTypeNext(with page: VideoItemPage) {
        guard !pendingByType.isEmpty else { return }
        pendingByType.removeFirst()(page)
    }

    func completeEmbyNext(with page: VideoItemPage) {
        guard !pendingEmby.isEmpty else { return }
        pendingEmby.removeFirst()(page)
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
        gateway.completeByTypeNext(with: page([], hasMore: true))
        XCTAssertFalse(viewModel.hasMore)

        let callsBefore = gateway.byTypeCalls.count
        viewModel.loadMore()
        XCTAssertEqual(gateway.byTypeCalls.count, callsBefore)
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
}
