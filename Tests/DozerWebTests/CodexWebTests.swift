import Foundation
import DozerKit
@testable import DozerHost
import XCTest
@testable import DozerWeb

/// 599i: Codex in the dashboard's server side — the accounts table by agent, the OpenAI default, the typed
/// key route (an OpenAI key yes, a ChatGPT sign-in never — it is Dozer's own browser sign-in, from the CLI).
final class CodexWebTests: XCTestCase {
    func testTheAccountsProjectionKnowsCodex() throws {
        let row = AccountRow(name: "plan", kind: "chatgpt", plan: "plus", identity: "person@example.invalid", expiresAt: nil, verification: "verified",
                             isDefault: true, usedBy: [], state: "ok", keychainService: "doz-chatgpt:plan", fingerprint: "abc")
        let a = WebAccounts(accounts: [WebAccount(row)], defaultAccount: "mac", keepalive: false, openaiDefault: "plan")
        XCTAssertEqual(a.agents["codex"], ["codex-mac", "chatgpt", "openai-key"])
        XCTAssertEqual(a.agents["pi"], ["api-key"], "unchanged")
        XCTAssertEqual(a.agents["claude-code"], ["mac", "setup-token", "api-key"], "unchanged")
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertTrue(json.contains("\"openaiDefault\":\"plan\""))
    }

    /// The Accounts & keys page: a card per provider in Dozer's order, the tools each one's key serves (named), the
    /// providers with no key check, and when a key last worked — and still never a secret-shaped field.
    func testTheAccountsProjectionGroupsByProvider() throws {
        var row = AccountRow(name: "grok1", kind: "key", plan: nil, identity: nil, expiresAt: nil, verification: "verified",
                             isDefault: true, usedBy: ["box"], state: "ok", keychainService: "doz-key:grok1", fingerprint: "abc")
        row.provider = "xai"
        row.verifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let a = WebAccounts(accounts: [WebAccount(row)], defaultAccount: "mac", keepalive: false)
        XCTAssertEqual(Array(a.providers.prefix(2)), ["anthropic", "openai"])
        XCTAssertEqual(Set(a.providers).count, a.providers.count, "each provider once")
        XCTAssertTrue(a.providers.contains("xai"))
        XCTAssertTrue(a.providerTools["anthropic"]?.contains("claude-code") == true)
        XCTAssertTrue(a.providerTools["anthropic"]?.contains("pi") == true)
        XCTAssertEqual(a.providerTools["openai"]?.first, "codex")
        XCTAssertTrue(a.providerTools["xai"]?.contains("grok") == true, "\(a.providerTools["xai"] ?? [])")
        for ids in a.providerTools.values { for id in ids { XCTAssertNotNil(a.agentTitles[id], id) } }
        XCTAssertTrue(a.uncheckedProviders.contains("vercel-ai-gateway"))
        XCTAssertTrue(a.uncheckedProviders.contains("google-stitch"))
        XCTAssertFalse(a.uncheckedProviders.contains("xai"), "xAI's key is checked")
        XCTAssertFalse(a.uncheckedProviders.contains("anthropic"))
        XCTAssertEqual(a.accounts.first?.verifiedAt, row.verifiedAt)
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertTrue(json.contains("\"providerTools\""))
        XCTAssertFalse(json.contains("secret"))
    }

    func testTheKeyRouteTakesAnOpenAIKeyButNeverASignIn() throws {
        let ok = try WebAccountAdd.decode(Data(#"{"name":"openai","kind":"openai-key","secret":"sk-proj-0123456789abcdefghij"}"#.utf8))
        XCTAssertEqual(ok.kind, .openaiKey)
        XCTAssertFalse("\(ok)".contains("sk-proj"))
        for kind in ["chatgpt", "mac"] {
            XCTAssertThrowsError(try WebAccountAdd.decode(Data(#"{"name":"x","kind":"\#(kind)","secret":"0123456789abcdefghij0123"}"#.utf8)), kind) { e in
                XCTAssertTrue("\(e)".contains("api-key, setup-token, openai-key or key"), "\(e)")
            }
        }
        XCTAssertThrowsError(try WebAccountAdd.decode(Data(#"{"name":"o","kind":"openai-key","secret":"sk-proj-0123456789abcdefghij","plan":"max"}"#.utf8)),
                             "a plan is for a setup token only")
    }

    func testCodexIsAnImageTheFormsAccept() throws {
        let cfg = try WebOnboardingConfig.decode(Data(#"{"defaultImage":"codex","account":"later"}"#.utf8))
        XCTAssertEqual(cfg.defaultImage, "codex")
    }
}
