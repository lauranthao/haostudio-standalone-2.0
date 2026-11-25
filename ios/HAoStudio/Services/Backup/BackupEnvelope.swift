// HAo Studio 2.0 — backup envelope (S6, leg A).
//
// The envelope is the first thing a backup zip carries
// (`backup.json`) and the first thing an import validates. It
// answers three questions before a single user value is touched:
// is this our file at all, is its schema one we understand, and is
// it newer than the app trying to read it.
//
// Version rules (plan section 7.2, and the web backup spec's
// "newer refuses, older accepts"):
// - `schema` is the envelope shape version. It is a small integer
//   that only changes when the envelope itself changes shape. It
//   is NOT the app version, and it is never a hardcoded app
//   version string.
// - `appVersion` / `appBuild` follow the CURRENT app version, read
//   from the bundle at export time (Info.plist
//   CFBundleShortVersionString / CFBundleVersion). No version
//   string is hardcoded anywhere in this file.
// - A backup whose appVersion is NEWER than the running app is
//   refused ("备份版本较新，无法恢复"): the newer app may have
//   written keys this app does not know. A backup from an OLDER
//   app version is accepted: missing keys keep their defaults,
//   unknown keys are isolated, never fatal.
// - When the running app's version cannot be read (no bundle
//   keys, e.g. under `swift test`), the newer-check is skipped
//   rather than guessed: refusing on an unknown version would
//   brick legitimate restores.
//
// The envelope itself is a plain dictionary, read and written
// with JSONSerialization like MigrationStore — the backup's `data`
// values are untyped JSON, so a Codable struct would need a
// parallel JSON-value enum for no benefit.

import Foundation

/// One line of the backup's content manifest: what the zip holds,
/// where it lands on import, and how many bytes it should have.
/// The import verifies payload files against `bytes` after
/// writing them.
struct BackupContentEntry: Equatable {
    /// Path inside the zip (`backup.json`,
    /// `collections/hao_fav.json`, `files/wallpapers/x.jpg`).
    let path: String
    /// `envelope`, `collection`, or `file`.
    let kind: String
    /// Expected byte count of the entry.
    let bytes: Int

    init(path: String, kind: String, bytes: Int) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
    }

    init?(dictionary: [String: Any]) {
        guard let path = dictionary["path"] as? String,
              let kind = dictionary["kind"] as? String,
              let bytes = MigrationStore.numberValue(dictionary["bytes"] as Any)
        else { return nil }
        self.init(path: path, kind: kind, bytes: bytes.intValue)
    }

    func asDictionary() -> [String: Any] {
        return ["path": path, "kind": kind, "bytes": bytes]
    }
}

