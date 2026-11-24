// HAo Studio 2.0 — live danmaku settings (S4 leg B).
//
// Foundation-only value type for the C leg's settings UI. Fields
// follow the Flutter danmaku settings page
// (`lib/features/settings/danmaku_settings_page.dart` +
// `DanmakuSettings` in `lib/features/settings/source_stores.dart`)
// one by one, with the same defaults and clamps. The dictionary
// keys are the Flutter Hive keys (`hao_danmaku_*`) — key names are
// the persistence contract (plan section 5.4), so they are kept
// verbatim here and in the C leg's store.
//
// Count note: the brief says 14 items; the Flutter page as shipped
// (build 31) actually carries 19 scalar settings plus the
// per-platform switch map and the block list. All 19 are ported
// rather than silently dropping five, and the block list rides in
// this struct too (merged at S4: the C leg's sheet and list view
// both read it off `settings`, so one settings object owns one
// persistence path — the Flutter `DanmakuBlockStore` is the same
// list, key `hao_dm_block`).
//
// Swift 5.0: Foundation only, no async/await, no `any`.

import Foundation

/// One blocked keyword / username (Flutter `DanmakuBlockEntry`:
/// `{id, text, kind}` with kind 'word' | 'user'). Decodes both the
/// Flutter shape (`kind`) and the plain shape (`isUser`) so a stored
/// value from either side loads; encodes the Flutter shape, so S1's
/// migrated `hao_dm_block` file keeps round-tripping.
struct LiveDanmakuBlockEntry: Identifiable, Equatable, Codable {
    let id: String
    let text: String
    let isUser: Bool

    init(id: String, text: String, isUser: Bool) {
        self.id = id
        self.text = text
        self.isUser = isUser
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case kind
        case isUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        if let kind = try? container.decode(String.self, forKey: .kind) {
            isUser = kind == "user"
        } else {
            isUser = (try? container.decode(Bool.self, forKey: .isUser)) ?? false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(isUser ? "user" : "word", forKey: .kind)
    }
}

/// Danmaku display + filtering settings. Every numeric field
/// clamps into its Flutter range on init and on dictionary load;
/// a wrong-typed stored value falls back to the default (the
/// Flutter page crashed on this in build 30 — never throw here).
struct LiveDanmakuSettings {
    // MARK: - Keys (Flutter Hive keys, verbatim)

    static let keyEnabled = "hao_danmaku_enabled"
    static let keyFontSize = "hao_danmaku_font_size"
    static let keyOpacity = "hao_danmaku_opacity"
    static let keyArea = "hao_danmaku_area"
    static let keyStroke = "hao_danmaku_stroke"
    static let keyStrokeWidth = "hao_danmaku_stroke_width"
    static let keySpeed = "hao_danmaku_speed"
    static let keyMaxCount = "hao_danmaku_max_count"
    static let keyColorMode = "hao_danmaku_color_mode"
    static let keyOcclusionAvoidance = "hao_danmaku_occlusion_avoidance"
    static let keyListStyle = "hao_danmaku_list_style"
    static let keyListSpacing = "hao_danmaku_list_spacing"
    static let keyShowUsernames = "hao_danmaku_show_names"
    static let keySimilarityEnabled = "hao_danmaku_similarity"
    static let keySimilarityThreshold = "hao_danmaku_similarity_threshold"
    static let keyBlockEmoteOnly = "hao_danmaku_block_emote"
    static let keyBlockLong = "hao_danmaku_block_long"
    static let keyBlockLongLength = "hao_danmaku_block_long_len"
    static let keyDouyuBotFilter = "hao_danmaku_douyu_bot"
    /// Block list key (Flutter `HiveKeys.danmakuBlockList`).
    static let keyBlockedEntries = "hao_dm_block"

    /// The VOD ("影视弹幕") key inside the enabled map. Unlike the
    /// live platforms it defaults to OFF (opt-in): VOD danmaku comes
    /// from a title guess, so a wrong guess would float another
    /// show's spoilers over the picture.
    static let vodSiteId = "vod"

    // MARK: - Ranges (Flutter defaults)

    static let defaultFontSize: Double = 14
    static let minFontSize: Double = 12
    static let maxFontSize: Double = 20

