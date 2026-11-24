// HAo Studio 2.0 — settings pure logic (S5-B leg).
//
// Foundation ONLY (no SwiftUI / UIKit / AppKit): the SwiftPM
// `swift test` target compiles this file through AppCore, which
// runs on macOS, so nothing iOS-only may live here. Everything
// in this file is a pure function over plain values — the SwiftUI
// views in this directory call these, the SettingsTests target
// tests these.
//
// The option VALUE strings are the Flutter storage values
// (standalone-app-merge23
// lib/features/settings/settings_tab_page.dart):
// skip-intro off/manual/auto3s/autoNow, subtitle size
// small/medium/large, subtitle colour white/yellow/cyan,
// subtitle position bottom/middle/top, low-memory
// auto/always/never. A stored value outside the list falls back
// to the default (never a crash, never a blank row).

import Foundation

// MARK: - Section ids

/// The 7 settings groups. Raw values are the section ids the
/// SettingsStore fold state is keyed by; titles copy the Flutter
/// settings page group titles verbatim.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case music
    case live
    case video
    case sources
    case data
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .music: return "音乐播放"
        case .live: return "直播"
        case .video: return "影视播放"
        case .sources: return "源管理"
        case .data: return "数据"
        case .about: return "关于"
        }
    }
}

// MARK: - Hex colour (#RRGGBB)

/// Pure `#RRGGBB` parse / format. The UI layer turns the tuple
/// into a SwiftUI Color; the tuple itself is what the tests
/// verify, so no UI framework is needed here.
enum HexRGB {
    /// Parse `#RRGGBB` (leading `#` required, exactly 6 hex
    /// digits). Nil for anything else — an invalid draft never
    /// overwrites the stored value.
    static func parse(_ text: String) -> (red: Int, green: Int, blue: Int)? {
        guard text.hasPrefix("#") else { return nil }
        let digits = String(text.dropFirst())
        guard digits.count == 6 else { return nil }
        var value: UInt64 = 0
        let scanner = Scanner(string: digits)
        guard scanner.scanHexInt64(&value), scanner.isAtEnd else { return nil }
        let red = Int((value >> 16) & 0xFF)
        let green = Int((value >> 8) & 0xFF)
        let blue = Int(value & 0xFF)
        return (red: red, green: green, blue: blue)
    }

    /// Format back to canonical uppercase `#RRGGBB`.
    static func string(red: Int, green: Int, blue: Int) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// True when the text is a usable `#RRGGBB` value.
    static func isValid(_ text: String) -> Bool {
        parse(text) != nil
    }
}

// MARK: - String option lists (stored value -> label)

/// Picker option lists for the String-backed settings
/// (skipIntroMode / subtitleFontSize / subtitleColor /
/// subtitlePosition / lowMemoryMode on SettingsStore). Labels copy
/// the Flutter settings page; `label(for:options:default:)`
/// falls back to the default label for an unknown stored value.
enum SettingsOptionLists {
    static let skipIntroOptions: [(value: String, label: String)] = [
        (value: "off", label: "关"),
        (value: "manual", label: "手动"),
        (value: "auto3s", label: "自动延时 3 秒"),
        (value: "autoNow", label: "自动立即"),
    ]
    static let skipIntroDefault = "off"

    static let subtitleFontSizeOptions: [(value: String, label: String)] = [
        (value: "small", label: "小"),
        (value: "medium", label: "标准"),
        (value: "large", label: "大"),
    ]
    static let subtitleFontSizeDefault = "medium"

    static let subtitleColorOptions: [(value: String, label: String)] = [
        (value: "white", label: "白色"),
        (value: "yellow", label: "黄色"),
        (value: "cyan", label: "青色"),
    ]
    static let subtitleColorDefault = "white"

    static let subtitlePositionOptions: [(value: String, label: String)] = [
        (value: "bottom", label: "底部"),
        (value: "middle", label: "中间"),
        (value: "top", label: "顶部"),
    ]
    static let subtitlePositionDefault = "bottom"

    static let lowMemoryOptions: [(value: String, label: String)] = [
        (value: "auto", label: "自动"),
        (value: "always", label: "始终开启"),
        (value: "never", label: "始终关闭"),
    ]
    static let lowMemoryDefault = "auto"

