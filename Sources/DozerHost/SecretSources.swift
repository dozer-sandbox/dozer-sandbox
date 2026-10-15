import CryptoKit
import Darwin
import Foundation
import DozerKit

// 617 (616.03 §7) — keys read from where the person already keeps them, AT THE MOMENT THEY ARE USED, on the Mac:
// 1Password (`op read`), AWS Secrets Manager (`aws secretsmanager get-secret-value`) or any command (argv, never a
// shell). An account stores only the REFERENCE (and a few allow-listed, non-secret tool variables); the host reads the
// value when a sandbox's request needs it (`CredentialVault.setProvider`), keeps it in memory for the account's TTL
// (55 minutes by default), and never writes it anywhere — not the keychain, not a file, not a log. A failure is the
// proxy's 401 naming the cause and the fix; never another account's key.

/// Where an account's key comes from.
public enum SecretSource: Codable, Equatable, Sendable {
    /// The login keychain (every account before 617; the default).
    case keychain(service: String)
    /// `op://vault/item/field`.
    case onePassword(reference: String)
    /// `arn:aws:secretsmanager:REGION:ACCOUNT:secret:NAME`, and a JSON key to take from the secret's string.
    case awsSecretsManager(arn: String, jsonKey: String?)
    /// An absolute program and its arguments, recorded at add time (and confirmed by the person).
    case command(program: String, arguments: [String])

