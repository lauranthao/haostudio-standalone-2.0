// MusicTrack.swift
// One track, as the music UI leg and the player leg both use it.
// `sourceID` is the platform code (`wy`/`tx`/`kg`/`kw`/`mg`);
// `id` is the platform song id. The resolver derives its
// `platform|songId` identity from these two fields (the Flutter
// `identityKey` convention).

import Foundation

/// Music platform codes, shared by search, resolvers and the LX engine.
/// `mg` (Migu) is resolver-only: no mg search exists (Flutter music_models.dart).
enum MusicPlatform: String, CaseIterable {
    case wy
    case tx
    case kg
    case kw
    case mg

    init?(code: String) {
        self.init(rawValue: code)
    }

    /// Map a code to a platform, defaulting to wy for unknown codes
    /// (Flutter fromCode behaviour). ORDERING / IDENTITY ONLY: this
    /// default must never drive the platform badge — an unknown
    /// code (notably an LX script id, `lx:…`) is NOT NetEase. Use
    /// platformIfKnown for anything the user sees.
    static func fromCode(_ code: String?) -> MusicPlatform {
        switch code {
        case "tx": return .tx
        case "kg": return .kg
        case "kw": return .kw
        case "mg": return .mg
        case "wy": fallthrough
        default: return .wy
        }
    }

    /// The platform a source id REALLY names, or nil when it names
    /// none. Known platform codes map directly; an LX script id
    /// (`lx:…`) has no platform signal, so it maps to nil — the
    /// badge is then hidden instead of lying about NetEase.
    static func platformIfKnown(_ sourceID: String?) -> MusicPlatform? {
        guard let code = sourceID, !code.isEmpty else { return nil }
        if code.hasPrefix("lx:") { return nil }
        switch code {
        case "tx": return .tx
        case "kg": return .kg
        case "kw": return .kw
        case "mg": return .mg
        case "wy": return .wy
        default: return nil
        }
    }

    /// Map an LX/search `sourceID` to a platform for ordering.
    /// Known platform codes map directly; an LX script id (e.g.
    /// "lx:…") has no platform signal, so it falls back to wy —
    /// ORDERING ONLY, never the badge (see platformIfKnown).
    static func fromSourceID(_ sourceID: String?) -> MusicPlatform {
        return fromCode(sourceID)
    }

    /// Short badge shown on song rows (Flutter badgeName).
    var badgeName: String {
        switch self {
        case .wy: return "网易"
        case .tx: return "QQ"
        case .kg: return "酷狗"
        case .kw: return "酷我"
        case .mg: return "咪咕"
        }
    }

    var displayName: String {
        switch self {
        case .wy: return "网易云"
        case .tx: return "QQ音乐"
        case .kg: return "酷狗音乐"
        case .kw: return "酷我"
        case .mg: return "咪咕"
        }
    }

    /// Search merge order wy/tx/kg/kw (Flutter kSearchPlatforms).
    var searchPriority: Int {
        switch self {
        case .wy: return 0
        case .tx: return 1
        case .kg: return 2
        case .kw: return 3
        case .mg: return 4
        }
    }
}

struct MusicTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let coverURL: URL?
    let duration: TimeInterval?
    /// Platform code: `wy` / `tx` / `kg` / `kw` / `mg`.
    let sourceID: String
    /// Search-time VIP-only flag (build 36 item 3): NetEase
    /// `fee != 0` / `privilege` `none`, QQ `pay.payplay` — the
    /// track is trial-only for a no-login client. Only ever
    /// tightens preview detection; never skips a source by itself.
    let trialOnly: Bool

    var platform: MusicPlatform? { MusicPlatform(code: sourceID) }

    /// The platform this track really came from, when known.
    /// Script (LX) results carry the platform the script searched
    /// (trackFromScriptMap stamps it); a bare `lx:…` source id
    /// carries no platform signal and yields nil here — the row
    /// badge hides instead of showing 网易 for a script result.
    var displayPlatform: MusicPlatform? {
        MusicPlatform.platformIfKnown(sourceID)
    }

    /// Resolver identity: `platform|songId` (Flutter `identityKey`).
    /// A track with an empty song id falls back to title+artist so
    /// it still has a stable identity for cache keys.
    var identityKey: String {
        if id.isEmpty { return "\(sourceID)|\(title)|\(artist)" }
        return "\(sourceID)|\(id)"
    }

    /// Dedupe key for search results: platform+songId, or title+artist
    /// when the id is empty (Flutter `dedupeKey`).
    var dedupeKey: String {
        if id.isEmpty { return "\(sourceID)|\(title)|\(artist)" }
        return "\(sourceID)|\(id)"
    }

    init(id: String, title: String, artist: String, album: String = "",
         coverURL: URL? = nil, duration: TimeInterval? = nil,
         sourceID: String, trialOnly: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.coverURL = coverURL
        self.duration = duration
        self.sourceID = sourceID
        self.trialOnly = trialOnly
    }
}
