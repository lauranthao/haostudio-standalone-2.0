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

    // MARK: - Build 36, item 14: format recognition (G-A)

    func testNewContainerSuffixes() {
        let cases: [(String, VideoStreamFormat)] = [
            ("https://a.b/c.avi", .avi),
            ("https://a.b/c.wmv", .wmv),
            ("https://a.b/c.asf", .wmv),
            ("https://a.b/c.rm", .rmvb),
            ("https://a.b/c.rmvb", .rmvb),
            ("https://a.b/c.ts", .ts),
            ("https://a.b/c.m2ts", .ts),
            ("https://a.b/c.mts", .ts),
            ("https://a.b/c.webm", .webm),
            ("https://a.b/c.mpg", .mpg),
            ("https://a.b/c.mpeg", .mpg),
            ("https://a.b/c.vob", .mpg),
            ("https://a.b/c.mpd", .dash),
            ("https://a.b/c.3gp", .mp4),
            ("https://a.b/c.3g2", .mp4),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(videoFormatOf(url: URL(string: raw)!, declaredFormat: nil), expected, raw)
        }
    }

    func testHaoContainerNormalisation() {
        // Emby reports `matroska` for MKV and `mpegts` for TS.
        let mkv = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=matroska")!
        XCTAssertEqual(videoFormatOf(url: mkv, declaredFormat: nil), .mkv)
        let ts = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mpegts")!
        XCTAssertEqual(videoFormatOf(url: ts, declaredFormat: nil), .ts)
        let asf = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=asf")!
        XCTAssertEqual(videoFormatOf(url: asf, declaredFormat: nil), .wmv)
        let webm = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=webm")!
        XCTAssertEqual(videoFormatOf(url: webm, declaredFormat: nil), .webm)
    }

    func testAVPlayerExcludedForNewFormats() {
        for format in [VideoStreamFormat.avi, .wmv, .rmvb, .ts, .webm, .mpg, .dash] {
            XCTAssertFalse(videoEngineCanPlay(.avplayer, format: format), "\(format)")
            XCTAssertTrue(videoEngineCanPlay(.mpv, format: format), "\(format)")
            XCTAssertTrue(videoEngineCanPlay(.ijk, format: format), "\(format)")
        }
        // New containers route MPV-first with AVPlayer absent.
        XCTAssertEqual(videoCandidatesFor(url: URL(string: "https://a.b/c.avi")!), [.mpv, .ijk])
        XCTAssertEqual(videoCandidatesFor(url: URL(string: "https://a.b/c.webm")!), [.mpv, .ijk])
        XCTAssertEqual(videoCandidatesFor(url: URL(string: "https://a.b/c.mpd")!), [.mpv, .ijk])
        XCTAssertEqual(videoPreferredEngine(format: .avi, facts: nil), .mpv)
        XCTAssertEqual(videoPreferredEngine(format: .dash, facts: nil), .mpv)
    }

    // MARK: - Build 36, item 14: codec gates (G-C / G-D)

    func testFactsGateExcludesIjkForAv1() {
        // FFmpeg 4.0 has no AV1 decoder: IJK is excluded, MPV
        // (dav1d) is the only engine left.
        let av1 = VideoStreamFacts(container: "mp4", videoCodec: "av1", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.ijk, facts: av1))
        XCTAssertTrue(videoEngineCanPlayFacts(.mpv, facts: av1))
        XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: av1))
        let av01 = VideoStreamFacts(container: "mp4", videoCodec: "av01", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        XCTAssertFalse(videoEngineCanPlayFacts(.ijk, facts: av01))
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_vcodec=av1")!
        XCTAssertEqual(videoCandidatesFor(url: url), [.mpv])
    }

    func testFactsGateRejectsVp9Vp8ApeOpusVorbisForAVPlayer() {
        for vcodec in ["vp9", "vp8"] {
            let facts = VideoStreamFacts(container: "mp4", videoCodec: vcodec, audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
            XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: facts), vcodec)
            XCTAssertTrue(videoEngineCanPlayFacts(.mpv, facts: facts), vcodec)
            XCTAssertTrue(videoEngineCanPlayFacts(.ijk, facts: facts), vcodec)
        }
        for acodec in ["ape", "opus", "vorbis"] {
            let facts = VideoStreamFacts(container: "mp4", videoCodec: "h264", audioCodec: acodec, dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
            XCTAssertFalse(videoEngineCanPlayFacts(.avplayer, facts: facts), acodec)
            XCTAssertTrue(videoEngineCanPlayFacts(.mpv, facts: facts), acodec)
        }
    }

    func testFactsGateExcludesAllEnginesForVvc() {
        // Honest limit (G-N): VVC / H.266 has no decoder in any
        // bundled kernel — the candidate list comes back empty so
        // the driver fails with the named reason.
        let vvc = VideoStreamFacts(container: "mkv", videoCodec: "vvc", audioCodec: "aac", dolbyVision: false, dvProfile: nil, width: nil, height: nil, bitRate: nil, size: nil)
        for engine in VideoEngine.allCases {
            XCTAssertFalse(videoEngineCanPlayFacts(engine, facts: vvc), "\(engine)")
        }
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mkv&hao_vcodec=vvc")!
        XCTAssertTrue(videoCandidatesFor(url: url).isEmpty)
    }

    // MARK: - Build 36, item 14: subtitle / track flags (G-B)

    func testFactsParseSubtitleMarkers() {
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_sub=ass&hao_atracks=3&hao_extsub=0:srt:en,1:ass:zho&hao_msrc=ms1")!
        let facts = VideoStreamFacts.parse(url: url)
        XCTAssertNotNil(facts)
        XCTAssertEqual(facts?.hasAssSubtitles, true)
        XCTAssertEqual(facts?.hasSubtitleTracks, true)
        XCTAssertEqual(facts?.hasMultipleAudioTracks, true)
        XCTAssertEqual(facts?.hasExternalSubtitles, true)
        XCTAssertEqual(facts?.mediaSourceId, "ms1")
        XCTAssertEqual(facts?.externalSubtitles.count, 2)
        XCTAssertEqual(facts?.externalSubtitles.first, ExternalSubtitleRef(index: 0, codec: "srt", language: "en"))
        XCTAssertEqual(facts?.externalSubtitles.last, ExternalSubtitleRef(index: 1, codec: "ass", language: "zho"))
    }

    func testFactsParseSrtMarkerIsNotAss() {
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_sub=srt&hao_atracks=1")!
        let facts = VideoStreamFacts.parse(url: url)
        XCTAssertEqual(facts?.hasAssSubtitles, false)
        XCTAssertEqual(facts?.hasSubtitleTracks, true)
        XCTAssertEqual(facts?.hasMultipleAudioTracks, false)
        XCTAssertEqual(facts?.hasExternalSubtitles, false)
    }

    func testCandidatesForMp4WithAssExcludeAVPlayer() {
        // MP4+ASS: MPV first, AVPlayer excluded (it would play
        // the video with no subtitles — silently wrong).
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_sub=ass")!
        XCTAssertEqual(videoCandidatesFor(url: url).first, .mpv)
        XCTAssertFalse(videoCandidatesFor(url: url).contains(.avplayer))
    }

    func testCandidatesForExternalSubtitlesGoMpvFirst() {
        let url = URL(string: "https://emby.invalid/Videos/1/stream?hao_container=mp4&hao_extsub=0:srt:en&hao_msrc=ms1")!
        XCTAssertEqual(videoCandidatesFor(url: url).first, .mpv)
        XCTAssertFalse(videoCandidatesFor(url: url).contains(.avplayer))
    }

    func testCandidatesExcludingEngines() {
        // G-E: the mid-play retry never loops back to the engine
        // that just failed.
        let url = URL(string: "https://a.b/movie.mp4")!
        XCTAssertEqual(videoCandidatesFor(url: url, excluding: [.avplayer]), [.mpv, .ijk])
        XCTAssertEqual(videoCandidatesFor(url: url, excluding: [.avplayer, .mpv]), [.ijk])
        XCTAssertTrue(videoCandidatesFor(url: url, excluding: [.mpv, .ijk, .avplayer]).isEmpty)
    }

    // MARK: - Build 36, item 14: failure reason (G-K)

    func testFailureReasonMapping() {
        XCTAssertEqual(
            VideoPlaybackFailure.reason(candidatesWereEmpty: false, timedOut: false, hadURL: false, formatDescription: ""),
            .noPlayableURL)
        XCTAssertEqual(
            VideoPlaybackFailure.reason(candidatesWereEmpty: false, timedOut: true, hadURL: true, formatDescription: "MKV"),
            .networkOrTimeout)
        XCTAssertEqual(
            VideoPlaybackFailure.reason(candidatesWereEmpty: true, timedOut: false, hadURL: true, formatDescription: "MKV · VVC"),
            .unsupportedFormat(details: "MKV · VVC"))
        XCTAssertEqual(
            VideoPlaybackFailure.reason(candidatesWereEmpty: false, timedOut: false, hadURL: true, formatDescription: "MKV"),
            .allEnginesFailed)
    }

    func testFailureDisplayLines() {
        let vvc = VideoPlaybackFailure(reason: .unsupportedFormat(details: "MKV · VVC"), attemptedEngines: [], formatDescription: "MKV · VVC")
        XCTAssertEqual(vvc.displayLine, "此格式暂不支持：MKV · VVC")
        let failed = VideoPlaybackFailure(reason: .allEnginesFailed, attemptedEngines: [.mpv, .ijk], formatDescription: "MKV · TrueHD")
        XCTAssertTrue(failed.displayLine.contains("MKV · TrueHD"))
        let timeout = VideoPlaybackFailure(reason: .networkOrTimeout, attemptedEngines: [.avplayer], formatDescription: "")
        XCTAssertTrue(timeout.displayLine.contains("超时"))
        let noURL = VideoPlaybackFailure(reason: .noPlayableURL, attemptedEngines: [], formatDescription: "")
        XCTAssertTrue(noURL.displayLine.contains("没有可播放的线路"))
    }

    // MARK: - Build 36, item 14: mpv track-list parsing (G-F)

    func testTrackListParse() {
        let json = """
        [{"id":0,"type":"video","codec":"h264"},
         {"id":1,"type":"audio","codec":"aac","lang":"eng","title":"English","default":true,"selected":true},
         {"id":2,"type":"audio","codec":"ac3","lang":"zho","title":"国语"},
         {"id":3,"type":"sub","codec":"ass","lang":"zho","title":"简体中文"},
         {"id":4,"type":"sub","codec":"srt","lang":"eng","external":true}]
        """
        let (audio, subtitles) = VodTrackList.parse(json: json)
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(audio[0], VodTrackInfo(index: 1, displayName: "English", language: "eng", isDefault: true, isExternal: false))
        XCTAssertEqual(audio[1].displayName, "国语")
        XCTAssertEqual(audio[1].language, "zho")
        XCTAssertEqual(subtitles.count, 2)
        XCTAssertEqual(subtitles[0].displayName, "简体中文")
        XCTAssertEqual(subtitles[1].isExternal, true)
        XCTAssertEqual(subtitles[1].displayName, "ENG")
    }

    func testTrackListParseMalformed() {
        XCTAssertEqual(VodTrackList.parse(json: "not json").0.count, 0)
        XCTAssertEqual(VodTrackList.parse(json: "{}").0.count, 0)
        XCTAssertEqual(VodTrackList.parse(json: "[]").0.count, 0)
    }

    // MARK: - 1080p ceiling (b49fix44 S33-P1-2)

    /// The token rule: a 2160 / 4K / UHD token in the filename or
    /// as a whole path segment exceeds the ceiling; a plain 1080p
    /// URL and a URL with no quality token do not.
    func testURLExceeds1080pTokens() {
        XCTAssertFalse(videoURLExceeds1080p(URL(string: "https://a.b/play_1080p.m3u8")!))
        XCTAssertFalse(videoURLExceeds1080p(URL(string: "https://a.b/play.m3u8")!))
        XCTAssertTrue(videoURLExceeds1080p(URL(string: "https://a.b/play_2160p.m3u8")!))
        XCTAssertTrue(videoURLExceeds1080p(URL(string: "https://a.b/4k/index.m3u8")!))
        XCTAssertTrue(videoURLExceeds1080p(URL(string: "https://a.b/play_uhd.m3u8")!))
        // A `:3840` port and a `4k` slug in the path are not tokens.
        XCTAssertFalse(videoURLExceeds1080p(URL(string: "https://a.b:3840/play.m3u8")!))
        XCTAssertFalse(videoURLExceeds1080p(URL(string: "https://a.b/4k-slug/play.m3u8")!))
    }

    /// The reorder: within-ceiling URLs keep their relative order
    /// first, over-ceiling ones follow in their original order —
    /// the stream still plays when no ≤1080p variant exists.
    func testPreferCappedResolutionURLsKeepsOrder() {
        let sd = URL(string: "https://a.b/sd.m3u8")!
        let hd = URL(string: "https://a.b/hd_1080p.m3u8")!
        let uhd = URL(string: "https://a.b/uhd_2160p.m3u8")!
        let fourK = URL(string: "https://a.b/4k/index.m3u8")!
        XCTAssertEqual(
            videoPreferCappedResolutionURLs([uhd, sd, fourK, hd]),
            [sd, hd, uhd, fourK])
        // No within-ceiling variant: the over-ceiling ones still
        // play, in their original order.
        XCTAssertEqual(videoPreferCappedResolutionURLs([fourK, uhd]), [fourK, uhd])
        XCTAssertEqual(videoPreferCappedResolutionURLs([sd, hd]), [sd, hd])
    }
}