    static let defaultOpacity: Double = 1.0
    static let minOpacity: Double = 0.3
    static let maxOpacity: Double = 1.0

    static let defaultStroke: Bool = true
    static let defaultStrokeWidth: Double = 1.0
    static let minStrokeWidth: Double = 0.5
    static let maxStrokeWidth: Double = 2.0

    static let defaultSpeed: Double = 1.0
    static let minSpeed: Double = 0.5
    static let maxSpeed: Double = 2.0

    static let defaultMaxCount: Int = 80
    static let minMaxCount: Int = 20
    static let maxMaxCount: Int = 200

    /// Flying-danmaku engine object-pool ceiling: the fullscreen
    /// flying side never shows more than this many items at once,
    /// however high `maxCount` is set.
    static let enginePoolMaxSize: Int = 72

    static let defaultSimilarityThreshold: Int = 85
    static let minSimilarityThreshold: Int = 0
    static let maxSimilarityThreshold: Int = 100

    static let defaultBlockLongLength: Int = 30
    static let minBlockLongLength: Int = 10
    static let maxBlockLongLength: Int = 100

    /// Area fractions for the fullscreen flying danmaku only (the
    /// portrait list is a chat list, not an overlay — area never
    /// moves it).
    static let areaFractions: [String: Double] = [
        "full": 1.0,
        "half": 0.5,
        "third": 1.0 / 3.0,
        "fifth": 1.0 / 5.0
    ]

    // MARK: - Fields (19 scalars + the per-platform switch map)

    /// Per-platform on/off, keyed by `LivePlatform.flutterSiteId`
    /// (the Flutter site ids — `bilibili`, `kuaishou`, … — NOT
    /// `LivePlatform.rawValue`, which is the player-kernel id
    /// `bili`/`ks`). The map is migrated verbatim from the Flutter
    /// Hive box by S1, so the keys must stay Flutter-shaped.
    /// An absent entry means enabled, except `vod` which is
    /// absent = disabled.
    var enabled: [String: Bool]

    /// Chat-list + flying font size, 12...20, default 14.
    var fontSize: Double
    /// Danmaku opacity, 0.3...1.0, default 1.0.
    var opacity: Double
    /// Flying-danmaku area, fullscreen only: full / half / third /
    /// fifth, default full.
    var area: String
    /// Flying-danmaku stroke on/off, default true. Fullscreen
    /// flying only.
    var stroke: Bool
    /// Flying-danmaku stroke width, 0.5...2.0, default 1.0.
    /// Fullscreen flying only; stroke colour is fixed black.
    var strokeWidth: Double
    /// Flying-danmaku speed multiplier, 0.5...2.0, default 1.0.
    /// Fullscreen flying only; this is NOT playback rate.
    var speed: Double
    /// Maximum danmaku count, 20...200, default 80. Caps the
    /// portrait list AND the flying side (flying additionally
    /// clamped to `enginePoolMaxSize`).
    var maxCount: Int
    /// Flying colour mode: uniform (default — theme text in the
    /// list, white flying danmaku) or platform (the platform's own
    /// colour, where the transport provides one).
    var colorMode: String
    /// Danmaku occlusion avoidance (MPV only), default off.
    /// 防遮挡未实现：Swift 2.0 无 MPV 取帧接口与 Vision 分割管线；字段保留只为与 Flutter 配置兼容，不上 UI。
    var occlusionAvoidance: Bool
    /// Chat-list style: compact (one line per message, default) or
    /// card (one card per message).
    var listStyle: String
    /// Chat-list line spacing: compact / standard (default) / loose.
    var listSpacing: String
    /// Show the sender name in the chat list, default true.
    var showUsernames: Bool
    /// Similarity filter on/off, default true (this app defaults
    /// it on; Pure Live defaults it off).
    var similarityEnabled: Bool
    /// Similarity threshold, 0...100, default 85. Higher is
    /// stricter (only blocks more-similar messages).
    var similarityThreshold: Int
    /// Hide pure-emoji danmaku, default false.
    var blockEmoteOnly: Bool
    /// Hide overlong danmaku, default false.
    var blockLong: Bool
    /// Overlong threshold in characters, 10...100, default 30.
    var blockLongLength: Int
    /// Douyu suspected-automated-message filter, default false.
    /// Douyu only.
    var douyuBotFilter: Bool

