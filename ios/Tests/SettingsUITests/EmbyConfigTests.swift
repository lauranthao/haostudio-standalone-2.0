// HAo Studio 2.0 — Emby config tests (S5, leg A).
//
// iOS-only (see SettingsStoreTests.swift header): unwired in
// `ios/Package.swift`, runs under the S7 Xcode test target.
// No network: `testConnection` runs against a canned fetcher /
// mutator injected through `makeClient`.
//
// Isolation: the Emby config file and the Keychain item are the
// REAL ones (EmbyConfigStore has no directory injection), so
// setUp backs the config file up and removes it, and tearDown
// restores it; the Keychain item is deleted in tearDown — the
// same pattern MigrationCoreTests/KeychainStoreTests uses. The
// Keychain tests skip when the runner cannot write to the
// Keychain instead of failing.

import Foundation
import XCTest

@testable import HAoStudio

@MainActor
final class EmbyConfigTests: XCTestCase {
    private var backedUpConfig: Data?
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        configURL = LocalStore.collectionURL(named: EmbyConfigStore.collectionName)
        backedUpConfig = try? Data(contentsOf: configURL)
        try? FileManager.default.removeItem(at: configURL)
        _ = KeychainStore.deleteEmbyApiKey()
    }

    override func tearDown() {
        if let backedUpConfig = backedUpConfig {
            try? backedUpConfig.write(to: configURL, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: configURL)
        }
        _ = KeychainStore.deleteEmbyApiKey()
        super.tearDown()
    }

    /// True when this runner lets the test write to the Keychain
    /// (same probe as KeychainStoreTests).
    private func requireKeychain() throws {
        let probeAccount = "hao-emby-config-probe"
        _ = KeychainStore.delete(account: probeAccount)
        guard KeychainStore.save("__probe__", account: probeAccount) else {
            throw XCTSkip("keychain write unavailable on this runner")
        }
        _ = KeychainStore.delete(account: probeAccount)
    }

    /// A client whose probe succeeds (System/Info + empty /Users)
    /// and whose password login succeeds.
    private func cannedClient() -> (EmbyServerConfig) -> EmbyClient {
        let fetcher: EmbyFetcher = { url, _, _, completion in
            if url.path.contains("System/Info") {
                completion(EmbyResponse(statusCode: 200, json: ["ServerName": "TestEmby", "Version": "4.8.0"]))
                return
            }
            if url.path.contains("/Users") {
                completion(EmbyResponse(statusCode: 200, json: [] as [Any]))
                return
            }
            completion(EmbyResponse(statusCode: 404, json: nil))
        }
        let mutator: EmbyMutator = { _, _, _, _, _, completion in
            completion(EmbyResponse(statusCode: 200, json: [
                "AccessToken": "tok-1",
                "User": ["Id": "user-1", "Name": "alice"],
            ]))
        }
        return { config in EmbyClient(config: config, fetcher: fetcher, mutator: mutator) }
    }

    // MARK: - Initial state

    func testStartsUnconfiguredWhenNothingStored() {
        let vm = EmbyConfigViewModel()
        XCTAssertEqual(vm.status, .unconfigured)
        XCTAssertEqual(vm.baseUrl, "")
    }

    func testEmptyAddressFailsWithoutNetwork() {
        let vm = EmbyConfigViewModel()
        vm.baseUrl = "   "
        vm.apiKey = "key"
        let expectation = self.expectation(description: "testConnection completes")
        vm.testConnection { ok in
            XCTAssertFalse(ok)
            XCTAssertEqual(vm.status, .failed(message: "请先填写服务器地址"))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testNoCredentialFailsWithoutNetwork() {
        let vm = EmbyConfigViewModel()
        vm.baseUrl = "http://emby.local:8096"
        let expectation = self.expectation(description: "testConnection completes")
        vm.testConnection { ok in
            XCTAssertFalse(ok)
            XCTAssertEqual(vm.status, .failed(message: "请填写 API 密钥或用户名密码"))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Probe / login (canned transport)

    func testProbeWithApiKeyConfigures() {
        let vm = EmbyConfigViewModel()
        vm.makeClient = cannedClient()
        vm.baseUrl = "http://emby.local:8096"
        vm.apiKey = "key-123"
        let expectation = self.expectation(description: "probe completes")
        vm.testConnection { ok in
            XCTAssertTrue(ok)
            XCTAssertEqual(vm.status, .configured(serverName: "TestEmby", version: "4.8.0"))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testPasswordLoginThenProbeConfigures() {
        let vm = EmbyConfigViewModel()
        vm.makeClient = cannedClient()
        vm.baseUrl = "http://emby.local:8096"
        vm.username = "alice"
        vm.password = "pw"
        let expectation = self.expectation(description: "login completes")
        vm.testConnection { ok in
            XCTAssertTrue(ok)
            XCTAssertEqual(vm.status, .configured(serverName: "TestEmby", version: "4.8.0"))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testFailedProbeReportsMessage() {
        let vm = EmbyConfigViewModel()
        vm.makeClient = { config in
            EmbyClient(config: config, fetcher: { _, _, _, completion in
                completion(EmbyResponse(statusCode: 0, json: nil))
            })
        }
        vm.baseUrl = "http://emby.local:8096"
        vm.apiKey = "key-123"
        let expectation = self.expectation(description: "probe fails")
        vm.testConnection { ok in
            XCTAssertFalse(ok)
            if case .failed(let message) = vm.status {
                XCTAssertFalse(message.isEmpty)
            } else {
                XCTFail("expected failed status, got \(vm.status)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Save validation (b35 sweep)

    /// An empty address never "saves": it used to return true and
    /// dismiss, leaving the user believing the server was set up.
    func testSaveWithEmptyAddressFails() {
        let vm = EmbyConfigViewModel()
        vm.baseUrl = "   "
        vm.apiKey = "key-123"
        XCTAssertFalse(vm.save())
        XCTAssertNil(EmbyConfigStore.load())
    }

    /// An address with no credential at all is not a config either.
    func testSaveWithAddressButNoCredentialFails() {
        let vm = EmbyConfigViewModel()
        vm.baseUrl = "http://emby.local:8096"
        XCTAssertFalse(vm.save())
        XCTAssertNil(EmbyConfigStore.load())
    }

    // MARK: - Credential field on load (b35 sweep)

    /// A password login round-trips as a token: the Keychain value
    /// lands in `accessToken` (keyed on the persisted user id),
    /// not in `apiKey`.
    func testPasswordLoginConfigRoundTripsAsToken() throws {
        try requireKeychain()
        var config = EmbyServerConfig(baseUrl: "http://emby.local:8096", username: "alice")
        config.accessToken = "tok-9"
        config.userId = "user-9"
        XCTAssertTrue(EmbyConfigStore.save(config))
        let loaded = EmbyConfigStore.load()
        XCTAssertEqual(loaded?.accessToken, "tok-9")
        XCTAssertEqual(loaded?.apiKey, "")
        XCTAssertEqual(loaded?.userId, "user-9")
        XCTAssertEqual(loaded?.usesPasswordAuth, true)
    }

    /// A key-only config round-trips as a key, never as a token.
    func testApiKeyConfigRoundTripsAsKey() throws {
        try requireKeychain()
        let config = EmbyServerConfig(baseUrl: "http://emby.local:8096", apiKey: "key-9")
        XCTAssertTrue(EmbyConfigStore.save(config))
        let loaded = EmbyConfigStore.load()
        XCTAssertEqual(loaded?.apiKey, "key-9")
        XCTAssertEqual(loaded?.accessToken, "")
        XCTAssertEqual(loaded?.usesPasswordAuth, false)
    }

    /// Switching from password login to key auth clears the user
    /// id, so the next load cannot mistake the key for a token —
    /// and the token no longer shows up in the API-key field.
    func testSwitchingToApiKeyClearsUserId() throws {
        try requireKeychain()
        var config = EmbyServerConfig(baseUrl: "http://emby.local:8096", username: "alice")
        config.accessToken = "tok-9"
        config.userId = "user-9"
        XCTAssertTrue(EmbyConfigStore.save(config))
        let vm = EmbyConfigViewModel()
        XCTAssertEqual(vm.apiKey, "")
        vm.apiKey = "new-key-1"
        XCTAssertTrue(vm.save())
        let loaded = EmbyConfigStore.load()
        XCTAssertEqual(loaded?.apiKey, "new-key-1")
        XCTAssertEqual(loaded?.accessToken, "")
        XCTAssertEqual(loaded?.userId, "")
        XCTAssertEqual(loaded?.usesPasswordAuth, false)
    }

    // MARK: - Save / clear (Keychain split)

    func testSavePutsCredentialInKeychainNotInFile() throws {
        try requireKeychain()
        let vm = EmbyConfigViewModel()
        vm.baseUrl = "http://emby.local:8096"
        vm.apiKey = "secret-key-xyz"
        vm.username = "alice"
        XCTAssertTrue(vm.save())
        // The password field is cleared on save (the token replaces it).
        XCTAssertEqual(vm.password, "")
        XCTAssertEqual(KeychainStore.loadEmbyApiKey(), "secret-key-xyz")
        // The JSON file on disk never carries the credential.
        let fileText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(fileText.contains("secret-key-xyz"))
        XCTAssertTrue(fileText.contains("emby.local"))
        // A fresh view model reads the stored config back.
        let reloaded = EmbyConfigViewModel()
        XCTAssertEqual(reloaded.baseUrl, "http://emby.local:8096")
        XCTAssertEqual(reloaded.apiKey, "secret-key-xyz")
        XCTAssertEqual(reloaded.status, .configured(serverName: "", version: ""))
    }

    func testClearForgetsEverything() throws {
        try requireKeychain()
        let vm = EmbyConfigViewModel()
        vm.baseUrl = "http://emby.local:8096"
        vm.apiKey = "secret-key-xyz"
        XCTAssertTrue(vm.save())
        vm.clear()
        XCTAssertEqual(vm.status, .unconfigured)
        XCTAssertEqual(vm.baseUrl, "")
        XCTAssertEqual(vm.apiKey, "")
        XCTAssertNil(KeychainStore.loadEmbyApiKey())
        XCTAssertNil(EmbyConfigStore.load())
    }
}
