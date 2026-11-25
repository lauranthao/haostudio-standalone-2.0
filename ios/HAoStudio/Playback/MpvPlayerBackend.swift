// HAo Studio 2.0 — MPV backend (S3, leg A).
//
// libmpv (Predidit 0.6.8, mpv 0.36 core) behind the
// VideoPlayerBackend protocol. This is the ffmpeg engine: FLV /
// MKV / ASS subtitles / multiple audio tracks go here because
// AVPlayer cannot play them at all.
//
// Rendering: the mpv software render API (MPV_RENDER_API_TYPE_SW,
// the same path media_kit's TextureSW uses as its fallback),
// rendering frames into a triple CVPixelBuffer pool and displaying
// them through an AVSampleBufferDisplayLayer. No OpenGL ES: EAGL
// is deprecated and the SW path is the only render path that
// needs no GL context at all. Hardware decode (hwdec=auto-safe)
// still applies — mpv downloads the VideoToolbox frames to CPU
// for the SW renderer, which is the documented hwdec + sw-render
// behaviour.
// Audio: mpv's audiounit output on the app's .playback audio
// session — background audio works like the other engines.
//
// P0-02 (this file's reason to exist): options are set ONE BY
// ONE, and a refused option is logged by NAME ONLY (never its
// value) and skipped — no single refused property is ever allowed
// to burn a whole engine. The old code ignored the return value
// of mpv_set_option_string entirely; a bad option failed
// silently and a later failure looked like an engine failure.
//
// Hard decode (plan §四 4.2): `hwdec=auto-safe` (NOT forced
// videotoolbox — forcing fails the open outright when
// VideoToolbox rejects a codec; auto-safe + verify + downgrade
// is steadier) + `hwdec-software-fallback=1`. After the file
// loads, `hwdec-current` is read back: `videotoolbox` means
// verified hard decode, `no`/empty means verified software
// decode. The state is exposed, never assumed.
//
// Framedrop is `no` for VOD and live alike (no backend exposes
// a framedrop knob — the live edge is kept by the stall watchdog
// + recovery loop, not by dropping frames). Cache /
// probe values are the Pure Live 3.x base table (30 s / 96 MB /
// 8 s readahead, 2 MB probe / 2 s analyze), not the old
// live-tuned 6 s / 32 MB / 2 s.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import UIKit
import AVFoundation
import Mpv

// Container whose layer IS the display layer (videoGravity
// .resizeAspect, sized by the driver to its video view bounds on
// every layout pass).
private final class MpvVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
}

