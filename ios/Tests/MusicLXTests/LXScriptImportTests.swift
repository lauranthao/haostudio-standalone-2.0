// HAo Studio 2.0 — LX script import tests (fix/js-import).
//
// Covers the build-33 import failure (chen 2026-11-24: "音源没
// 办法用 js 上传"): the validator accepts a legal script and
// rejects an empty file / a non-.js file / a non-LX script / a
// syntax-broken script, each with its own error; file import
// saves the record + the file copy and the script then takes
// part in the resolve chain; URL import downloads first (stubbed
// transport) and rejects a 404 and a non-script body; a legacy
// URL-only record (no downloaded file) is skipped by engine load.

import Foundation
import XCTest

@testable import AppCore

final class LXScriptImportTests: XCTestCase {
    private var docs: URL!

    override func setUp() {
        super.setUp()
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-import-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        StubURLProtocol.handler = nil
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        if let docs = docs {
            try? FileManager.default.removeItem(at: docs)
        }
        super.tearDown()
    }

    private func makeEngine(initedTimeout: TimeInterval = 2) -> LXEngine {
        LXEngine(
            fileStore: LXScriptFileStore(documentsDirectory: docs),
            scriptStore: LXScriptStore(documentsDirectory: docs),
            initedTimeout: initedTimeout,
            bundleLoader: { _ in nil })
    }

    /// Minimal script: one `request` handler routing `musicUrl` +
    /// synchronous `inited` (same shape as LXEngineTests).
    private let fakeScript = """
        /*! @name Fake Script @version 1.0.0 */
        globalThis.lx.on('request', function (data) {
            if (data.action === 'musicUrl') {
                return 'https://example.com/fake.mp3';
            }
            return null;
        });
        globalThis.lx.send('inited', { status: true, sources: {
            tx: { name: 'fake', actions: ['musicUrl'], qualitys: ['128k'] }
        } });
        """

    private func write(_ code: String, named name: String) -> URL {
        let url = docs.appendingPathComponent(name)
        try? code.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Validator

    func testValidatorAcceptsValidScript() {
        if case .success = LXScriptImportValidator.validate(code: fakeScript) {
        } else {
            XCTFail("valid script must pass validation")
        }
    }

    func testValidatorRejectsEmptyFile() {
        if case .failure(.emptyFile) = LXScriptImportValidator.validate(code: "") {
        } else {
            XCTFail("empty file must fail with .emptyFile")
        }
        if case .failure(.emptyFile) = LXScriptImportValidator.validate(code: "  \n\t ") {
        } else {
            XCTFail("whitespace-only file must fail with .emptyFile")
        }
    }

    func testValidatorRejectsNonLXScript() {
        if case .failure(.missingLXMarker) = LXScriptImportValidator.validate(code: "var x = 1;\n") {
        } else {
            XCTFail("non-LX script must fail with .missingLXMarker")
        }
    }

    func testValidatorRejectsBrokenScript() {
        let result = LXScriptImportValidator.validate(
            code: "globalThis.lx.on('request', function () { let x = ; })")
        if case .failure(.syntaxError) = result {
        } else {
            XCTFail("broken script must fail with .syntaxError, got \(result)")
        }
    }

    func testValidateRemoteURL() {
        if case .success = LXScriptImportValidator.validateRemoteURL(
            URL(string: "https://example.com/fake.js")!) {
        } else {
            XCTFail("https .js address must pass")
        }
        if case .failure(.notJavaScriptFile) = LXScriptImportValidator.validateRemoteURL(
            URL(string: "https://example.com/fake.txt")!) {
        } else {
            XCTFail("non-.js address must fail with .notJavaScriptFile")
        }
        if case .failure(.invalidURL) = LXScriptImportValidator.validateRemoteURL(
            URL(string: "ftp://example.com/fake.js")!) {
        } else {
            XCTFail("ftp address must fail with .invalidURL")
        }
        if case .failure(.invalidURL) = LXScriptImportValidator.validateRemoteURL(
            URL(string: "https:fake.js")!) {
        } else {
            XCTFail("malformed address must fail with .invalidURL")
        }
    }

    // MARK: - File import

    func testImportFileAcceptsValidScriptAndJoinsResolveChain() {
        let engine = makeEngine()
        let source = write(fakeScript, named: "import-me.js")
        let result = engine.importScript(from: source)
        guard case .success(let record) = result else {
            XCTFail("valid file must import, got \(result)")
            return
        }
        XCTAssertTrue(record.id.hasPrefix("custom:file:"))
        XCTAssertFalse(record.fileName.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: LXScriptFileStore(documentsDirectory: docs)
                .fileURL(forFileName: record.fileName).path))
        XCTAssertTrue(LXScriptStore(documentsDirectory: docs)
            .customScripts().contains(record))
        // The load follows: wait, then the script must offer a
        // musicUrl source for tx — i.e. it takes part in parsing.
        let expectation = self.expectation(description: "import load")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        let sources = engine.musicUrlSources(platform: "tx", quality: .standard128)
        XCTAssertTrue(sources.contains(where: { $0.scriptID == record.id }),
                      "imported script must appear in musicUrlSources")
    }

