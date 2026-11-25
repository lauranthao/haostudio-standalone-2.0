// HAo Studio 2.0 — music API parser tests (S2-B).
//
// Pure parsers, no network: LRC (with translation matching),
// Kuwo pseudo-JSON song/playlist parsing, playlist-link id
// extractors, the Kugou sign (always nil — the secret lives
// outside the source), and the shared text helpers.

import Foundation
import XCTest

@testable import AppCore

final class MusicAPIParserTests: XCTestCase {
    // MARK: - LRC

    func testParseLrcBasic() {
        let text = """
            [ti:Test Song]
            [ar:Singer]
            [00:01.00]First line
            [00:05.50]Second line
            [01:00.00]Third line
            """
        let lines = MusicLyricsAPI.parseLrc(text)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].time, 1.0, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[1].time, 5.5, accuracy: 0.001)
        XCTAssertEqual(lines[2].time, 60.0, accuracy: 0.001)
    }

    func testParseLrcSkipsTagsAndEmptyLines() {
        let text = """
            [00:01.00][ti:ignored]
            [00:02.00]
            [00:03.00]纯音乐，请欣赏
            [00:04.00]Real line
            """
        let lines = MusicLyricsAPI.parseLrc(text)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Real line")
    }

    func testParseLrcWithTranslationMatchesByTimestamp() {
        let main = "[00:01.00]Hello\n[00:05.00]World\n"
        let trans = "[00:01.00]你好\n[00:05.00]世界\n"
        let lines = MusicLyricsAPI.parseLrcWithTranslation(main, translation: trans)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].translation, "你好")
        XCTAssertEqual(lines[1].translation, "世界")
    }

    func testParseLrcWithTranslationKeepsUnmatchedLines() {
        let main = "[00:01.00]Hello\n[00:09.00]Alone\n"
        let trans = "[00:01.00]你好\n"
        let lines = MusicLyricsAPI.parseLrcWithTranslation(main, translation: trans)
        XCTAssertEqual(lines[0].translation, "你好")
        XCTAssertNil(lines[1].translation)
    }

    func testParseLrcWithTranslationNilIsPlainParse() {
        let main = "[00:01.00]Hello\n"
        XCTAssertEqual(
            MusicLyricsAPI.parseLrcWithTranslation(main, translation: nil).count, 1)
        XCTAssertNil(
            MusicLyricsAPI.parseLrcWithTranslation(main, translation: nil)[0].translation)
    }

    // MARK: - Kuwo pseudo-JSON

    func testParseKwSongsFromPseudoJson() {
        let text = """
            {'abslist':[{'MUSICRID':'MUSIC_12345','NAME':'Test Song','ARTIST':'Singer','ALBUM':'Album','DURATION':'200','web_albumpic_short':'abc.jpg'}],'TOTAL':'1'}
            """
        let tracks = MusicSearchAPI.parseKwSongs(text)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].id, "12345")
        XCTAssertEqual(tracks[0].title, "Test Song")
        XCTAssertEqual(tracks[0].artist, "Singer")
        XCTAssertEqual(tracks[0].album, "Album")
        XCTAssertEqual(tracks[0].duration, 200)
        XCTAssertEqual(tracks[0].sourceID, "kw")
    }

    func testParseKwSongsSkipsEntriesWithoutIdOrTitle() {
        let text = """
            {'abslist':[{'MUSICRID':'MUSIC_','NAME':'No id','ARTIST':'Singer'},{'MUSICRID':'MUSIC_9','NAME':'','ARTIST':'Singer'},{'MUSICRID':'MUSIC_7','NAME':'Good','ARTIST':'Singer'}]}
            """
        let tracks = MusicSearchAPI.parseKwSongs(text)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].id, "7")
    }

    func testParseKwPlaylistsFromPseudoJson() {
        let text = """
            {'abslist':[{'DC_TARGETID':'67890','name':'My Playlist','hts_pic':'pic.jpg','playcnt':'1234','songnum':'42','nickname':'Creator','intro':'Desc'}],'TOTAL':'1'}
            """
        let (items, total) = MusicPlaylistImportAPI.parseKwPlaylists(text)
        XCTAssertEqual(total, 1)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "67890")
        XCTAssertEqual(items[0].name, "My Playlist")
        XCTAssertEqual(items[0].creator, "Creator")
        XCTAssertEqual(items[0].playCount, 1234)
        XCTAssertEqual(items[0].trackCount, 42)
        XCTAssertEqual(items[0].platform, .kw)
    }

    // MARK: - NetEase song detail (b40)

    /// b40 (chen 2026-11-25: 广场/排行榜歌单打开后歌曲读不出
    /// 信息): `/api/song/detail/` dropped `ar` / `al` — the live
    /// payload (热歌榜, 2026-11-25) carries `artists` / `album`
    /// on 100/100 songs and the old keys on 0/100. Fixture below
    /// is the real shape (first song of that payload: 海屿你 /
    /// 马也_Crabbit). The old-shape case pins the fallback.
    func testParseWySongDetailReadsNewArtistsAlbumKeys() {
        let json: [String: Any] = ["songs": [
            ["id": 1973665667, "name": "海屿你", "duration": 295940,
             "artists": [["name": "马也_Crabbit"]],
             "album": ["name": "海屿你",
                       "picUrl": "https://p1.music.126.net/Enhy6dPn4gpyqrKhVEQvgA==/109951170483249998.jpg"]],
            ["id": 287398, "name": "我不难过", "duration": 320400,
             "artists": [["name": "孙燕姿"]],
             "album": ["name": "未完成",
                       "picUrl": "https://p1.music.126.net/Pzxy6py26NgNmhJjYMf2RQ==/109951169868874363.jpg"]],
        ]]
        let tracks = MusicPlaylistImportAPI.parseWySongDetail(json)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].title, "海屿你")
        XCTAssertEqual(tracks[0].artist, "马也_Crabbit")
        XCTAssertEqual(tracks[0].album, "海屿你")
        XCTAssertTrue(tracks[0].coverURL?.absoluteString.contains("p1.music.126.net") == true)
        XCTAssertEqual(tracks[0].duration, 296)
        XCTAssertEqual(tracks[1].title, "我不难过")
        XCTAssertEqual(tracks[1].artist, "孙燕姿")
        XCTAssertEqual(tracks[1].album, "未完成")
        XCTAssertFalse(tracks[1].coverURL?.absoluteString.isEmpty == true)
    }

    func testParseWySongDetailFallsBackToOldArAlKeys() {
        let json: [String: Any] = ["songs": [
            ["id": 123, "name": "旧歌", "dt": 200000,
             "ar": [["name": "旧歌手"]],
             "al": ["name": "旧专辑", "picUrl": "https://example.com/cover.jpg"]],
        ]]
        let tracks = MusicPlaylistImportAPI.parseWySongDetail(json)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].artist, "旧歌手")
        XCTAssertEqual(tracks[0].album, "旧专辑")
        XCTAssertEqual(tracks[0].coverURL?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertEqual(tracks[0].duration, 200)
    }

    // MARK: - Playlist-link id extractors

    func testWyPlaylistIdFromURL() {
        XCTAssertEqual(
            MusicPlaylistImportAPI.wyPlaylistIdFromURL("https://music.163.com/playlist?id=123456"),
            "123456")
        XCTAssertEqual(
            MusicPlaylistImportAPI.wyPlaylistIdFromURL("https://music.163.com/#/playlist?id=789"),
            "789")
        XCTAssertNil(
            MusicPlaylistImportAPI.wyPlaylistIdFromURL("https://music.163.com/song?id=123"))
        XCTAssertNil(
            MusicPlaylistImportAPI.wyPlaylistIdFromURL("https://example.com/playlist?id=123"))
    }

    func testKgSpecialIdFromURL() {
        XCTAssertEqual(
            MusicPlaylistImportAPI.kgSpecialIdFromURL(
                "https://www.kugou.com/yy/special/single/54321.html"),
            "54321")
        XCTAssertEqual(
            MusicPlaylistImportAPI.kgSpecialIdFromURL(
                "https://www.kugou.com/yy/special/single/?specialid=111"),
            "111")
        XCTAssertNil(
            MusicPlaylistImportAPI.kgSpecialIdFromURL("https://www.kugou.com/song/123.html"))
    }

    func testKgPlistIdFromURL() {
        XCTAssertEqual(
            MusicPlaylistImportAPI.kgPlistIdFromURL("https://m.kugou.com/plist/list/98765"),
            "98765")
        XCTAssertEqual(
            MusicPlaylistImportAPI.kgPlistIdFromURL("https://m.kugou.com/plist/12345"),
            "12345")
        XCTAssertNil(
            MusicPlaylistImportAPI.kgPlistIdFromURL("https://m.kugou.com/plist/list/12"))
    }

    func testKgShareParamsFromURL() {
        let params = MusicPlaylistImportAPI.kgShareParamsFromURL(
            "https://m.kugou.com/share/zlist.html?listid=111&uid=222&sign=abc&_t=999&type=1")
        XCTAssertEqual(params?.listid, "111")
        XCTAssertEqual(params?.uid, "222")
        XCTAssertEqual(params?.sign, "abc")
        XCTAssertEqual(params?.type, "1")
        XCTAssertNil(
            MusicPlaylistImportAPI.kgShareParamsFromURL(
                "https://m.kugou.com/share/zlist.html?listid=111"))
    }

    func testExtractURLFromPastedText() {
        XCTAssertEqual(
            MusicPlaylistImportAPI.extractURL(from: "check this https://music.163.com/playlist?id=5 out"),
            "https://music.163.com/playlist?id=5")
        XCTAssertNil(MusicPlaylistImportAPI.extractURL(from: "no link here"))
    }

    // MARK: - Kugou sign: always nil, never hardcoded

    func testKugouSignAlwaysReturnsNil() {
        XCTAssertNil(MusicPlaylistImportAPI.kugouSign(params: ["listid": "1", "uid": "2"]))
        XCTAssertNil(MusicPlaylistImportAPI.kugouSign(params: [:]))
    }

    // MARK: - Text helpers

    func testToHttpsAndPlayableURL() {
        XCTAssertEqual(MusicText.toHttps("http://example.com/a.mp3"), "https://example.com/a.mp3")
        XCTAssertEqual(MusicText.toHttps("https://example.com/a.mp3"), "https://example.com/a.mp3")
        XCTAssertTrue(MusicText.isPlayableURL("https://example.com/a.mp3"))
        XCTAssertTrue(MusicText.isPlayableURL("http://example.com/a.mp3"))
        XCTAssertFalse(MusicText.isPlayableURL(""))
        XCTAssertFalse(MusicText.isPlayableURL("ftp://example.com/a.mp3"))
        XCTAssertFalse(MusicText.isPlayableURL("https://exa%mple.com/a.mp3"))
    }

    func testNormalizeNameAndBaseSongTitle() {
        XCTAssertEqual(MusicText.normalizeName("  Hello   World  "), "hello world")
        XCTAssertEqual(MusicText.baseSongTitle("Song (Live)"), "Song")
        XCTAssertEqual(MusicText.baseSongTitle("Song [Remix]"), "Song")
        XCTAssertEqual(MusicText.baseSongTitle("Plain Song"), "Plain Song")
    }

    func testDecodeEntities() {
        XCTAssertEqual(MusicText.decodeEntities("A &amp; B"), "A & B")
        XCTAssertEqual(MusicText.decodeEntities("&#23398;"), "学")
        XCTAssertEqual(MusicText.decodeEntities("&#x5B66;"), "学")
    }

    func testCoverHiUpgradesQqAndNetease() {
        let qq = MusicText.coverHi(
            "https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg", platform: "tx")
        XCTAssertTrue(qq.contains("T002R800x800M000"))
        let wy = MusicText.coverHi("https://p1.music.126.net/abc", platform: "wy")
        XCTAssertTrue(wy.contains("param=800y800"))
    }

    // MARK: - Script search hits

    func testTrackFromScriptMap() {
        let track = MusicSearchAPI.trackFromScriptMap(
            ["songmid": "001", "title": "Song", "singer": "Singer", "album": "Alb",
             "pic": "https://example.com/c.jpg", "interval": 180],
            platform: .tx)
        XCTAssertEqual(track?.id, "001")
        XCTAssertEqual(track?.title, "Song")
        XCTAssertEqual(track?.artist, "Singer")
        XCTAssertEqual(track?.duration, 180)
        XCTAssertEqual(track?.sourceID, "tx")
        XCTAssertNil(MusicSearchAPI.trackFromScriptMap([:], platform: .tx))
    }
}
