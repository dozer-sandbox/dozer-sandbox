import CryptoKit
import Foundation
import XCTest
@testable import DozerKit

/// 599i: the proxy's side of Codex's credentials — JWT claims (never verified, never altered), the guest's
/// id_token and auth.json (placeholders only), the renewal answer, the bindings.
final class OpenAIAccessTests: XCTestCase {
    static func jwt(_ payload: [String: Any], signature: String = "c2lnbmF0dXJl") -> String {
        let h = OpenAIAccess.base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let p = OpenAIAccess.base64URL(try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        return "\(h).\(p).\(signature)"
    }

    nonisolated(unsafe) static let idClaims: [String: Any] = ["email": "person@example.invalid", "exp": 2_000_000_000,
                                          "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-123",
                                                                          "chatgpt_user_id": "user-9"]]

    func testClaimsAreReadNotVerified() throws {
        let id = Self.jwt(Self.idClaims)
        XCTAssertEqual(OpenAIAccess.accountID(idToken: id), "acct-123")
        XCTAssertEqual(OpenAIAccess.planType(idToken: id), "plus")
        XCTAssertEqual(OpenAIAccess.email(idToken: id), "person@example.invalid")
        XCTAssertEqual(OpenAIAccess.expiry(Self.jwt(["exp": 1_900_000_000])), Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertNil(OpenAIAccess.expiry("doz_cred_00"), "a placeholder is no JWT")
        XCTAssertNil(OpenAIAccess.claims("a.b"))
    }

    /// The guest's id_token: the same header and claims, a signature that is not one — never the real token.
    func testTheGuestsIDTokenHasTheClaimsButNotTheSignature() throws {
        let id = Self.jwt(Self.idClaims, signature: "UkVBTC1TSUdOQVRVUkU")
        let g = try XCTUnwrap(OpenAIAccess.guestIDToken(id))
        XCTAssertNotEqual(g, id)
        XCTAssertFalse(g.contains("UkVBTC1TSUdOQVRVUkU"))
        XCTAssertTrue(g.hasSuffix("." + OpenAIAccess.guestSignature))
        XCTAssertEqual(g.split(separator: ".").count, 3, "Codex needs three non-empty parts")
        XCTAssertEqual(OpenAIAccess.accountID(idToken: g), "acct-123")
        XCTAssertEqual(OpenAIAccess.planType(idToken: g), "plus")
        XCTAssertEqual(String(decoding: OpenAIAccess.base64URLDecode(OpenAIAccess.guestSignature)!, as: UTF8.self), "doz-unsigned")
        XCTAssertNil(OpenAIAccess.guestIDToken("not-a-jwt"))
    }

    /// auth.json as Codex 0.160.1 reads it: auth_mode said, a placeholder for both tokens, last_refresh set.
    func testTheGuestsAuthJSONHoldsPlaceholdersOnly() throws {
        let ph = "doz_cred_" + String(repeating: "ab", count: 24)
        let g = OpenAIAccess.guestIDToken(Self.jwt(Self.idClaims))!
        let d = OpenAIAccess.guestAuthJSON(placeholder: ph, guestIDToken: g, accountID: "acct-123", now: Date(timeIntervalSince1970: 1_800_000_000))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(o["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(o["OPENAI_API_KEY"] is NSNull, "a non-null key would make it an API-key login")
        let t = try XCTUnwrap(o["tokens"] as? [String: Any])
        XCTAssertEqual(t["access_token"] as? String, ph)
        XCTAssertEqual(t["refresh_token"] as? String, ph)
        XCTAssertEqual(t["id_token"] as? String, g)
        XCTAssertEqual(t["account_id"] as? String, "acct-123")
        XCTAssertEqual(o["last_refresh"] as? String, "2027-01-15T08:00:00.000Z")
        let k = try XCTUnwrap(try JSONSerialization.jsonObject(with: OpenAIAccess.guestAPIKeyAuthJSON(placeholder: ph)) as? [String: Any])
        XCTAssertEqual(k["auth_mode"] as? String, "apikey")
        XCTAssertEqual(k["OPENAI_API_KEY"] as? String, ph)
    }

    func testTheRenewalAnswer() throws {
        let ph = "doz_cred_" + String(repeating: "cd", count: 24)
        let ok = String(decoding: OpenAIAccess.refreshAnswer(placeholder: ph, guestIDToken: "a.b.c", problem: nil), as: UTF8.self)
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ok.components(separatedBy: "\r\n\r\n")[1].utf8)) as? [String: Any])
        XCTAssertEqual(body["access_token"] as? String, ph)
        XCTAssertEqual(body["refresh_token"] as? String, ph)
        XCTAssertEqual(body["id_token"] as? String, "a.b.c")
        let no = String(decoding: OpenAIAccess.refreshAnswer(placeholder: ph, guestIDToken: nil, problem: "signed out — doz account add x --chatgpt --force"), as: UTF8.self)
        XCTAssertTrue(no.hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue(no.contains("\"error\":\"invalid_grant\""))
        XCTAssertTrue(no.contains("doz: signed out"))
        XCTAssertFalse(no.contains(ph), "a refusal hands out nothing")
        // What the proxy finds in Codex's request (JSON, as 0.160.1 sends it — or a form).
        XCTAssertEqual(OpenAIAccess.refreshToken(inRenewalBody: Array(#"{"client_id":"x","grant_type":"refresh_token","refresh_token":"doz_cred_ab"}"#.utf8)), "doz_cred_ab")
        XCTAssertEqual(OpenAIAccess.refreshToken(inRenewalBody: Array("grant_type=refresh_token&refresh_token=doz_cred_ef".utf8)), "doz_cred_ef")
        XCTAssertNil(OpenAIAccess.refreshToken(inRenewalBody: Array("{}".utf8)))
    }

    func testTheRefusalIsOpenAIShaped() throws {
        let r = String(decoding: OpenAIAccess.refusal(401, "the account x has ended"), as: UTF8.self)
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 401 Unauthorized"))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.components(separatedBy: "\r\n\r\n")[1].utf8)) as? [String: Any])
        XCTAssertEqual((o["error"] as? [String: Any])?["message"] as? String, "doz: the account x has ended")
    }

    /// The sign-in is Codex's own flow: its client, scopes, parameters, a loopback redirect, PKCE S256.
    func testTheAuthorizeURLAndPKCE() throws {
        let (v, c) = OpenAIAccess.pkce()
        XCTAssertEqual(c, OpenAIAccess.base64URL(Data(SHA256.hash(data: Data(v.utf8)))))
        XCTAssertGreaterThanOrEqual(v.count, 43)
        let u = OpenAIAccess.authorizeURL(port: 1455, challenge: c, state: "st")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(u.host, "auth.openai.com")
        XCTAssertEqual(u.path, "/oauth/authorize")
        XCTAssertEqual(q["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(q["scope"], "openid profile email offline_access api.connectors.read api.connectors.invoke")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], c)
        XCTAssertEqual(q["state"], "st")
        XCTAssertEqual(q["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(q["originator"], "codex_cli_rs")
    }

    func testTokensParseAndNeverPrint() throws {
        let t = ChatGPTTokens(idToken: Self.jwt(Self.idClaims), accessToken: "at-SECRET", refreshToken: "rt-SECRET")
        XCTAssertEqual(t.accountID, "acct-123")
        XCTAssertEqual(ChatGPTTokens.parse(t.json), t)
        XCTAssertFalse("\(t)".contains("SECRET"))
        XCTAssertFalse(String(reflecting: t).contains("SECRET"))
        XCTAssertNil(ChatGPTTokens.parse(#"{"id_token":"x","access_token":"a","refresh_token":"r"}"#), "the id_token must be a JWT")
    }

    // MARK: the bindings

    func testTheChatGPTBindingIsSwapOnlyAndOnlyForItsHosts() throws {
        let v = CredentialVault()
        v.set(.chatgpt, secret: "ACCESS-REAL")
        v.set(.openai, secret: "sk-REAL")
        let ph = try XCTUnwrap(v.mintForFile("chatgpt"))
        // Codex's request: the placeholder in Bearer → the access token.
        let head = Array("POST /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nAuthorization: Bearer \(ph)\r\nChatGPT-Account-ID: acct-123\r\n\r\n".utf8)
        guard case .swapped(let out, binding: "chatgpt") = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail("not swapped") }
        let s = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(s.contains("Authorization: Bearer ACCESS-REAL\r\n"))
        XCTAssertTrue(s.contains("ChatGPT-Account-ID: acct-123"))
        XCTAssertFalse(s.contains(ph))
        // The WebSocket upgrade is a head like any other.
        let ws = Array("GET /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8)
        guard case .swapped = v.rewrite(head: ws, host: "chatgpt.com") else { return XCTFail("upgrade not swapped") }
        // Never added to a request without the placeholder (a page on chatgpt.com stays anonymous).
        let anon = Array("GET / HTTP/1.1\r\nHost: chatgpt.com\r\n\r\n".utf8)
        XCTAssertEqual(v.rewrite(head: anon, host: "chatgpt.com"), .passThrough(anon))
        // Never to another host — the API's key binding is not the sign-in's.
        let wrong = Array("POST /v1/responses HTTP/1.1\r\nHost: api.openai.com\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8)
        guard case .reject = v.rewrite(head: wrong, host: "api.openai.com") else { return XCTFail("a sign-in placeholder reached the API host") }
        // The API key: swapped on api.openai.com.
        let kph = try XCTUnwrap(v.mint("openai"))
        let api = Array("POST /v1/responses HTTP/1.1\r\nHost: api.openai.com\r\nAuthorization: Bearer \(kph)\r\n\r\n".utf8)
        guard case .swapped(let o2, binding: "openai") = v.rewrite(head: api, host: "api.openai.com") else { return XCTFail("key not swapped") }
        XCTAssertTrue(String(decoding: o2, as: UTF8.self).contains("Bearer sk-REAL"))
        XCTAssertEqual(v.binding(ofPlaceholder: ph), "chatgpt")
        XCTAssertEqual(CredentialBinding.chatgpt.placeholderVariables, [], "the sign-in's placeholder lives in auth.json, not a variable")
        XCTAssertEqual(CredentialBinding.openai.environmentVariable, "OPENAI_API_KEY")
    }

    /// No silent fallback: a sign-in that cannot be used is the proxy's 401 with why — the API key beside it never.
    func testAnUnusableSignInIsAnsweredWithWhyNeverTheKey() throws {
        let v = CredentialVault()
        v.set(.openai, secret: "sk-REAL")
        v.set(.chatgpt, secret: nil, expiresAt: nil, environment: [:], notice: "the ChatGPT sign-in of account x has ended — doz account add x --chatgpt --force")
        let ph = try XCTUnwrap(v.mintForFile("chatgpt"))
        let head = Array("POST /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8)
        guard case .refuse(401, let why) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail("not refused") }
        XCTAssertTrue(why.contains("doz account add x --chatgpt --force"))
    }

    /// A ChatGPT sign-in's renewal reads its source on use; the version change drops the cached read at once.
    func testTheSignInIsReadOnUseAndAGenerationChangeRereads() throws {
        let v = CredentialVault()
        let box = Box()
        v.setProvider(.chatgpt, ttl: 3600, version: { "\(box.generation)" }, read: { (box.token, nil) })
        let ph = try XCTUnwrap(v.mintForFile("chatgpt"))
        let head = Array("POST /x HTTP/1.1\r\nHost: chatgpt.com\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8)
        box.token = "T1"
        guard case .swapped(let a, _) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail() }
        XCTAssertTrue(String(decoding: a, as: UTF8.self).contains("Bearer T1"))
        box.token = "T2"
        guard case .swapped(let b, _) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail() }
        XCTAssertTrue(String(decoding: b, as: UTF8.self).contains("Bearer T1"), "cached within its ttl")
        box.generation += 1
        guard case .swapped(let c, _) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail() }
        XCTAssertTrue(String(decoding: c, as: UTF8.self).contains("Bearer T2"), "renewed: read again at once")
    }

    final class Box: @unchecked Sendable { var token = ""; var generation = 0 }
}
