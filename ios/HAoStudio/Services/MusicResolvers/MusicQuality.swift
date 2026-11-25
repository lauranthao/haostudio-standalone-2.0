// MusicQuality.swift
// Audio-quality mappings and the Master honesty gate.
//
// Codes: the Swift `AudioQuality` cases (contract in
// `PlaybackCoordinator.swift`) map to LX/API codes as follows —
// master->`master`, hiRes->`hires`, flac->`lossless`,
// high320->`320k`, standard128->`128k`. The downgrade chain is
// best-first: `[master, hiRes, flac, high320, standard128]`.
//
// Master honesty gate (Flutter `music_quality.dart` parity):
// only a resolver/script/API that genuinely served Master may
// label its result Master. A lower-tier URL plays immediately as a
// drop-down — it is never labelled Master, and the target tier
// persists to the next track.

import Foundation

extension AudioQuality {
    /// LX / platform-API quality code for this tier.
    var lxCode: String {
        switch self {
        case .master: return "master"
        case .hiRes: return "hires"
        case .flac: return "lossless"
        case .high320: return "320k"
        case .standard128: return "128k"
        }
    }

    /// The quality parameter most direct APIs take. Master maps to
    /// each API's best known parameter — never to a parameter the API
    /// does not understand, never to a low tier. Only the LX APIs
    /// (zddyr/xinghai) get a literal `master` (see `lxCode`).
    var srcCode: String {
        switch self {
        case .master, .hiRes, .flac: return "flac"
        case .high320: return "320k"
        case .standard128: return "128k"
        }
    }

    /// NetEase song-level parameter.
    var songLevel: String {
        switch self {
        case .master, .hiRes, .flac: return "lossless"
        case .high320: return "exhigh"
        case .standard128: return "standard"
        }
    }

    /// Downgrade chain from the requested tier, best first.
    /// `qualityChainFrom(.master)` is the full chain.
    static func chain(from requested: AudioQuality) -> [AudioQuality] {
        let all: [AudioQuality] = [.master, .hiRes, .flac, .high320, .standard128]
        guard let index = all.firstIndex(of: requested) else { return all }
        return Array(all[index...])
    }

    /// Rank for candidate comparison (higher is better).
    var rank: Int {
        switch self {
        case .master: return 5
        case .hiRes: return 4
        case .flac: return 3
        case .high320: return 2
        case .standard128: return 1
        }
    }
}

enum MusicQualityGate {
    /// Pick the quality string to ask an LX script for, given the
    /// qualities that script declares for the platform. Nil when the
    /// script cannot serve the requested tier at all (the caller then
    /// skips the script; the resolver chain downgrades).
    /// - master: only a literal `master` counts — never substitute hires.
    /// - hiRes: `hires`, else `flac24bit`, else `flac`.
    /// - flac: `flac`, else `flac24bit`.
    /// - 320k/128k: literal only.
    static func lxQualityForScript(_ quality: AudioQuality, available: [String]) -> String? {
        switch quality {
        case .master:
            return available.contains("master") ? "master" : nil
        case .hiRes:
            if available.contains("hires") { return "hires" }
            if available.contains("flac24bit") { return "flac24bit" }
            if available.contains("flac") { return "flac" }
            return nil
        case .flac:
            if available.contains("flac") { return "flac" }
            if available.contains("flac24bit") { return "flac24bit" }
            return nil
        case .high320:
            return available.contains("320k") ? "320k" : nil
        case .standard128:
            return available.contains("128k") ? "128k" : nil
        }
    }

    /// What a resolver ACTUALLY returns at the requested tier (the
    /// declared label, used when the resolver reports no tier).
    /// Master gate: only `zddyr` and `xinghai` (LX APIs with a
    /// verified real Master path) may claim Master. Every other
    /// resolver — including LX scripts (`lx:*`) — caps at hires: a
    /// script that returns a bare URL string carries no tier signal.
    /// A script keeps Master ONLY when it returns a
    /// `{url, quality: 'master'}` map (see `reportedTierFor`).
    static func declaredTier(resolverKey: String, requested: AudioQuality) -> AudioQuality {
        guard requested == .master else { return requested }
        switch resolverKey {
        case "zddyr", "xinghai":
            return .master
        default:
            return .hiRes
        }
    }

