// LXScriptImport.swift
// User import of LX music-source scripts: validation + errors.
//
// Root cause (chen 2026-11-24, build 33: "音源没办法用 js 上传"):
// the source-management page had no file picker at all, and its URL
// "add" only saved the address string (empty file name), so the
// engine could never load the script — it showed in the list but
// never took part in search or playback, with no error shown.
// This file is the single validation path both import entries use:
//   - file import: `.js` extension, readable UTF-8, non-empty,
//     contains the `globalThis.lx` marker, parses + runs clean in
//     a throwaway JSContext (prelude only, no network, no host
//     bridge — a top-level throw fails here too).
//   - URL import: http(s) address ending in `.js`; the engine
//     downloads it first, then the same validation runs.
// Every failure is a typed error with a user-facing Chinese message;
// nothing fails silently. No script body or key is ever copied into
// an error message (only a truncated JS exception line, at most).
// No script is bundled here: import only handles the user's own
// files, and the 4 obfuscated scripts stay unbundled.

import Foundation
import JavaScriptCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a script import failed. `localizedDescription` is safe to
/// show in UI; it never contains a key or a script body.
enum LXScriptImportError: Error, Equatable {
    /// The picked file / URL is not a `.js` file.
    case notJavaScriptFile
    /// The file / download is empty.
    case emptyFile
    /// The file could not be read (damaged, gone, permission).
    case unreadableFile
    /// No `globalThis.lx` marker: not an LX music-source script.
    case missingLXMarker
    /// JS syntax error or top-level throw; the detail is the JS
    /// exception line, truncated.
    case syntaxError(String)
    /// Writing the copy into `Documents/lx_scripts/` failed.
    case writeFailed
    /// The pasted address is not a usable http(s) URL.
    case invalidURL
    /// The download failed (network, non-200 status, undecodable
    /// body); the detail is the cause, truncated.
    case downloadFailed(String)
    /// The script was validated and saved, but the engine could not
    /// load it (e.g. it never sends `inited`); the detail is the
    /// load error.
    case loadFailed(String)

    var localizedDescription: String {
        switch self {
        case .notJavaScriptFile:
            return "不是 .js 文件，请选择扩展名为 .js 的脚本文件。"
        case .emptyFile:
            return "文件是空的，没有可导入的内容。"
        case .unreadableFile:
            return "读不到这个文件，请确认文件没有损坏，再选一次。"
        case .missingLXMarker:
            return "这不是 LX 音源脚本：文件里找不到 globalThis.lx。"
        case .syntaxError(let detail):
            return "脚本无法执行：\(detail)"
        case .writeFailed:
            return "保存脚本失败，请检查存储空间后重试。"
        case .invalidURL:
            return "请输入一个有效的 http(s) 脚本地址。"
        case .downloadFailed(let detail):
            return "下载失败：\(detail)"
        case .loadFailed(let detail):
            return "脚本已保存，但加载失败：\(detail)。可在列表中删除后重试。"
        }
    }
}

/// The single validation path for file import and URL import.
/// Pure except for the throwaway JSContext syntax probe.
enum LXScriptImportValidator {
    /// Validate one script body: non-empty, LX marker present,
    /// parses and runs clean with the prelude in a throwaway
    /// context (no network, no host bridge).
    static func validate(code: String) -> Result<Void, LXScriptImportError> {
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.emptyFile)
        }
        guard code.contains("globalThis.lx") else {
            return .failure(.missingLXMarker)
        }
        let probe = JSContext()
        probe?.evaluateScript(LXPrelude.source)
        probe?.evaluateScript(code)
        if let exception = probe?.exception {
            let detail = exception.toString() ?? ""
            let short = String(detail.prefix(120))
            return .failure(.syntaxError(short.isEmpty ? "脚本执行出错" : short))
        }
        return .success(())
    }

    /// Validate a pasted script address: http(s), host present,
    /// path ends in `.js`.
    static func validateRemoteURL(_ url: URL) -> Result<Void, LXScriptImportError> {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return .failure(.invalidURL) }
        guard url.pathExtension.lowercased() == "js" else {
            return .failure(.notJavaScriptFile)
        }
        return .success(())
    }

    /// Truncate a download-failure cause for an error message.
    static func shortDetail(_ text: String) -> String {
        let short = String(text.prefix(120))
        return short.isEmpty ? "网络错误" : short
    }
}