    static func label(
        for value: String,
        in options: [(value: String, label: String)],
        default defaultValue: String
    ) -> String {
        if let found = options.first(where: { $0.value == value }) {
            return found.label
        }
        return options.first(where: { $0.value == defaultValue })?.label ?? value
    }

    static func isValidSkipIntroMode(_ value: String) -> Bool {
        skipIntroOptions.contains { $0.value == value }
    }

    static func isValidSubtitleFontSize(_ value: String) -> Bool {
        subtitleFontSizeOptions.contains { $0.value == value }
    }

    static func isValidSubtitleColor(_ value: String) -> Bool {
        subtitleColorOptions.contains { $0.value == value }
    }

    static func isValidSubtitlePosition(_ value: String) -> Bool {
        subtitlePositionOptions.contains { $0.value == value }
    }

    static func isValidLowMemoryMode(_ value: String) -> Bool {
        lowMemoryOptions.contains { $0.value == value }
    }
}

// MARK: - Low-memory mode effect (wiring leg B)
//
// Flutter `LowMemoryMode.isEffective` (mpv_properties.dart):
// auto = on when the device has <= 4 CPU cores, always = on,
// never = off. The stored string is "auto" / "always" /
// "never"; anything else (including a legacy value) reads as
// auto. `cpuCores` is a test seam — production passes
// `ProcessInfo.processInfo.processorCount`.
enum LowMemoryModeEffect {
    static func normalizedMode(_ raw: String?) -> String {
        guard let raw = raw,
              SettingsOptionLists.isValidLowMemoryMode(raw) else { return "auto" }
        return raw
    }

    static func isEffective(mode: String?, cpuCores: Int) -> Bool {
        switch normalizedMode(mode) {
        case "always":
            return true
        case "never":
            return false
        default:
            return cpuCores <= 4
        }
    }
}

// MARK: - Live cellular downgrade (wiring leg B)
//
// Pure port of Flutter `lib/domains/live/live_network_quality.dart`
// (build 29, item 3 + D 组): on mobile data the live entry quality
// is capped at the cellular ceiling ("超清" when the room offers
// it, else the lowest quality above 流畅, else the lowest quality
// outright — never 原画/蓝光 on mobile data); on Wi-Fi / unknown
// the preferred quality applies unchanged. This only sets the
// ENTRY quality: the user can still switch up manually in the room.
//
// Network classification copies Flutter's interface-name heuristic
// (no connectivity dependency in either codebase): iOS names its
// interfaces `en0` (Wi-Fi) and `pdp_ip0` (cellular); Android uses
// `wlan0` / `rmnet*`. An unclassifiable list reads as unknown and
// never downgrades. The entry decision itself takes quality NAMES
// (LiveQuality.name — server labels, matched exactly like
// Flutter's `q.quality == label`) so it stays independent of any
// one platform's tier ids.
enum LiveNetworkType: Equatable {
    case wifi
    case cellular
    case unknown
}

enum LiveCellularDowngrade {
    /// Cellular ceiling, by label (first match wins).
    static let cellularCeilingLabels = ["超清", "高清", "流畅"]

    /// The switch's stored value: nil (never written) means ON —
    /// Flutter `liveCellularDowngradeEnabled()` defaults true.
    static func enabled(stored: Bool?) -> Bool {
        stored ?? true
    }

    /// Classify one interface name. Case-insensitive; nil when
    /// unclassifiable.
    static func classifyInterfaceName(_ name: String) -> LiveNetworkType? {
        let lower = name.lowercased()
        if lower.hasPrefix("en") || lower.hasPrefix("wlan") {
            return .wifi
        }
        if lower.hasPrefix("pdp_ip") || lower.hasPrefix("rmnet") {
            return .cellular
        }
        return nil
    }

    /// Classify a list of interface names: cellular wins over
    /// Wi-Fi when both are present, Wi-Fi wins over unknown,
    /// unknown when nothing classifies.
    static func classifyInterfaces(_ names: [String]) -> LiveNetworkType {
        var sawWifi = false
        for name in names {
            if classifyInterfaceName(name) == .cellular { return .cellular }
            if classifyInterfaceName(name) == .wifi { sawWifi = true }
        }
        return sawWifi ? .wifi : .unknown
    }

