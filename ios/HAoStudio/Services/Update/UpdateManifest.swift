// HAo Studio 2.0 — update manifest (S6).
//
// The version.json shape the shop server and GitHub raw both serve
// (see the Flutter main version.json: version, build, minOs, size,
// ipaUrl, changelog). The changelog is a trilingual map in the real
// files; a plain string is accepted too, for hand-written manifests.

import Foundation

/// The trilingual changelog from one manifest. Either the map form
/// with zh, tw and en entries, or a single plain string.
struct UpdateChangelog {
    let zh: String?
    let tw: String?
    let en: String?
    let text: String?

    /// Best entry for a language code: zh-Hans takes zh, zh-Hant
    /// takes tw, en takes en; anything else takes the plain string,
    /// then zh, tw, en in that order.
    ///
    /// b36 item 8, F5: the input is normalized first (lowercase,
    /// "_" → "-", prefix match) because the callers pass BCP 47
    /// tags such as "zh-Hant-TW" / "zh-Hans-CN", and
    /// `Locale.current.languageCode` returns only "zh" — the
    /// old exact-match switch never saw a Traditional tag, so
    /// Traditional users always got the Simplified entry.
    func localized(for languageCode: String?) -> String? {
        guard let code = languageCode else {
            return text ?? zh ?? tw ?? en
        }
        let normalized = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized.hasPrefix("zh-hant") || normalized == "zh-tw"
            || normalized == "zh-hk" || normalized == "zh-mo" {
            return tw ?? text
        }
        if normalized.hasPrefix("zh-hans") || normalized == "zh-cn"
            || normalized == "zh-sg" || normalized == "zh" {
            return zh ?? text
        }
        if normalized == "en" || normalized.hasPrefix("en-") {
            return en ?? text
        }
        return text ?? zh ?? tw ?? en
    }
}

/// One release described by a version.json manifest.
struct UpdateManifest {
    let version: String
    let build: Int
    let minOs: String?
    let downloadURL: URL
    let size: Int?
    let changelog: UpdateChangelog?

    /// Identity of this release for the skip check: version + build.
    /// Skipping one build must not skip the next build of the same
    /// version, so the id carries the build.
    var id: String {
        "\(version)+\(build)"
    }
}

/// Parses a decoded JSON object into an UpdateManifest. Returns nil
/// when the version or the download URL is missing or empty; every
/// other field is optional and defaults when absent.
enum UpdateManifestParser {
    static func parse(_ object: Any) -> UpdateManifest? {
        guard let root = object as? [String: Any] else {
            return nil
        }
        guard let version = root["version"] as? String, !version.isEmpty else {
            return nil
        }
        guard let urlString = root["ipaUrl"] as? String,
              !urlString.isEmpty,
              let downloadURL = URL(string: urlString)
        else {
            return nil
        }
        let build = asInt(root["build"]) ?? 0
        let minOs = asString(root["minOs"])
        let size = asInt(root["size"])
        let changelog = parseChangelog(root["changelog"])
        return UpdateManifest(
            version: version, build: build, minOs: minOs,
            downloadURL: downloadURL, size: size, changelog: changelog
        )
    }

    static func parseChangelog(_ value: Any?) -> UpdateChangelog? {
        if let text = value as? String {
            return UpdateChangelog(zh: nil, tw: nil, en: nil, text: text.isEmpty ? nil : text)
        }
        guard let dict = value as? [String: Any] else {
            return nil
        }
        let zh = asString(dict["zh"])
        let tw = asString(dict["tw"])
        let en = asString(dict["en"])
        if zh == nil && tw == nil && en == nil {
            return nil
        }
        return UpdateChangelog(zh: zh, tw: tw, en: en, text: nil)
    }

    static func asString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    static func asInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}