    enum CodingKeys: String, CodingKey { case kind, service, reference, arn, jsonKey, program, arguments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "keychain": self = .keychain(service: try c.decode(String.self, forKey: .service))
        case "1password": self = .onePassword(reference: try c.decode(String.self, forKey: .reference))
        case "aws": self = .awsSecretsManager(arn: try c.decode(String.self, forKey: .arn), jsonKey: try c.decodeIfPresent(String.self, forKey: .jsonKey))
        case "command": self = .command(program: try c.decode(String.self, forKey: .program), arguments: try c.decode([String].self, forKey: .arguments))
        case let k: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown secret source \(k)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keychain(let s): try c.encode("keychain", forKey: .kind); try c.encode(s, forKey: .service)
        case .onePassword(let r): try c.encode("1password", forKey: .kind); try c.encode(r, forKey: .reference)
        case .awsSecretsManager(let a, let k): try c.encode("aws", forKey: .kind); try c.encode(a, forKey: .arn); try c.encodeIfPresent(k, forKey: .jsonKey)
        case .command(let p, let a): try c.encode("command", forKey: .kind); try c.encode(p, forKey: .program); try c.encode(a, forKey: .arguments)
        }
    }

    public var isKeychain: Bool { if case .keychain = self { return true }; return false }

    /// "1Password: op://Dev/xai/credential" — what a person reads (a reference, never a value).
    public var label: String {
        switch self {
        case .keychain(let s): "keychain: \(s)"
        case .onePassword(let r): "1Password: \(r)"
        case .awsSecretsManager(let a, let k): "AWS Secrets Manager: \(a)" + (k.map { "#\($0)" } ?? "")
        case .command(let p, let a): "command: " + ([p] + a).joined(separator: " ")
        }
    }

    /// The tool a person needs on this Mac for it (nil: none of its own).
    public var tool: String? {
        switch self {
        case .onePassword: "op"
        case .awsSecretsManager: "aws"
        default: nil
        }
    }

    // MARK: parsing what a person types

    /// `--from op://Vault/Item/field` or `--from aws:arn:aws:secretsmanager:…[#jsonKey]`.
    public static func parse(from s: String) throws -> SecretSource {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("op://") {
            let parts = t.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), t.count <= 512, !t.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw HostError(.invalid, "a 1Password reference is op://VAULT/ITEM/FIELD (no spaces) — op item get ITEM --format json shows the fields")
            }
            return .onePassword(reference: t)
        }
        if t.hasPrefix("aws:") {
            let rest = String(t.dropFirst(4))
            let (arn, key): (String, String?) = {
                guard let h = rest.lastIndex(of: "#") else { return (rest, nil) }
                return (String(rest[..<h]), String(rest[rest.index(after: h)...]))
            }()
            guard arn.range(of: #"^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$"#, options: .regularExpression) != nil else {
                throw HostError(.invalid, "an AWS secret is aws:arn:aws:secretsmanager:REGION:ACCOUNT:secret:NAME (optionally #jsonKey)")
            }
            if let key, key.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) == nil {
                throw HostError(.invalid, "the JSON key after # is letters, digits, _ . -")
            }
            return .awsSecretsManager(arn: arn, jsonKey: key)
        }
        throw HostError(.invalid, "--from takes op://VAULT/ITEM/FIELD (1Password) or aws:arn:aws:secretsmanager:… (AWS Secrets Manager); any other tool: --from-command")
    }

    /// The characters `--from-command` refuses anywhere (a shell would give them a meaning; this is never a shell).
    public static let shellCharacters: [String] = [";", "|", "&", "$(", "`", ">", "<", "\n", "\r"]

    /// `--from-command 'gh auth token'`: split ONCE with sh-like quoting into argv — no expansion, no pipes, no `;` —
    /// the program resolved to an absolute path (`resolve`, the standard locations), an absolute one checked.
    public static func parseCommand(_ s: String, resolve: (String) -> String?) throws -> SecretSource {
        for c in shellCharacters where s.contains(c) {
            throw HostError(.invalid, "--from-command runs a program with arguments, never a shell — no \(c == "\n" || c == "\r" ? "newline" : c); put a pipeline in a script file and give its path")
        }
        var argv: [String] = [], cur = "", quote: Character?, any = false, escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; any = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true } else { cur.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch; any = true
            case "\\": escaped = true
            case " ", "\t": if any { argv.append(cur); cur = ""; any = false }
            default: cur.append(ch); any = true
            }
        }
        guard quote == nil, !escaped else { throw HostError(.invalid, "--from-command: an unclosed quote") }
        if any { argv.append(cur) }
        guard let first = argv.first, !first.isEmpty else { throw HostError(.invalid, "--from-command: which program?") }
        if first.contains("$") || first.contains("*") || first.contains("~") && !first.hasPrefix("~/") { throw HostError(.invalid, "--from-command: the program is a name or a path, nothing a shell would expand") }
        let program: String
        if first.contains("/") {
            let p = (first as NSString).expandingTildeInPath
            guard p.hasPrefix("/") else { throw HostError(.invalid, "--from-command: a program path must be absolute (\(first))") }
            program = URL(fileURLWithPath: p).standardizedFileURL.path
        } else {
            guard let r = resolve(first) else { throw HostError(.notFound, "--from-command: no program \(first) in \(SecretSources.standardPath)") }
            program = r
        }
        guard FileManager.default.isExecutableFile(atPath: program) else { throw HostError(.invalid, "--from-command: \(program) is not an executable file") }
        return .command(program: program, arguments: Array(argv.dropFirst()))
    }
}

/// The result of running a source's program (never logged; `stdout` is the secret).
struct SecretRun {
    var status: Int32
    var stdout: Data
    /// Only to classify a failure — never shown, never logged.
    var stderr: String
    var timedOut: Bool
    var notFound: Bool
}

public enum SecretSources {
    /// The non-secret tool variables an account may carry (`--env K=V`).
    public static let allowedEnvironment = ["OP_ACCOUNT", "AWS_PROFILE", "AWS_REGION", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE"]
    public static let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    public static let defaultTTL = 3300
    /// The most a source's output may be.
    static let outputCap = 8 << 10

    /// `--env K=V` checked against the allow-list.
    public static func checkEnvironment(_ env: [String: String]) throws {
        for (k, v) in env {
            guard allowedEnvironment.contains(k) else {
                throw HostError(.invalid, "--env \(k): only \(allowedEnvironment.joined(separator: ", ")) (never a secret — a token stays in your own environment)")
            }
            guard !v.isEmpty, v.count <= 512, !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw HostError(.invalid, "--env \(k): a plain value")
            }
        }
    }