    /// Pure tier check for a script-reported tier string: at a master
    /// request, only a literal `master` report keeps master; any
    /// other report is hires. Other requests keep the declared label
    /// (nil = no override).
    static func reportedTierFor(reported: String?, requested: AudioQuality) -> AudioQuality? {
        guard requested == .master, let reported = reported else { return nil }
        return reported == "master" ? .master : .hiRes
    }

    /// LX-API served-tier check (zddyr/xinghai response): only
    /// `quality == 'master'` with no `quality_fallback` keeps the
    /// master label at a master request; anything the API actually
    /// served is hires (its best fallback tier). Other tiers carry
    /// no verifiable signal, so they keep the declared label (nil).
    static func lxApiServedTier(response: [String: Any], requested: AudioQuality) -> AudioQuality? {
        guard requested == .master else { return nil }
        let servedMaster = (response["quality"] as? String) == "master"
            && (response["quality_fallback"] as? Bool) != true
        return servedMaster ? .master : .hiRes
    }
}

// MARK: - b45-F: honesty verification (plan §7.2, Coda AudioQualityCheck)

// Server labels are not trusted: any lossless / hires claim is
// re-tiered from a `Range: bytes=0-41` FLAC header read
// (STREAMINFO sample rate / bit depth: >48 kHz or >16 bit =
// hires, otherwise lossless), a lossy encoding claiming
// lossless is downgraded by bitrate, and only a real complete
// Master address ever keeps the Master label. Pure Foundation,
// no network: the caller fetches the 42 header bytes.
enum AudioQualityCheck {
    /// Minimum header bytes for a FLAC STREAMINFO read
    /// (`Range: bytes=0-41`).
    static let flacHeaderLength = 42

    /// STREAMINFO sample rate / bit depth parsed from the first
    /// 42 bytes of a FLAC stream. Nil when the bytes are not a
    /// FLAC stream (no `fLaC` magic or a short / non-STREAMINFO
    /// first block).
    ///
    /// Layout: `fLaC` (4) + block header (1: last-flag + type 0,
    /// 3: length 34) + STREAMINFO (34): min/max blocksize (2+2),
    /// min/max framesize (3+3), then 8 bytes holding sample rate
    /// (20 bits), channels-1 (3), bits-per-sample-1 (5), total
    /// samples (36).
    static func flacStreamInfo(_ header: Data) -> (sampleRateHz: Int, bitsPerSample: Int)? {
        guard header.count >= flacHeaderLength else { return nil }
        guard header[0] == 0x66, header[1] == 0x4C, header[2] == 0x61, header[3] == 0x43 else {
            return nil // not "fLaC"
        }
        guard (header[4] & 0x7F) == 0 else { return nil } // first block must be STREAMINFO
        guard header[5] == 0, header[6] == 0, header[7] == 34 else { return nil }
        let b18 = Int(header[18]), b19 = Int(header[19]), b20 = Int(header[20]), b21 = Int(header[21])
        let sampleRate = (b18 << 12) | (b19 << 4) | (b20 >> 4)
        let bitsPerSample = (((b20 & 0x01) << 4) | (b21 >> 4)) + 1
        guard sampleRate > 0, bitsPerSample > 0 else { return nil }
        return (sampleRate, bitsPerSample)
    }

    /// Tier implied by a FLAC STREAMINFO header alone:
    /// >48 kHz or >16 bit = hires, otherwise lossless.
    static func tierFromFLACHeader(_ header: Data) -> AudioQuality? {
        guard let info = flacStreamInfo(header) else { return nil }
        if info.sampleRateHz > 48_000 || info.bitsPerSample > 16 { return .hiRes }
        return .flac
    }

