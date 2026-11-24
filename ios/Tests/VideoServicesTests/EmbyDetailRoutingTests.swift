// HAo Studio 2.0 — Emby detail routing tests (build 36, item 16).
//
// The bug: an Emby film watched on Emby lands in Home "继续观看",
// but tapping it opened the CMS detail loader, which answers nil
// for Emby items (fetchDetail guards on sourceId) — the page
// showed "暂无可播剧集". The routing decision is pure
// (VideoItem.detailSource + VideoDetailRouting.resumeSelection),
// so it is covered here with fixture data only, no files, no
// network. Swift 5.0.

import XCTest
@testable import AppCore

final class EmbyDetailRoutingTests: XCTestCase {

    // MARK: - Fixtures

    /// An Emby item, as EmbyClient.toVideoItem builds it: the Emby
    /// item id in `id`, no CMS source.
    private func embyItem(id: String = "emby-731", title: String = "731", year: String? = "2025") -> VideoItem {
        VideoItem(
            id: id, title: title, coverURL: nil, year: year,
            typeName: "剧情 / 战争", remarks: nil, sourceId: nil)
    }

    /// A CMS item, as CmsClient.parseVideoItem builds it: the CMS
    /// vod_id in `id`, its source id set.
    private func cmsItem(id: String = "12345", title: String = "狂飙", year: String? = "2023") -> VideoItem {
        VideoItem(
            id: id, title: title, coverURL: nil, year: year,
            typeName: "电视剧", remarks: nil, sourceId: 7)
    }

    private func episode(_ name: String, index: Int) -> PlayEpisode {
        PlayEpisode(name: name, url: URL(string: "http://example.invalid/\(index).mp4"), index: index)
    }

    private func resume(episodeName: String, episodeIndex: Int) -> ResumeInfo {
        ResumeInfo(
            key: "k", episodeName: episodeName, episodeIndex: episodeIndex,
            positionSeconds: 300, durationSeconds: 2700, updatedAt: Date())
    }

    /// An Emby series detail shape: one line per season.
    private func seriesLines() -> [PlayLine] {
        [
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
        ]
    }

    // MARK: - Item -> loader

    func testEmbyItemRoutesToEmbyDetail() {
        XCTAssertEqual(embyItem().detailSource, .emby)
    }

    func testCmsItemRoutesToCmsDetail() {
        XCTAssertEqual(cmsItem().detailSource, .cms)
    }

    // MARK: - Resume selection

    /// Distinct episode titles: the resume episode is found in
    /// its own season, not the first line.
    func testResumeInLaterSeasonWithDistinctTitles() {
        let lines = [
            PlayLine(name: "第 1 季", episodes: [
                episode("试播集", index: 0),
                episode("回乡", index: 1),
            ]),
            PlayLine(name: "第 2 季", episodes: [
                episode("新开始", index: 0),
                episode("重逢", index: 1),
            ]),
        ]
        let found = VideoDetailRouting.resumeSelection(
            lines: lines, resume: resume(episodeName: "重逢", episodeIndex: 1))
        XCTAssertEqual(found?.lineIndex, 1)
        XCTAssertEqual(found?.episodeIndex, 1)
    }

    /// Same-name episodes across seasons ("第 N 集" with no episode
    /// title): the recorded line name picks the right season.
    func testSameNameEpisodesPreferRecordedLine() {
        let found = VideoDetailRouting.resumeSelection(
            lines: seriesLines(),
            resume: resume(episodeName: "第2集", episodeIndex: 1),
            lineName: "第 2 季")
        XCTAssertEqual(found?.lineIndex, 1)
        XCTAssertEqual(found?.episodeIndex, 1)
    }

    /// Same-name episodes, no recorded line: the episode at its
    /// recorded index in the first line holding it wins (still
    /// better than always reopening the first episode).
    func testSameNameEpisodesWithoutLineNameFallBackToFirstLine() {
        let found = VideoDetailRouting.resumeSelection(
            lines: seriesLines(),
            resume: resume(episodeName: "第2集", episodeIndex: 1))
        XCTAssertEqual(found?.lineIndex, 0)
        XCTAssertEqual(found?.episodeIndex, 1)
    }

    /// CMS shape (lines are sources holding the same episodes):
    /// the first line holding the resume episode at its recorded
    /// index wins — the previous behaviour (first playable line)
    /// is preserved.
    func testCmsLinesKeepFirstLineWithEpisode() {
        let lines = [
            PlayLine(name: "线路1", episodes: [episode("第01集", index: 0), episode("第02集", index: 1)]),
            PlayLine(name: "线路2", episodes: [episode("第01集", index: 0), episode("第02集", index: 1)]),
        ]
        let found = VideoDetailRouting.resumeSelection(
            lines: lines, resume: resume(episodeName: "第02集", episodeIndex: 1))
        XCTAssertEqual(found?.lineIndex, 0)
        XCTAssertEqual(found?.episodeIndex, 1)
    }

    /// A resume episode that no longer exists on any line selects
    /// nothing (the caller falls back to the first playable line).
    func testUnknownResumeEpisodeSelectsNothing() {
        let found = VideoDetailRouting.resumeSelection(
            lines: seriesLines(),
            resume: resume(episodeName: "第9集", episodeIndex: 8))
        XCTAssertNil(found)
    }
}