    func testImportFileRejectsNonJsEmptyAndNonLX() {
        let engine = makeEngine()
        XCTAssertEqual(
            engine.importScript(from: write(fakeScript, named: "not-a-script.txt")),
            .failure(.notJavaScriptFile))
        XCTAssertEqual(
            engine.importScript(from: write("", named: "empty.js")),
            .failure(.emptyFile))
        XCTAssertEqual(
            engine.importScript(from: write("var x = 1;\n", named: "plain.js")),
            .failure(.missingLXMarker))
        let broken = engine.importScript(
            from: write("globalThis.lx.on('request', function () { let x = ; })",
                        named: "broken.js"))
        if case .failure(.syntaxError) = broken {
        } else {
            XCTFail("broken script must fail with .syntaxError, got \(broken)")
        }
    }

    // MARK: - URL import (stubbed transport)

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testImportFromURLDownloadsValidScript() {
        let engine = makeEngine()
        StubURLProtocol.handler = { _ in
            (200, self.fakeScript.data(using: .utf8)!)
        }
        let expectation = self.expectation(description: "url import")
        var imported: LxScriptInfo?
        engine.importScript(
            fromRemoteURL: URL(string: "https://example.com/fake.js")!,
            session: stubSession()
        ) { result in
            if case .success(let info) = result { imported = info }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNotNil(imported)
        XCTAssertTrue(imported?.id.hasPrefix("custom:file:") == true)
        XCTAssertFalse(LXScriptStore(documentsDirectory: docs)
            .customScripts().isEmpty)
    }

    func testImportFromURLRejects404() {
        let engine = makeEngine()
        StubURLProtocol.handler = { _ in (404, Data()) }
        let expectation = self.expectation(description: "url 404")
        var result: Result<LxScriptInfo, LXScriptImportError>?
        engine.importScript(
            fromRemoteURL: URL(string: "https://example.com/fake.js")!,
            session: stubSession()
        ) { outcome in
            result = outcome
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        if case .failure(.downloadFailed) = result {
        } else {
            XCTFail("404 must fail with .downloadFailed, got \(String(describing: result))")
        }
    }

    func testImportFromURLRejectsNonScriptBody() {
        let engine = makeEngine()
        StubURLProtocol.handler = { _ in
            (200, "hello, not a script".data(using: .utf8)!)
        }
        let expectation = self.expectation(description: "url non-script")
        var result: Result<LxScriptInfo, LXScriptImportError>?
        engine.importScript(
            fromRemoteURL: URL(string: "https://example.com/fake.js")!,
            session: stubSession()
        ) { outcome in
            result = outcome
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        if case .failure(.missingLXMarker) = result {
        } else {
            XCTFail("non-script body must fail with .missingLXMarker, got \(String(describing: result))")
        }
    }

    func testImportFromURLRejectsNonJsAddressWithoutNetwork() {
        let engine = makeEngine()
        var called = false
        StubURLProtocol.handler = { _ in
            called = true
            return (200, self.fakeScript.data(using: .utf8)!)
        }
        let expectation = self.expectation(description: "url non-js")
        var result: Result<LxScriptInfo, LXScriptImportError>?
        engine.importScript(
            fromRemoteURL: URL(string: "https://example.com/fake.txt")!,
            session: stubSession()
        ) { outcome in
            result = outcome
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        if case .failure(.notJavaScriptFile) = result {
        } else {
            XCTFail("non-.js address must fail with .notJavaScriptFile, got \(String(describing: result))")
        }
        XCTAssertFalse(called, "a non-.js address must never be fetched")
    }

    // MARK: - Legacy URL-only records

    func testLoadSkipsLegacyURLOnlyRecord() {
        let engine = makeEngine()
        let store = LXScriptStore(documentsDirectory: docs)
        store.saveCustomScript(LxCustomScriptRecord(
            id: "custom:url:0123456789ab", name: "example.com",
            url: "https://example.com/legacy.js", fileName: "",
            addedAt: Date()))
        let expectation = self.expectation(description: "init skips legacy")
        var snapshot: [LxScriptInfo] = []
        engine.ensureInitialized { infos in
            snapshot = infos
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertFalse(snapshot.contains(where: { $0.id == "custom:url:0123456789ab" }),
                       "a record with no downloaded file must not load")
    }
}

/// Stub transport: answers every request from `handler`, so URL
/// import tests never touch the network.
private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (statusCode: Int, data: Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
