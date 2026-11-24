// HAo Studio 2.0 — video capability tests (S3, leg A).
//
// SwiftPM style, same shape as S1's MigrationCoreTests and S2's
// MusicLXTests: the `AppCore` target compiles the Services/Video
// sources (Leg B adds the directory to AppCore in
// `ios/Package.swift` — this leg does not edit Package.swift),
// and this test target runs them with `swift test` from ios/.
// Pure logic only (Foundation): no network, no engine, no
// fixture files — every URL is built inline.
//
// NO separate VideoServices target: build #18 (2026-11-23) proved
// SwiftPM forbids one source file in two targets, and the
// coordinator ruled the video test sources hang on AppCore.
// One file, one target.
//
// What is covered: format resolution order (declared wins,
// suffix, host/path FLV markers, `hao_container`), the AVPlayer
// capability gate (FLV/MKV/AV1/DV/TrueHD), the facts gate (DV P8
// + switch), the capability split (who goes first), candidate
// ordering (preferred first among capable, incapable never
// listed), and the software-decode fallback trigger.

import Foundation
import XCTest

@testable import AppCore

final class VideoCapabilityTests: XCTestCase {
    // MARK: - Format resolution

    func testDeclaredFormatWinsOverSuffix() {
        let url = URL(string: "https://example.invalid/play.mp4")!
        XCTAssertEqual(videoFormatOf(url: url, declaredFormat: "flv"), .flv)
        XCTAssertEqual(videoFormatOf(url: url, declaredFormat: "hls"), .hls)
        XCTAssertEqual(videoFormatOf(url: url, declaredFormat: "mkv"), .mkv)
        XCTAssertEqual(videoFormatOf(url: url, declaredFormat: nil), .mp4)
    }

