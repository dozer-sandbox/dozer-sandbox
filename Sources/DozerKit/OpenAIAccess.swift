import CryptoKit
import Darwin
import Foundation
import NIOSSL

// 599i — OpenAI Codex as a first-class agent: the parts of its credentials the PROXY needs.
//
// Two kinds of OpenAI account (`AccountKind.openaiKey`, `.chatgpt` in DozerHost):
//   · an OpenAI API key — `Authorization: Bearer sk-…` on api.openai.com, like Anthropic's key: the guest
//     gets a placeholder (in OPENAI_API_KEY and in Codex's auth.json), the proxy swaps it;
//   · a ChatGPT plan — Dozer's OWN sign-in on the Mac (never the Mac's ~/.codex): an OAuth access token
//     (a JWT) on chatgpt.com/backend-api, refreshed ON THE MAC with the refresh token only Dozer holds.
//     The guest's ~/.codex/auth.json holds placeholders where the tokens go and an id_token whose
//     CLAIMS are the real ones (Codex reads the plan and the account id from it) but whose signature is
//     not — so nothing in the VM is a usable credential. Codex's own refresh request
//     (POST auth.openai.com/oauth/token) never leaves the Mac: the proxy answers it itself
//     (`OpenAIAccess.refreshAnswer`) with the same placeholders.

public enum OpenAIAccess {
    /// The hosts Codex sends a ChatGPT sign-in's access token to.
    public static let chatgptHosts = ["chatgpt.com"]
    /// The OpenAI API (an API key).
    public static let apiHosts = ["api.openai.com"]
    /// Where Codex refreshes a ChatGPT sign-in (answered by the proxy, never forwarded).
    public static let authHost = "auth.openai.com"
    public static let tokenPath = "/oauth/token"
    /// Every host whose upstream leg the test seam may redirect.
    public static let allHosts = chatgptHosts + apiHosts + [authHost]

    /// The claim namespace OpenAI puts the plan and the account id under.
    public static let authClaim = "https://api.openai.com/auth"

    // MARK: JWTs (claims only — never verified here; the Mac's copy came from auth.openai.com over TLS)

    /// A JWT's payload as JSON (nil: not a JWT).
    public static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let d = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// The `exp` of a JWT (nil: none, or not a JWT).
    public static func expiry(_ jwt: String) -> Date? {
        guard let e = claims(jwt)?["exp"] else { return nil }
        if let n = e as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }

    /// The ChatGPT account id (`chatgpt_account_id` in the auth claim of an id_token).
    public static func accountID(idToken: String) -> String? {
        (claims(idToken)?[authClaim] as? [String: Any])?["chatgpt_account_id"] as? String
    }

    /// The plan (`chatgpt_plan_type`: free, plus, pro, team, …).
    public static func planType(idToken: String) -> String? {
        (claims(idToken)?[authClaim] as? [String: Any])?["chatgpt_plan_type"] as? String
    }

    public static func email(idToken: String) -> String? { claims(idToken)?["email"] as? String }

