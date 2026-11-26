// HAo Studio 2.0 — de-key regression tests (S2-B, P0-15).
//
// Asserts the 13 bundled LX scripts contain no key material, by
// PATTERN ONLY: no real key value is ever written into this file.
// The patterns check that every known key-shaped assignment is
// blank, every key array is empty, and the removed key-vault
// mechanism is gone entirely. The deep `_u(...)` checks live in
// the de-key verifier script, not here.

import Foundation
import JavaScriptCore
import XCTest

@testable import AppCore

final class LXKeyRegressionTests: XCTestCase {
    /// The 13 bundled scripts (4 heavily obfuscated scripts —
    /// aya, molan, yuningxi, fish — are NOT bundled; see the S2-B
    /// report).
    static let bundledScripts = [
        "suyin", "jiexiang", "helloworld", "huibi", "hyw", "kuliao",
        "stellarwave", "stellarwave014", "tongyi", "xinghai", "yuxi",
        "feichangdao", "gdstudio",
    ]

    /// The 4 excluded scripts must stay out of the bundle.
    static let excludedScripts = ["aya", "molan", "yuningxi", "fish"]

    private func scriptsDirectory() throws -> URL {
        // This file lives at ios/Tests/MusicLXTests/; the scripts
        // live at ios/HAoStudio/Services/LXEngine/Scripts/.
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let dir = url.appendingPathComponent(
            "ios/HAoStudio/Services/LXEngine/Scripts")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw NSError(
                domain: "LXKeyRegressionTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "scripts dir not found at \(dir.path)"])
        }
        return dir
    }

    private func contents() throws -> [String: String] {
        let dir = try scriptsDirectory()
        var out: [String: String] = [:]
        for id in Self.bundledScripts {
            let url = dir.appendingPathComponent("\(id).js")
            out[id] = try String(contentsOf: url, encoding: .utf8)
        }
        return out
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    func testAllBundledScriptsExistAndExcludedOnesDoNot() throws {
        let dir = try scriptsDirectory()
        for id in Self.bundledScripts {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("\(id).js").path),
                "\(id).js must be bundled")
        }
        for id in Self.excludedScripts {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("\(id).js").path),
                "\(id).js must NOT be bundled (obfuscated, unauditable)")
        }
        XCTAssertEqual(LxBundledScript.allIDs.sorted(), Self.bundledScripts.sorted())
    }

    func testBundledScriptsParseAndDeclareHeaders() throws {
        let all = try contents()
        for (id, code) in all {
            XCTAssertTrue(code.hasPrefix("/*!") || code.hasPrefix("/**"),
                          "\(id): leading doc comment (header tags) must survive de-keying")
            XCTAssertTrue(code.contains("@name"), "\(id): @name header tag missing")
            // Syntax check in a throwaway context (real prelude
            // installed, no network): a broken script must fail here,
            // not on device. The prelude is required: every bundled
            // script destructures `globalThis.lx` at load time.
            // b49fix44 (S33 R31 note): annotated like round 31 —
            // a bare `let context = JSContext()` infers `JSContext?`
            // (IUO import) and member access fails to compile.
            let context: JSContext = JSContext()
            context.evaluateScript(LXPrelude.source)
            XCTAssertNil(context.exception, "prelude must install cleanly")
            context.evaluateScript(code)
            XCTAssertNil(context.exception, "\(id): script must parse cleanly")
        }
    }

    func testNoNonEmptyKeyAssignments() throws {
        let all = try contents()
        // Any assignment of a non-empty quoted string to a
        // key/token/secret-shaped name is a leak. Empty ('') is the
        // de-keyed state.
        let pattern = "(?:eapiKey|HELLO_WORLD_API_KEY|HELLO_WORLD_SECRET_KEY|HYW_CARD_KEY)"
            + "\\s*=\\s*['\"][^'\"]+['\"]"
        for (id, code) in all {
            XCTAssertTrue(
                matches(pattern, in: code).isEmpty,
                "\(id): non-empty key assignment found: \(matches(pattern, in: code))")
        }
    }

    func testNoNonEmptyKeyArrays() throws {
        let all = try contents()
        // `apiKeys` arrays must be empty: a non-empty bracket is a leak.
        for (id, code) in all {
            XCTAssertTrue(
                matches("apiKeys\\s*=\\s*\\[[^\\]]*[A-Za-z0-9'\"]", in: code).isEmpty,
                "\(id): non-empty apiKeys array")
        }
    }

    func testKeyVaultMechanismIsGone() throws {
        let all = try contents()
        for token in ["KEY_VAULT", "unlockKey", "VAULT_SEED", "B64_ALPHABET", "b64Decode"] {
            for (id, code) in all {
                XCTAssertFalse(code.contains(token), "\(id): vault remnant \(token)")
            }
        }
    }

    func testNoPlainKeyQueryParamsWithValues() throws {
        let all = try contents()
        // A literal `apikey=`, `token=` or `secret=` in a URL with a
        // value of 4+ characters is key material. Empty values and
        // variable references are fine.
        let pattern = "(?:apikey|token|secret|api_key)=[A-Za-z0-9%_\\-]{4,}"
        for (id, code) in all {
            let hits = matches(pattern, in: code)
            XCTAssertTrue(hits.isEmpty, "\(id): plain key param with value: \(hits)")
        }
    }
}
