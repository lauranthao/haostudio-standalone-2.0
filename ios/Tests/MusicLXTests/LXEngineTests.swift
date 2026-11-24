// HAo Studio 2.0 — LX engine tests (S2-B).
//
// A fake script (no network, no bundled script): it registers a
// `request` handler routing `musicUrl` and sends `inited` synchronously. Covers load
// + dispatch, the `inited` timeout for a silent script, the
// import path (accepts a valid script, rejects a non-.js file and
// a syntax-broken script), and removal.

import Foundation
import XCTest

@testable import AppCore

final class LXEngineTests: XCTestCase {
    private var docs: URL!

    override func setUp() {
        super.setUp()
        docs = FileManager.default.temporaryDirectory
            .appendingPathComponent("hao-engine-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDown() {
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
    /// synchronous `inited`. (The engine dispatches every call as a
    /// `request` event with the function name in `data.action` —
    /// scripts never listen on the function name itself.)
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

    private func loadFake(_ engine: LXEngine, id: String = "fake1") -> LxScriptInfo? {
        let fileStore = LXScriptFileStore(documentsDirectory: docs)
        XCTAssertTrue(fileStore.write(code: fakeScript, fileName: "\(id).js"))
        let expectation = self.expectation(description: "load \(id)")
        var info: LxScriptInfo?
        engine.loadScript(id: id, name: "Fake") { result in
            if case .success(let loaded) = result { info = loaded }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return info
    }

    func testLoadFakeScriptRegistersTxMusicUrlSource() {
        let engine = makeEngine()
        let info = loadFake(engine)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.loaded, true)
        let tx = info?.sources.first(where: { $0.platform == "tx" })
        XCTAssertNotNil(tx)
        XCTAssertTrue(tx?.actions.contains("musicUrl") == true)
        XCTAssertEqual(engine.musicUrlSources(platform: "tx", quality: .standard128).count, 1)
    }

    func testRunScriptMusicUrlReturnsFakeUrl() {
        let engine = makeEngine()
        XCTAssertNotNil(loadFake(engine))
        let expectation = self.expectation(description: "musicUrl")
        var out: Any?
        var outError: Error?
        engine.runScript(
            sourceID: "fake1",
            function: "musicUrl",
            args: [["source": "tx", "songmid": "001"], "128k"]
        ) { result in
            switch result {
            case .success(let value): out = value
            case .failure(let error): outError = error
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(outError)
        XCTAssertEqual(out as? String, "https://example.com/fake.mp3")
    }

    func testRunScriptOnUnloadedScriptFails() {
        let engine = makeEngine()
        let expectation = self.expectation(description: "not loaded")
        var failed = false
        engine.runScript(sourceID: "nope", function: "musicUrl", args: [[], "128k"]) { result in
            if case .failure = result { failed = true }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(failed)
    }

    func testSilentScriptFailsInitedTimeout() {
        let engine = makeEngine(initedTimeout: 1)
        let fileStore = LXScriptFileStore(documentsDirectory: docs)
        XCTAssertTrue(fileStore.write(code: "// never sends inited\nvar x = 1;\n", fileName: "silent.js"))
        let expectation = self.expectation(description: "silent load")
        var timedOut = false
        engine.loadScript(id: "silent", name: "Silent") { result in
            if case .failure(let error) = result,
               case LXError.initedTimeout = error {
                timedOut = true
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(timedOut)
    }

    func testParseSourcesSkipsLocal() {
        let engine = makeEngine()
        let code = """
            globalThis.lx.send('inited', { status: true, sources: {
                local: { name: 'local', actions: ['musicUrl'], qualitys: ['128k'] },
                tx: { name: 'fake', actions: ['musicUrl'], qualitys: ['128k'] }
            } });
            """
        let fileStore = LXScriptFileStore(documentsDirectory: docs)
        XCTAssertTrue(fileStore.write(code: code, fileName: "withlocal.js"))
        let expectation = self.expectation(description: "load with local")
        var info: LxScriptInfo?
        engine.loadScript(id: "withlocal", name: "WithLocal") { result in
            if case .success(let loaded) = result { info = loaded }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(info?.sources.map { $0.platform }, ["tx"])
    }

    func testImportScriptAcceptsValidScript() {
        let engine = makeEngine()
        let source = docs.appendingPathComponent("import-me.js")
        try? fakeScript.write(to: source, atomically: true, encoding: .utf8)
        if case .success = engine.importScript(from: source) {
        } else {
            XCTFail("valid script must import")
        }
        // Registered as a custom script; the load follows async.
        let expectation = self.expectation(description: "import load")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertFalse(engine.scripts.filter { $0.id.hasPrefix("custom:file:") }.isEmpty)
    }

    func testImportScriptRejectsNonJsAndBrokenScript() {
        let engine = makeEngine()
        let txt = docs.appendingPathComponent("not-a-script.txt")
        try? fakeScript.write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            engine.importScript(from: txt),
            .failure(.notJavaScriptFile))
        let broken = docs.appendingPathComponent("broken.js")
        try? "globalThis.lx.on('musicUrl', function () { let x = ; })".write(
            to: broken, atomically: true, encoding: .utf8)
        if case .failure(.syntaxError) = engine.importScript(from: broken) {
        } else {
            XCTFail("broken script must fail with .syntaxError")
        }
    }

    func testRemoveScriptDropsRuntimeAndRegistry() {
        let engine = makeEngine()
        XCTAssertNotNil(loadFake(engine))
        XCTAssertNotNil(engine.runtime(for: "fake1"))
        engine.removeScript("fake1")
        let expectation = self.expectation(description: "remove settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(engine.runtime(for: "fake1"))
        XCTAssertNil(engine.script("fake1"))
    }
}
