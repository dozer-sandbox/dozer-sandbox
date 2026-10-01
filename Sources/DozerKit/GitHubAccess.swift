import Foundation

// 599d (owner: "how do we optionally give the agent in the vm git credentials (ie. the same that are on
// the local machine) so it can operate the same way an agent would on the host. Another proxy credential
// insertion ?"): the user's GitHub login reaches GitHub through the proxy (`CredentialBinding.github`),
// and — unless "Push to GitHub" is on — only to READ. The proxy enforces that here, request by request,
// for the requests that carry the user's login (a swapped placeholder):
//
//   github.com       git fetch/clone (`…/info/refs?service=git-upload-pack`, `POST …/git-upload-pack`),
//                    any GET/HEAD; LFS downloads (`POST …/info/lfs/objects/batch` whose body says
//                    `"operation": "download"`). REFUSED: `git-receive-pack` (push) in either form, any
//                    other method.
//   api.github.com   GET/HEAD; `POST /graphql` only when its document is a QUERY (no mutation or
//                    subscription — parsed conservatively: anything this parser is unsure of is
//                    refused). REFUSED: every other POST/PATCH/PUT/DELETE.
//   uploads.github.com, codeload.github.com   GET/HEAD only.
//
// With push, everything passes (and the network log records each request's method and path — never a body).

public enum GitHubAccess {
    /// The hosts the user's login is swapped for (and decrypted on). raw.githubusercontent.com and
    /// objects.githubusercontent.com are not among them: they get no login (a placeholder sent there is
    /// refused like any other misplaced one).
    public static let credentialHosts = ["github.com", "api.github.com", "uploads.github.com", "codeload.github.com"]

    public enum Mode: String, Codable, Sendable, Equatable {
        case read, push
    }

    /// What a request needs before it is decided.
    public enum BodyKind: String, Sendable, Equatable {
        case graphQL, lfsBatch
    }

    public enum Verdict: Equatable, Sendable {
        case allow
        case refuse(String)
        /// Hold the request until its whole body is here (≤ `maximumBody`), then `classify(body:)`.
        case needsBody(BodyKind)
    }

    /// The most a held body may be; a larger one (or a chunked one) is refused in read mode.
    public static let maximumBody = 256 << 10

    /// The refusal's text, for a sandbox (`name`): what is off, and how to turn it on.
    public static func pushOff(_ name: String, _ what: String) -> String {
        "Dozer: \(what) — pushing to GitHub is off for \(name) (read-only). Turn on \"Push to GitHub\": doz net allow \(name) github:push"
    }

    /// One request carrying the user's GitHub login, in `mode`.
    public static func classify(mode: Mode, method: String, host: String, target: String, sandbox: String) -> Verdict {
        guard mode == .read else { return .allow }
        let m = method.uppercased()
        let h = host.lowercased()
        guard credentialHosts.contains(h) else { return .allow }
        let (rawPath, query) = split(target)
        // Judged decoded, without trailing slashes, case-folded — an encoded or padded name is the same name.
        var path = (rawPath.removingPercentEncoding ?? rawPath).lowercased()
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let readMethod = m == "GET" || m == "HEAD"
        switch h {
        case "github.com":
            // Conservative: receive-pack anywhere in the path or the query is a push.
            if path.contains("receive-pack") || (query.removingPercentEncoding ?? query).lowercased().contains("receive-pack") {
                return .refuse(pushOff(sandbox, "git push refused"))
            }
            if readMethod { return .allow }
            if m == "POST", path.hasSuffix("/git-upload-pack") { return .allow }
            if m == "POST", path.hasSuffix("/info/lfs/objects/batch") { return .needsBody(.lfsBatch) }
            return .refuse(pushOff(sandbox, "\(m) \(path) refused"))
        case "api.github.com":
            if readMethod { return .allow }
            if m == "POST", path == "/graphql" { return .needsBody(.graphQL) }
            return .refuse(pushOff(sandbox, "\(m) \(path) refused (it would change something on GitHub)"))
        default:
            return readMethod ? .allow : .refuse(pushOff(sandbox, "\(m) to \(h) refused"))
        }
    }

