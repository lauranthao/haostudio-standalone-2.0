// HAo Studio 2.0 — video player kernel (S3, leg A).
//
// Capability gate + candidate queue + downgrade ladder + backend
// factory. The three engines (MPV / IJK / AVPlayer) all sit behind
// `VideoPlayerBackend`; the VOD driver (VideoDriver) only talks to
// the protocol, never to an engine directly, so engine behaviour is
// identical from the UI side.
//
// Rules (chen 2026-11-16/17, plan §四):
// - Capability is the gate, preference is second: an engine that
//   cannot play a format never appears in the candidate list.
// - Music uses AVPlayer only and never reads this selector; this
//   kernel is video (and, in S4, live) only.
// - VOD and live are different players: this kernel serves VOD in
//   S3; live gets its own driver in S4. Both run framedrop off
//   (no backend exposes a framedrop knob): the live edge is kept
//   by the stall watchdog + recovery loop, not by dropping frames.
// - First playable source plays immediately; a failed engine falls
//   to the next candidate, never to an error dialog.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import UIKit

// MARK: - Backend events

/// One event a backend reports up to the driver. Mirrors the
/// ijkplayer notifications the old player drove its UI from, so
/// the driver logic does not change when the engine changes.
enum VideoBackendEvent {
    /// Engine is ready to play (ijk: isPreparedToPlay; AVPlayer:
    /// item .readyToPlay; mpv: FILE_LOADED). The driver seeks to
    /// its start position and plays from here.
    case prepared
    /// First video frame hit the screen (ijk:
    /// FirstVideoFrameRendered; mpv: VIDEO_RECONFIG; AVPlayer:
    /// first timeControlStatus .playing). The driver hides its
    /// loading UI from here.
    case firstFrame
    /// Playback state (ijk: playbackState; AVPlayer:
    /// timeControlStatus; mpv: "pause" property).
    case playing
    case paused
    /// Stalled / buffering while not started yet. The driver only
    /// shows the spinner from this while playback has not started
    /// — the clock-based stall watchdog owns stalls after start,
    /// for every engine.
    case stalled
    /// Stream finished. .ended = clean EOF (VOD: genuine end).
    /// .error = the engine gave up on this URL.
    case finished(VideoBackendEndReason)
}

enum VideoBackendEndReason {
    case ended
    case error
}

/// Picture fit (Pure Live PlayerVideoFitButton): the driver cycles
/// 适应 / 裁剪 / 拉伸. Each backend maps it to its own scaling
/// control (ijk scalingMode, AVPlayerLayer / display-layer
/// videoGravity).
enum VideoFit: String, CaseIterable {
    case aspectFit
    case aspectFill
    case fill

    var label: String {
        switch self {
        case .aspectFit: return "适应"
        case .aspectFill: return "裁剪"
        case .fill: return "拉伸"
        }
    }
}

// MARK: - Backend protocol

/// The single interface every video engine implements. The driver
/// only talks to this — never to an engine directly.
protocol VideoPlayerBackend: AnyObject {
    /// Which engine this is (for diagnostics + the ladder).
    var engine: VideoEngine { get }
    /// The video surface. The driver embeds it in its video view
    /// and sizes it to the video view bounds on every layout pass.
    var view: UIView { get }
    var isPlaying: Bool { get }
    /// Seconds. currentTime is 0 before start; duration is NaN for
    /// engines that do not know it yet (VOD always knows it once
    /// prepared — live never does, but live has its own driver).
    var currentTime: Double { get }
    var duration: Double { get }
    var isPrepared: Bool { get }
    /// 0.5-2.0. Applied live; a later play() resumes at this rate.
    var playbackRate: Double { get set }
    /// Hard-decode state, read back after open (never assumed from
    /// the requested option). See Diagnostics.swift.
    var hardwareDecode: VideoHardwareDecodeState { get }
    /// Option/property names the backend tried to set and the engine
    /// refused (names only, never values — P0-02). Empty when every
    /// option was accepted.
    var rejectedOptionNames: [String] { get }
    /// Picture fit. Applied live; a later open() starts at it.
    func setVideoFit(_ fit: VideoFit)
    /// Engine -> driver events (always delivered on the main thread).
    var onEvent: ((VideoBackendEvent) -> Void)? { get set }
    /// Video size in pixels (0x0 until known).
    var onVideoSize: ((CGSize) -> Void)? { get set }
    /// Open + autoplay. The completion fires exactly once: true
    /// when the engine is prepared and playing, false when it could
    /// not open this URL (bad URL, engine creation failed, load
    /// error, or the open timeout fired — the driver treats a
    /// timeout exactly like a stream error and falls to the next
    /// candidate). headers: HTTP headers for the stream (browser
    /// User-Agent; see PlayerKernel.httpHeaders).
    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void)
    func play()
    func pause()
    /// VOD only (live has no seek). The completion reports whether
    /// the playhead actually landed near the target (read-back
    /// verified); false means the driver rolls the UI back.
    func seek(to seconds: Double, completion: @escaping (Bool) -> Void)
    /// Stop + release everything (engine, observers, views).
    /// Idempotent.
    func shutdown()
}

