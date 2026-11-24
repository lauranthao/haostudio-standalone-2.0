// HAo Studio 2.0 — IJK backend (S3, leg A).
//
// ijkplayer (FFmpeg) behind the VideoPlayerBackend protocol. This
// is the third-choice engine: it plays the ffmpeg-kernel set
// (FLV / MKV / HLS / MP4 / AVI / WMV / RMVB / TS / WebM / MPG /
// DASH), but it is never first — the capability split sends HEVC /
// Dolby Vision / HLS / MP4 to AVPlayer and FLV / MKV / ASS /
// multi-track to MPV, and IJK covers whatever is left.
//
// Honest limits (build 36, item 14):
// - NOT "plays everything": ijkplayer is FFmpeg 4.0, which
//   predates AV1 entirely (no native decoder, no dav1d) — the
//   facts gate excludes IJK for AV1 (G-C), MPV covers it.
// - DTS / TrueHD decode in this build is UNVERIFIED (G-I):
//   ijkplayer's module-lite FFmpeg 4.0 may strip the `dca` /
//   `truehd` decoders. Do not claim support until D8/D9 pass on
//   a real iPhone; MPV is tried before IJK, so a missing decoder
//   here only costs one failed attempt.
// - No track API and no subtitle rendering at all (G-F/G-G):
//   this backend deliberately does NOT conform to
//   `VodTrackListCapable` / `VodExternalSubtitleCapable` —
//   the driver no-ops through the `as?` cast and the track
//   picker rows stay hidden while IJK is the running engine.
//
// Hard decode (plan §四 4.2): `videotoolbox=1` is set explicitly
// (the old Flutter side only set `mediacodec=1`, an Android
// option that is inert on iOS — the build-31 audit found IJK on
// iOS never asked for hardware decode at all). Verification:
// ijkplayer exposes NO public API that returns the VideoToolbox
// session, so the honest state is "session established + frames
// rendering" (prepared + first frame rendered), reported as
// assumed-hardware, never as verified. The driver never routes
// 4K HEVC / Dolby Vision to IJK first, so the unverified state
// can never hide a soft decode on a high-demand stream.
//
// Framedrop is 0 for VOD and live alike: no backend exposes a
// framedrop knob, so the live edge is kept by the stall watchdog
// + recovery loop, not by dropping frames (the old live-tuned
// `framedrop=1` was never re-applied for live in this backend).
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import UIKit
import IJKMediaFramework