    /// A held request's body decides it (read mode).
    public static func classify(body: [UInt8], kind: BodyKind, sandbox: String) -> Verdict {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            return .refuse(pushOff(sandbox, "a request Dozer could not read was refused"))
        }
        switch kind {
        case .lfsBatch:
            return (obj["operation"] as? String) == "download" ? .allow : .refuse(pushOff(sandbox, "an LFS upload refused"))
        case .graphQL:
            guard let q = obj["query"] as? String else { return .refuse(pushOff(sandbox, "a GraphQL request without a query refused")) }
            switch graphQLIsQuery(q) {
            case true?: return .allow
            case false?: return .refuse(pushOff(sandbox, "a GraphQL mutation refused"))
            case nil: return .refuse(pushOff(sandbox, "a GraphQL request Dozer could not tell was read-only refused"))
            }
        }
    }

    /// true: every operation in `doc` is a query (or the `{ … }` shorthand); false: one is a mutation or
    /// a subscription; nil: unsure (anything but queries, fragments and well-formed brackets).
    /// Strings ("…", """…""") and comments (# …) are skipped; only TOP-LEVEL definitions count.
    public static func graphQLIsQuery(_ doc: String) -> Bool? {
        let s = Array(doc.unicodeScalars)
        var i = 0, depth = 0, paren = 0
        var expectDefinition = true, sawOperation = false
        func isNameStart(_ c: Unicode.Scalar) -> Bool { c == "_" || (c.value < 128 && CharacterSet.letters.contains(c)) }
        func isName(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || (c.value >= 48 && c.value <= 57) }
        while i < s.count {
            let c = s[i]
            switch c {
            case " ", "\t", "\n", "\r", ",", "\u{FEFF}":
                i += 1
            case "#":
                while i < s.count, s[i] != "\n", s[i] != "\r" { i += 1 }
            case "\"":
                if i + 2 < s.count, s[i + 1] == "\"", s[i + 2] == "\"" {
                    i += 3
                    var closed = false
                    while i < s.count {
                        if s[i] == "\\", i + 3 < s.count, s[i + 1] == "\"", s[i + 2] == "\"", s[i + 3] == "\"" { i += 4; continue }
                        if s[i] == "\"", i + 2 < s.count, s[i + 1] == "\"", s[i + 2] == "\"" { i += 3; closed = true; break }
                        i += 1
                    }
                    if !closed { return nil }
                } else {
                    i += 1
                    var closed = false
                    while i < s.count {
                        if s[i] == "\\" { i += 2; continue }
                        if s[i] == "\n" { return nil }
                        if s[i] == "\"" { i += 1; closed = true; break }
                        i += 1
                    }
                    if !closed { return nil }
                }
            case "{":
                if depth == 0, paren == 0 {
                    if expectDefinition { sawOperation = true }          // the `{ … }` shorthand is a query
                    expectDefinition = false
                }
                depth += 1
                i += 1
            case "}":
                depth -= 1
                if depth < 0 { return nil }
                if depth == 0, paren == 0 { expectDefinition = true }
                i += 1
            case "(":
                paren += 1; i += 1
            case ")":
                paren -= 1
                if paren < 0 { return nil }
                i += 1
            default:
                if isNameStart(c) {
                    var j = i
                    while j < s.count, isName(s[j]) { j += 1 }
                    let word = String(String.UnicodeScalarView(s[i..<j]))
                    if depth == 0, paren == 0, expectDefinition {
                        switch word {
                        case "query": sawOperation = true
                        case "fragment": break
                        case "mutation", "subscription": return false
                        default: return nil
                        }
                        expectDefinition = false
                    }
                    i = j
                } else if depth == 0, paren == 0, expectDefinition {
                    return nil                                    // anything else where a definition starts
                } else {
                    i += 1
                }
            }
        }
        return depth == 0 && paren == 0 && sawOperation ? true : nil
    }

    static func split(_ target: String) -> (path: String, query: String) {
        var t = target
        if t.hasPrefix("http://") || t.hasPrefix("https://"), let u = URLComponents(string: t) {
            t = u.percentEncodedPath + (u.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        let parts = t.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts.first ?? "/"), parts.count > 1 ? String(parts[1]) : "")
    }

    static func queryHas(_ query: String, _ name: String, _ value: String) -> Bool {
        query.split(separator: "&").contains { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return kv.count == 2 && (kv[0].removingPercentEncoding ?? String(kv[0])) == name
                && (kv[1].removingPercentEncoding ?? String(kv[1])) == value
        }
    }
}

/// 599d: what the proxy needs to know about this sandbox's GitHub login: the mode and its name (for the
/// refusal's text). nil on the proxy: the user's login is not this sandbox's (nothing to enforce).
public struct GitHubGate: Sendable, Equatable {
    public var mode: GitHubAccess.Mode
    public var sandbox: String
    public init(mode: GitHubAccess.Mode, sandbox: String) { self.mode = mode; self.sandbox = sandbox }
}