extension VideoPlayerBackend {
    var rejectedOptionNames: [String] { [] }
}

/// Runtime subtitle appearance (MPV only). A backend that
/// cannot style subtitles (AVPlayer renders its own legible
/// tracks, IJK exposes no styling API) simply does not conform
/// and the driver no-ops through the `as?` cast — never a fake
/// row, never a forced protocol method on engines that cannot
/// do it. Values are the resolved mpv properties from
/// `VodSubtitleAppearance` (sub-font-size / sub-color / sub-pos).
protocol VodSubtitleAppearanceCapable: AnyObject {
    func setSubtitleAppearance(fontSize: Int, color: String, position: Double)
}

/// Runtime VOD enhancement branch (MPV only). The driver applies
/// the resolved trio branch (see `resolveVodEnhancement`); a
/// backend that cannot do it does not conform. The super-resolution
/// branch is a deliberate no-op on the MPV backend until Anime4K
/// shaders are bundled — there is nothing to mount, so the method
/// must not pretend.
protocol VodEnhancementCapable: AnyObject {
    func setVodEnhancement(_ branch: VodEnhancementBranch?)
}

/// Runtime dialogue boost (MPV only, VOD only — Flutter
/// `DialogueBoostCapableBackend`, K 组 build 29). Same capability
/// pattern as `VodEnhancementCapable`: a backend that cannot do
/// it does not conform and the driver no-ops through the `as?`
/// cast. The driver remembers the switch and re-applies it at
/// every open, so a toggle made before the backend existed still
/// lands; the MPV half is `volume-max=300` + a centre-channel
/// fold with loudnorm (see `MpvPlayerBackend`).
protocol DialogueBoostCapable: AnyObject {
    func setDialogueBoost(_ enabled: Bool)
}

/// Runtime audio / subtitle track list (build 36, item 14, G-F).
/// MPV reads `track-list` and switches with `aid` / `sid`;
/// AVPlayer reads its media-selection groups and switches with
/// `select(_:in:)`. IJK does NOT conform — it has no track API,
/// so the driver no-ops through the `as?` cast and the picker
/// rows stay hidden on IJK (consistent with today: the sheet
/// only shows rows when the lists are non-empty).
/// `selectAudioTrack` / `selectSubtitleTrack` take the
/// engine-native id from `VodTrackInfo.index` (-1 = default/auto
/// for audio, -1 = off for subtitles). The backend publishes a
/// fresh list through `onTracksChanged` whenever the file's
/// tracks are known (after load, and after an external subtitle
/// is added).
protocol VodTrackListCapable: AnyObject {
    var audioTracks: [VodTrackInfo] { get }
    var subtitleTracks: [VodTrackInfo] { get }
    var onTracksChanged: (([VodTrackInfo], [VodTrackInfo]) -> Void)? { get set }
    func selectAudioTrack(index: Int)
    func selectSubtitleTrack(index: Int)
}

/// Runtime external subtitles (build 36, item 14, G-G). MPV only:
/// `sub-add` loads a sidecar file (Emby external stream, local
/// `.srt` / `.ass` / `.vtt` next to the video). AVPlayer has no
/// sidecar-loading API and IJK has no subtitle rendering at all,
/// so neither conforms — external subtitles route to MPV (see the
/// `hasExternalSubtitles` routing flag), and the honest limit is
/// written in the capability comment, not faked.
protocol VodExternalSubtitleCapable: AnyObject {
    func addSubtitle(url: URL, language: String?)
}

