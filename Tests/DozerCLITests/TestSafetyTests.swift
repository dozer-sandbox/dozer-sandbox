import XCTest
@testable import DozerHost
@testable import DozerCLI

/// 611: test safety by default — the guard's decisions, one by one (a forgotten seam STOPS a test run).
final class TestSafetyTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")

    func testGuardedByTheMakefileSeamOrXCTestAndLiftedOnlyExplicitly() {
        XCTAssertTrue(TestSafety.guarded(["DOZ_TEST_GUARD": "1"], inXCTest: false))
        XCTAssertTrue(TestSafety.guarded([:], inXCTest: true))
        XCTAssertFalse(TestSafety.guarded([:], inXCTest: false), "a person's doz is never guarded")
        XCTAssertFalse(TestSafety.guarded(["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1"], inXCTest: true))
        XCTAssertTrue(TestSafety.guarded(["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "yes"], inXCTest: false),
                      "only the exact opt-out lifts it")
    }

    func testTheDefaultStoreAndAnythingInsideItAreRefused() {
        let d = home.appendingPathComponent("Library/Application Support/dozer-sandbox")
        XCTAssertNotNil(TestSafety.storeViolation(d, home: home))
        XCTAssertNotNil(TestSafety.storeViolation(d.appendingPathComponent("sandboxes/x"), home: home))
        XCTAssertNotNil(TestSafety.storeViolation(URL(fileURLWithPath: d.path + "/./"), home: home))
        XCTAssertNil(TestSafety.storeViolation(URL(fileURLWithPath: "/tmp/doz-test-store"), home: home))
        XCTAssertNil(TestSafety.storeViolation(home.appendingPathComponent("Library/Application Support/dozer-sandbox-other"), home: home))
    }

    func testTheRealCodexHomeIsRefusedAndAScratchOneIsNot() {
        XCTAssertNotNil(TestSafety.codexHomeViolation(home.appendingPathComponent(".codex"), home: home))
        XCTAssertNotNil(TestSafety.codexHomeViolation(URL(fileURLWithPath: "/Users/someone/x/../.codex"), home: home))
        XCTAssertNil(TestSafety.codexHomeViolation(URL(fileURLWithPath: "/tmp/codex-home"), home: home))
    }

    func testClaudeCodesKeychainItemsAreRefusedAndDozersOwnAreNot() {
        XCTAssertNotNil(TestSafety.keychainViolation(service: "Claude Code-credentials"))
        XCTAssertNotNil(TestSafety.keychainViolation(service: ClaudeLogin.service(configDir: "/tmp/x")))
        XCTAssertNil(TestSafety.keychainViolation(service: "doz-anthropic:work"))
        XCTAssertNil(TestSafety.keychainViolation(service: "doz-test-limit-1"))
    }

    func testEnforceIsSilentWhenNotGuardedOrNothingIsWrong() {
        TestSafety.enforce(nil, env: ["DOZ_TEST_GUARD": "1"])
        TestSafety.enforce("anything", env: ["DOZ_TEST_REAL_MAC": "1"])
        TestSafety.checkStore(URL(fileURLWithPath: "/tmp/doz-ok"), env: ["DOZ_TEST_GUARD": "1"])
    }

    /// The CLI's own looks at the Mac's Claude login use an empty in-memory keychain under either seam.
    func testTheMacLoginKeychainIsAFakeUnderTheSeams() {
        XCTAssertTrue(macLoginKeychain(["DOZ_TEST_NO_MAC_LOGIN": "1"]) is MemoryKeychain)
        XCTAssertTrue(macLoginKeychain(["DOZ_TEST_CREDENTIALS": "memory"]) is MemoryKeychain)
        XCTAssertTrue(macLoginKeychain([:]) is SystemKeychain)
    }

    /// The guard is armed in this very run when `make test` runs it (DOZ_TEST_GUARD=1 is a forced default).
    func testTheMakefileArmsTheGuard() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DOZ_TEST_GUARD"] != nil, "run through make test")
        XCTAssertEqual(env["DOZ_TEST_GUARD"], "1")
        XCTAssertEqual(env["DOZ_TEST_CREDENTIALS"], "memory")
        XCTAssertEqual(env["DOZ_TEST_NO_MAC_LOGIN"], "1")
        XCTAssertNotNil(env["DOZ_TEST_CODEX_HOME"])
        let s = DozerSettings.load()
        let store = s.fileValues[SettingKey.storePath]
        let projects = s.fileValues[SettingKey.projectsDir]
        guard case .string(let sp)? = store, case .string(let pp)? = projects else { return XCTFail("the scratch doz.toml sets store.path and projects_dir") }
        XCTAssertNil(TestSafety.storeViolation(URL(fileURLWithPath: sp)))
        XCTAssertFalse(pp.contains("/Developer/"), "a test's new workspace is never under ~/Developer")
    }
}