final class MpvPlayerBackend: NSObject, VideoPlayerBackend, LiveAudioOnlyCapable, VodSubtitleAppearanceCapable, VodEnhancementCapable, DialogueBoostCapable, VodTrackListCapable, VodExternalSubtitleCapable {
    var onEvent: ((VideoBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    let engine: VideoEngine = .mpv

    /// Audio / subtitle tracks from the last `track-list` read
    /// (build 36, item 14, G-F). Published through
    /// `onTracksChanged` after the file loads and after an
    /// external subtitle is added; the driver mirrors them into
    /// the settings sheet pickers.
    private var cachedAudioTracks: [VodTrackInfo] = []
    private var cachedSubtitleTracks: [VodTrackInfo] = []
    var onTracksChanged: (([VodTrackInfo], [VodTrackInfo]) -> Void)?

    var audioTracks: [VodTrackInfo] { cachedAudioTracks }
    var subtitleTracks: [VodTrackInfo] { cachedSubtitleTracks }

    private let containerView = MpvVideoView()
    private var rate: Double = 1

    private var mpvHandle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var isShutdown = false
    private var didEmitFirstFrame = false
    private var didEmitPrepared = false
    private var isBackgrounded = false

    /// Names of options the engine refused (P0-02). Names only,
    /// never values. Read by Diagnostics; empty when every option
    /// was accepted.
    private(set) var rejectedOptionNames: [String] = []

    /// Hard-decode state, from the `hwdec-current` read-back after
    /// the file loads. `.unknown` until the first read-back.
    private(set) var hardwareDecode: VideoHardwareDecodeState = .unknown

    /// Pending open completion (fires exactly once).
    private var openCompletion: ((Bool) -> Void)?

    // Serial queues: the mpv event loop (mpv_wait_event) and the
    // render work (render + display-layer enqueue) never overlap
    // each other.
    private let eventQueue = DispatchQueue(label: "studio.hao.mpv-event", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "studio.hao.mpv-render", qos: .userInitiated)

    /// Queue-identity keys for the shutdown drain (b36 item 5):
    /// `queue.sync {}` from the queue itself deadlocks, so the
    /// drain skips a queue this thread is already running on.
    /// The drain is what makes tearing the core down safe: the
    /// event loop and the render work are the only threads that
    /// ever call mpv on this backend's handle/context.
    private static let eventQueueKey = DispatchSpecificKey<Void>()
    private static let renderQueueKey = DispatchSpecificKey<Void>()

    /// Retained context pointer handed to mpv as the render
    /// update-callback context (b36 item 5): `passUnretained`
    /// let a late callback dereference a backend freed by a
    /// back-out. The retain keeps the backend alive until
    /// shutdown() releases it after clearing the callback and
    /// draining the render queue.
    private var renderCallbackToken: UnsafeMutableRawPointer?

    // Video size in pixels (dwidth/dheight), capped for the SW renderer.
    private var videoSize = CGSize.zero
    // Triple pixel-buffer pool (media_kit TextureSW pattern).
    private var pixelBuffers: [CVPixelBuffer] = []
    private var poolSize = CGSize.zero
    private var poolIndex = 0
    private var formatDescription: CMVideoFormatDescription?

    override init() {
        super.init()
        eventQueue.setSpecific(key: Self.eventQueueKey, value: ())
        renderQueue.setSpecific(key: Self.renderQueueKey, value: ())
        containerView.backgroundColor = .black
        containerView.displayLayer?.videoGravity = .resizeAspect
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func setVideoFit(_ fit: VideoFit) {
        switch fit {
        case .aspectFit: containerView.displayLayer?.videoGravity = .resizeAspect
        case .aspectFill: containerView.displayLayer?.videoGravity = .resizeAspectFill
        case .fill: containerView.displayLayer?.videoGravity = .resize
        }
    }

    var view: UIView { containerView }

    var isPlaying: Bool {
        guard let handle = mpvHandle else { return false }
        var paused: Int32 = 0
        guard mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &paused) >= 0 else { return false }
        return paused == 0
    }

    var currentTime: Double {
        guard let handle = mpvHandle else { return 0 }
        var t: Double = 0
        guard mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &t) >= 0, t.isFinite, t >= 0 else { return 0 }
        return t
    }

    var duration: Double {
        guard let handle = mpvHandle else { return Double.nan }
        var d: Double = 0
        guard mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &d) >= 0 else { return Double.nan }
        // Live streams report inf / -1: the driver treats
        // non-finite as "unknown" (same guard it uses for the
        // other engines).
        return d.isFinite ? d : Double.nan
    }

    var isPrepared: Bool {
        guard let handle = mpvHandle else { return false }
        // mpv has no single "prepared" flag; a file is loaded when
        // the core is not idle. FILE_LOADED also drives .prepared.
        var idle: Int32 = 0
        guard mpv_get_property(handle, "core-idle", MPV_FORMAT_FLAG, &idle) >= 0 else { return false }
        return idle == 0
    }

    var playbackRate: Double {
        get { rate }
        set {
            rate = newValue
            if let handle = mpvHandle {
                mpv_set_property_string(handle, "speed", String(newValue))
            }
        }
    }