// MARK: - Kernel

enum PlayerKernel {
    /// UserDefaults key (native side). Mirrors Pure Live's Hive
    /// `videoPlayerKey` and the old Swift `hao_video_player_key`.
    /// The stored value is a preference, not a command: it wins
    /// only among engines that CAN play the stream (capability
    /// gate first). Switching takes effect on the next open.
    static let userDefaultsKey = "hao_video_player_key"

    /// Current preferred engine. Default MPV (Pure Live's
    /// defaultKey = 'mpv'); the capability split in
    /// VideoCapability overrides this per stream (HEVC / Dolby
    /// Vision / HLS / MP4 go to AVPlayer first).
    static var preferred: VideoEngine {
        get {
            let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
            return VideoEngine.from(raw: raw)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }

    /// The STORED preference, or nil when the user never picked
    /// one (b49 sweep P0-1): `preferred` above defaults to MPV
    /// when nothing is stored, and that default must NOT
    /// masquerade as an explicit pick — passing it would defeat
    /// the capability split for every user who never touched
    /// the picker (HLS / MP4 / HEVC would go to MPV instead of
    /// AVPlayer's hardware decode, the exact problem the split
    /// fixed). nil lets the split decide; a stored value —
    /// including an explicit MPV pick — wins among capable
    /// engines.
    static var storedPreferred: VideoEngine? {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey) else { return nil }
        return VideoEngine.from(raw: raw)
    }

    static func makeBackend(engine: VideoEngine) -> VideoPlayerBackend {
        switch engine {
        case .mpv: return MpvPlayerBackend()
        case .ijk: return IJKPlayerBackend()
        case .avplayer: return AVPlayerBackend()
        }
    }

    /// Candidate engines for a URL, in try order. The capability
    /// split picks the first engine (HEVC/DV/HLS/MP4 -> AVPlayer,
    /// FLV/MKV/ASS/multi-track -> MPV); an explicit user preference
    /// overrides the split but never the capability gate.
    /// `dvDowngradeToHdr` is the persisted DV-P8 switch
    /// (`SettingsStore.dvP8Downgrade`, default true): when off,
    /// Dolby Vision profile 8 in an Apple container is NOT
    /// admitted to AVPlayer and stays on the ffmpeg kernels. The
    /// driver passes the live setting at every open; callers that
    /// do not pass it keep the default-on behaviour.
    /// `excluding` removes engines that already failed for this
    /// episode (build 36, item 14, G-E mid-play fallback).
    static func candidatesFor(
        url: URL,
        declaredFormat: String? = nil,
        hasAssSubtitles: Bool = false,
        hasMultipleAudioTracks: Bool = false,
        hasExternalSubtitles: Bool = false,
        dvDowngradeToHdr: Bool = true,
        excluding: [VideoEngine] = []
    ) -> [VideoEngine] {
        // b49 sweep P0-1: the settings picker writes
        // `hao_video_player_key` (PlayerKernel.preferred) but this
        // used to hardcode preferred: nil, so the picker changed
        // nothing — every caller got the capability-split order.
        // The STORED preference now wins among capable engines
        // (the gate in videoCandidatesFor still excludes engines
        // that cannot play the stream); when nothing is stored,
        // nil lets the split decide instead of letting the .mpv
        // default masquerade as a pick (see storedPreferred).
        return videoCandidatesFor(
            url: url, declaredFormat: declaredFormat,
            preferred: PlayerKernel.storedPreferred,
            hasAssSubtitles: hasAssSubtitles,
            hasMultipleAudioTracks: hasMultipleAudioTracks,
            hasExternalSubtitles: hasExternalSubtitles,
            dvDowngradeToHdr: dvDowngradeToHdr,
            excluding: excluding
        )
    }

    /// HTTP headers every engine sends for a stream (the ijkplayer
    /// options this was copied from, shared so all three engines
    /// get the same CDN treatment):
    /// - Browser User-Agent: some CDNs reject FFmpeg's default UA
    ///   (HTTP 403) but accept a browser UA (verified with ffprobe).
    /// - Referer per platform, same rule as the old ijk options.
    /// VOD (CMS/Emby) has no live platform: callers pass nil and
    /// get the User-Agent only.
    static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func httpHeaders(platform: String?) -> [String: String] {
        var headers = ["User-Agent": browserUserAgent]
        let referer: String?
        switch platform {
        case "huya": referer = "https://www.huya.com/"
        case "bili": referer = "https://live.bilibili.com/"
        case "douyin": referer = "https://live.douyin.com/"
        case "douyu": referer = "https://www.douyu.com/"
        case "ks": referer = "https://live.kuaishou.com/"
        default: referer = nil
        }
        if let referer = referer { headers["Referer"] = referer }
        return headers
    }
}