    /// Entry-quality index for `qualityNames` on `network`,
    /// starting from the user's `preferredIndex`. Wi-Fi / unknown:
    /// preferred unchanged. Cellular: capped at the ceiling label
    /// when present, else at the middle tier (never the top tier),
    /// else the lowest quality.
    static func entryQualityIndex(
        qualityNames: [String],
        preferredIndex: Int,
        network: LiveNetworkType
    ) -> Int {
        guard !qualityNames.isEmpty else { return 0 }
        let preferred = min(max(preferredIndex, 0), qualityNames.count - 1)
        guard network == .cellular else { return preferred }
        for label in cellularCeilingLabels {
            if let at = qualityNames.firstIndex(of: label) { return at }
        }
        if qualityNames.count >= 3 { return qualityNames.count / 2 }
        return qualityNames.count - 1
    }

    /// Target quality index when the cellular-downgrade switch
    /// flips mid-room (Flutter `cellularDowngradeTargetIndex`),
    /// or nil when no switch is needed. Wi-Fi / unknown: nil.
    /// Turning it ON caps at the cellular ceiling — but never
    /// switches UP: a room already below the ceiling stays put.
    /// Turning it OFF restores the preferred quality. Both paths
    /// are no-ops when the target already equals the current
    /// quality, so a flip that changes nothing never re-opens
    /// the stream.
    static func cellularDowngradeTargetIndex(
        qualityNames: [String],
        currentIndex: Int,
        preferredIndex: Int,
        network: LiveNetworkType,
        enabled: Bool
    ) -> Int? {
        guard !qualityNames.isEmpty else { return nil }
        guard network == .cellular else { return nil }
        let current = min(max(currentIndex, 0), qualityNames.count - 1)
        let target: Int
        if enabled {
            let ceiling = entryQualityIndex(
                qualityNames: qualityNames, preferredIndex: 0, network: .cellular)
            target = ceiling > current ? ceiling : current
        } else {
            target = min(max(preferredIndex, 0), qualityNames.count - 1)
        }
        return target == current ? nil : target
    }
}

// MARK: - Auto-resume decision (wiring leg B)
//
// Flutter `music_player_controller.dart` onInit: when the
// "启动时自动播放上次歌曲" switch is on, the restored queue
// plays once per launch at its restored index. The decision is
// pure (the view model supplies the stored switch + the restored
// queue); nil means "do not auto-play".
enum AutoResumeDecision {
    static func resumeIndex(
        autoResumeEnabled: Bool,
        queueCount: Int,
        currentIndex: Int
    ) -> Int? {
        guard autoResumeEnabled, queueCount > 0 else { return nil }
        return min(max(currentIndex, 0), queueCount - 1)
    }
}


/// 0...2 strength slider label: weak / medium / strong.
/// Boundaries: under 0.75 is weak, under 1.5 is medium.
enum NormalizationStrengthLabel {
    static func label(for strength: Double) -> String {
        if strength < 0.75 { return "弱" }
        if strength < 1.5 { return "中" }
        return "强"
    }
}

// MARK: - "Keep at least one" guard

/// Shared guard for every "at least one must stay on" list
/// (CMS sources, live platforms). The toggle is greyed out when
/// it would switch off the last enabled entry — the write never
/// happens, so the guard is enforced in the UI and in the pure
/// transform, never by hoping the store refuses.
enum SourceKeepOneGuard {
    /// True when switching this entry off is allowed.
    static func canDisable(enabledCount: Int) -> Bool {
        enabledCount > 1
    }
}

// MARK: - LX source list rows (pure ordering)

/// One row of the 音源管理 page: a bundled script id or a custom
/// record. The view reads enabled state from LXScriptStore per
/// row; this struct only carries identity for ordering.
struct LXSourceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let isCustom: Bool
    /// Custom script URL (empty for bundled scripts). URL-only
    /// records have no downloaded file yet — see
    /// LXSourceManagementView.
    let url: String
    /// File name under `Documents/lx_scripts/` (empty for bundled
    /// scripts and for legacy URL-only records that were never
    /// downloaded — those show a re-download button).
    let fileName: String

    init(id: String, name: String, isCustom: Bool, url: String, fileName: String = "") {
        self.id = id
        self.name = name
        self.isCustom = isCustom
        self.url = url
        self.fileName = fileName
    }
}

