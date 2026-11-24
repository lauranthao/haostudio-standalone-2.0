// LXModels.swift
// LX engine data model: script registry records, capability records,
// and engine errors.
//
// The registry persistence keys are the S1 storage-mapping contract
// (`docs/storage-mapping.md`): `hao_lx_disabled`,
// `hao_lx_explicit_enabled`, `hao_lx_custom`,
// `hao_lx_deleted_bundled`, `hao_lx_order`. Key names are never
// renamed. The registry value shapes are this slice's own: the
// Flutter Hive boxes held `{id, name, url, code, addedAt}` for custom
// scripts; the Swift registry keeps `{id, name, url, addedAt}` and
// the code lives ONLY in the `lx_scripts/` file (see
// `LXScriptFileStore`), so no script body is duplicated in JSON.

import Foundation

/// One capability a script reported in its `inited` event: a platform
/// (`wy`/`tx`/`kg`/`kw`/`mg` …) plus the actions it supports there
/// and the quality tiers it claims.
struct LxScriptSourceInfo: Equatable {
    let scriptId: String
    let scriptName: String
    /// Platform code: `wy`, `tx`, `kg`, `kw`, `mg`.
    let platform: String
    /// Display name for the script on this platform, e.g. `suyin`.
    let displayName: String
    /// Actions the script says it supports on this platform:
    /// `musicUrl`, `search`, `pic`, `lyric`.
    let actions: [String]
    /// Quality tiers the script says it supports on this platform
    /// (LX codes: `master`, `hires`, `lossless`, `320k`, `128k`).
    let qualities: [String]

    var supportsMusicUrl: Bool { actions.contains("musicUrl") }
    var supportsSearch: Bool { actions.contains("search") }
}

/// One script in the registry: bundled (shipped in the app bundle,
/// seeded to Documents) or user-imported.
struct LxScriptInfo {
    let id: String
    let name: String
    /// Version reported by the script's header, when known.
    let version: String
    /// `custom:file:<digest>` for user scripts, otherwise the bundled id.
    let origin: String
    var isCustom: Bool { origin.hasPrefix("custom:") }
    var loaded: Bool
    var error: String?
    /// Capabilities reported by the `inited` event (empty until loaded).
    var sources: [LxScriptSourceInfo]
    /// Header `showConfigView` flag (user key entry UI, settings leg).
    var configView: Bool
    /// `updateAlert` payload from the script, if any.
    var updateAlert: String?

    init(id: String, name: String, version: String = "", origin: String = "",
         loaded: Bool = false, error: String? = nil,
         sources: [LxScriptSourceInfo] = [], configView: Bool = false,
         updateAlert: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.origin = origin
        self.loaded = loaded
        self.error = error
        self.sources = sources
        self.configView = configView
        self.updateAlert = updateAlert
    }
}

/// One custom script record in the `hao_lx_custom` collection.
/// The code itself lives in `Documents/lx_scripts/<fileName>`; this
/// record only registers it.
struct LxCustomScriptRecord: Codable, Equatable {
    let id: String
    let name: String
    let url: String
    /// File name under `Documents/lx_scripts/` (never an absolute path).
    let fileName: String
    let addedAt: Date
}

/// Errors surfaced by the LX engine. `localizedDescription` is safe
/// to show in UI; it never contains a key or a script body.
enum LXError: Error, Equatable {
    case scriptNotLoaded(String)
    case invalidScript(String)
    case initedTimeout(String)
    case dispatchFailed(String)
    case timedOut(String)
    case cancelled
    case httpFailed(String)
    case importFailed(String)
    case notFound(String)

    var localizedDescription: String {
        switch self {
        case .scriptNotLoaded(let id): return "脚本未加载：\(id)"
        case .invalidScript(let why): return "脚本无效：\(why)"
        case .initedTimeout(let id): return "脚本初始化超时：\(id)"
        case .dispatchFailed(let why): return "脚本调用失败：\(why)"
        case .timedOut(let fn): return "脚本调用超时：\(fn)"
        case .cancelled: return "已取消"
        case .httpFailed(let why): return "网络请求失败：\(why)"
        case .importFailed(let why): return "导入脚本失败：\(why)"
        case .notFound(let what): return "未找到：\(what)"
        }
    }
}

/// The 13 bundled scripts that ship in the app (see `Scripts/`).
/// The four obfuscated scripts (`aya`, `molan`, `yuningxi`, `fish`)
/// are NOT bundled: their single-line blobs cannot be statically
/// audited for embedded keys, so they are left out pending a
/// coordinator decision. Users may re-add them via the user-import
/// path, where the key (if any) lives in the Keychain.
enum LxBundledScript {
    /// Bundled script ids, in seed order (fastest first where known:
    /// `suyin` first — it is the Flutter default).
    static let allIDs: [String] = [
        "suyin", "jiexiang", "helloworld", "huibi", "hyw", "kuliao",
        "stellarwave", "stellarwave014", "tongyi", "xinghai", "yuxi",
        "feichangdao", "gdstudio",
    ]

    /// Bundled ids the user has deleted (never re-seeded).
    /// Mirrors Flutter's `lxDeletedBundled`.
    static let deletedBundledKey = "hao_lx_deleted_bundled"

    /// Bundled ids that no longer ship. A stale `<id>.js` left in
    /// Documents by an older build is deleted on startup, never
    /// re-seeded (build 36 item 6): `tang` shipped in an early
    /// build; its resolver host never answers (deleted 2026-11-24).
    static let removedBundledIDs: [String] = ["tang"]

    static func isBundled(_ id: String) -> Bool { allIDs.contains(id) }
}
