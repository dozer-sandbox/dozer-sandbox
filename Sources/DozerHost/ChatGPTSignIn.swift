import Darwin
import Foundation
import DozerKit

// 599i — Dozer's OWN ChatGPT sign-in, on this Mac (`doz account add NAME --chatgpt`). The same browser
// flow Codex's `codex login` runs (0.160.1 `login/src/server.rs`): PKCE S256, Codex's public client, its
// scopes, a loopback callback on 127.0.0.1:1455 (else 1457) — then the code is exchanged with
// auth.openai.com from this Mac. The tokens go to the host as an `account-add` request (the one path a
// secret takes into an account) and live in the login keychain. Nothing is read from or written to the
// Mac's own ~/.codex, and no API key is minted from the id_token (Codex's optional token exchange).
//
// Tests: with DOZ_TEST_OPENAI_UPSTREAM the exchange goes to the fake (its CA only), the callback port is
// the OS's choice, and DOZ_TEST_OPEN_URL plays the browser (it GETs the callback with a test code).

public enum ChatGPTSignIn {
    /// How long the browser has to come back.
    public static let timeout: TimeInterval = 600

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ m: String) { message = m }
        public var errorDescription: String? { message }
    }

    /// Run the sign-in; `say` gets the lines a person reads (the URL included, for a browser that did not open).
    public static func run(environment env: [String: String] = ProcessInfo.processInfo.environment,
                           say: (String) -> Void) throws -> ChatGPTTokens {
        let override = OpenAISeam.upstream(environment: env)
        let ports: [UInt16] = override != nil ? [0] : OpenAIAccess.callbackPorts
        var listener: (fd: Int32, port: UInt16)?
        for p in ports { if let l = listen(port: p) { listener = l; break } }
        guard let (fd, port) = listener else {
            throw Failure("the sign-in's callback port (127.0.0.1:\(ports.map(String.init).joined(separator: " or "))) is in use — "
                          + "is another sign-in (codex login) waiting? Finish or cancel it, then try again")
        }
        defer { close(fd) }
        let (verifier, challenge) = OpenAIAccess.pkce()
        let state = OpenAIAccess.randomState()
        let url = OpenAIAccess.authorizeURL(port: port, challenge: challenge, state: state)
        say("Signing Dozer in to ChatGPT — your browser opens OpenAI's sign-in page (this is Dozer's own sign-in; your Mac's Codex login is not touched).")
        say("If the browser does not open, visit:\n  \(url.absoluteString)")
        guard BrowserBridge.open(url, callback: (host: "127.0.0.1", port: Int(port), path: OpenAIAccess.callbackPath), environment: env) else {
            throw Failure("could not open the browser — visit the address above")
        }
        say("Waiting for the browser (up to \(Int(timeout / 60)) minutes; Ctrl-C cancels)…")
        let code = try waitForCode(fd, state: state)
        say("Signed in — exchanging the code with OpenAI…")
        switch OpenAIAccess.exchange(code: code, verifier: verifier, redirectURI: OpenAIAccess.redirectURI(port: port), override: override) {
        case .success(let t): return t
        case .failure(let f): throw Failure(f.reason)
        }
    }

    /// Bind 127.0.0.1:`port` (0: the OS picks) and listen.
    static func listen(port: UInt16) -> (Int32, UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                            sin_port: in_port_t(port.bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return nil }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: got.sin_port))
    }

    /// Answer the browser's requests until the callback comes (or the time is up): its code, checked against `state`.
    static func waitForCode(_ fd: Int32, state: String) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&p, 1, 1000)
            if n < 0 { if errno == EINTR { continue }; throw Failure("the sign-in's callback stopped listening") }
            if n == 0 { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            defer { close(c) }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
            var head = [UInt8]()
            var buf = [UInt8](repeating: 0, count: 4096)
            while head.count < 16 << 10, head.firstRange(of: Array("\r\n\r\n".utf8)) == nil {
                let r = read(c, &buf, buf.count)
                if r <= 0 { break }
                head += buf[0..<r]
            }
            let line = String(decoding: head.prefix { $0 != 13 }, as: UTF8.self).split(separator: " ")
            guard line.count >= 2, line[0] == "GET", let comps = URLComponents(string: "http://127.0.0.1" + line[1]) else {
                respond(c, 400, "Bad request")
                continue
            }
            guard comps.path == OpenAIAccess.callbackPath else {
                respond(c, 404, "Not found")
                continue
            }
            let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            if let e = q["error"] {
                respond(c, 200, page("Sign-in not completed", "OpenAI said: \(e). You can close this tab and try again in Terminal."))
                throw Failure("OpenAI did not complete the sign-in (\(e)\(q["error_description"].map { ": \($0)" } ?? ""))")
            }
            guard q["state"] == state else {
                respond(c, 400, page("Sign-in refused", "This answer was not for this sign-in. You can close this tab."))
                throw Failure("the browser's answer did not belong to this sign-in (state mismatch) — try again")
            }
            guard let code = q["code"], !code.isEmpty else {
                respond(c, 400, page("Sign-in not completed", "No code came back. You can close this tab and try again."))
                throw Failure("the browser came back without a code — try again")
            }
            respond(c, 200, page("Signed in to ChatGPT for Dozer Sandbox", "You can close this tab and go back to Terminal."))
            return code
        }
        throw Failure("no answer from the browser within \(Int(timeout / 60)) minutes — run the command again")
    }

    static func page(_ title: String, _ text: String) -> String {
        "<!doctype html><meta charset=utf-8><title>\(title)</title><body style=\"font-family:-apple-system,sans-serif;margin:4em\"><h1>\(title)</h1><p>\(text)</p></body>"
    }

    static func respond(_ c: Int32, _ status: Int, _ body: String) {
        let b = Array(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(b.count)\r\n\r\n"
        _ = UnixSocket.writeAll(c, Data(Array(head.utf8) + b))
    }
}