    /// Blocked keywords / usernames. Persisted with the rest of
    /// the settings (collection file `hao_dm_block`, Flutter shape
    /// `{id, text, kind}`) — the sheet edits it, the list view
    /// filters on it.
    var blockedEntries: [LiveDanmakuBlockEntry]

    // MARK: - Defaults

    static let `default` = LiveDanmakuSettings()

    init(
        enabled: [String: Bool] = [:],
        fontSize: Double = defaultFontSize,
        opacity: Double = defaultOpacity,
        area: String = "full",
        stroke: Bool = defaultStroke,
        strokeWidth: Double = defaultStrokeWidth,
        speed: Double = defaultSpeed,
        maxCount: Int = defaultMaxCount,
        colorMode: String = "uniform",
        occlusionAvoidance: Bool = false,
        listStyle: String = "compact",
        listSpacing: String = "standard",
        showUsernames: Bool = true,
        similarityEnabled: Bool = true,
        similarityThreshold: Int = defaultSimilarityThreshold,
        blockEmoteOnly: Bool = false,
        blockLong: Bool = false,
        blockLongLength: Int = defaultBlockLongLength,
        douyuBotFilter: Bool = false,
        blockedEntries: [LiveDanmakuBlockEntry] = []
    ) {
        self.enabled = enabled
        self.fontSize = LiveDanmakuSettings.clamp(fontSize, min: LiveDanmakuSettings.minFontSize, max: LiveDanmakuSettings.maxFontSize)
        self.opacity = LiveDanmakuSettings.clamp(opacity, min: LiveDanmakuSettings.minOpacity, max: LiveDanmakuSettings.maxOpacity)
        self.area = LiveDanmakuSettings.areaFractions[area] != nil ? area : "full"
        self.stroke = stroke
        self.strokeWidth = LiveDanmakuSettings.clamp(strokeWidth, min: LiveDanmakuSettings.minStrokeWidth, max: LiveDanmakuSettings.maxStrokeWidth)
        self.speed = LiveDanmakuSettings.clamp(speed, min: LiveDanmakuSettings.minSpeed, max: LiveDanmakuSettings.maxSpeed)
        self.maxCount = LiveDanmakuSettings.clamp(maxCount, min: LiveDanmakuSettings.minMaxCount, max: LiveDanmakuSettings.maxMaxCount)
        self.colorMode = colorMode == "platform" ? "platform" : "uniform"
        self.occlusionAvoidance = occlusionAvoidance
        self.listStyle = listStyle == "card" ? "card" : "compact"
        self.listSpacing = (listSpacing == "compact" || listSpacing == "loose") ? listSpacing : "standard"
        self.showUsernames = showUsernames
        self.similarityEnabled = similarityEnabled
        self.similarityThreshold = LiveDanmakuSettings.clamp(similarityThreshold, min: LiveDanmakuSettings.minSimilarityThreshold, max: LiveDanmakuSettings.maxSimilarityThreshold)
        self.blockEmoteOnly = blockEmoteOnly
        self.blockLong = blockLong
        self.blockLongLength = LiveDanmakuSettings.clamp(blockLongLength, min: LiveDanmakuSettings.minBlockLongLength, max: LiveDanmakuSettings.maxBlockLongLength)
        self.douyuBotFilter = douyuBotFilter
        self.blockedEntries = blockedEntries
    }

    // MARK: - Derived

    /// Whether danmaku is enabled for a platform id (absent =
    /// enabled, except `vod` which is absent = disabled).
    func isEnabled(_ siteId: String) -> Bool {
        if let value = enabled[siteId] {
            return value
        }
        return siteId != LiveDanmakuSettings.vodSiteId
    }

    /// Platform convenience for `isEnabled(_:)`: keys the map by
    /// the platform's Flutter site id, so callers never have to
    /// remember which id shape the map uses.
    func isEnabled(for platform: LivePlatform) -> Bool {
        isEnabled(platform.flutterSiteId)
    }

    mutating func setEnabled(_ value: Bool, for platform: LivePlatform) {
        enabled[platform.flutterSiteId] = value
    }

    /// Flying-danmaku area as a fraction of the video height.
    var areaFraction: Double {
        LiveDanmakuSettings.areaFractions[area] ?? 1.0
    }