    /// The id_token the GUEST gets: the same header and claims, and a signature that is not one
    /// (`doz-unsigned`), so it can never be presented anywhere as the real id_token.
    public static func guestIDToken(_ idToken: String) -> String? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, claims(idToken) != nil else { return nil }
        return "\(parts[0]).\(parts[1]).\(guestSignature)"
    }
    public static let guestSignature = "ZG96LXVuc2lnbmVk"   // base64url("doz-unsigned")

    /// 599i rc.2: the claims Codex 0.160.1 reads from an id_token (`login/src/token_data.rs` IdClaims,
    /// AccountUserClaims, exp) — everything else (organizations, …) dropped — as base64url JSON. What Dozer
    /// keeps of a sign-in (small), and what the guest's id_token carries.
    public static func keptClaims(idToken: String) -> String {
        let c = claims(idToken) ?? [:]
        var out: [String: Any] = [:]
        if let e = c["email"] as? String { out["email"] = e } else if let e = (c["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String { out["email"] = e }
        if let x = c["exp"] { out["exp"] = x }
        if let a = c[authClaim] as? [String: Any] {
            var k: [String: Any] = [:]
            for key in ["chatgpt_plan_type", "chatgpt_user_id", "user_id", "chatgpt_account_id", "chatgpt_account_is_fedramp", "chatgpt_account_user_id"] {
                if let v = a[key] { k[key] = v }
            }
            out[authClaim] = k
        }
        let d = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return base64URL(d)
    }

    /// An id_token made of kept claims and the `doz-unsigned` signature.
    public static func idToken(claims: String) -> String {
        base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8)) + "." + claims + "." + guestSignature
    }

    public static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let r = b.count % 4
        if r == 1 { return nil }
        if r > 0 { b += String(repeating: "=", count: 4 - r) }
        return Data(base64Encoded: b)
    }

    public static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: the guest's auth.json

    /// `~/.codex/auth.json` for a ChatGPT sign-in: the placeholder where both tokens go, the id_token's
    /// claims (not its signature), the account id, and `last_refresh` = now (so Codex does not ask for a
    /// refresh it does not need).
    public static func guestAuthJSON(placeholder: String, guestIDToken: String, accountID: String?, now: Date = Date()) -> Data {
        var tokens: [String: Any] = ["id_token": guestIDToken, "access_token": placeholder, "refresh_token": placeholder]
        if let a = accountID { tokens["account_id"] = a }
        // `auth_mode` said explicitly: with none, Codex picks the mode from the fields (0.160.1 `manager.rs:1763-1780`).
        let obj: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": tokens, "last_refresh": iso8601(now)]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
    }

    /// `~/.codex/auth.json` for an API key: the placeholder in `OPENAI_API_KEY`.
    public static func guestAPIKeyAuthJSON(placeholder: String) -> Data {
        let obj: [String: Any] = ["auth_mode": "apikey", "OPENAI_API_KEY": placeholder]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
    }

    static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // MARK: the proxy's answer to Codex's own refresh

    /// What the proxy answers a guest refresh (`POST auth.openai.com/oauth/token`) whose body carries
    /// one of this sandbox's placeholders: 200 with the same placeholder for both tokens and the guest
    /// id_token, or — when the sign-in cannot be used — a 401 with why (an OAuth-shaped error Codex shows).
    public static func refreshAnswer(placeholder: String, guestIDToken: String?, problem: String?) -> [UInt8] {
        let status: Int
        let obj: [String: Any]
        if let problem {
            status = 401
            obj = ["error": "invalid_grant", "error_description": "doz: " + problem]
        } else {
            status = 200
            var o: [String: Any] = ["access_token": placeholder, "refresh_token": placeholder, "token_type": "Bearer", "expires_in": 3600]
            if let g = guestIDToken { o["id_token"] = g }
            obj = o
        }
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])).map(Array.init) ?? []
        let reason = status == 200 ? "OK" : "Unauthorized"
        return Array("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nX-Sandbox-Policy: credential\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// The proxy's own refusal for an OpenAI host, in OpenAI's error shape (Codex shows `message`).
    public static func refusal(_ code: Int, _ message: String) -> [UInt8] {
        let obj: [String: Any] = ["error": ["message": "doz: " + message, "type": code == 401 ? "invalid_request_error" : "permission_error",
                                            "code": code == 401 ? "doz_credential_unavailable" : "doz_refused"]]
        let b = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])).map(Array.init) ?? []
        let reason = code == 401 ? "Unauthorized" : "Forbidden"
        return Array("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nX-Sandbox-Policy: credential\r\nConnection: close\r\nContent-Length: \(b.count)\r\n\r\n".utf8) + b
    }

    public static func isOpenAIHost(_ host: String) -> Bool { allHosts.contains(host.lowercased()) }
}

// MARK: - the tokens, and the Mac's side of OpenAI's sign-in (599i)