final class IJKPlayerBackend: NSObject, VideoPlayerBackend {
    var onEvent: ((VideoBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    let engine: VideoEngine = .ijk

    private var player: IJKFFMoviePlayerController?
    private var streamURL: URL?
    private var rate: Double = 1
    private var currentFitMode: IJKMPMovieScalingMode = .aspectFit

    /// Hard-decode state. `.unknown` until the first frame renders;
    /// then assumed-hardware (see the header: IJK has no read-back
    /// API, so this is "session established + frames", not a
    /// verified decoder read-back).
    private(set) var hardwareDecode: VideoHardwareDecodeState = .unknown

    /// Pending open completion (fires exactly once).
    private var openCompletion: ((Bool) -> Void)?
    private var didEmitPrepared = false
    private var didEmitFirstFrame = false

    var view: UIView {
        // The player always owns a view once opened; before that a
        // plain placeholder keeps the driver's layout code simple.
        if let v = player?.view { return v }
        let v = UIView()
        v.backgroundColor = .black
        return v
    }

    var isPlaying: Bool { player?.isPlaying() ?? false }

    var currentTime: Double {
        let t = player?.currentPlaybackTime ?? 0
        return t.isFinite ? t : 0
    }

    var duration: Double {
        let d = player?.duration ?? Double.nan
        return d.isFinite ? d : Double.nan
    }

    var isPrepared: Bool { player?.isPreparedToPlay ?? false }

    var playbackRate: Double {
        get { rate }
        set {
            rate = newValue
            player?.playbackRate = Float(newValue)
        }
    }

    func setVideoFit(_ fit: VideoFit) {
        switch fit {
        case .aspectFit: currentFitMode = .aspectFit
        case .aspectFill: currentFitMode = .aspectFill
        case .fill: currentFitMode = .fill
        }
        player?.scalingMode = currentFitMode
    }

    func open(url: URL, headers: [String: String], completion: @escaping (Bool) -> Void) {
        shutdown()
        streamURL = url
        didEmitPrepared = false
        didEmitFirstFrame = false
        hardwareDecode = .unknown
        openCompletion = completion
        guard let p = IJKFFMoviePlayerController(contentURL: url, with: makeIJKOptions(headers: headers)) else {
            finishOpen(false)
            return
        }
        p.scalingMode = currentFitMode
        p.shouldAutoplay = true
        p.shouldShowHudView = false
        p.setPauseInBackground(false)
        // ijkplayer applies the rate live; there is no pitch
        // correction in IJKFFMoviePlayerController, so 2x sound
        // higher-pitched — that is the engine's behaviour, not a bug.
        p.playbackRate = Float(rate)
        p.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.player = p
        registerIJKNotifications(for: p)
        p.prepareToPlay()
        p.play()
    }

    /// Fire the pending open completion exactly once.
    private func finishOpen(_ ok: Bool) {
        guard let completion = openCompletion else { return }
        openCompletion = nil
        completion(ok)
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        guard let p = player else {
            completion(false)
            return
        }
        // IJK seek is a property set with no completion of its own:
        // verify by reading the playhead back after a short delay.
        p.currentPlaybackTime = seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.player != nil else {
                completion(false)
                return
            }
            completion(abs(self.currentTime - seconds) <= 2.0)
        }
    }

    func shutdown() {
        finishOpen(false)
        NotificationCenter.default.removeObserver(self)
        if let p = player {
            p.view.removeFromSuperview()
            p.shutdown()
        }
        player = nil
    }

    deinit {
        shutdown()
    }

    // MARK: - Options

    private func makeIJKOptions(headers: [String: String]) -> IJKFFOptions {
        let options = IJKFFOptions.byDefault() ?? IJKFFOptions()
        // Hardware decoding (VideoToolbox) — smooth 1080p on iPhone.
        // Explicit on iOS: the Flutter side only set mediacodec=1
        // (Android-only, inert here), so IJK on iOS never asked.
        options.setPlayerOptionIntValue(1, forKey: "videotoolbox")
        // Never drop frames — for live too: no backend exposes a
        // framedrop knob; the live edge is kept by the stall
        // watchdog + recovery loop, not by dropping frames.
        options.setPlayerOptionIntValue(0, forKey: "framedrop")
        options.setPlayerOptionIntValue(1, forKey: "packet-buffering")
        options.setPlayerOptionIntValue(32 * 1024 * 1024, forKey: "max-buffer-size")
        options.setPlayerOptionIntValue(0, forKey: "infbuf")
        // Let FFmpeg reconnect instead of failing when a flaky CDN
        // drops the HTTP connection.
        options.setFormatOptionIntValue(1, forKey: "reconnect")
        options.setFormatOptionIntValue(1, forKey: "reconnect_streamed")
        options.setFormatOptionIntValue(5, forKey: "reconnect_delay_max")
        // Fast open + fast failure on a dead line (Pure Live's probe /
        // buffer policy: 2 MiB probe, 2 s analyze, 15 s network
        // timeout; its cache is 30 s memory-only for VOD).
        options.setFormatOptionIntValue(2097152, forKey: "probesize")
        options.setFormatOptionIntValue(2000000, forKey: "analyzeduration")
        options.setFormatOptionIntValue(15000000, forKey: "timeout")
        // A CDN rejects FFmpeg's default UA (HTTP 403) but accepts
        // a browser UA (verified with ffprobe: default 403, browser
        // UA returns a valid playlist). Send a browser UA + Referer
        // so picky CDNs treat ijkplayer like a browser.
        if let ua = headers["User-Agent"] {
            options.setFormatOptionValue(ua, forKey: "user_agent")
        }
        if let referer = headers["Referer"] {
            options.setFormatOptionValue("Referer: \(referer)\r\n", forKey: "headers")
        }
        // HLS segments carry a query string (xxx.ts?EXTINF=2.7).
        // FFmpeg 4's HLS demuxer blocks segments whose "extension"
        // is not whitelisted — it reads the extension as
        // "ts?EXTINF=2.7", not "ts", so EVERY such segment is
        // refused and playback never starts. Allow all extensions —
        // segment URLs come from the platform's own playlist.
        options.setFormatOptionValue("ALL", forKey: "allowed_extensions")
        return options
    }

    // MARK: - Notifications -> events

    private func registerIJKNotifications(for p: IJKFFMoviePlayerController) {
        // NOTE: ijkplayer's notification names are `NSString *const`
        // globals. In this toolchain (Xcode 26 / Swift 6) they import
        // as `NSNotification.Name` values that CANNOT be referenced
        // by name — neither as a bare identifier, nor as a
        // `NSNotification.Name.<Name>` member (builds #13/#14/#15
        // each proved one of those forms fails). So build the names
        // from their raw strings instead. Verified against the
        // framework binary: each constant's runtime string value
        // equals its name, so these match the posted notifications.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(ijkLoadStateChanged), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerLoadStateDidChangeNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkPlaybackStateChanged), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerPlaybackStateDidChangeNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkPlaybackDidFinish), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerPlaybackDidFinishNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkPreparedToPlayChanged), name: NSNotification.Name(rawValue: "IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification"), object: p)
        nc.addObserver(self, selector: #selector(ijkFirstFrameRendered), name: NSNotification.Name(rawValue: "IJKMPMoviePlayerFirstVideoFrameRenderedNotification"), object: p)
    }

    private func emit(_ event: VideoBackendEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    @objc private func ijkLoadStateChanged(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.player, obj === p else { return }
            if p.loadState.contains(.stalled) {
                self.emit(.stalled)
            }
        }
    }

    @objc private func ijkPlaybackStateChanged(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.player, obj === p else { return }
            switch p.playbackState {
            case .playing:
                self.emit(.playing)
            case .paused, .interrupted:
                self.emit(.paused)
            case .stopped, .seekingForward, .seekingBackward:
                break
            @unknown default:
                break
            }
        }
    }

    @objc private func ijkPlaybackDidFinish(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.player, obj === p else { return }
            let reasonValue = (note.userInfo?[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue
            let reason = reasonValue.flatMap { IJKMPMovieFinishReason(rawValue: $0) }
            switch reason {
            case .playbackEnded:
                self.emit(.finished(.ended))
            case .playbackError:
                if !self.didEmitPrepared { self.finishOpen(false) }
                self.emit(.finished(.error))
            case .userExited, .none:
                break
            @unknown default:
                break
            }
        }
    }

    @objc private func ijkPreparedToPlayChanged(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.player, obj === p, p.isPreparedToPlay else { return }
            if !self.didEmitPrepared {
                self.didEmitPrepared = true
                self.emit(.prepared)
                self.finishOpen(true)
            }
            if !p.isPlaying() { p.play() }
        }
    }

    @objc private func ijkFirstFrameRendered(_ note: Notification) {
        guard let obj = note.object as? IJKFFMoviePlayerController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.player === obj else { return }
            if !self.didEmitFirstFrame {
                self.didEmitFirstFrame = true
                // Session verification: prepared + first frame
                // rendered means the VideoToolbox session is up and
                // producing frames. There is no public API to read
                // the session back, so this is assumed-hardware,
                // never verified — see the header.
                self.hardwareDecode = .assumedHardware(decoder: "videotoolbox")
                self.emit(.firstFrame)
                if let size = self.player?.naturalSize {
                    let w = size.width, h = size.height
                    if w > 0, h > 0 { self.onVideoSize?(CGSize(width: w, height: h)) }
                }
            }
        }
    }
}