    /// Tier from a server claim, before any header check. A `level`
    /// field wins; otherwise the container type (flac/alac/wav/ape
    /// = lossless) or the bitrate (<=128k standard, <=192k /
    /// <=320k high320 — our five-tier model has no separate
    /// "higher" case, so exhigh swallows higher here too, see
    /// `dedupTierName`).
    static func tierForClaim(level: String?, type: String?, bitrateKbps: Int?) -> AudioQuality {
        if let level = level?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            switch level {
            case "master": return .master
            case "hires", "hi-res", "hi_res", "flac24bit", "flac24": return .hiRes
            case "lossless", "flac": return .flac
            case "exhigh": return .high320
            case "higher": return .high320
            case "standard": return .standard128
            default: break
            }
        }
        if let type = type?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            switch type {
            case "flac", "alac", "wav", "ape": return .flac
            case "mp3", "aac", "m4a", "ogg", "opus": break // lossy: fall through to bitrate
            default: break
            }
        }
        return tierForBitrate(bitrateKbps)
    }

    /// Bitrate-only tier. Nil / unknown bitrate keeps the
    /// caller's declared tier (the caller passes its fallback);
    /// a known bitrate caps a lossy claim at its real tier.
    static func tierForBitrate(_ kbps: Int?) -> AudioQuality {
        guard let kbps = kbps, kbps > 0 else { return .high320 }
        if kbps <= 128 { return .standard128 }
        if kbps <= 320 { return .high320 }
        return .flac // >320 kbps with no type signal: best lossy-adjacent claim
    }

    /// Re-tier a claimed lossless / hires / Master tier against
    /// the fetched header bytes and the measured bitrate.
    /// - A valid FLAC header re-tiers to hires / lossless from
    ///   STREAMINFO. A Master claim keeps Master ONLY when
    ///   `masterVerified` (a real complete Master address was
    ///   served — a FLAC header alone cannot prove Master).
    /// - A non-FLAC header on a lossless claim means a lossy
    ///   encoding posing as lossless: downgrade by bitrate.
    /// - No header at all: keep the claim (the caller could not
    ///   fetch it — e.g. the host rejects Range); the claim is
    ///   unverified, never upgraded.
    static func reTierClaimedLossless(
        header: Data?,
        bitrateKbps: Int?,
        claimed: AudioQuality,
        masterVerified: Bool = false
    ) -> AudioQuality {
        guard claimed == .master || claimed == .hiRes || claimed == .flac else { return claimed }
        guard let header = header else { return claimed }
        if let headerTier = tierFromFLACHeader(header) {
            if claimed == .master, masterVerified { return .master }
            // A FLAC header proves lossless at most: Master without
            // a verified Master address demotes to the header tier.
            return headerTier
        }
        // Not FLAC at all: lossy bytes claiming lossless.
        return tierForBitrate(bitrateKbps)
    }

    /// Estimated bitrate from served size / duration (the LX-mirror
    /// check: size / duration). Nil when either input is missing
    /// or non-positive.
    static func estimatedBitrateKbps(byteCount: Int64, durationSeconds: Double) -> Int? {
        guard byteCount > 0, durationSeconds > 0 else { return nil }
        return Int((Double(byteCount) * 8.0 / durationSeconds) / 1000.0)
    }

    /// Preview / placeholder floor (plan §7.5): a resolved stream
    /// under 96 kbps is a preview or placeholder, not a playable
    /// tier — discard it.
    static func isBelowPreviewFloor(bitrateKbps: Int?) -> Bool {
        guard let kbps = bitrateKbps else { return false }
        return kbps < 96
    }

    /// Unified menu title: "标准 / 高品质 / 无损 / 高解析度无损
    /// + 码率", estimated values prefixed with "约". The Master
    /// title is only used for a verified Master address.
    static func menuTitle(for tier: AudioQuality, estimatedBitrateKbps: Int?, estimated: Bool = true) -> String {
        let base: String
        switch tier {
        case .master: base = "Master"
        case .hiRes: base = "高解析度无损"
        case .flac: base = "无损"
        case .high320: base = "高品质"
        case .standard128: base = "标准"
        }
        guard let kbps = estimatedBitrateKbps, kbps > 0 else { return base }
        return "\(base) · \(estimated ? "约 " : "")\(kbps)kbps"
    }

    /// Dedup key for a claimed tier string: exhigh swallows
    /// higher, so a 192k "higher" claim and a 320k "exhigh"
    /// claim dedupe to the same tier.
    static func dedupTierName(forClaim claim: String?) -> String {
        guard let claim = claim?.lowercased() else { return AudioQuality.high320.rawValue }
        if claim == "higher" || claim == "exhigh" { return AudioQuality.high320.rawValue }
        return claim
    }
}