// MARK: - Recovery ladder

/// Staged, automatic engine ladder (Flutter
/// `lib/core/player/kernel/recovery_ladder.dart`, Pure Live 3.x
/// media_core recovery/ladder).
///
/// Shape: per engine, every URL once, in order; URLs exhausted ->
/// next engine, sweep again; nothing left -> exhausted. Every
/// attempt is verified by ACTUAL playback (open completion);
/// bounded by the candidate lists (each (engine, url) pair is
/// tried exactly once per run, no budgets/backoff/memory).
/// A source-level failure (unopenable URL — expired signature,
/// unsupported format) is never re-attempted on the same pair:
/// replaying the same URL reproduces the fault.
final class VideoRecoveryLadder {
    enum Status: Equatable {
        case idle
        case running
        case completed
        case exhausted
    }

    /// Capable engines in try order (from `videoCandidatesFor`).
    let engines: [VideoEngine]
    /// URLs to try, in order (current line first, then other lines).
    let urls: [URL]
    /// One attempt: open `url` on `engine` and verify real
    /// playback. Calls its completion exactly once.
    let attempt: (VideoEngine, URL, @escaping (Bool) -> Void) -> Void
    /// Called before each attempt (engine + url), so the UI can show
    /// ladder progress ("正在尝试 MPV…") instead of a bare spinner.
    let onAttempt: ((VideoEngine, URL) -> Void)?

    private(set) var status: Status = .idle
    private var tried: Set<String> = []
    private var running = false

    init(
        engines: [VideoEngine],
        urls: [URL],
        attempt: @escaping (VideoEngine, URL, @escaping (Bool) -> Void) -> Void,
        onAttempt: ((VideoEngine, URL) -> Void)? = nil
    ) {
        self.engines = engines
        self.urls = urls
        self.attempt = attempt
        self.onAttempt = onAttempt
    }

    private func attemptKey(engine: VideoEngine, url: URL) -> String {
        // Redacted: a stream URL carries api_key, and this key
        // lives in the `tried` set for the ladder's whole run.
        // Redaction does not merge distinct URLs — two streams
        // differ in path, never only in the token.
        "\(engine.rawValue)::\(EmbyClient.redactedURL(url.absoluteString))"
    }

    /// Run the ladder. Calls completion exactly once with the
    /// (engine, url) that verified playback, or nil when every
    /// capable engine failed on every URL. A second run while one
    /// is in flight completes immediately with nil.
    func run(completion: @escaping ((VideoEngine, URL)?) -> Void) {
        guard !running else {
            completion(nil)
            return
        }
        running = true
        status = .running
        runNext(engineIndex: 0, urlIndex: 0, completion: completion)
    }

    private func runNext(engineIndex: Int, urlIndex: Int, completion: @escaping ((VideoEngine, URL)?) -> Void) {
        guard engineIndex < engines.count else {
            running = false
            status = .exhausted
            completion(nil)
            return
        }
        guard urlIndex < urls.count else {
            runNext(engineIndex: engineIndex + 1, urlIndex: 0, completion: completion)
            return
        }
        let engine = engines[engineIndex]
        let url = urls[urlIndex]
        let key = attemptKey(engine: engine, url: url)
        if tried.contains(key) {
            runNext(engineIndex: engineIndex, urlIndex: urlIndex + 1, completion: completion)
            return
        }
        tried.insert(key)
        onAttempt?(engine, url)
        attempt(engine, url) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.running = false
                self.status = .completed
                completion((engine, url))
            } else {
                self.runNext(engineIndex: engineIndex, urlIndex: urlIndex + 1, completion: completion)
            }
        }
    }

    /// Healthy playback resets the budget (30 s of playback):
    /// the next failure may try every pair again.
    func resetBudget() {
        tried.removeAll()
        status = .idle
    }
}
