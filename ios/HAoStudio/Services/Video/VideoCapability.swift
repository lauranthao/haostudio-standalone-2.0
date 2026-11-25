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
/// it waste one open attempt and fall back. (Build 36, item 14,
/// G-A: AVI / WMV / RMVB / TS / WebM / MPG / DASH are real
/// containers too — they used to fall through to `.unknown` and
/// AVPlayer was never excluded for them, burning a wasted open
/// attempt on every file.)
enum VideoStreamFormat: String {
    case flv
    case hls
    case mp4
    case mkv
    case avi
    case wmv
    case rmvb
    case ts
    case webm
    case mpg
    case dash
    case other
    case unknown
}

/// Container name (declared format, `hao_container` marker, or an
/// Emby container string) -> format. Nil when the name is not a
/// known container — the caller falls through to `.unknown`
/// (which excludes nothing) instead of guessing. Emby reports
/// `matroska` for MKV and `mpegts` for TS; both normalise here.
func videoFormatForContainerName(_ name: String) -> VideoStreamFormat? {
    switch name {
    case "flv": return .flv
    case "hls", "m3u8": return .hls
    case "mp4", "mov", "m4v", "3gp", "3g2": return .mp4
    case "mkv", "matroska": return .mkv
    case "avi": return .avi
    case "wmv", "asf": return .wmv
    case "rm", "rmvb": return .rmvb
    case "ts", "m2ts", "mts", "mpegts": return .ts
    case "webm": return .webm
    case "mpg", "mpeg", "vob": return .mpg
    case "mpd", "dash": return .dash
    case "other": return .other
    default: return nil
    }
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
    if let declared = declared, !declared.isEmpty,
       let format = videoFormatForContainerName(declared) {
        return format
    }
    let lower = url.absoluteString.lowercased().components(separatedBy: "?").first ?? ""
    if lower.hasSuffix(".flv") { return .flv }
    if lower.hasSuffix(".m3u8") || lower.hasSuffix(".m3u") { return .hls }
    if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") { return .mp4 }
    if lower.hasSuffix(".mkv") { return .mkv }
    if lower.hasSuffix(".avi") { return .avi }
    if lower.hasSuffix(".wmv") || lower.hasSuffix(".asf") { return .wmv }
    if lower.hasSuffix(".rm") || lower.hasSuffix(".rmvb") { return .rmvb }
    if lower.hasSuffix(".ts") || lower.hasSuffix(".m2ts") || lower.hasSuffix(".mts") { return .ts }
    if lower.hasSuffix(".webm") { return .webm }
    if lower.hasSuffix(".mpg") || lower.hasSuffix(".mpeg") || lower.hasSuffix(".vob") { return .mpg }
    if lower.hasSuffix(".mpd") { return .dash }
    if lower.hasSuffix(".3gp") || lower.hasSuffix(".3g2") { return .mp4 }
    let whole = url.absoluteString.lowercased()
    if whole.contains(".flv.") || whole.contains("/flv/") ||
       whole.contains("flv_pull") || whole.contains("pull-flv") {
        return .flv
    }
    if whole.contains(".m3u8") { return .hls }
    if let facts = VideoStreamFacts.parse(url: url), let container = facts.container,
       let format = videoFormatForContainerName(container) {
        return format
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
    /// (Build 36, item 14, G-B) The file carries ASS/SSA
    /// subtitles — only MPV renders them, so routing must send
    /// the file to MPV first. `var` with a default: `let` with a
    /// default is NOT a memberwise-init parameter, so these must
    /// be `var` to stay settable from `parse` while keeping the
    /// existing memberwise constructions compiling.
    var hasAssSubtitles: Bool = false
    /// Any subtitle track is known (embedded or external).
    var hasSubtitleTracks: Bool = false
    /// Two or more audio tracks are known — MPV first, so the
    /// track picker has something to switch between.
    var hasMultipleAudioTracks: Bool = false
    /// Server-external subtitle streams (Emby `IsExternal`).
    /// Only MPV can load them (`sub-add`), so they also force
    /// MPV-first routing.
    var hasExternalSubtitles: Bool = false
    /// External subtitle descriptors, in server order.
    var externalSubtitles: [ExternalSubtitleRef] = []
    /// Emby media-source id, needed to build the subtitle URL
    /// (`/Videos/{id}/{mediaSourceId}/Subtitles/{index}`).
    var mediaSourceId: String? = nil

    /// 4K by frame size: 3840 wide or 2160 tall (covers 3840x2160
    /// and wider DCI 4K / scope crops whose height is under 2160).
    var is4K: Bool {
        (width != nil && width! >= 3840) || (height != nil && height! >= 2160)
    }

    var isEmpty: Bool {
        container == nil && videoCodec == nil && audioCodec == nil &&
        !dolbyVision && dvProfile == nil && width == nil &&
        height == nil && bitRate == nil && size == nil &&
        !hasAssSubtitles && !hasSubtitleTracks &&
        !hasMultipleAudioTracks && !hasExternalSubtitles &&
        externalSubtitles.isEmpty && mediaSourceId == nil
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
        // (Build 36, item 14, G-B) `hao_sub` is the subtitle codec
        // (`ass` / `srt` / `vtt` / `pgs` / `none`); `hao_atracks`
        // is the audio-track count; `hao_extsub` is the external
        // subtitle list (`index:codec:language`, comma-joined);
        // `hao_msrc` is the Emby media-source id for the
        // subtitle URL.
        let subMarker = values["hao_sub"]?.lowercased()
        let hasAssSubtitles = subMarker == "ass" || subMarker == "ssa"
        let hasSubtitleTracks = subMarker != nil && subMarker != "none"
        let atracks = values["hao_atracks"].flatMap { Int($0) } ?? 0
        let hasMultipleAudioTracks = atracks >= 2
        var externalSubtitles: [ExternalSubtitleRef] = []
        if let ext = values["hao_extsub"], !ext.isEmpty {
            for part in ext.components(separatedBy: ",") {
                let fields = part.components(separatedBy: ":")
                guard let first = fields.first, let idx = Int(first) else { continue }
                let codec = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil
                let language = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
                externalSubtitles.append(ExternalSubtitleRef(index: idx, codec: codec, language: language))
            }
        }
        let hasExternalSubtitles = !externalSubtitles.isEmpty
        let mediaSourceId = values["hao_msrc"]
        var facts = VideoStreamFacts(
            container: container, videoCodec: videoCodec, audioCodec: audioCodec,
            dolbyVision: dolbyVision, dvProfile: dvProfile, width: width,
            height: height, bitRate: bitRate, size: size
        )
        facts.hasAssSubtitles = hasAssSubtitles
        facts.hasSubtitleTracks = hasSubtitleTracks
        facts.hasMultipleAudioTracks = hasMultipleAudioTracks
        facts.hasExternalSubtitles = hasExternalSubtitles
        facts.externalSubtitles = externalSubtitles
        facts.mediaSourceId = mediaSourceId
        return facts.isEmpty ? nil : facts
    }
}

// MARK: - Capability gate

/// Capability table (Flutter `kSupportedFormats`).
/// MPV / IJK: flv, hls/m3u8, mp4, mkv, avi, wmv, rmvb, ts, webm,
/// mpg, dash, other. AVPlayer: hls/m3u8, mp4, other — NO flv,
/// NO mkv, NO avi/wmv/rmvb/ts/webm/mpg/dash (AVFoundation has
/// none of those demuxers; build 36, item 14, G-A).
/// Unknown format excludes NOTHING.
func videoEngineCanPlay(_ engine: VideoEngine, format: VideoStreamFormat) -> Bool {
    if format == .unknown { return true }
    switch engine {
    case .mpv, .ijk:
        return true
    case .avplayer:
        switch format {
        case .hls, .mp4, .other: return true
        case .flv, .mkv, .avi, .wmv, .rmvb, .ts, .webm, .mpg, .dash, .unknown: return false
        }
    }
}

/// Capability gate for stream facts.
///
/// Honest limits (build 36, item 14):
/// - VVC / H.266 has NO decoder in any bundled kernel (FFmpeg 6.0
///   predates the native VVC decoder, FFmpeg 4.0 has none,
///   AVFoundation has none) — every engine is excluded, so the
///   candidate list comes back empty and the driver fails with
///   the named unsupported-format reason instead of burning three
///   open attempts. Emby items still play via the server
///   transcode fallback (G-H); CMS VVC stays unsupported until a
///   future libmpv upgrade.
/// - IJK is NOT "plays everything": FFmpeg 4.0 predates AV1
///   entirely (no native decoder, no dav1d), so IJK is excluded
///   for AV1 (G-C). MPV covers AV1 via bundled dav1d.
/// - AVPlayer is excluded when the file needs a demuxer or decoder
///   AVFoundation does not have:
///   - container outside {mp4, mov, m4v} (mkv/avi/webm/ts/...),
///   - AV1 video (no AVFoundation decoder on most devices),
///   - VP8 / VP9 video (no VPx decoder in AVFoundation) (G-D),
///   - Dolby Vision profile 7 (dual-layer; the ffmpeg kernels
///     render its HDR10 base layer) and profile 8 when the
///     downgrade switch is off (its base layer plays on the ffmpeg
///     kernels instead). Profile 5 is ALWAYS admitted in an Apple
///     container: it has no HDR base layer at all, so a player that
///     ignores the DV layer renders its IPTPQc2 values as ordinary
///     HDR10 and the picture comes out green/pink (mpv #10700) —
///     only AVPlayer applies the DV mapping on iOS. An unknown
///     profile is admitted too: P5/P8 play natively, P7 plays its
///     base layer, and if AVPlayer refuses the open the ladder
///     falls back to MPV — AVPlayer-first can only fail over, never
///     strand. (Build 36, item 13: P5 used to be excluded here, so
///     every Dolby movie landed on MPV's software render path and
///     showed green.)
///   - TrueHD / DTS audio (AVFoundation cannot decode them),
///     APE / Opus / Vorbis audio (no AVFoundation decoder) (G-D).
///   - ASS subtitles or external subtitles (AVPlayer has no ASS
///     renderer and no sidecar loading — it would play the video
///     with the subtitles silently missing) (G-B).
/// HEVC in MP4/MOV stays allowed on AVPlayer (hardware-decoded
/// since iOS 11), as does HDR10/HLG in MP4 — the gate is about the
/// container/codec combination, never the resolution. The 1080p
/// ceiling for CMS lives one layer up: resolve time prefers a
/// ≤1080p variant (`videoPreferCappedResolutionURLs`, b49 sweep
/// #25) instead of excluding a stream here — a 4K-only stream
/// still plays.
func videoEngineCanPlayFacts(
    _ engine: VideoEngine,
    facts: VideoStreamFacts,
    dvDowngradeToHdr: Bool = true
) -> Bool {
    let vcodec = (facts.videoCodec ?? "").lowercased()
    // VVC / H.266: no decoder anywhere (see above).
    if vcodec == "vvc" || vcodec == "h266" || vcodec == "h.266" { return false }
    if engine == .ijk {
        // FFmpeg 4.0 has no AV1 decoder (G-C). Every other fact
        // passes: IJK's container/codec breadth is the FFmpeg 4.0
        // set, and the container gate already ran before this.
        if vcodec == "av1" || vcodec == "av01" { return false }
        return true
    }
    if engine != .avplayer { return true }
    let appleContainers: Set<String> = ["mp4", "mov", "m4v"]
    if let container = facts.container, !appleContainers.contains(container) {
        return false
    }
    if vcodec == "av1" || vcodec == "av01" { return false }
    if vcodec == "vp9" || vcodec == "vp8" { return false }
    // (G-B) ASS subtitles / external subtitles: AVPlayer has no
    // ASS renderer and no sidecar loading, so it would play the
    // video with the subtitles silently missing. Only the ffmpeg
    // kernels reach here for these files (MPV first, IJK as the
    // video-only last resort).
    if facts.hasAssSubtitles || facts.hasExternalSubtitles { return false }
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
    let ffmpegOnlyAudio: Set<String> = ["truehd", "dts", "dtshd", "dts-hd", "dca", "ape", "opus", "vorbis"]
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
/// - FLV / MKV / AVI / WMV / RMVB / TS / WebM / MPG / DASH / ASS
///   subtitles / multiple audio tracks / external subtitles -> MPV
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
    hasMultipleAudioTracks: Bool = false,
    hasExternalSubtitles: Bool = false
) -> VideoEngine {
    if hasAssSubtitles || hasMultipleAudioTracks || hasExternalSubtitles { return .mpv }
    switch format {
    case .flv, .mkv, .avi, .wmv, .rmvb, .ts, .webm, .mpg, .dash: return .mpv
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
/// `excluding` removes engines that already failed for this
/// episode (build 36, item 14, G-E mid-play fallback): the retry
/// never loops back to the engine that just failed.
func videoCandidatesFor(
    url: URL,
    declaredFormat: String? = nil,
    preferred: VideoEngine? = nil,
    hasAssSubtitles: Bool = false,
    hasMultipleAudioTracks: Bool = false,
    hasExternalSubtitles: Bool = false,
    dvDowngradeToHdr: Bool = true,
    excluding: [VideoEngine] = []
) -> [VideoEngine] {
    let format = videoFormatOf(url: url, declaredFormat: declaredFormat)
    let facts = VideoStreamFacts.parse(url: url)
    let first = preferred ?? videoPreferredEngine(
        format: format, facts: facts,
        hasAssSubtitles: hasAssSubtitles,
        hasMultipleAudioTracks: hasMultipleAudioTracks,
        hasExternalSubtitles: hasExternalSubtitles
    )
    let capable = VideoEngine.allCases.filter { engine in
        !excluding.contains(engine) &&
        videoEngineCanPlay(engine, format: format) &&
        (facts == nil || videoEngineCanPlayFacts(engine, facts: facts!, dvDowngradeToHdr: dvDowngradeToHdr))
    }
    return capable.sorted { a, b in
        if a == first && b != first { return true }
        if b == first && a != first { return false }
        return a.priority > b.priority
    }
}

/// 1080p ceiling for CMS (b49 sweep #25): a stream URL that
/// names a higher resolution (2160 / 3840 / 4K / UHD as a
/// quality token, e.g. `…_2160p.m3u8` or `…/4k/…`) exceeds the
/// ceiling. The match is token-bounded (a separator or string
/// edge on both sides), so a hash that merely contains `4k`
/// does not trip it. No signal = within the ceiling.
func videoURLExceeds1080p(_ url: URL) -> Bool {
    let s = url.absoluteString.lowercased()
    guard let re = try? NSRegularExpression(
        pattern: "(?:^|[^a-z0-9])(2160p?|3840|4k|uhd)(?:[^a-z0-9]|$)",
        options: []) else { return false }
    return re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
}

/// Prefer ≤1080p variants, stable: candidates that do not exceed
/// the ceiling keep their relative order first, then the
/// over-ceiling ones in their original order (used when no
/// ≤1080p variant exists at all — the stream still plays).
func videoPreferCappedResolutionURLs(_ urls: [URL]) -> [URL] {
    let capped = urls.filter { !videoURLExceeds1080p($0) }
    let over = urls.filter { videoURLExceeds1080p($0) }
    return capped + over
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

// MARK: - Failure reason (build 36, item 14, G-K)

/// One failed open, with the specific reason — so the failure card
/// can say WHY instead of a generic "加载失败". Foundation-only
/// (lives in this file so the SwiftPM tests can cover the mapping).
struct VideoPlaybackFailure: Equatable {
    enum Reason: Equatable {
        case noPlayableURL
        case unsupportedFormat(details: String)
        case networkOrTimeout
        case allEnginesFailed
    }
    let reason: Reason
    let attemptedEngines: [VideoEngine]
    /// Human format summary, e.g. "MKV · AV1 · TrueHD" — unknown
    /// parts omitted, "" when nothing is known.
    let formatDescription: String

    /// The one specific line the failure card shows.
    var displayLine: String {
        switch reason {
        case .noPlayableURL:
            return "没有可播放的线路，请换个线路。"
        case .unsupportedFormat(let details):
            return details.isEmpty ? "此格式暂不支持播放。" : "此格式暂不支持：\(details)"
        case .networkOrTimeout:
            return "网络超时，请检查网络后重试。"
        case .allEnginesFailed:
            if formatDescription.isEmpty { return "该集暂时无法播放，换个线路或重试。" }
            return "该集暂时无法播放（\(formatDescription)），换个线路或重试。"
        }
    }

    /// Pure reason mapping for the driver: no URL at all ->
    /// noPlayableURL; the open timed out -> networkOrTimeout; the
    /// candidate list was empty (no capable engine — e.g. VVC) ->
    /// unsupportedFormat naming the format; anything else ->
    /// allEnginesFailed.
    static func reason(
        candidatesWereEmpty: Bool,
        timedOut: Bool,
        hadURL: Bool,
        formatDescription: String
    ) -> Reason {
        if !hadURL { return .noPlayableURL }
        if timedOut { return .networkOrTimeout }
        if candidatesWereEmpty { return .unsupportedFormat(details: formatDescription) }
        return .allEnginesFailed
    }
}

/// One server-external subtitle stream, as carried in the
/// `hao_extsub` URL marker (`index:codec:language`, comma-joined).
struct ExternalSubtitleRef: Equatable {
    let index: Int
    let codec: String?
    let language: String?
}

// MARK: - Audio / subtitle tracks (build 36, item 14, G-F)

/// One audio or subtitle track, as listed by a backend. `index`
/// is the engine-native id: the mpv `track-list` id (the value
/// for `aid` / `sid`), or the position in the AVPlayer media
/// selection group. The driver keeps the published lists and
/// translates the picker's list position into this id.
struct VodTrackInfo: Equatable {
    let index: Int
    let displayName: String
    let language: String?
    let isDefault: Bool
    /// True for a sidecar / server-external subtitle (loaded via
    /// `sub-add` on MPV). The picker shows it as 外挂.
    let isExternal: Bool
}

/// Pure parser for mpv's `track-list` property (JSON array of
/// objects with `id` / `type` / `lang` / `title` / `default` /
/// `external`). Factored pure so the SwiftPM target can cover it
/// on Linux — no libmpv needed. `JSONSerialization.jsonObject`
/// only ever sees a top-level array here (a dict/array top level
/// is the one legal shape for it).
enum VodTrackList {
    static func parse(json: String) -> ([VodTrackInfo], [VodTrackInfo]) {
        guard let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
            return ([], [])
        }
        var audio: [VodTrackInfo] = []
        var subtitles: [VodTrackInfo] = []
        for entry in top {
            guard let type = entry["type"] as? String else { continue }
            guard type == "audio" || type == "sub" else { continue }
            let id = (entry["id"] as? NSNumber)?.intValue ?? -1
            guard id >= 0 else { continue }
            let title = entry["title"] as? String
            let lang = entry["lang"] as? String
            let isDefault = (entry["default"] as? Bool) ?? false
            let isExternal = (entry["external"] as? Bool) ?? false
            let name: String
            if let title = title, !title.isEmpty {
                name = title
            } else if let lang = lang, !lang.isEmpty {
                name = lang.uppercased()
            } else {
                name = type == "audio" ? "音轨 \(id)" : "字幕 \(id)"
            }
            let info = VodTrackInfo(
                index: id, displayName: name, language: lang,
                isDefault: isDefault, isExternal: isExternal)
            if type == "audio" { audio.append(info) } else { subtitles.append(info) }
        }
        return (audio, subtitles)
    }
}
