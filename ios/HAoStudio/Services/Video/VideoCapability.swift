// HAo Studio 2.0 — video capability decisions (S3, leg A).
//
// Pure functions only (Foundation, no iOS-only frameworks): format
// gating + kernel ordering + stream-facts parsing. This file is the
// one the SwiftPM `VideoServices` test target compiles (Leg B wires
// the target in Package.swift); the runtime kernel
// (`Playback/PlayerKernel.swift`) calls these and builds real
// backends from the answers.
//
// Behaviour baseline: Flutter build 31
// (`lib/core/player/kernel/player_kernel.dart`) — capability table,
// format resolution order, StreamFacts (`hao_*` URL markers), the
// AVPlayer facts gate, and the candidate ordering. Differences from
// Flutter are called out where they exist.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

// MARK: - Engines

/// The three video engines. Raw values are the Pure Live key space
/// (`mpv` / `ijk` / `exo`); the iOS `exo` slot is AVPlayer
/// (BetterPlayer is ExoPlayer on Android / AVPlayer on iOS), so the
/// key stays `exo` and the display name says what it is.
enum VideoEngine: String, CaseIterable {
    case mpv = "mpv"
    case ijk = "ijk"
    case avplayer = "exo"

    /// Registration priority (Flutter `PlayerEngine.priority`):
    /// MPV 100 / IJK 90 / AVPlayer 80. Priority only breaks ties
    /// between capable engines — capability is the gate, never the
    /// priority (an incapable engine never appears in the candidate
    /// list, however high its priority).
    var priority: Int {
        switch self {
        case .mpv: return 100
        case .ijk: return 90
        case .avplayer: return 80
        }
    }

    var displayName: String {
        switch self {
        case .mpv: return "MPV"
        case .ijk: return "IJK"
        case .avplayer: return "系统播放器"
        }
    }

    static func from(raw: String?) -> VideoEngine {
        guard let raw = raw, let engine = VideoEngine(rawValue: raw) else { return .mpv }
        return engine
    }
}

// MARK: - Stream format

/// Stream format as declared by the platform adapter, or read off
/// the URL. `mkv` is a real container, not a flavour of `other`:
/// AVPlayer has no MKV demuxer, while the ffmpeg kernels do — so
/// MKV must exclude AVPlayer at selection time instead of letting
/// it waste one open attempt and fall back.
enum VideoStreamFormat: String {
    case flv
    case hls
    case mp4
    case mkv
    case other
    case unknown
}

/// Resolve the stream format. The DECLARED format wins over the URL
/// suffix. Resolution order (Flutter `formatOf`): declared flv ->
/// flv; declared hls/m3u8 -> hls; declared mp4/mov -> mp4; declared
/// mkv -> mkv; otherwise URL extension (.flv / .m3u8 / .mp4/.mov /
/// .mkv); then host/path scan for FLV markers (Huya `al-game.flv`,
/// Douyin `pull-flv`, Kuaishou `/flv/`); then the `hao_container`
/// query marker (Emby direct streams have no suffix); unknown/empty
/// excludes nothing.
func videoFormatOf(url: URL, declaredFormat: String?) -> VideoStreamFormat {
    let declared = declaredFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let declared = declared, !declared.isEmpty {
        switch declared {
        case "flv": return .flv
        case "hls", "m3u8": return .hls
        case "mp4", "mov": return .mp4
        case "mkv": return .mkv
        case "other": return .other
        default: break
        }
    }
    let lower = url.absoluteString.lowercased().components(separatedBy: "?").first ?? ""
    if lower.hasSuffix(".flv") { return .flv }
    if lower.hasSuffix(".m3u8") || lower.hasSuffix(".m3u") { return .hls }
    if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") { return .mp4 }
    if lower.hasSuffix(".mkv") { return .mkv }
    let whole = url.absoluteString.lowercased()
    if whole.contains(".flv.") || whole.contains("/flv/") ||
       whole.contains("flv_pull") || whole.contains("pull-flv") {
        return .flv
    }
    if whole.contains(".m3u8") { return .hls }
    if let facts = VideoStreamFacts.parse(url: url) {
        if facts.container == "mkv" { return .mkv }
        if facts.container == "mp4" || facts.container == "mov" || facts.container == "m4v" {
            return .mp4
        }
    }
    return .unknown
}

// MARK: - Stream facts (Emby `hao_*` URL markers)