/// A ChatGPT sign-in's tokens as Dozer holds them on the Mac (ONE keychain item, `doz-chatgpt:NAME`, as
/// this JSON). Never in a file, a log, an event or the guest. Its description is redacted.
public struct ChatGPTTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token", accessToken = "access_token", refreshToken = "refresh_token", accountID = "account_id"
    }

    public init(idToken: String, accessToken: String, refreshToken: String, accountID: String? = nil) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID ?? OpenAIAccess.accountID(idToken: idToken)
    }

    public var description: String { "ChatGPTTokens(<redacted>, account \(accountID ?? "?"))" }
    public var customMirror: Mirror { Mirror(self, children: ["tokens": "<redacted>", "accountID": accountID ?? "?"]) }

    /// The JSON the keychain item holds.
    public var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// From the keychain item (or the CLI's request): all three tokens, the id_token a JWT with claims.
    public static func parse(_ s: String) -> ChatGPTTokens? {
        guard let d = s.data(using: .utf8), let t = try? JSONDecoder().decode(ChatGPTTokens.self, from: d),
              !t.accessToken.isEmpty, !t.refreshToken.isEmpty, OpenAIAccess.claims(t.idToken) != nil else { return nil }
        var out = t
        if out.accountID == nil { out.accountID = OpenAIAccess.accountID(idToken: t.idToken) }
        return out
    }
}