    /// Flying-danmaku base speed in px/s (engine default 120 px/s
    /// at speed 1.0).
    var flyingBaseSpeed: Double {
        120.0 * speed
    }

    /// Flying-danmaku visible cap: `maxCount` clamped to the
    /// engine pool ceiling.
    var flyingMaxVisibleCount: Int {
        min(max(maxCount, LiveDanmakuSettings.minMaxCount), LiveDanmakuSettings.enginePoolMaxSize)
    }

    /// Flying-danmaku crossing time in seconds at the current
    /// `speed` (base 8 s at speed 1.0 — VOD parity). The overlay
    /// and its per-row removal timer both use this one value, so
    /// a row is never removed before it lands. The model clamps
    /// speed to 0.5...2.0; the `max` guards a stale stored value
    /// all the same.
    var flyingDuration: Double {
        8.0 / max(speed, 0.5)
    }

    // MARK: - Persistence (tolerant dictionary round-trip)

    /// Load from a stored dictionary. Unknown / wrong-typed /
    /// out-of-range values fall back to defaults, never throw.
    init(dictionary: [String: Any]) {
        var enabledMap: [String: Bool] = [:]
        if let raw = dictionary[LiveDanmakuSettings.keyEnabled] as? [String: Bool] {
            enabledMap = raw
        } else if let rawString = dictionary[LiveDanmakuSettings.keyEnabled] as? String,
                  let data = rawString.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Bool] {
            enabledMap = decoded
        }
        self.init(
            enabled: enabledMap,
            fontSize: LiveDanmakuSettings.doubleValue(dictionary[LiveDanmakuSettings.keyFontSize]) ?? LiveDanmakuSettings.defaultFontSize,
            opacity: LiveDanmakuSettings.doubleValue(dictionary[LiveDanmakuSettings.keyOpacity]) ?? LiveDanmakuSettings.defaultOpacity,
            area: LiveDanmakuSettings.stringValue(dictionary[LiveDanmakuSettings.keyArea]) ?? "full",
            stroke: LiveDanmakuSettings.boolValue(dictionary[LiveDanmakuSettings.keyStroke]) ?? LiveDanmakuSettings.defaultStroke,
            strokeWidth: LiveDanmakuSettings.doubleValue(dictionary[LiveDanmakuSettings.keyStrokeWidth]) ?? LiveDanmakuSettings.defaultStrokeWidth,
            speed: LiveDanmakuSettings.doubleValue(dictionary[LiveDanmakuSettings.keySpeed]) ?? LiveDanmakuSettings.defaultSpeed,
            maxCount: LiveDanmakuSettings.intValue(dictionary[LiveDanmakuSettings.keyMaxCount]) ?? LiveDanmakuSettings.defaultMaxCount,
            colorMode: LiveDanmakuSettings.stringValue(dictionary[LiveDanmakuSettings.keyColorMode]) ?? "uniform",
            occlusionAvoidance: LiveDanmakuSettings.boolValue(dictionary[LiveDanmakuSettings.keyOcclusionAvoidance]) ?? false,
            listStyle: LiveDanmakuSettings.stringValue(dictionary[LiveDanmakuSettings.keyListStyle]) ?? "compact",
            listSpacing: LiveDanmakuSettings.stringValue(dictionary[LiveDanmakuSettings.keyListSpacing]) ?? "standard",
            showUsernames: LiveDanmakuSettings.boolValue(dictionary[LiveDanmakuSettings.keyShowUsernames]) ?? true,
            similarityEnabled: LiveDanmakuSettings.boolValue(dictionary[LiveDanmakuSettings.keySimilarityEnabled]) ?? true,
            similarityThreshold: LiveDanmakuSettings.intValue(dictionary[LiveDanmakuSettings.keySimilarityThreshold]) ?? LiveDanmakuSettings.defaultSimilarityThreshold,
            blockEmoteOnly: LiveDanmakuSettings.boolValue(dictionary[LiveDanmakuSettings.keyBlockEmoteOnly]) ?? false,
            blockLong: LiveDanmakuSettings.boolValue(dictionary[LiveDanmakuSettings.keyBlockLong]) ?? false,
            blockLongLength: LiveDanmakuSettings.intValue(dictionary[LiveDanmakuSettings.keyBlockLongLength]) ?? LiveDanmakuSettings.defaultBlockLongLength,
            douyuBotFilter: LiveDanmakuSettings.boolValue(dictionary[LiveDanmakuSettings.keyDouyuBotFilter]) ?? false,
            blockedEntries: LiveDanmakuSettings.blockedEntries(from: dictionary[LiveDanmakuSettings.keyBlockedEntries])
        )
    }