    func testSuffixResolution() {
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/c.flv")!, declaredFormat: nil), .flv)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/c.m3u8")!, declaredFormat: nil), .hls)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/c.m3u")!, declaredFormat: nil), .hls)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/c.mp4")!, declaredFormat: nil), .mp4)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/c.mov")!, declaredFormat: nil), .mp4)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/c.mkv")!, declaredFormat: nil), .mkv)
    }

    func testQueryStringDoesNotBreakSuffix() {
        // Huya-style segment URL: the suffix is before the query.
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/c.mp4?token=xyz")!, declaredFormat: nil), .mp4)
    }

    func testHostAndPathFlvMarkers() {
        XCTAssertEqual(videoFormatOf(url: URL(string: "http://al-game.flv.huya.com/src")!, declaredFormat: nil), .flv)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://pull-flv-l1.douyin.com/live/abc")!, declaredFormat: nil), .flv)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/flv/stream")!, declaredFormat: nil), .flv)
    }

    func testUnknownExcludesNothing() {
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/stream")!, declaredFormat: nil), .unknown)
        XCTAssertEqual(videoFormatOf(url: URL(string: "https://a.b/stream")!, declaredFormat: "other"), .other)
    }

    func testHaoContainerMarker() {
        // Emby direct stream: no suffix, container rides the query.
        let mkv = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mkv&hao_vcodec=hevc")!
        XCTAssertEqual(videoFormatOf(url: mkv, declaredFormat: nil), .mkv)
        let mp4 = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_vcodec=h264")!
        XCTAssertEqual(videoFormatOf(url: mp4, declaredFormat: nil), .mp4)
    }

    // MARK: - Stream facts

    func testFactsParse() {
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mkv&hao_vcodec=hevc&hao_acodec=truehd&hao_dv=1&hao_dvprofile=8.1&hao_width=3840&hao_height=2160&hao_bitrate=20000000&hao_size=123456")!
        let facts = VideoStreamFacts.parse(url: url)
        XCTAssertNotNil(facts)
        XCTAssertEqual(facts?.container, "mkv")
        XCTAssertEqual(facts?.videoCodec, "hevc")
        XCTAssertEqual(facts?.audioCodec, "truehd")
        XCTAssertEqual(facts?.dolbyVision, true)
        XCTAssertEqual(facts?.dvProfile, 8)
        XCTAssertEqual(facts?.width, 3840)
        XCTAssertEqual(facts?.height, 2160)
        XCTAssertEqual(facts?.is4K, true)
    }

    func testFactsParseReturnsNilWithoutMarkers() {
        XCTAssertNil(VideoStreamFacts.parse(url: URL(string: "https://a.b/c.mp4")!))
    }

    func testIs4KByWidthOrHeight() {
        let wide = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: nil, dolbyVision: false, dvProfile: nil, width: 3840, height: 1600, bitRate: nil, size: nil)
        XCTAssertTrue(wide.is4K)
        let tall = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: nil, dolbyVision: false, dvProfile: nil, width: 1920, height: 2160, bitRate: nil, size: nil)
        XCTAssertTrue(tall.is4K)
        let hd = VideoStreamFacts(container: "mp4", videoCodec: "h264", audioCodec: nil, dolbyVision: false, dvProfile: nil, width: 1920, height: 1080, bitRate: nil, size: nil)
        XCTAssertFalse(hd.is4K)
    }

    // MARK: - Capability gate

    func testAVPlayerRejectsFlvAndMkv() {
        XCTAssertFalse(videoEngineCanPlay(.avplayer, format: .flv))
        XCTAssertFalse(videoEngineCanPlay(.avplayer, format: .mkv))
        XCTAssertTrue(videoEngineCanPlay(.avplayer, format: .hls))
        XCTAssertTrue(videoEngineCanPlay(.avplayer, format: .mp4))
        XCTAssertTrue(videoEngineCanPlay(.avplayer, format: .other))
    }

    func testFfmpegKernelsPlayEverything() {
        for format in [VideoStreamFormat.flv, .hls, .mp4, .mkv, .other] {
            XCTAssertTrue(videoEngineCanPlay(.mpv, format: format))
            XCTAssertTrue(videoEngineCanPlay(.ijk, format: format))
        }
    }

    func testUnknownFormatExcludesNothing() {
        for engine in VideoEngine.allCases {
            XCTAssertTrue(videoEngineCanPlay(engine, format: .unknown))
        }
    }

    func testFactsGateRejectsNonAppleContainerForAVPlayer() {
        let mkv = VideoStreamFacts(container: "mkv", videoCodec: "h264", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: mkv))
        XCTAssertTrue(videoEngineCanPlayFacts(.mpv, facts: mkv))
    }

    func testFactsGateRejectsAv1AndTrueHdForAVPlayer() {
        let av1 = VideoStreamFacts(container: "mp4", videoCodec: "av1", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: av1))
        let truehd = VideoStreamFacts(container: "mp4", videoCodec: "h264", audioCodec: "truehd", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: truehd))
        let dts = VideoStreamFacts(container: "mp4", videoCodec: "h264", audioCodec: "dts-hd", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: dts))
    }

    func testFactsGateAdmitsHevcMp4ToAVPlayer() {
        let hevc = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: 3840, height: 2160, bitRate: nil, size: nil)
        XCTAssertTrue(videoEngineCanPlayFacts(.avplayer, facts: hevc))
    }

    func testFactsGateDolbyVisionP8WithSwitchOn() {
        let p8 = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: true, dvProfile: 8, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertTrue(videoEngineCanPlayFacts(.avplayer, facts: p8, dvDowngradeToHdr: true))
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: p8, dvDowngradeToHdr: false))
        // Build 36, item 13: profile 5 has no HDR base layer, so
        // it is ALWAYS admitted to AVPlayer in an Apple container
        // — the ffmpeg kernels render it green. The P8 switch
        // never governed it.
        let p5 = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: true, dvProfile: 5, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertTrue(videoEngineCanPlayFacts(.avplayer, facts: p5, dvDowngradeToHdr: true))
        XCTAssertTrue(videoEngineCanPlayFacts(.avplayer, facts: p5, dvDowngradeToHdr: false))
        let p7 = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: true, dvProfile: 7, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: p7, dvDowngradeToHdr: true))
    }

    func testFactsGateDolbyVisionUnknownProfileAdmittedInAppleContainer() {
        // Server reported DV but no profile: best bet is AVPlayer
        // (P5/P8 native, P7 base layer); the ladder falls back
        // to MPV if AVPlayer refuses the open.
        let unknown = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: true, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertTrue(videoEngineCanPlayFacts(.avplayer, facts: unknown))
        // Same DV in MKV stays off AVPlayer (no MKV demuxer).
        let mkv = VideoStreamFacts(container: "mkv", videoCodec: "hevc", audioCodec: "aac", dolbyVision: true, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: mkv))
    }

    // MARK: - Capability split (who goes first)

    func testPreferredEngineSplit() {
        XCTAssertEqual(videoPreferredEngine(format: .flv, facts: nil), .mpv)
        XCTAssertEqual(videoPreferredEngine(format: .mkv, facts: nil), .mpv)
        XCTAssertEqual(videoPreferredEngine(format: .hls, facts: nil), .avplayer)
        XCTAssertEqual(videoPreferredEngine(format: .mp4, facts: nil), .avplayer)
        XCTAssertEqual(videoPreferredEngine(format: .unknown, facts: nil), .mpv)
        XCTAssertEqual(videoPreferredEngine(format: .mp4, facts: nil, hasAssSubtitles: true), .mpv)
        XCTAssertEqual(videoPreferredEngine(format: .mp4, facts: nil, hasMultipleAudioTracks: true), .mpv)
        let hevcUnknown = VideoStreamFacts(container: nil, videoCodec: "hevc", audioCodec: nil, dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertEqual(videoPreferredEngine(format: .unknown, facts: hevcUnknown), .avplayer)
    }

    func testIjkIsNeverFirst() {
        for format in [VideoStreamFormat.flv, .hls, .mp4, .mkv, .other, .unknown] {
            XCTAssertNotEqual(videoPreferredEngine(format: format, facts: nil), .ijk)
        }
    }

    // MARK: - Candidate ordering

    func testCandidatesForFlvExcludeAVPlayer() {
        let candidates = videoCandidatesFor(url: URL(string: "https://a.b/live.flv")!)
        XCTAssertEqual(candidates, [.mpv, .ijk])
    }

    func testCandidatesForHlsStartWithAVPlayer() {
        let candidates = videoCandidatesFor(url: URL(string: "https://a.b/list.m3u8")!)
        XCTAssertEqual(candidates, [.avplayer, .mpv, .ijk])
    }

    func testCandidatesForMkvExcludeAVPlayer() {
        let candidates = videoCandidatesFor(url: URL(string: "https://a.b/movie.mkv")!)
        XCTAssertEqual(candidates, [.mpv, .ijk])
    }

    func testCandidatesForDvP8Mp4StartWithAVPlayer() {
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_vcodec=hevc&hao_dv=1&hao_dvprofile=8")!
        XCTAssertEqual(videoCandidatesFor(url: url).first, .avplayer)
    }

    func testCandidatesForDvP5Mp4StartWithAVPlayer() {
        // Build 36, item 13: P5 in MP4 goes to AVPlayer first —
        // MPV renders it green (no base layer, no RPU handling
        // on the software render path). The old expectation
        // (AVPlayer excluded, MPV first) was the bug.
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_vcodec=hevc&hao_dv=1&hao_dvprofile=5")!
        XCTAssertEqual(videoCandidatesFor(url: url).first, .avplayer)
        XCTAssertTrue(videoCandidatesFor(url: url).contains(.avplayer))
    }

    func testCandidatesForDvP5MkvStayOnFfmpegKernels() {
        // P5 in MKV cannot reach AVPlayer (no MKV demuxer):
        // MPV first, honest limit — its base-layer-less picture
        // stays wrong-coloured on every bundled kernel.
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mkv&hao_vcodec=hevc&hao_dv=1&hao_dvprofile=5")!
        XCTAssertFalse(videoCandidatesFor(url: url).contains(.avplayer))
        XCTAssertEqual(videoCandidatesFor(url: url).first, .mpv)
    }

    func testCandidatesForDvP7Mp4ExcludeAVPlayer() {
        // Dual-layer P7 stays on the ffmpeg kernels, which render
        // its HDR10 base layer (AVPlayer would do the same).
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_vcodec=hevc&hao_dv=1&hao_dvprofile=7")!
        XCTAssertFalse(videoCandidatesFor(url: url).contains(.avplayer))
        XCTAssertEqual(videoCandidatesFor(url: url).first, .mpv)
    }

    func testCandidatesForDvP8Mp4SwitchOffExcludeAVPlayer() {
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_vcodec=hevc&hao_dv=1&hao_dvprofile=8")!
        XCTAssertFalse(videoCandidatesFor(url: url, dvDowngradeToHdr: false).contains(.avplayer))
        XCTAssertEqual(videoCandidatesFor(url: url, dvDowngradeToHdr: false).first, .mpv)
    }

    func testCandidatesForHdr10Mp4StartWithAVPlayer() {
        // HDR10 (HEVC, no DV flag) in MP4: AVPlayer first, native
        // HDR. HLG rides the same facts (HEVC in MP4) — same route.
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_vcodec=hevc&hao_width=3840&hao_height=2160")!
        XCTAssertEqual(videoCandidatesFor(url: url).first, .avplayer)
    }

    func testExplicitPreferenceWinsAmongCapable() {
        // User preference for IJK on an HLS stream: IJK first, but
        // the incapable engines still never appear (FLV + AVPlayer
        // preference -> AVPlayer is dropped, not first).
        let hls = videoCandidatesFor(url: URL(string: "https://a.b/list.m3u8")!, preferred: .ijk)
        XCTAssertEqual(hls, [.ijk, .mpv, .avplayer])
        let flv = videoCandidatesFor(url: URL(string: "https://a.b/live.flv")!, preferred: .avplayer)
        XCTAssertEqual(flv, [.mpv, .ijk])
    }

    func testUnknownFormatListsAllEngines() {
        XCTAssertEqual(videoCandidatesFor(url: URL(string: "https://a.b/stream")!), [.mpv, .ijk, .avplayer])
    }

    // MARK: - Software-decode fallback trigger

    func testNeedsHardwareDecode() {
        let hevc4k = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: 3840, height: 2160, bitRate: nil, size: nil)
        XCTAssertTrue(videoNeedsHardwareDecode(facts: hevc4k))
        let dv = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: true, dvProfile: 5, width: 1920, height: 1080, bitRate: nil, size: nil)
        XCTAssertTrue(videoNeedsHardwareDecode(facts: dv))
        let hevcHd = VideoStreamFacts(container: "mp4", videoCodec: "hevc", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: 1920, height: 1080, bitRate: nil, size: nil)
        XCTAssertFalse(videoNeedsHardwareDecode(facts: hevcHd))
        let h2644k = VideoStreamFacts(container: "mp4", videoCodec: "h264", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: 3840, height: 2160, bitRate: nil, size: nil)
        XCTAssertFalse(videoNeedsHardwareDecode(facts: h2644k))
        XCTAssertFalse(videoNeedsHardwareDecode(facts: nil))
    }
}