    // MARK: - Open / play / pause / seek / shutdown

    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void) {
        shutdown()
        isShutdown = false
        didEmitFirstFrame = false
        didEmitPrepared = false
        videoSize = .zero
        rejectedOptionNames = []
        hardwareDecode = .unknown
        cachedAudioTracks = []
        cachedSubtitleTracks = []
        openCompletion = completion
        guard let handle = mpv_create() else {
            finishOpen(false)
            return
        }
        mpvHandle = handle
        // Options must be set BEFORE mpv_initialize. Each one is
        // set defensively (P0-02): a refusal is logged by name
        // and skipped, never fatal.
        setOption(handle, "config", "no")
        setOption(handle, "terminal", "no")
        setOption(handle, "vo", "libmpv")
        setOption(handle, "hwdec", "auto-safe")
        setOption(handle, "hwdec-software-fallback", "1")
        setOption(handle, "ao", "audiounit")
        setOption(handle, "force-seekable", "yes")
        setOption(handle, "protocol-whitelist", "httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt")
        setOption(handle, "demuxer-lavf-probesize", "2097152")
        setOption(handle, "demuxer-lavf-analyzeduration", "2")
        // Huya HLS segments carry a query string (xxx.ts?EXTINF=2.7);
        // FFmpeg's HLS demuxer blocks them without this.
        setOption(handle, "demuxer-lavf-allowed-extensions", "ALL")
        // Low-memory mode (wiring leg B; Flutter LowMemoryMode /
        // mpvBaseProperties): the low-end property set applies when
        // the stored mode says so ("always" always, "never" never,
        // "auto" on <= 4-core devices). Read at every open, so live
        // + VOD both follow the current mode; a change while a VOD
        // episode is playing re-opens it at its position (see
        // VideoDriver.reopenEpisodeAtCurrentPosition). MPV only — Flutter's
        // mode lives in the mpv table, IJK / AVPlayer are untouched.
        let lowEnd = LowMemoryModeEffect.isEffective(
            mode: UserDefaults.standard.string(forKey: SettingsStore.lowMemoryModeKey),
            cpuCores: ProcessInfo.processInfo.processorCount)
        setOption(handle, "cache", "yes")
        setOption(handle, "cache-on-disk", "no")
        setOption(handle, "cache-secs", "30")
        setOption(handle, "demuxer-max-bytes", lowEnd ? "41943040" : "100663296")
        setOption(handle, "demuxer-max-back-bytes", lowEnd ? "5242880" : "8388608")
        setOption(handle, "demuxer-donate-buffer", "no")
        setOption(handle, "demuxer-readahead-secs", "8")
        setOption(handle, "demuxer-thread", "yes")
        setOption(handle, "cache-pause-wait", "4")
        if lowEnd {
            setOption(handle, "audio-buffer", "0.4")
            setOption(handle, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2")
        }
        // Framedrop stays `no` for live too: no backend exposes
        // a framedrop knob, so the live edge is kept by the
        // stall watchdog + recovery loop, not by dropping frames.
        setOption(handle, "framedrop", "no")
        // Dolby Vision base layer (build 36, item 13): a DV stream
        // that reaches this engine is one AVPlayer cannot take
        // (dual-layer profile 7, or DV in an MKV container) — only
        // its HDR10/HLG base layer is decoded. Pin the tone
        // mapping for that base layer (mpv's default for SDR
        // output is bt.2390; pinning it makes the HDR path
        // deterministic instead of default-dependent). Profile 5
        // has no base layer and never reaches a correct picture
        // here — the capability gate routes it to AVPlayer, never
        // an option. HDR10/HLG without DV need no option: mpv
        // tone-maps them by default and their facts carry no HDR
        // marker to key off.
        if let facts = VideoStreamFacts.parse(url: url), facts.dolbyVision {
            setOption(handle, "tone-mapping", "bt.2390")
        }
        if lowEnd {
            setOption(handle, "vd-lavc-threads", "2")
        }
        setOption(handle, "vd-lavc-o", lowEnd ? "lowres=1" : "lowres=0")
        setOption(handle, "vd-lavc-skiploopfilter", lowEnd ? "nonref" : "default")
        setOption(handle, "network-timeout", "15")
        if let ua = headers["User-Agent"] { setOption(handle, "user-agent", ua) }
        if let referer = headers["Referer"] { setOption(handle, "http-header-fields", "Referer: \(referer)") }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            mpvHandle = nil
            finishOpen(false)
            return
        }
        // Render context BEFORE loadfile: with vo=libmpv the VO needs
        // its render context when the file opens.
        guard createRenderContext(handle) else {
            mpv_terminate_destroy(handle)
            mpvHandle = nil
            finishOpen(false)
            return
        }
        // Properties the event loop watches (ids double as the
        // reply_userdata so the handler knows which one changed).
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 5, "dheight", MPV_FORMAT_INT64)
        startEventLoop()
        runCommand(["loadfile", url.absoluteString, "replace"])
    }

    /// Fire the pending open completion exactly once.
    private func finishOpen(_ ok: Bool) {
        guard let completion = openCompletion else { return }
        openCompletion = nil
        completion(ok)
    }

    func play() {
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "pause", "no")
        // Keep the chosen speed: mpv resets speed to 1 on some seeks.
        mpv_set_property_string(handle, "speed", String(rate))
    }

    func pause() {
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "pause", "yes")
    }

    // MARK: - Live background audio (LiveAudioOnlyCapable)

    /// S7-C: Flutter `setAudioOnly` — drop the video track, keep
    /// the audio flowing. mpv `video=no` stops video decoding /
    /// output; `video=auto` restores it. No-op before open (no
    /// handle yet), mirroring play()/pause(). Live background
    /// audio (S4) and VOD background audio (S7 wiring, the
    /// `audioOnlyBackground` switch) share this one call.
    func setAudioOnly(_ audioOnly: Bool) {
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "video", audioOnly ? "no" : "auto")
    }

    // MARK: - VOD subtitle appearance + enhancement (S7 wiring)

    /// Set one property on the running player, defensively: a
    /// refusal is ignored, never fatal — a decoration must never
    /// break playback (same discipline as Flutter's
    /// `_setPropertiesDefensively`). No-op before open.
    private func setRuntimeProperty(_ name: String, _ value: String) {
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, name, value)
    }

    /// Flutter `setSubtitleAppearance`: mpv `sub-font-size` /
    /// `sub-color` / `sub-pos`, runtime setProperty calls. The
    /// values arrive already resolved from the tiers (see
    /// `VodSubtitleAppearance.forTiers`). Applies to whatever
    /// subtitle track mpv auto-selected; AVPlayer/IJK never reach
    /// here (they do not conform to the capability protocol).
    func setSubtitleAppearance(fontSize: Int, color: String, position: Double) {
        setRuntimeProperty("sub-font-size", String(fontSize))
        setRuntimeProperty("sub-color", color)
        setRuntimeProperty("sub-pos", String(Int(position)))
    }

    /// Apply one resolved trio branch to the running player
    /// (Flutter `setSuperResolution` / `setFrameInterpolation` /
    /// `setSdrToHdr` on the running player, b30: 马上生效, no
    /// reopen). Only the resolved branch runs — the driver
    /// resolves first-branch-wins, so turning one branch on while
    /// another is on cannot take effect until the other is off.
    /// Turning a branch off restores the mpv defaults instead of
    /// leaving the "on" values behind.
    ///
    /// Honest limits (same as Flutter's own comments):
    /// - `.superResolution` is a NO-OP: no Anime4K shaders are
    ///   bundled in this app, and `glsl-shaders` needs a GPU
    ///   video output while this backend renders through the
    ///   software render API (`vo=libmpv`). Nothing is mounted,
    ///   nothing is faked — the switch stays a stored preference
    ///   until shaders + a GPU vo land, with real-device
    ///   verification.
    /// - `.interpolation` / `.sdrToHdr` only guarantee the
    ///   properties are SENT: `vo=libmpv` may silently disable
    ///   interpolation, and inverse tone mapping is marked
    ///   `vo=gpu-next` only. Whether the picture visibly changes
    ///   on a real iPhone is 待真机验证.
    func setVodEnhancement(_ branch: VodEnhancementBranch?) {
        switch branch {
        case .none:
            setRuntimeProperty("video-sync", "audio")
            setRuntimeProperty("interpolation", "no")
            setRuntimeProperty("inverse-tone-mapping", "no")
            setRuntimeProperty("tone-mapping", "bt.2390")
            setRuntimeProperty("target-trc", "auto")
            setRuntimeProperty("target-peak", "auto")
        case .superResolution:
            // No shaders bundled, no GPU vo: nothing to mount.
            // Deliberately no property write here.
            break
        case .interpolation:
            setRuntimeProperty("video-sync", "display-resample")
            setRuntimeProperty("interpolation", "yes")
            setRuntimeProperty("tscale", "oversample")
            setRuntimeProperty("inverse-tone-mapping", "no")
            setRuntimeProperty("tone-mapping", "bt.2390")
            setRuntimeProperty("target-trc", "auto")
            setRuntimeProperty("target-peak", "auto")
        case .sdrToHdr:
            setRuntimeProperty("inverse-tone-mapping", "yes")
            setRuntimeProperty("tone-mapping", "spline")
            setRuntimeProperty("target-trc", "pq")
            setRuntimeProperty("target-peak", "1000")
            setRuntimeProperty("video-sync", "audio")
            setRuntimeProperty("interpolation", "no")
        }
    }

    /// Flutter `kDialogueBoostCentreFilter` (K 组 build 29, b30
    /// loudnorm): centre-channel fold + dynamic normalization.
    /// Stereo-safe — the pan stage is bit-identical on stereo (a
    /// missing centre reads as silence) and folds correctly on
    /// 5.1; loudnorm is what makes it audible on stereo, lifting
    /// quiet passages and taming loud ones. Coefficients / target
    /// 待真机验证 (same caveat as Flutter).
    static let dialogueBoostFilter = "lavfi[pan=stereo|c0=1.0*c0+0.7*c2+0.3*c4|c1=1.0*c1+0.7*c2+0.3*c5,loudnorm=I=-16:TP=-1.5:LRA=11:linear=false]"

    /// Flutter `MpvBackend.setDialogueBoost` (VOD only, MPV
    /// only): `volume-max=300` (Flutter `kMpvVolumeMax`, so gain
    /// can exceed 100%) + the centre filter above while on.
    /// Off drops the filter; the 300 ceiling stays — the live
    /// volume boost needs it regardless of this switch. Best
    /// effort through `setRuntimeProperty`: a refused write never
    /// breaks playback, and no-op before open (the driver
    /// remembers the switch and re-applies it at open).
    func setDialogueBoost(_ enabled: Bool) {
        setRuntimeProperty("volume-max", "300")
        if !enabled {
            setRuntimeProperty("af", "")
            return
        }
        setRuntimeProperty("af", Self.dialogueBoostFilter)
    }

    // MARK: - Audio / subtitle tracks + external subtitles (build 36, item 14, G-F/G-G)

    /// Read `track-list` and publish it. Called after the file
    /// loads and after an external subtitle is added. The JSON
    /// parses through the pure `VodTrackList.parse` (a top-level
    /// array — the one legal shape for `JSONSerialization`).
    private func refreshTrackList() {
        guard let handle = mpvHandle, !isShutdown else { return }
        guard let raw = mpv_get_property_string(handle, "track-list") else { return }
        defer { mpv_free(raw) }
        let json = String(cString: raw)
        let (audio, subtitles) = VodTrackList.parse(json: json)
        cachedAudioTracks = audio
        cachedSubtitleTracks = subtitles
        onTracksChanged?(audio, subtitles)
    }

    /// Switch the audio track: `aid` takes the mpv track id from
    /// `VodTrackInfo.index` (-1 = auto/default).
    func selectAudioTrack(index: Int) {
        setRuntimeProperty("aid", index < 0 ? "auto" : String(index))
    }

    /// Switch the subtitle track: `sid` takes the mpv track id
    /// (-1 = no subtitles).
    func selectSubtitleTrack(index: Int) {
        setRuntimeProperty("sid", index < 0 ? "no" : String(index))
    }

    /// Load an external subtitle file (`sub-add`, "auto" flag so
    /// mpv selects it by language). The track list is re-read
    /// shortly after, so the new track appears in the picker.
    /// No-op before open (no handle yet).
    func addSubtitle(url: URL, language: String?) {
        guard mpvHandle != nil else { return }
        runCommand(["sub-add", url.absoluteString, "auto"])
        eventQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.refreshTrackList()
            }
        }
    }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        guard let handle = mpvHandle else {
            completion(false)
            return
        }
        // Drop stale frames queued in the display layer.
        containerView.displayLayer?.flush()
        runCommand(["seek", String(seconds), "absolute"])
        // Read-back verification: the seek command only queues the
        // seek, so confirm the playhead actually landed near the
        // target before reporting success.
        eventQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.mpvHandle != nil else {
                completion(false)
                return
            }
            let landed = self.currentTime
            completion(abs(landed - seconds) <= 2.0)
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        finishOpen(false)
        // sweep-4 P2-58: the background/foreground observers are
        // NOT removed here. open() starts with shutdown(), so
        // removing them here dropped them before the first
        // playback ever ran — and nothing re-added them, so the
        // backend never learned the app backgrounded again
        // (isBackgrounded stayed false, frames kept rendering
        // behind the lock screen). The handlers only flip the
        // isBackgrounded flag and renderIfNeeded is guarded on
        // !isShutdown, so leaving them registered across a
        // shutdown is safe. They are removed in deinit only.
        // Ordered teardown (b36 item 5 — the back-out crash):
        // the old code freed the render context and destroyed
        // the core while the event loop could still be inside
        // handleEvent and a render block inside
        // mpv_render_context_render on them — a use-after-free
        // inside libmpv on every FLV room exit (MPV is the FLV
        // engine, so most live rooms). Nothing below touches
        // the handle/context after this point except the
        // drains, which wait the in-flight work out first:
        // 1. Drop the stored references: every mpv call in
        //    this file guards on mpvHandle/renderContext, so
        //    no NEW mpv call can start after this.
        // 2. Clear the render update callback: no new frame
        //    callback can enqueue render work after this.
        // 3. Drain the render queue: a block already past
        //    renderIfNeeded's guard finishes its render call
        //    on the still-alive context.
        // 4. Free the render context (it must go before the
        //    core, as before).
        // 5. terminate_destroy: wakes the event loop's
        //    mpv_wait_event with MPV_EVENT_SHUTDOWN, so the
        //    loop exits at once instead of after its 0.5 s
        //    wait timeout. Safe now: the only thread that
        //    could still be in an mpv call on the handle is
        //    the event loop's wait itself, which this wakes.
        // 6. Drain the event queue: the loop has exited and
        //    no thread can touch the handle any more.
        // 7. Release the retained update-callback context.
        // The drains skip a queue this thread is already on
        // (deinit can land on either queue when a queued block
        // drops the last reference — a sync there would
        // deadlock). No mpv call in this file blocks on the
        // main thread, so draining from main cannot deadlock.
        let ctx = renderContext
        let handle = mpvHandle
        renderContext = nil
        mpvHandle = nil
        if let ctx = ctx {
            mpv_render_context_set_update_callback(ctx, nil, nil)
        }
        drainQueue(renderQueue, key: Self.renderQueueKey)
        if let ctx = ctx {
            mpv_render_context_free(ctx)
        }
        if let handle = handle {
            mpv_terminate_destroy(handle)
        }
        drainQueue(eventQueue, key: Self.eventQueueKey)
        releaseRenderCallbackToken()
        pixelBuffers.removeAll()
        formatDescription = nil
        poolSize = .zero
        DispatchQueue.main.async { [weak self] in
            self?.containerView.displayLayer?.flush()
        }
    }

    /// Wait for all work already queued on `queue` to finish,
    /// unless this thread is already running on that queue (a
    /// sync from the queue to itself deadlocks — skip it: the
    /// caller is then the in-flight work itself).
    private func drainQueue(_ queue: DispatchQueue, key: DispatchSpecificKey<Void>) {
        guard DispatchQueue.getSpecific(key: key) == nil else { return }
        queue.sync {}
    }

    /// Drop the retained render update-callback context (see the
    /// property note). Only ever called from shutdown(), after
    /// the callback is cleared and the render queue drained.
    private func releaseRenderCallbackToken() {
        guard let token = renderCallbackToken else { return }
        renderCallbackToken = nil
        Unmanaged<MpvPlayerBackend>.fromOpaque(token).release()
    }

    deinit {
        shutdown()
        // sweep-4 P2-58: the only place the background/foreground
        // observers are removed (see shutdown()).
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - mpv helpers

    /// Set one option defensively (P0-02): a refusal is recorded
    /// by NAME ONLY (the value is never logged — option values
    /// can carry URLs, tokens or headers) and the open continues
    /// with the remaining options. A single bad option must never
    /// burn the whole engine.
    private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
        let result = mpv_set_option_string(handle, name, value)
        if result < 0 {
            rejectedOptionNames.append(name)
            NSLog("[HAoStudio][MPV] option rejected: %@ (%d)", name, result)
        }
    }

    /// Read back the live hardware decoder after the file loads
    /// (plan §四 4.2): `hwdec-current` is `videotoolbox` when
    /// auto-safe engaged hardware, `no`/empty when it fell back
    /// to software. This is the ONLY thing that may set
    /// hardwareDecode — never the requested option.
    private func verifyHardwareDecode() {
        guard let handle = mpvHandle else { return }
        guard let raw = mpv_get_property_string(handle, "hwdec-current") else {
            hardwareDecode = .software
            return
        }
        defer { mpv_free(raw) }
        let current = String(cString: raw)
        if current == "videotoolbox" {
            hardwareDecode = .hardware(decoder: "videotoolbox")
        } else if current.isEmpty || current == "no" {
            hardwareDecode = .software
        } else {
            hardwareDecode = .hardware(decoder: current)
        }
    }

    private func runCommand(_ args: [String]) {
        guard let handle = mpvHandle else { return }
        // Keep the mutable pointers to free them; pass the const
        // view to mpv (its args are `const char **`).
        let owned: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { owned.forEach { if let p = $0 { free(p) } } }
        var cStrings: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
        cStrings.append(nil)
        cStrings.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command_async(handle, 0, buf.baseAddress)
        }
    }

    private func createRenderContext(_ handle: OpaquePointer) -> Bool {
        // Software renderer (media_kit TextureSW): "sw" + the four
        // SW_* params at render time. Must run on the main thread
        // (the display layer lives there).
        var ctx: OpaquePointer?
        let api = UnsafeMutableRawPointer(mutating: ("sw" as NSString).utf8String)
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        guard mpv_render_context_create(&ctx, handle, &params) >= 0, let ctx = ctx else { return false }
        renderContext = ctx
        let token = Unmanaged.passRetained(self)
        renderCallbackToken = token.toOpaque()
        mpv_render_context_set_update_callback(ctx, { cb in
            guard let cb = cb else { return }
            let backend = Unmanaged<MpvPlayerBackend>.fromOpaque(cb).takeUnretainedValue()
            backend.renderQueue.async { backend.renderIfNeeded() }
        }, token.toOpaque())
        return true
    }

    // MARK: - Event loop

    private func startEventLoop() {
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            while !self.isShutdown {
                guard let handle = self.mpvHandle else { break }
                guard let event = mpv_wait_event(handle, 0.5) else { continue }
                let eventId = event.pointee.event_id
                if eventId == MPV_EVENT_NONE { continue }
                if eventId == MPV_EVENT_SHUTDOWN { break }
                self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_FILE_LOADED:
            verifyHardwareDecode()
            DispatchQueue.main.async { [weak self] in
                self?.refreshTrackList()
            }
            if !didEmitPrepared {
                didEmitPrepared = true
                emit(.prepared)
                finishOpen(true)
            }
        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { break }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            switch end.reason {
            case MPV_END_FILE_REASON_EOF:
                emit(.finished(.ended))
            case MPV_END_FILE_REASON_ERROR:
                // A load error before prepared fails the open;
                // after prepared it is a mid-play failure.
                if !didEmitPrepared { finishOpen(false) }
                emit(.finished(.error))
            case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT, MPV_END_FILE_REASON_REDIRECT:
                break
            default:
                break
            }
        case MPV_EVENT_VIDEO_RECONFIG:
            readVideoSize()
            if !didEmitFirstFrame {
                didEmitFirstFrame = true
                emit(.firstFrame)
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { break }
            let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let namePtr = prop.name else { break }
            let name = String(cString: namePtr)
            switch name {
            case "pause":
                guard prop.format == MPV_FORMAT_FLAG, let p = prop.data else { break }
                let paused = p.assumingMemoryBound(to: Int32.self).pointee
                emit(paused == 0 ? .playing : .paused)
            case "dwidth", "dheight":
                readVideoSize()
            default:
                break
            }
        default:
            break
        }
    }

    private func readVideoSize() {
        guard let handle = mpvHandle else { return }
        var w: Int64 = 0, h: Int64 = 0
        guard mpv_get_property(handle, "dwidth", MPV_FORMAT_INT64, &w) >= 0,
              mpv_get_property(handle, "dheight", MPV_FORMAT_INT64, &h) >= 0,
              w > 0, h > 0 else { return }
        let size = CGSize(width: CGFloat(w), height: CGFloat(h))
        if size != videoSize {
            videoSize = size
            DispatchQueue.main.async { [weak self] in
                self?.onVideoSize?(size)
            }
        }
    }

    private func emit(_ event: VideoBackendEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    // MARK: - Software rendering

    @objc private func appDidEnterBackground() {
        isBackgrounded = true
    }

    @objc private func appWillEnterForeground() {
        isBackgrounded = false
    }

    private func renderIfNeeded() {
        guard let ctx = renderContext, !isShutdown, !isBackgrounded else { return }
        // Render on every update callback (media_kit TextureSW does
        // the same): the callback only fires when mpv has a new frame
        // or a redraw request, so there is no idle re-render loop.
        _ = mpv_render_context_update(ctx)
        // Render at the video's native size, capped at 1080p: the
        // display layer scales to the view; rendering bigger only
        // burns CPU.
        var size = videoSize
        if size.width <= 0 || size.height <= 0 {
            // No video size yet (audio-only moment / before reconfig).
            return
        }
        if size.width > 1920 || size.height > 1920 {
            let scale = min(1920 / size.width, 1920 / size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        size = CGSize(width: max(2, Int(size.width) & ~1), height: max(2, Int(size.height) & ~1))
        guard let buffer = nextPixelBuffer(size: size) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        var ssize: [Int32] = [Int32(size.width), Int32(size.height)]
        var pitch = Int(CVPixelBufferGetBytesPerRow(buffer))
        let format = "bgr0"
        ssize.withUnsafeMutableBytes { ssizePtr in
            format.withCString { formatPtr in
                withUnsafeMutablePointer(to: &pitch) { pitchPtr in
                    var params: [mpv_render_param] = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: ssizePtr.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: formatPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: pitchPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(ctx, &params)
                }
            }
        }
        enqueue(buffer: buffer)
    }

    private func nextPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if poolSize != size || pixelBuffers.isEmpty {
            // (Re)build the triple pool for this size.
            pixelBuffers.removeAll()
            formatDescription = nil
            poolSize = size
            poolIndex = 0
            for _ in 0..<3 {
                guard let buffer = makePixelBuffer(size: size) else { return nil }
                pixelBuffers.append(buffer)
            }
        }
        let buffer = pixelBuffers[poolIndex]
        poolIndex = (poolIndex + 1) % pixelBuffers.count
        return buffer
    }

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer = buffer else { return nil }
        return buffer
    }

    private func enqueue(buffer: CVPixelBuffer) {
        if formatDescription == nil {
            var desc: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &desc
            ) == noErr, let desc = desc else { return }
            formatDescription = desc
        }
        guard let desc = formatDescription else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer = sampleBuffer else { return }
        guard let layer = containerView.displayLayer else { return }
        if layer.status == .failed {
            // A failed layer drops everything until flushed.
            layer.flush()
        }
        if layer.isReadyForMoreMediaData {
            layer.enqueue(sampleBuffer)
        }
    }
}
