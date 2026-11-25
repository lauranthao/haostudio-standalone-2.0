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

/// The 9 sections (我的 + the 8 settings groups). Raw values are the section ids the
/// SettingsStore fold state is keyed by; titles copy the Flutter
/// settings page group titles verbatim.
enum SettingsSection: String, CaseIterable, Identifiable {
    case my
    case appearance
    case music
    case live
    case video
    case sources
    case data
    case storage
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .my: return "我的"
        case .appearance: return "外观"
        case .music: return "音乐播放"
        case .live: return "直播"
        case .video: return "影视播放"
        case .sources: return "源管理"
        case .data: return "数据"
        case .storage: return "存储空间"
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

// MARK: - 存储空间 (b45-coda 包 C, §4.4)
//
// Pure math for the storage capacity bar: three fractions of the
// device total — this app / other used / free. Clamped to 0...1
// and never dividing by zero (total <= 0 reads as all free).
enum StorageCapacityMath {
    static func segments(app: Int64, used: Int64, total: Int64) -> (app: Double, other: Double, free: Double) {
        guard total > 0 else { return (app: 0, other: 0, free: 1) }
        let clampedUsed = min(max(used, 0), total)
        let clampedApp = min(max(app, 0), clampedUsed)
        let appFraction = Double(clampedApp) / Double(total)
        let otherFraction = Double(clampedUsed - clampedApp) / Double(total)
        let freeFraction = Double(total - clampedUsed) / Double(total)
        return (app: appFraction, other: otherFraction, free: freeFraction)
    }
}

/// 歌曲缓存上限档位 (MB). 0 = 自动 (Coda: 空闲空间 1/10, 夹在
/// 2–30GB, 永远保留最后 1GB — 上限的执行是包 F 音频缓存引擎
/// 的事, 这里只存用户选择).
enum SongCacheLimitOptions {
    static let values: [Int] = [0, 500, 1000, 2000, 5000, 10000]

    static func label(for megabytes: Int) -> String {
        if megabytes <= 0 { return "自动" }
        return "\(megabytes) MB"
    }

    static func isValid(_ megabytes: Int) -> Bool {
        values.contains(megabytes)
    }
}

// MARK: - 免责声明 (b45-coda 包 C, §4.3)
//
// Disclaimer text, version 4 (b49fix2: clauses 5 and 6 were
// corrected — clause 5 omitted the Emby upload, clause 6
// over-promised auto-cleanup for downloads; the change is
// material, so the version bumps and consent is re-asked).
// Written for THIS app (local-only, no login, third-party
// sources) — never copied from Coda's text, which names its
// platforms and login risks.
enum DisclaimerGate {
    /// Current disclaimer version. Bump on any material change;
    /// the stored accepted version must equal this to count.
    /// b49fix3: 4 → 5 (clauses 5 + 6 rewritten to match the code).
    static let currentVersion = 5
    static let acceptedVersionKey = "hao_disclaimer_accepted_version"

    static func isAccepted(storedVersion: Int?) -> Bool {
        storedVersion == currentVersion
    }
}

/// One disclaimer clause: headline + body. Exactly 10 clauses.
struct DisclaimerClause {
    let title: String
    let body: String
}

enum DisclaimerContent {
    static let summary = "使用 HAo Studio 前请阅读以下声明。继续使用即表示你已阅读并同意本声明的全部内容。"

    static let clauses: [DisclaimerClause] = [
        DisclaimerClause(
            title: "1. 软件性质",
            body: "HAo Studio 是一款免费的独立应用，提供音乐、视频与直播的浏览与播放功能。本应用不收取任何费用，不设账号，不要求注册或登录。"
        ),
        DisclaimerClause(
            title: "2. 内容来源",
            body: "应用内的音乐、视频与直播内容来自公开的第三方来源，以及你自行添加的来源。本应用本身不制作、不托管这些内容，也不保证某一来源长期可用。"
        ),
        DisclaimerClause(
            title: "3. 版权归属",
            body: "全部内容的版权归原权利人所有。播放与下载仅供个人学习与欣赏，请通过合法渠道支持你喜欢的创作者与平台，不要将内容传播或用于商业用途。"
        ),
        DisclaimerClause(
            title: "4. 播放地址",
            body: "播放地址由各来源实时提供，可能随来源的调整而失效。遇到无法播放的情况，可以切换其他来源，或稍后重试。"
        ),
        DisclaimerClause(
            title: "5. 本地数据",
            body: "你的歌单、收藏、播放记录、下载与各项设置只保存在本机，不会上传到我们的服务器——我们没有自己的服务器。搜索与播放仍会直接向你所选来源的服务器发请求（见设置里的“数据与来源”）；你自己配置的 Emby 服务器除外：开启上报后，播放进度会同步到你的 Emby。卸载应用或清除数据后，这些内容将无法恢复。"
        ),
        DisclaimerClause(
            title: "6. 下载与缓存",
            body: "下载与缓存的内容仅供本机离线播放使用。下载的文件会一直保留，直到你手动删除，不会自动清理；音频缓存放在系统缓存目录，空间不足时可能被系统清理，应用也会在缓存写满上限时按最近最少使用清理，清理后需要重新获取。"
        ),
        DisclaimerClause(
            title: "7. 网络与费用",
            body: "播放与下载会产生流量。使用移动数据时可能产生费用，相关费用由你的运营商收取，与本应用无关。"
        ),
        DisclaimerClause(
            title: "8. 内容准确性",
            body: "第三方来源提供的标题、封面、歌词、简介与播放信息可能存在错误、缺失或过期，本应用不对这些信息的准确性与完整性作保证。"
        ),
        DisclaimerClause(
            title: "9. 服务现状",
            body: "本应用按“现状”提供。开发者不对第三方内容的可用性、连续性与质量作保证，也不对因第三方服务中断、调整或下线造成的损失负责。"
        ),
        DisclaimerClause(
            title: "10. 同意与更新",
            body: "本声明可能随应用更新而修订，实质性修订会重新征得你的同意。继续使用本应用，即表示你接受届时有效的声明内容。"
        ),
    ]
}

// MARK: - 开源许可 (b45-coda 包 C, §4.3)
//
// Our licence is MIT (not Coda's AGPL). The standard MIT text
// below is the licence itself, not Coda content.
enum OpenSourceLicenses {
    static let mitTitle = "MIT 许可证"

    static let mitText = """
        MIT License

        Copyright (c) HAo Studio

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """

    static let thanksText = "HAo Studio 使用并参考了多个开源项目，感谢每一位开源作者的付出。完整的第三方声明见 GitHub 仓库根目录的 THIRD-PARTY-NOTICES.md。"
}