enum LXSourceListOrdering {
    /// Merge bundled ids (minus user-deleted) + custom records
    /// into display order: the saved `hao_lx_order` first, then
    /// bundled seed order, then anything unknown last. Custom
    /// records not in the saved order sort after the bundled
    /// scripts, in import order.
    static func orderedRows(
        bundledIDs: [String],
        customRecords: [LxCustomScriptRecord],
        deletedBundledIDs: [String],
        savedOrder: [String]
    ) -> [LXSourceRow] {
        let deleted = Set(deletedBundledIDs)
        var rows: [LXSourceRow] = []
        for id in bundledIDs where !deleted.contains(id) {
            rows.append(LXSourceRow(id: id, name: id, isCustom: false, url: ""))
        }
        for record in customRecords {
            rows.append(LXSourceRow(
                id: record.id, name: record.name,
                isCustom: true, url: record.url, fileName: record.fileName))
        }
        let orderIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) })
        let seedIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: bundledIDs.enumerated().map { ($0.element, $0.offset) })
        return rows.sorted { a, b in
            let ai = orderIndex[a.id] ?? Int.max
            let bi = orderIndex[b.id] ?? Int.max
            if ai != bi { return ai < bi }
            if a.isCustom != b.isCustom { return !a.isCustom }
            let sa = seedIndex[a.id] ?? Int.max
            let sb = seedIndex[b.id] ?? Int.max
            if sa != sb { return sa < sb }
            return a.id < b.id
        }
    }
}

// MARK: - Live platform switches (hao_live_sources)

/// Enabled live platforms, stored as the `hao_live_sources`
/// collection (`Documents/hao_live_sources.json`): a JSON list of
/// enabled Flutter site ids
/// (`bilibili` / `douyu` / `huya` / `douyin` / `kuaishou` —
/// LivePlatform.flutterSiteId), at least one. This is the
/// Flutter LiveSourcesStore shape verbatim; there was no Swift
/// accessor in the baseline, so this enum is the first one —
/// it reads/writes the EXISTING collection, it does not invent a
/// new store. The I/O takes an injectable documents directory
/// (tests pass a temp dir; production passes nothing).
enum LiveSourcePrefs {
    /// Collection file name (storage-mapping contract).
    static let collectionName = "hao_live_sources"

    /// All five platform ids, in Flutter display order.
    static let allIDs: [String] = [
        "bilibili", "douyu", "huya", "douyin", "kuaishou",
    ]

    /// Enabled ids from a stored list. Nil / empty / fully
    /// invalid stored value means all five (Flutter default).
    static func enabledIDs(from stored: [String]?) -> [String] {
        guard let stored = stored else { return allIDs }
        let kept = stored.filter { allIDs.contains($0) }
        if kept.isEmpty { return allIDs }
        var ordered: [String] = []
        for id in allIDs where kept.contains(id) {
            ordered.append(id)
        }
        return ordered
    }

    /// Pure toggle transform. Returns nil (and the caller writes
    /// nothing) when switching off would leave zero enabled
    /// platforms. Enabling always succeeds.
    static func settingEnabled(
        _ enabled: [String],
        siteId: String,
        value: Bool
    ) -> [String]? {
        if value {
            if enabled.contains(siteId) { return enabled }
            var next = enabled
            next.append(siteId)
            return enabledIDs(from: next)
        }
        let next = enabled.filter { $0 != siteId }
        guard !next.isEmpty else { return nil }
        return next
    }

    /// Load the enabled list from the collection file.
    static func load(documentsDirectory: URL? = nil) -> [String] {
        let dir = documentsDirectory ?? LocalStore.documentsDirectory()
        let url = dir.appendingPathComponent("\(collectionName).json")
        guard let data = try? Data(contentsOf: url) else { return allIDs }
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            return enabledIDs(from: list)
        }
        if let wrapped = try? JSONDecoder().decode(String.self, from: data),
           let inner = wrapped.data(using: .utf8),
           let list = try? JSONDecoder().decode([String].self, from: inner) {
            return enabledIDs(from: list)
        }
        return allIDs
    }

    /// Save the enabled list to the collection file.
    static func save(_ enabled: [String], documentsDirectory: URL? = nil) {
        let dir = documentsDirectory ?? LocalStore.documentsDirectory()
        let url = dir.appendingPathComponent("\(collectionName).json")
        guard let data = try? JSONEncoder().encode(enabled) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