    /// `55m`, `3300`, `2h`, `90s` → seconds (1 minute … 24 hours).
    public static func parseTTL(_ s: String) -> Int? {
        let t = s.lowercased()
        let (num, mult): (Substring, Int) = t.hasSuffix("h") ? (t.dropLast(), 3600) : t.hasSuffix("m") ? (t.dropLast(), 60) : t.hasSuffix("s") ? (t.dropLast(), 1) : (Substring(t), 1)
        guard let n = Int(num), n > 0 else { return nil }
        let v = n * mult
        return (60...86_400).contains(v) ? v : nil
    }

    /// A program on the standard locations (nil: not installed).
    public static func locate(_ name: String) -> String? {
        for d in standardPath.split(separator: ":") {
            let p = "\(d)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Doctor: an account's source tool that is not installed (nil: installed, or no tool) — "op is not installed …".
    public static func missingTool(_ s: SecretSource, environment env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let t = s.tool else {
            if case .command(let p, _) = s, !FileManager.default.isExecutableFile(atPath: p) { return "\(p) is not an executable file any more" }
            return nil
        }
        let found = toolProgram(t, environment: env)
        if let r = found.refusal { return r }
        if found.path == nil { return t == "op" ? "1Password's op is not installed (brew install 1password-cli)" : "the AWS CLI is not installed (brew install awscli)" }
        return nil
    }

    /// The program for a tool: the test seam (`DOZ_TEST_OP` / `DOZ_TEST_AWS`), else the standard locations. A guarded
    /// test run never runs the REAL op or aws (TestSafety) — it says so instead.
    static func toolProgram(_ tool: String, environment env: [String: String]) -> (path: String?, refusal: String?) {
        if let fake = env["DOZ_TEST_\(tool.uppercased())"], !fake.isEmpty { return (fake, nil) }
        if TestSafety.guarded(env) { return (nil, TestSafety.secretToolViolation(tool)) }
        return (locate(tool), nil)
    }

    /// sha256 of the reference and its tool variables (the cached value's version, beside the account's generation).
    public static func fingerprint(_ s: SecretSource, environment env: [String: String]) -> String {
        let material = s.label + "|" + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: reading

    /// Read the key now. `account`: its name, for the notice. Never throws; a failure is the notice the proxy
    /// answers with (the cause and the fix), never another key.
    /// `knownFingerprint`: the account's last key fingerprint — a failing tool's message is never shown when a word of
    /// it is that key (a tool that echoes what it read).
    public static func read(_ source: SecretSource, account: String, sourceEnv: [String: String],
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            knownFingerprint: String? = nil) -> CredentialVault.SecretRead {
        let from = "the key of account \(account) comes from \(source.label)"
        let argv: [String], timeout: TimeInterval
        switch source {
        case .keychain:
            return (nil, "\(from) — read it with the keychain")
        case .onePassword(let ref):
            let (p, refusal) = toolProgram("op", environment: environment)
            if let refusal { return (nil, "\(from), but \(refusal)") }
            guard let p else { return (nil, "\(from), but op is not installed on this Mac — brew install 1password-cli, then doz account refresh \(account)") }
            argv = [p, "read", "--no-newline", ref]
            timeout = 20
        case .awsSecretsManager(let arn, _):
            let (p, refusal) = toolProgram("aws", environment: environment)
            if let refusal { return (nil, "\(from), but \(refusal)") }
            guard let p else { return (nil, "\(from), but aws is not installed on this Mac — brew install awscli, then doz account refresh \(account)") }
            argv = [p, "secretsmanager", "get-secret-value", "--secret-id", arn, "--query", "SecretString", "--output", "text"]
            timeout = 10
        case .command(let p, let args):
            guard FileManager.default.isExecutableFile(atPath: p) else { return (nil, "\(from), but \(p) is not there any more — add the account again with --from-command") }
            argv = [p] + args
            timeout = 10
        }
        let r = run(argv, environment: toolEnvironment(environment, sourceEnv: sourceEnv), timeout: timeout)
        let tool = (argv[0] as NSString).lastPathComponent
        if r.notFound { return (nil, "\(from), but \(argv[0]) could not be run") }
        if r.timedOut {
            if case .onePassword = source {
                return (nil, "\(from), but op did not answer within 20 s (a Touch ID prompt nobody saw?) — run op signin\(opAccount(sourceEnv)), then doz account refresh \(account)")
            }
            return (nil, "\(from), but \(tool) timed out after \(Int(timeout)) s — check it on this Mac, then doz account refresh \(account)")
        }
        if r.status != 0 {
            return (nil, from + ", but " + classify(source, r, account: account, sourceEnv: sourceEnv, program: argv[0], knownFingerprint: knownFingerprint))
        }
        guard var value = clean(r.stdout) else {
            return (nil, "\(from), but \(tool) answered nothing usable (empty, more than one line, control characters or over 8 KiB)")
        }
        if case .awsSecretsManager(_, let key?) = source {
            guard let o = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], let v = o[key] as? String, let c = clean(Data(v.utf8)) else {
                return (nil, "\(from), but its secret has no string field \(key)")
            }
            value = c
        }
        return (value, nil)
    }

    /// The variables of the host's own environment a tool runs with — who and where (HOME, USER, …), and the tools'
    /// own sign-in variables the person gave the host (OP_SERVICE_ACCOUNT_TOKEN, AWS_*); nothing else of the host's
    /// (never a DOZ_ variable). Then the standard PATH and the account's allow-listed variables.
    static let passedThrough = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "XDG_CONFIG_HOME"]
    static let passedThroughPrefixes = ["OP_", "AWS_"]

    static func toolEnvironment(_ host: [String: String], sourceEnv: [String: String]) -> [String: String] {
        var env = host.filter { kv in passedThrough.contains(kv.key) || passedThroughPrefixes.contains { kv.key.hasPrefix($0) } }
        env["PATH"] = standardPath
        env.merge(sourceEnv.filter { allowedEnvironment.contains($0.key) }) { _, b in b }
        return env
    }

    static func opAccount(_ env: [String: String]) -> String { env["OP_ACCOUNT"].map { " --account \($0)" } ?? "" }

    /// Why a tool failed, in three parts (owner, after an opaque "exited 44"): the TOOL'S OWN WORDS — the first line of
    /// its stderr, made inert and short (`firstErrorLine`); a plain reason for the codes and messages that are known;
    /// and what to do. stdout is never used (it may hold a key).
    static func classify(_ source: SecretSource, _ r: SecretRun, account: String, sourceEnv: [String: String],
                         program: String? = nil, knownFingerprint: String? = nil) -> String {
        let e = r.stderr.lowercased()
        // 1Password's and AWS's tools by their names; a command by its path (the person wrote it).
        let path = source.tool ?? program ?? "the tool"
        let words = firstErrorLine(r.stderr, tool: (path as NSString).lastPathComponent, knownFingerprint: knownFingerprint)
        let refresh = "doz account refresh \(account)"
        func told(_ reason: String?, _ fix: String) -> String {
            var s = words.map { "\(path) says: \($0)" } ?? "\(path) exited \(r.status)"
            if let reason { s += " (\(reason))" }
            return s + " — " + fix
        }
        switch source {
        case .onePassword:
            if e.contains("not signed in") || e.contains("not currently signed in") || e.contains("sign in") || e.contains("authorization") || e.contains("session expired") {
                return told("op is not signed in", "run op signin\(opAccount(sourceEnv)) (or give the host OP_SERVICE_ACCOUNT_TOKEN), then \(refresh)")
            }
            if e.contains("isn't an item") || e.contains("could not find") || e.contains("not found") || e.contains("no item") {
                return told("1Password has no such item or field", "check the reference with op read REF in Terminal, then \(refresh)")
            }
            return told(nil, "run op read REF in Terminal to see why, then \(refresh)")
        case .awsSecretsManager(let arn, _):
            for (code, what) in [("accessdenied", "AccessDenied: the profile may not read \(arn)"),
                                 ("resourcenotfound", "no secret \(arn)"),
                                 ("expiredtoken", "its AWS credentials expired — aws sso login\(sourceEnv["AWS_PROFILE"].map { " --profile \($0)" } ?? "")"),
                                 ("unable to locate credentials", "no AWS credentials on this Mac — aws configure (or --env AWS_PROFILE=…)")]
            where e.contains(code) { return told(what, "check it in Terminal, then \(refresh)") }
            return told(nil, "run the same get-secret-value in Terminal to see why, then \(refresh)")
        case .command(let p, _):
            return told(knownReason((p as NSString).lastPathComponent, status: r.status, stderr: e), "run that command in Terminal to check it, then \(refresh)")
        case .keychain:
            return "the keychain refused"
        }
    }

    /// Plain words for the exits and messages of the programs people use as a key's command.
    static func knownReason(_ tool: String, status: Int32, stderr e: String) -> String? {
        switch tool {
        case "security":
            switch status {
            case 44: return "the keychain has no such item"
            case 51: return "the keychain would have to ask you, and nobody can answer here"
            case 36: return "the keychain is locked"
            default: return nil
            }
        case "op":
            if e.contains("not signed in") || e.contains("sign in") || e.contains("session expired") { return "op is not signed in" }
            return nil
        case "aws":
            if e.contains("accessdenied") { return "AccessDenied" }
            if e.contains("expiredtoken") { return "its AWS credentials expired" }
            return nil
        case "gh":
            if e.contains("not logged in") || e.contains("gh auth login") || e.contains("authentication") { return "gh is not signed in — gh auth login" }
            return nil
        default: return nil
        }
    }

    /// The first non-empty line of a tool's stderr as a person may read it: control characters removed, the tool's own
    /// "name:" prefix and an API name ("SecKeychainSearchCopyNext:") dropped, at most 160 characters — and nothing at
    /// all when a word of it is the account's last key (its fingerprint matches).
    static func firstErrorLine(_ stderr: String, tool: String, knownFingerprint: String?) -> String? {
        guard var line = stderr.split(whereSeparator: \.isNewline).map({ String($0).trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        line = String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) })
        // A log prefix ("[ERROR] 2026/10/12 16:21:03 " — 1Password's op) is not the message.
        if let r = line.range(of: #"^\[[A-Z]+\]\s*(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}\s*)?"#, options: .regularExpression) { line = String(line[r.upperBound...]) }
        if let fp = knownFingerprint, !fp.isEmpty {
            for w in line.split(whereSeparator: { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "=" || $0 == ":" }) where w.count >= 8 {
                if CredentialFingerprint.of(String(w)) == fp { return nil }
            }
        }
        for _ in 0..<2 {
            // One word and a colon: the tool's own name, or an API's (capitalised) — never a sentence.
            if let r = line.range(of: #"^[A-Za-z][A-Za-z0-9_.-]*:\s+"#, options: .regularExpression),
               line[r].lowercased().hasPrefix(tool.lowercased() + ":") || line[r].first?.isUppercase == true {
                line = String(line[r.upperBound...])
            }
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    /// The output as a key: trimmed, one line, no control characters, not empty, ≤ 8 KiB.
    static func clean(_ d: Data) -> String? {
        guard d.count <= outputCap, let s = String(data: d, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\u{7f}" }) else { return nil }
        return t
    }

    /// `posix_spawn` of an absolute program with argv (no shell), its own process group, stdin /dev/null, stdout capped
    /// at 8 KiB, stderr captured; after `timeout` the whole group is killed.
    static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval) -> SecretRun {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { return SecretRun(status: -1, stdout: Data(), stderr: "", timedOut: false, notFound: true) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return SecretRun(status: -1, stdout: Data(), stderr: "", timedOut: false, notFound: true)
        }
        // Never inherited by anything else this process spawns meanwhile.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cArgs, cEnv)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return SecretRun(status: -1, stdout: Data(), stderr: "", timedOut: false, notFound: true)
        }
        var out = Data(), err = Data(), timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var open = [outPipe[0], errPipe[0]]
        var buf = [UInt8](repeating: 0, count: 4096)
        while !open.isEmpty {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { timedOut = true; break }
            var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let n = poll(&fds, nfds_t(fds.count), Int32(min(left, 1) * 1000))
            if n <= 0 { continue }
            for f in fds where f.revents != 0 {
                let got = Darwin.read(f.fd, &buf, buf.count)
                if got <= 0 { open.removeAll { $0 == f.fd }; continue }
                if f.fd == outPipe[0] {
                    if out.count <= outputCap { out.append(contentsOf: buf[0..<got]) }
                } else if err.count < 4096 {
                    err.append(contentsOf: buf[0..<got])
                }
            }
        }
        if timedOut { kill(-pid, SIGKILL) }
        var status: Int32 = 0
        // The program has closed its outputs (or was killed): reap it, killing the group if it lingers.
        let reapBy = Date().addingTimeInterval(2)
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() > reapBy { kill(-pid, SIGKILL); waitpid(pid, &status, 0); break }
            usleep(10_000)
        }
        close(outPipe[0]); close(errPipe[0])
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return SecretRun(status: timedOut ? -1 : code, stdout: out, stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut, notFound: false)
    }
}

/// The host's record of each account's reads: a generation (bumped by refresh, an edit, or an upstream 401) and the last
/// read's outcome (never the value). Shared with the proxy threads that read.
public final class SecretSourceState: @unchecked Sendable {
    public struct Outcome: Sendable, Equatable {
        public var ok: Bool
        public var notice: String?
        public var at: Date
    }
    private let lock = NSLock()
    private var generations: [String: Int] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var lastStale: [String: Date] = [:]
    /// Read counts (tests).
    private var reads: [String: Int] = [:]

    public init() {}

    public func generation(_ account: String) -> Int { lock.withLock { generations[account] ?? 0 } }
    public func bump(_ account: String) { lock.withLock { generations[account, default: 0] += 1 } }
    public func outcome(_ account: String) -> Outcome? { lock.withLock { outcomes[account] } }
    public func readCount(_ account: String) -> Int { lock.withLock { reads[account] ?? 0 } }

    func record(_ account: String, _ r: CredentialVault.SecretRead, now: Date = Date()) {
        lock.withLock {
            outcomes[account] = Outcome(ok: r.secret != nil, notice: r.notice, at: now)
            reads[account, default: 0] += 1
        }
    }

    /// The provider answered 401 to a request that carried this account's key: read it again — once per 10 s at most
    /// (a key that is simply wrong must not make every request re-run the tool).
    func staleAfterRejection(_ account: String, now: Date = Date()) {
        lock.withLock {
            if let t = lastStale[account], now.timeIntervalSince(t) < 10 { return }
            lastStale[account] = now
            generations[account, default: 0] += 1
        }
    }
}

extension TestSafety {
    /// A guarded test run never runs the person's real 1Password or AWS CLI (they would read real secrets).
    public static func secretToolViolation(_ tool: String) -> String {
        "TEST SAFETY: a test would run the real \(tool) — set DOZ_TEST_\(tool.uppercased()) to a fake (DOZ_TEST_REAL_MAC=1 lifts this deliberately)"
    }
}