/// A parsed app version (`major.minor.patch`, with an optional
/// pre-release suffix such as `-dev.1` ignored for comparison:
/// a dev build of 2.0.0 is not newer than 2.0.0). Unparseable
/// strings give nil — the caller then skips the newer-check
/// instead of refusing the backup.
struct BackupVersion: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let raw: String

    init?(raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let core = trimmed.split(separator: "-", maxSplits: 1).first ?? Substring(trimmed)
        let parts = core.split(separator: ".")
        guard let first = parts.first, let major = Int(first) else {
            return nil
        }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = trimmed
    }

    static func < (lhs: BackupVersion, rhs: BackupVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// The result of validating a backup envelope: either the parsed
/// envelope, or the reason the file must be refused.
enum BackupValidation {
    case valid(BackupEnvelope)
    case rejected(String)
}

/// The backup envelope: format identity, schema, app version,
/// export time, content manifest, warnings, and per-section
/// counts. The user values themselves live beside it in the same
/// `backup.json` file under the `data` key — the envelope never
/// carries them, so validation never has to parse user data.
struct BackupEnvelope {
    /// Format identity. A file without exactly this string is
    /// not our backup, whatever else it contains.
    static let formatName = "hao-studio-backup"
    /// Envelope shape version. Bump only when the envelope
    /// fields themselves change shape.
    static let currentSchemaVersion = 1

    let format: String
    let schema: Int
    let appVersion: String
    let appBuild: String
    let exportedAt: String
    let contents: [BackupContentEntry]
    let warnings: [String]
    let counts: [String: Int]

    init(
        schema: Int = BackupEnvelope.currentSchemaVersion,
        appVersion: String,
        appBuild: String,
        exportedAt: String,
        contents: [BackupContentEntry],
        warnings: [String],
        counts: [String: Int]
    ) {
        self.format = BackupEnvelope.formatName
        self.schema = schema
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.exportedAt = exportedAt
        self.contents = contents
        self.warnings = warnings
        self.counts = counts
    }

    /// b49fix4 P2-38: the preview sheet used to show the raw ISO
    /// string ("2026-11-25T21:00:00Z"). The export time is
    /// local-timezone formatted here. Unparseable input falls
    /// back to the raw string instead of showing nothing.
    var formattedExportedAt: String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: exportedAt) else { return exportedAt }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// b49fix4 P2-38: "设置 12 项、集合 8 个、文件 3 个" — the
    /// old preview said "内容 N 项" (the zip entry count, which
    /// says nothing about what is inside). Skipped keys ride
    /// along when present ("跳过 2 个坏键"). Zero sections are
    /// omitted; an empty counts dict falls back to the entry
    /// count.
    var contentsSummary: String {
        var parts: [String] = []
        if let keys = counts["keys"], keys > 0 { parts.append("设置 \(keys) 项") }
        if let collections = counts["collections"], collections > 0 { parts.append("集合 \(collections) 个") }
        if let files = counts["files"], files > 0 { parts.append("文件 \(files) 个") }
        if let skipped = counts["skippedKeys"], skipped > 0 { parts.append("跳过 \(skipped) 个坏键") }
        if parts.isEmpty { return "\(contents.count) 项" }
        return parts.joined(separator: "、")
    }

    init?(dictionary: [String: Any]) {
        guard let format = dictionary["format"] as? String,
              let schema = MigrationStore.numberValue(dictionary["schema"] as Any),
              let appVersion = dictionary["appVersion"] as? String,
              let appBuild = dictionary["appBuild"] as? String,
              let exportedAt = dictionary["exportedAt"] as? String
        else { return nil }
        let contents = (dictionary["contents"] as? [[String: Any]] ?? [])
            .compactMap { BackupContentEntry(dictionary: $0) }
        let warnings = dictionary["warnings"] as? [String] ?? []
        var counts: [String: Int] = [:]
        if let rawCounts = dictionary["counts"] as? [String: Any] {
            for entry in rawCounts {
                if let number = MigrationStore.numberValue(entry.value) {
                    counts[entry.key] = number.intValue
                }
            }
        }
        self.format = format
        self.schema = schema.intValue
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.exportedAt = exportedAt
        self.contents = contents
        self.warnings = warnings
        self.counts = counts
    }

    func asDictionary() -> [String: Any] {
        return [
            "format": format,
            "schema": schema,
            "appVersion": appVersion,
            "appBuild": appBuild,
            "exportedAt": exportedAt,
            "contents": contents.map { $0.asDictionary() },
            "warnings": warnings,
            "counts": counts,
        ]
    }

    // MARK: - Current app version (from the bundle, never hardcoded)

    /// The running app's version from the bundle, or nil when the
    /// bundle carries no version (test hosts have none). Callers
    /// pass an explicit version in tests instead of relying on
    /// this.
    static func currentAppVersion(bundle: Bundle = .main) -> BackupVersion? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return BackupVersion(raw: raw)
    }

    static func currentAppBuild(bundle: Bundle = .main) -> String {
        return bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    // MARK: - Validation

    /// Validates a parsed `backup.json` root dictionary. The
    /// `currentVersion` is the running app's version; when nil
    /// the newer-check is skipped (see the header note).
    /// Anything wrong returns `.rejected` with a human-readable
    /// reason — never a crash, never a partial import.
    static func validate(
        dictionary: [String: Any],
        currentVersion: BackupVersion?
    ) -> BackupValidation {
        guard let format = dictionary["format"] as? String, format == formatName else {
            return .rejected("不是 HAo Studio 的备份文件")
        }
        guard let schemaNumber = MigrationStore.numberValue(dictionary["schema"] as Any) else {
            return .rejected("备份文件缺少 schema 版本")
        }
        let schema = schemaNumber.intValue
        if schema > currentSchemaVersion {
            return .rejected("备份版本较新，无法恢复（schema \(schema)）")
        }
        if schema < currentSchemaVersion {
            return .rejected("备份版本过旧，无法恢复（schema \(schema)）")
        }
        guard let envelope = BackupEnvelope(dictionary: dictionary) else {
            return .rejected("备份信封损坏")
        }
        guard dictionary["data"] is [String: Any] else {
            return .rejected("备份文件缺少数据")
        }
        if let backupVersion = BackupVersion(raw: envelope.appVersion),
           let current = currentVersion,
           backupVersion > current {
            return .rejected("备份来自更新的版本 \(envelope.appVersion)，无法恢复")
        }
        return .valid(envelope)
    }
}