/// One HTTPS exchange from the Mac over the SAME leg the proxy uses (`TLSUpstream`: verified against
/// this Mac's trust store — or, with `override`, ONLY the test seam's CA). HTTP/1.1, `Connection: close`.
public enum HTTPSOnce {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
    }

    public static func request(host: String, method: String, path: String, headers: [(String, String)] = [], body: Data = Data(),
                               override: EgressProxy.UpstreamOverride? = nil, timeout: TimeInterval = 30) -> Result<Response, CheckFailure> {
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.applicationProtocols = ["http/1.1"]
        guard let ctx = try? NIOSSLContext(configuration: cfg) else { return .failure("TLS could not be set up") }
        guard let u = TLSUpstream(host: host, port: 443, context: ctx, override: override) else {
            return .failure(CheckFailure("could not connect to \(host) from this Mac"))
        }
        defer { u.close() }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Dozer-Sandbox\r\nAccept: application/json\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if method != "GET" || !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        u.send(Array(head.utf8) + Array(body))
        var raw: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        loop: while Date() < deadline, raw.count < 4 << 20 {
            var p = pollfd(fd: u.fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 1000) <= 0 { continue }
            switch u.receive() {
            case .data(let d): raw += d
            case .closed: break loop
            case .failed(let why): return .failure(CheckFailure(why))
            }
        }
        guard let sep = raw.firstRange(of: Array("\r\n\r\n".utf8)) else { return .failure(CheckFailure("no answer from \(host)")) }
        let lines = String(decoding: raw[..<sep.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = lines.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") } ?? 0
        var hs: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            hs[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        var b = Data(raw[sep.upperBound...])
        if hs["transfer-encoding"]?.lowercased().contains("chunked") == true { b = GitHubAccess.dechunked(b) }
        return .success(Response(status: status, headers: hs, body: b))
    }
}

extension OpenAIAccess {
    /// Codex's public OAuth client (codex-rs `login/src/auth/manager.rs:1717`, 0.160.1): the tokens Dozer
    /// signs in for are Codex's own, used by Codex in the sandbox.
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let issuer = "https://auth.openai.com"
    /// Codex's scopes and authorize parameters (`login/src/server.rs:585-615`).
    public static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    /// The loopback ports Codex's redirect allow-list has (`server.rs:77-79`): 1455, else 1457.
    public static let callbackPorts: [UInt16] = [1455, 1457]
    public static let callbackPath = "/auth/callback"

    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }

    /// The browser's URL for a sign-in (PKCE S256).
    public static func authorizeURL(port: UInt16, challenge: String, state: String) -> URL {
        var c = URLComponents(string: issuer + "/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)), URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"), URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        // `+`/`:`/`/` in the scope and the redirect: encoded as a form would (URLComponents leaves some).
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// A PKCE verifier (64 random bytes, base64url) and its S256 challenge.
    public static func pkce() -> (verifier: String, challenge: String) {
        var raw = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytesShim.fill(&raw)
        let v = base64URL(Data(raw))
        return (v, base64URL(Data(SHA256.hash(data: Data(v.utf8)))))
    }

    public static func randomState() -> String {
        var raw = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytesShim.fill(&raw)
        return base64URL(Data(raw))
    }

    static func form(_ items: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    static func tokens(from r: HTTPSOnce.Response, previous: ChatGPTTokens? = nil) -> ChatGPTTokens? {
        guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { return nil }
        let id = (o["id_token"] as? String) ?? previous?.idToken
        let access = o["access_token"] as? String
        let refresh = (o["refresh_token"] as? String) ?? previous?.refreshToken
        guard let id, let access, let refresh, claims(id) != nil else { return nil }
        return ChatGPTTokens(idToken: id, accessToken: access, refreshToken: refresh, accountID: accountID(idToken: id) ?? previous?.accountID)
    }

    static func errorText(_ r: HTTPSOnce.Response) -> String {
        let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        if let e = o?["error"] as? [String: Any] { return (e["code"] as? String) ?? (e["message"] as? String) ?? "HTTP \(r.status)" }
        if let e = o?["error"] as? String { return e + ((o?["error_description"] as? String).map { ": \($0)" } ?? "") }
        return "HTTP \(r.status)"
    }

    /// The sign-in's code → tokens (a FORM post, as Codex's `oauth/client.rs:58-74`). No token exchange
    /// for an API key: Dozer never makes one.
    public static func exchange(code: String, verifier: String, redirectURI: String,
                                override: EgressProxy.UpstreamOverride? = nil) -> Result<ChatGPTTokens, CheckFailure> {
        let body = form([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                         ("client_id", clientID), ("code_verifier", verifier)])
        switch HTTPSOnce.request(host: authHost, method: "POST", path: tokenPath,
                                 headers: [("Content-Type", "application/x-www-form-urlencoded")], body: body, override: override) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            guard r.status == 200 else { return .failure(CheckFailure("OpenAI refused the sign-in (\(errorText(r)))")) }
            guard let t = tokens(from: r) else { return .failure("OpenAI's answer has no tokens") }
            return .success(t)
        }
    }

    public enum RefreshResult: Equatable, Sendable {
        case renewed(ChatGPTTokens)
        /// The sign-in has ended (401, `refresh_token_expired|reused|invalidated`): sign in again.
        case signedOut(String)
        /// Network, 5xx — says nothing about the sign-in; try again later.
        case unavailable(String)
    }

    /// A refresh ON THE MAC (JSON, as Codex's `oauth/client.rs:76-110`). The answer's refresh token is
    /// the new one (rotation) — the caller keeps it before it uses the access token.
    public static func refresh(_ t: ChatGPTTokens, override: EgressProxy.UpstreamOverride? = nil) -> RefreshResult {
        let obj: [String: String] = ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": t.refreshToken]
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        switch HTTPSOnce.request(host: authHost, method: "POST", path: tokenPath, headers: [("Content-Type", "application/json")], body: body, override: override) {
        case .failure(let f): return .unavailable(f.reason)
        case .success(let r):
            if r.status == 200, let n = tokens(from: r, previous: t) { return .renewed(n) }
            let why = errorText(r)
            if r.status == 400 || r.status == 401 || ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated", "invalid_grant"].contains(where: why.contains) {
                return .signedOut(why)
            }
            return .unavailable(why)
        }
    }

    /// An OpenAI API key, checked with one `GET api.openai.com/v1/models`: 200 ok, 401/403 refused.
    public static func checkKey(_ key: String, override: EgressProxy.UpstreamOverride? = nil) -> Result<Bool, CheckFailure> {
        switch HTTPSOnce.request(host: apiHosts[0], method: "GET", path: "/v1/models", headers: [("Authorization", "Bearer " + key)], override: override, timeout: 20) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            if r.status == 200 { return .success(true) }
            if r.status == 401 || r.status == 403 { return .success(false) }
            return .failure(CheckFailure(errorText(r)))
        }
    }

    /// The refresh token a guest's renewal request carries (JSON or a form), nil: none.
    public static func refreshToken(inRenewalBody body: [UInt8]) -> String? {
        let d = Data(body)
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o["refresh_token"] as? String }
        let text = String(decoding: body, as: UTF8.self)
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == "refresh_token" { return kv[1].removingPercentEncoding }
        }
        return nil
    }
}