    /// Parse a stored block list: an array of entry dicts (the
    /// `dictionary()` shape), or a JSON string of such an array
    /// (the Flutter `DanmakuBlockStore` shape). Anything else is
    /// an empty list, never a throw.
    static func blockedEntries(from value: Any?) -> [LiveDanmakuBlockEntry] {
        if let list = value as? [[String: Any]] {
            return decodeBlockEntries(list)
        }
        if let jsonString = value as? String,
           let data = jsonString.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
            return decodeBlockEntries(decoded)
        }
        return []
    }

    private static func decodeBlockEntries(_ list: [[String: Any]]) -> [LiveDanmakuBlockEntry] {
        return list.compactMap { dict in
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            let id = dict["id"] as? String ?? ""
            let isUser: Bool
            if let kind = dict["kind"] as? String {
                isUser = kind == "user"
            } else {
                isUser = dict["isUser"] as? Bool ?? false
            }
            return LiveDanmakuBlockEntry(id: id, text: text, isUser: isUser)
        }
    }

    /// Store as a dictionary under the Flutter Hive keys.
    func dictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict[LiveDanmakuSettings.keyEnabled] = enabled
        dict[LiveDanmakuSettings.keyFontSize] = fontSize
        dict[LiveDanmakuSettings.keyOpacity] = opacity
        dict[LiveDanmakuSettings.keyArea] = area
        dict[LiveDanmakuSettings.keyStroke] = stroke
        dict[LiveDanmakuSettings.keyStrokeWidth] = strokeWidth
        dict[LiveDanmakuSettings.keySpeed] = speed
        dict[LiveDanmakuSettings.keyMaxCount] = maxCount
        dict[LiveDanmakuSettings.keyColorMode] = colorMode
        dict[LiveDanmakuSettings.keyOcclusionAvoidance] = occlusionAvoidance
        dict[LiveDanmakuSettings.keyListStyle] = listStyle
        dict[LiveDanmakuSettings.keyListSpacing] = listSpacing
        dict[LiveDanmakuSettings.keyShowUsernames] = showUsernames
        dict[LiveDanmakuSettings.keySimilarityEnabled] = similarityEnabled
        dict[LiveDanmakuSettings.keySimilarityThreshold] = similarityThreshold
        dict[LiveDanmakuSettings.keyBlockEmoteOnly] = blockEmoteOnly
        dict[LiveDanmakuSettings.keyBlockLong] = blockLong
        dict[LiveDanmakuSettings.keyBlockLongLength] = blockLongLength
        dict[LiveDanmakuSettings.keyDouyuBotFilter] = douyuBotFilter
        dict[LiveDanmakuSettings.keyBlockedEntries] = blockedEntries.map { entry in
            ["id": entry.id, "text": entry.text, "kind": entry.isUser ? "user" : "word"]
        }
        return dict
    }

    // MARK: - Persistence (S1 destinations)

    /// Load from the S1-migrated stores: scalars from UserDefaults
    /// under their `hao_danmaku_*` keys, the enabled map from the
    /// `hao_danmaku_enabled` collection file, the block list from
    /// the `hao_dm_block` collection file. Missing values fall back
    /// to defaults — a fresh install has nothing stored yet.
    static func load(defaults: UserDefaults = .standard) -> LiveDanmakuSettings {
        let enabled: [String: Bool] = LocalStore.loadCollection(named: keyEnabled, default: [:])
        return LiveDanmakuSettings(
            enabled: enabled,
            fontSize: (defaults.object(forKey: keyFontSize) as? Double) ?? defaultFontSize,
            opacity: (defaults.object(forKey: keyOpacity) as? Double) ?? defaultOpacity,
            area: (defaults.object(forKey: keyArea) as? String) ?? "full",
            stroke: (defaults.object(forKey: keyStroke) as? Bool) ?? defaultStroke,
            strokeWidth: (defaults.object(forKey: keyStrokeWidth) as? Double) ?? defaultStrokeWidth,
            speed: (defaults.object(forKey: keySpeed) as? Double) ?? defaultSpeed,
            maxCount: (defaults.object(forKey: keyMaxCount) as? Int) ?? defaultMaxCount,
            colorMode: (defaults.object(forKey: keyColorMode) as? String) ?? "uniform",
            occlusionAvoidance: (defaults.object(forKey: keyOcclusionAvoidance) as? Bool) ?? false,
            listStyle: (defaults.object(forKey: keyListStyle) as? String) ?? "compact",
            listSpacing: (defaults.object(forKey: keyListSpacing) as? String) ?? "standard",
            showUsernames: (defaults.object(forKey: keyShowUsernames) as? Bool) ?? true,
            similarityEnabled: (defaults.object(forKey: keySimilarityEnabled) as? Bool) ?? true,
            similarityThreshold: (defaults.object(forKey: keySimilarityThreshold) as? Int) ?? defaultSimilarityThreshold,
            blockEmoteOnly: (defaults.object(forKey: keyBlockEmoteOnly) as? Bool) ?? false,
            blockLong: (defaults.object(forKey: keyBlockLong) as? Bool) ?? false,
            blockLongLength: (defaults.object(forKey: keyBlockLongLength) as? Int) ?? defaultBlockLongLength,
            douyuBotFilter: (defaults.object(forKey: keyDouyuBotFilter) as? Bool) ?? false,
            blockedEntries: loadBlockedEntries()
        )
    }

    /// Persist to the same stores `load()` reads. The sheet calls
    /// this after every edit; the room page calls it when the
    /// per-platform toggle flips.
    func persist(defaults: UserDefaults = .standard) {
        LocalStore.saveCollection(named: Self.keyEnabled, value: enabled)
        LocalStore.saveCollection(named: Self.keyBlockedEntries, value: blockedEntries)
        defaults.set(fontSize, forKey: Self.keyFontSize)
        defaults.set(opacity, forKey: Self.keyOpacity)
        defaults.set(area, forKey: Self.keyArea)
        defaults.set(stroke, forKey: Self.keyStroke)
        defaults.set(strokeWidth, forKey: Self.keyStrokeWidth)
        defaults.set(speed, forKey: Self.keySpeed)
        defaults.set(maxCount, forKey: Self.keyMaxCount)
        defaults.set(colorMode, forKey: Self.keyColorMode)
        defaults.set(occlusionAvoidance, forKey: Self.keyOcclusionAvoidance)
        defaults.set(listStyle, forKey: Self.keyListStyle)
        defaults.set(listSpacing, forKey: Self.keyListSpacing)
        defaults.set(showUsernames, forKey: Self.keyShowUsernames)
        defaults.set(similarityEnabled, forKey: Self.keySimilarityEnabled)
        defaults.set(similarityThreshold, forKey: Self.keySimilarityThreshold)
        defaults.set(blockEmoteOnly, forKey: Self.keyBlockEmoteOnly)
        defaults.set(blockLong, forKey: Self.keyBlockLong)
        defaults.set(blockLongLength, forKey: Self.keyBlockLongLength)
        defaults.set(douyuBotFilter, forKey: Self.keyDouyuBotFilter)
    }

    /// Block list from the `hao_dm_block` collection file. Tolerates
    /// both shapes: a decoded array (written by `persist`) and a
    /// JSON string of an array (Flutter stored the list as one JSON
    /// string, and S1 migrates that string verbatim).
    private static func loadBlockedEntries() -> [LiveDanmakuBlockEntry] {
        let url = LocalStore.collectionURL(named: keyBlockedEntries)
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let entries = try? JSONDecoder().decode([LiveDanmakuBlockEntry].self, from: data) {
            return entries
        }
        guard let jsonString = try? JSONDecoder().decode(String.self, from: data),
              let inner = jsonString.data(using: .utf8),
              let entries = try? JSONDecoder().decode([LiveDanmakuBlockEntry].self, from: inner) else {
            return []
        }
        return entries
    }

    // MARK: - Tolerant readers

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text)
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }

    private static func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.min(Swift.max(value, min), max)
    }
}