/// Container / codec facts for one stream, carried in the URL query
/// as `hao_container` / `hao_vcodec` / `hao_acodec` / `hao_dv` /
/// `hao_dvprofile` / `hao_width` / `hao_height` / `hao_bitrate` /
/// `hao_size`. Only Emby stream URLs carry them — every other
/// caller sees nil and keeps the old behaviour.
struct VideoStreamFacts: Equatable {
    /// Lowercase container: 'mkv' | 'mp4' | 'mov' | 'avi' | ...
    let container: String?
    /// Lowercase video codec: 'hevc' | 'h264' | 'av1' | ...
    let videoCodec: String?
    /// Lowercase codec of the DEFAULT audio track: 'aac' | 'truehd' |
    /// 'dts' | ... (only the default track matters for the gate — an
    /// optional TrueHD track next to an AAC default still plays).
    let audioCodec: String?
    /// Dolby Vision video range, whatever the profile.
    let dolbyVision: Bool
    /// Dolby Vision bitstream profile (5 / 7 / 8 / ...). Null when
    /// the server did not report a profile.
    let dvProfile: Int?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let size: Int?

    /// 4K by frame size: 3840 wide or 2160 tall (covers 3840x2160
    /// and wider DCI 4K / scope crops whose height is under 2160).
    var is4K: Bool {
        (width != nil && width! >= 3840) || (height != nil && height! >= 2160)
    }

    var isEmpty: Bool {
        container == nil && videoCodec == nil && audioCodec == nil &&
        !dolbyVision && dvProfile == nil && width == nil &&
        height == nil && bitRate == nil && size == nil
    }

    static func parse(url: URL) -> VideoStreamFacts? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        var values: [String: String] = [:]
        for item in items {
            if let value = item.value { values[item.name] = value }
        }
        let container = values["hao_container"]?.lowercased()
        let videoCodec = values["hao_vcodec"]?.lowercased()
        let audioCodec = values["hao_acodec"]?.lowercased()
        let dolbyVision = values["hao_dv"] == "1"
        let dvProfile = values["hao_dvprofile"].flatMap { Int($0.components(separatedBy: ".").first ?? "") }
        let width = values["hao_width"].flatMap { Int($0) }
        let height = values["hao_height"].flatMap { Int($0) }
        let bitRate = values["hao_bitrate"].flatMap { Int($0) }
        let size = values["hao_size"].flatMap { Int($0) }
        let facts = VideoStreamFacts(
            container: container, videoCodec: videoCodec, audioCodec: audioCodec,
            dolbyVision: dolbyVision, dvProfile: dvProfile, width: width,
            height: height, bitRate: bitRate, size: size
        )
        return facts.isEmpty ? nil : facts
    }
}

// MARK: - Capability gate

/// Capability table (Flutter `kSupportedFormats`).
/// MPV / IJK: flv, hls/m3u8, mp4, mkv, other. AVPlayer: hls/m3u8,
/// mp4, other — NO flv, NO mkv (AVFoundation has neither demuxer).
/// Unknown format excludes NOTHING.
func videoEngineCanPlay(_ engine: VideoEngine, format: VideoStreamFormat) -> Bool {
    if format == .unknown { return true }
    switch engine {
    case .mpv, .ijk:
        return true
    case .avplayer:
        switch format {
        case .hls, .mp4, .other: return true
        case .flv, .mkv, .unknown: return false
        }
    }
}

/// Capability gate for stream facts. The ffmpeg kernels (MPV/IJK)
/// play everything; AVPlayer is excluded when the file needs a
/// demuxer or decoder AVFoundation does not have:
/// - container outside {mp4, mov, m4v} (mkv/avi/webm/ts/...),
/// - AV1 video (no AVFoundation decoder on most devices),
/// - Dolby Vision profile 7 (dual-layer; the ffmpeg kernels
///   render its HDR10 base layer) and profile 8 when the
///   downgrade switch is off (its base layer plays on the ffmpeg
///   kernels instead). Profile 5 is ALWAYS admitted in an Apple
///   container: it has no HDR base layer at all, so a player that
///   ignores the DV layer renders its IPTPQc2 values as ordinary
///   HDR10 and the picture comes out green/pink (mpv #10700) —
///   only AVPlayer applies the DV mapping on iOS. An unknown
///   profile is admitted too: P5/P8 play natively, P7 plays its
///   base layer, and if AVPlayer refuses the open the ladder
///   falls back to MPV — AVPlayer-first can only fail over, never
///   strand. (Build 36, item 13: P5 used to be excluded here, so
///   every Dolby movie landed on MPV's software render path and
///   showed green.)
/// - TrueHD / DTS audio (AVFoundation cannot decode them).
/// HEVC in MP4/MOV stays allowed on AVPlayer (hardware-decoded
/// since iOS 11), as does HDR10/HLG in MP4 — the gate is about the
/// container/codec combination, never the resolution: there is no
/// resolution cap anywhere in the kernel.
func videoEngineCanPlayFacts(
    _ engine: VideoEngine,
    facts: VideoStreamFacts,
    dvDowngradeToHdr: Bool = true
) -> Bool {
    if engine != .avplayer { return true }
    let appleContainers: Set<String> = ["mp4", "mov", "m4v"]
    if let container = facts.container, !appleContainers.contains(container) {
        return false
    }
    if facts.videoCodec == "av1" { return false }
    if facts.dolbyVision {
        // Profile 5 or unknown: admitted (see above). Profile 8:
        // admitted only with the downgrade switch on. Profile 7
        // and anything else: excluded.
        if let profile = facts.dvProfile {
            if profile == 8 {
                if !dvDowngradeToHdr { return false }
            } else if profile != 5 {
                return false
            }
        }
    }
    let ffmpegOnlyAudio: Set<String> = ["truehd", "dts", "dtshd", "dts-hd", "dca"]
    if let audio = facts.audioCodec, ffmpegOnlyAudio.contains(audio) {
        return false
    }
    return true
}

