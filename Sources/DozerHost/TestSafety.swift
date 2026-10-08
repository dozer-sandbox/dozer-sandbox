import Foundation

/// Test safety by default (611). Tests and probes must never reach the person's real Dozer: the default store,
/// the Mac's own `~/.codex`, or the login keychain's Claude Code item. Three agents leaked into a real login in
/// one month, each through a test that forgot ONE seam — so the seams are the Makefile's DEFAULT for every test
/// target (`DOZ_TEST_GUARD=1` and the scratch values beside it), and this guard turns a forgotten one into a
/// hard stop instead of a quiet read of real data.
///
/// The guard is on when `DOZ_TEST_GUARD=1` (every `make test*` target, the probes' `guard-doz.sh`) or inside
/// XCTest, and off only when the run says so explicitly: `DOZ_TEST_REAL_MAC=1` (a person deliberately testing
/// against this Mac). It never changes behaviour outside a test run.
///
/// The decisions are pure functions (unit-tested); `enforce` stops the process with the reason.
public enum TestSafety {
    /// Is this process a guarded test run?
    public static func guarded(_ env: [String: String] = ProcessInfo.processInfo.environment,
                               inXCTest: Bool = NSClassFromString("XCTestCase") != nil) -> Bool {
        if env["DOZ_TEST_REAL_MAC"] == "1" { return false }
        return env["DOZ_TEST_GUARD"] == "1" || inXCTest
    }

    /// The person's real home (never `$HOME`, which a test may point elsewhere — the danger is the REAL one).
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The default store a person's Dozer uses.
    public static func defaultStore(home: URL = realHome) -> URL {
        home.appendingPathComponent("Library/Application Support/dozer-sandbox").standardizedFileURL
    }

    /// Why using `store` is refused in a guarded run (nil: allowed). The default store and anything inside it.
    public static func storeViolation(_ store: URL, home: URL = realHome) -> String? {
        let d = defaultStore(home: home).path
        let s = store.standardizedFileURL.resolvingSymlinksInPath().path
        guard s == d || s.hasPrefix(d + "/") || store.standardizedFileURL.path == d else { return nil }
        return "a test resolved the DEFAULT store (\(d)) — give it a scratch store (--store / DOZ_STORE, and store.path in a scratch XDG_CONFIG_HOME)"
    }

    // `codexHomeViolation` lives in CodexMacLogin.swift — the one file that may name the Mac's Codex home.

    /// Why touching keychain item `service` is refused (nil: allowed). Claude Code's own login items.
    public static func keychainViolation(service: String) -> String? {
        guard service.hasPrefix(ClaudeLogin.baseService) else { return nil }
        return "a test reached the login keychain's Claude Code item (\(service)) — set DOZ_TEST_CREDENTIALS=memory and DOZ_TEST_NO_MAC_LOGIN=1"
    }

    /// Stop a guarded run that is about to do what `violation` describes.
    public static func enforce(_ violation: String?, env: [String: String] = ProcessInfo.processInfo.environment) {
        guard let violation, guarded(env) else { return }
        FileHandle.standardError.write(Data("doz: TEST SAFETY: \(violation). (DOZ_TEST_REAL_MAC=1 lifts this guard deliberately.)\n".utf8))
        fatalError("TEST SAFETY: \(violation)")
    }

    public static func checkStore(_ store: URL, env: [String: String] = ProcessInfo.processInfo.environment) {
        guard guarded(env) else { return }
        enforce(storeViolation(store), env: env)
    }
}