// MARK: - Capability split (which engine first)

/// Which engine goes FIRST for a stream. This is the S3 capability
/// split (plan §四 4.1, chen 2026-11-23 feedback: Emby 4K HEVC was
/// not smooth on MPV because the hard-decode request was never
/// verified):
/// - FLV / MKV / ASS subtitles / multiple audio tracks -> MPV
///   (AVPlayer cannot play them at all; IJK is the third choice,
///   never the first for these).
/// - HEVC / Dolby Vision / HLS / MP4 -> AVPlayer (VideoToolbox
///   hard decode, no silent software-decode problem).
/// - Unknown / other -> MPV (Flutter default; MPV plays everything).
/// IJK is never first: it is the third choice on every format.
func videoPreferredEngine(
    format: VideoStreamFormat,
    facts: VideoStreamFacts?,
    hasAssSubtitles: Bool = false,
    hasMultipleAudioTracks: Bool = false
) -> VideoEngine {
    if hasAssSubtitles || hasMultipleAudioTracks { return .mpv }
    switch format {
    case .flv, .mkv: return .mpv
    case .hls, .mp4: return .avplayer
    case .other, .unknown:
        if let facts = facts, facts.videoCodec == "hevc" || facts.dolbyVision {
            return .avplayer
        }
        return .mpv
    }
}

/// Candidate engines for a stream, in try order: the capable
/// preferred engine first, then the remaining capable engines in
/// registration priority order. An incapable engine never appears
/// in the list, so it can never be selected or retried for that
/// stream. `preferred` overrides the capability split (user
/// preference wins, but only among engines that CAN play this
/// format — preference first, capability as a gate).
func videoCandidatesFor(
    url: URL,
    declaredFormat: String? = nil,
    preferred: VideoEngine? = nil,
    hasAssSubtitles: Bool = false,
    hasMultipleAudioTracks: Bool = false,
    dvDowngradeToHdr: Bool = true
) -> [VideoEngine] {
    let format = videoFormatOf(url: url, declaredFormat: declaredFormat)
    let facts = VideoStreamFacts.parse(url: url)
    let first = preferred ?? videoPreferredEngine(
        format: format, facts: facts,
        hasAssSubtitles: hasAssSubtitles,
        hasMultipleAudioTracks: hasMultipleAudioTracks
    )
    let capable = VideoEngine.allCases.filter { engine in
        videoEngineCanPlay(engine, format: format) &&
        (facts == nil || videoEngineCanPlayFacts(engine, facts: facts!, dvDowngradeToHdr: dvDowngradeToHdr))
    }
    return capable.sorted { a, b in
        if a == first && b != first { return true }
        if b == first && a != first { return false }
        return a.priority > b.priority
    }
}

// MARK: - Software-decode fallback trigger

/// True when a software-decoded stream is high-demand enough that
/// staying on it is visibly wrong: 4K HEVC or any Dolby Vision.
/// The driver then switches to AVPlayer and reopens at the same
/// position. Software decode of anything else (SD/HD H.264,
/// FLV/MKV that AVPlayer cannot play) stays put and is labelled
/// "软解中" in the diagnostics — never silent.
func videoNeedsHardwareDecode(facts: VideoStreamFacts?) -> Bool {
    guard let facts = facts else { return false }
    if facts.dolbyVision { return true }
    if facts.is4K && facts.videoCodec == "hevc" { return true }
    return false
}
