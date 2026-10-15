import DozerKit
import Foundation

/// 617: what reaches a preparation's build log (by way of `HostCore.buildOutputSink`): a step's whole output, or what
/// the bake ran.
public enum BuildRecordPiece: Sendable {
    case section(String, [String])
    case plan(BakePlan)
}

/// 617 (owner: "the objective is to show how the image was made including all the commands to build and configure"):
/// an image's build log as ONE document — what the web's build-log tab draws and `doz image log IMAGE` prints, from the
/// same data by the same builder. In order: the inputs (base with digest, kernel, guest init, the recipe and its
/// version, the bake network policy, the early steps and whether each was cached); then each step — a plain heading,
/// the command exactly as it ran (a script verbatim), every file it writes (path and contents, from the script's
/// heredocs), how it went, and its output; then each check (the command, what it expects, what it got); then the trim.
/// Nothing is reconstructed: the commands are the `BakePlan` the baker handed out as it ran.
public struct BuildLogDocument: Codable, Equatable, Sendable {
    public struct Fact: Codable, Equatable, Sendable {
        public var label: String
        public var value: String
    }
    public struct Early: Codable, Equatable, Sendable {
        public var label: String
        public var seconds: Double
        public var cached: Bool
        public var ok: Bool
    }
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var lines: [String]
        /// Long: shown folded (the web's details; the CLI prints it whole).
        public var long: Bool
    }
    public struct Step: Codable, Equatable, Sendable {
        /// A short plain label ("Install the developer baseline") — display only, never part of the image's key.
        public var title: String
        /// The spec's own name for it, as the progress showed it.
        public var name: String
        public var user: String
        public var environment: [Fact]
        /// How it was run ("bash -euo pipefail -c") and the script, verbatim, line by line; or the command alone.
        public var runner: String?
        public var script: [String]
        public var files: [File]
        public var seconds: Double?
        /// ran · failed · not run (a step after a failure).
        public var result: String
        public var error: String?
        public var output: [String]
    }
    public struct Check: Codable, Equatable, Sendable {
        public var title: String
        public var command: String
        public var expect: String
        public var got: [String]
        public var seconds: Double?
        public var result: String
        public var error: String?
    }
    public var image: String
    public var state: String
    public var finishedAt: Date
    public var seconds: Double
    public var error: String?
    public var inputs: [Fact]
    public var policy: [String]
    public var early: [Early]
    public var steps: [Step]
    public var checks: [Check]
    public var closing: [Early]
    /// The last command, the disk's trim (as root).
    public var trimCommand: String?
    /// A log without a recorded plan (kept by an earlier build): only the steps' names and their output.
    public var recorded: Bool
}

extension BuildLogs {
    // MARK: nothing secret-shaped is ever kept

    /// Credential-shaped text — API keys, tokens, JWTs, Dozer placeholders, a URL's password, a private key — replaced by
    /// "[redacted]". Bake scripts name no credential (ImageSpec's validation) and the bake environment is scrubbed, but a
    /// build log keeps commands, environments and a guest's output: whatever is shaped like a secret never reaches it.
    static let secretPatterns: [NSRegularExpression] = [
        #"sk-ant-[A-Za-z0-9_\-]{8,}"#, #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#, #"\bxai-[A-Za-z0-9_\-]{16,}"#,
        #"\bAIza[0-9A-Za-z_\-]{20,}"#, #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, #"doz_cred_[A-Za-z0-9_\-]{6,}"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=\-]{12,}"#,
        #"(?i)(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ s: String) -> String {
        var out = s
        for re in secretPatterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        return out
    }

    /// The whole record with every string scrubbed, and any environment value whose NAME is a credential's removed.
    public static func scrubbed(_ log: BuildLog) -> BuildLog {
        var l = log
        l.error = l.error.map(redact)
        l.steps = l.steps.map { var s = $0; s.label = redact(s.label); s.error = s.error.map(redact); s.output = s.output?.map(redact); return s }
        l.sections = l.sections.map { .init(label: redact($0.label), lines: $0.lines.map(redact)) }
        if var p = l.plan {
            p.steps = p.steps.map { st in
                var s = st
                s.name = redact(s.name)
                s.argv = s.argv.map(redact)
                s.environment = Dictionary(uniqueKeysWithValues: s.environment.compactMap { k, v in
                    BakeEnvironment.isCredential(k) ? nil : (k, redact(v)) })
                return s
            }
            p.checks = p.checks.map { var c = $0; c.argv = c.argv.map(redact); c.expect = c.expect.map(redact); return c }
            p.policyRules = p.policyRules.map(redact)
            l.plan = p
        }
        return l
    }

    // MARK: plain labels (display only)

    /// A step's short plain label. The spec's names are kept as they are (they are in the bake key); this only says them.
    public static func title(ofStep name: String, agentTitle: String?) -> String {
        let n = name.hasPrefix("step: ") ? String(name.dropFirst(6)) : name
        let l = n.lowercased()
        if l.hasPrefix("create the agent user") { return "Create the agent user" }
        if l.hasPrefix("install the developer baseline") { return "Install the developer baseline" }
        if l.range(of: #"^install the doz \S+ launcher"#, options: .regularExpression) != nil { return "Install the launcher" }
        if let m = n.range(of: #"@([0-9][0-9A-Za-z.+\-]*)"#, options: .regularExpression), l.hasPrefix("npm install") || l.hasPrefix("install ") {
            let version = String(n[m].dropFirst())
            return "Install " + (agentTitle ?? "the agent") + " " + version
        }
        // Otherwise the name itself: its first word capitalised, a long parenthesised list left out.
        let short = n.replacingOccurrences(of: #"\s*\([^)]{24,}\)"#, with: "", options: .regularExpression)
        return short.prefix(1).uppercased() + short.dropFirst()
    }

    /// A check's plain label, by what it checks (its marker, else its program).
    public static func title(ofCheck argv: [String], expect: String?) -> String {
        let all = argv.joined(separator: " ")
        switch expect {
        case "apt-lists-ok": return "Check: apt's package lists are kept"
        case "baseline-ok": return "Check: the developer baseline's tools are there"
        case "sudoers-ok": return "Check: sudo is installed"
        case "launcher-ok": return "Check: the launcher is installed"
        default: break
        }
        if argv.count == 2, argv[1] == "--version" { return "Check: \(argv[0]) runs (\(argv[0]) --version)" }
        return "Check: " + (all.count > 60 ? String(all.prefix(57)) + "…" : all)
    }

    // MARK: the files a step writes

    /// Every heredoc file a script writes (`cat > PATH <<'TAG'` … `TAG`, `>>` too), with its contents verbatim.
    public static func files(inScript script: String) -> [BuildLogDocument.File] {
        let lines = script.components(separatedBy: "\n")
        let head = try! NSRegularExpression(pattern: #"^\s*cat\s+>>?\s*(\S+)\s+<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?\s*$"#)
        var out: [BuildLogDocument.File] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if let m = head.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
               let p = Range(m.range(at: 1), in: l), let t = Range(m.range(at: 2), in: l) {
                let tag = String(l[t])
                var body: [String] = []
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: CharacterSet(charactersIn: "\t")) != tag { body.append(lines[j]); j += 1 }
                out.append(.init(path: String(l[p]), lines: body, long: body.count > 12))
                i = j + 1
                continue
            }
            i += 1
        }
        return out
    }

    // MARK: the document

    public static func document(_ log: BuildLog) -> BuildLogDocument {
        let agentTitle = ImageChoice.parse(log.image).map { $0.agent.title }.flatMap { $0 == "none" ? nil : $0 }
        // Every line inert as it enters the document (a guest's output may hold sequences; nothing of one is kept).
        let output = Dictionary(log.sections.map { ($0.label, $0.lines.map(verbatim)) }, uniquingKeysWith: { a, b in a + b })
        let timed = log.steps.filter { $0.kind != "transfer" }
        func timing(_ label: String) -> PreparationStep? {
            timed.first { $0.label == label || $0.label.hasPrefix(label + " → ") }
        }
        var inputs: [BuildLogDocument.Fact] = []
        var policy: [String] = []
        var steps: [BuildLogDocument.Step] = []
        var checks: [BuildLogDocument.Check] = []
        var used = Set<String>()
        if let p = log.plan {
            inputs.append(.init(label: "Base image", value: p.base))
            inputs.append(.init(label: "Kernel", value: "\(p.kernelFile) (sha256 \(p.kernelSHA256.prefix(16))…)"))
            inputs.append(.init(label: "Guest init", value: p.initfsReference))
            if let a = p.agent {
                inputs.append(.init(label: "Recipe", value: (ImageChoice.parse(log.image).map { $0.agent.rawValue } ?? log.image)
                                    + " — \(a.package) \(a.version)" + (a.integrity.map { " (integrity \($0))" } ?? "")))
            } else {
                inputs.append(.init(label: "Recipe", value: "none (no agent)"))
            }
            inputs.append(.init(label: "Image key", value: "\(p.key.prefix(12)) (base disk \(p.baseKey.prefix(12)))"))
            inputs.append(.init(label: "Bake VM", value: "\(p.cpus) CPUs, \(p.memoryMiB) MiB; the agent user \(p.user), home \(p.home)"))
            inputs.append(.init(label: "Bake network", value: p.network == "proxy"
                ? "no interface — only through the Mac's proxy, policy \(p.policyPreset ?? "custom") (anything else: \(p.policyDefault ?? "deny"))"
                : "a NAT interface"))
            policy = p.policyRules
            var failed = false
            for s in p.steps {
                let label = "step: " + s.name
                used.insert(label)
                let t = timing(label)
                let result = t.map { $0.kind == "failed" ? "failed" : "ran" } ?? (failed || log.state != "done" ? "not run" : "ran")
                if result == "failed" { failed = true }
                let isScript = s.argv.count >= 2 && ["bash", "sh"].contains(s.argv[0]) && s.argv.dropLast().last == "-c"
                let script = isScript ? s.argv.last! : ""
                steps.append(.init(title: title(ofStep: s.name, agentTitle: agentTitle), name: s.name, user: s.user ?? "root",
                                   environment: s.environment.sorted { $0.key < $1.key }.map { .init(label: $0.key, value: $0.value) },
                                   runner: isScript ? s.argv.dropLast().joined(separator: " ") : nil,
                                   script: (isScript ? script.components(separatedBy: "\n") : [s.argv.map(shellWord).joined(separator: " ")]).map(verbatim),
                                   files: isScript ? files(inScript: script).map { .init(path: verbatim($0.path), lines: $0.lines.map(verbatim), long: $0.long) } : [],
                                   seconds: t?.seconds, result: result, error: t?.error.map(verbatim), output: output[label] ?? []))
            }
            for c in p.checks {
                let label = "verify: " + c.argv.joined(separator: " ")
                used.insert(label)
                let t = timing(label)
                checks.append(.init(title: title(ofCheck: c.argv, expect: c.expect), command: c.argv.map(shellWord).joined(separator: " "),
                                    expect: c.expect.map { "exit 0, and the output contains “\($0)”" } ?? "exit 0",
                                    got: output[label] ?? [], seconds: t?.seconds,
                                    result: t.map { $0.kind == "failed" ? "failed" : "passed" } ?? "not run", error: t?.error.map(verbatim)))
            }
        }
        // The steps around the bake (kernel, guest init, base image and disk, the VM, its network; then the trim and
        // the stop): with their time and whether they were cached.
        var early: [BuildLogDocument.Early] = [], closing: [BuildLogDocument.Early] = []
        var afterBake = false
        for s in timed {
            let isBake = s.label.hasPrefix("step: ") || s.label.hasPrefix("verify: ")
            if isBake { afterBake = true; continue }
            let cached = s.label.contains("cached") || s.label.contains("already")
            let e = BuildLogDocument.Early(label: s.label, seconds: s.seconds, cached: cached, ok: s.kind != "failed")
            if afterBake { closing.append(e) } else { early.append(e) }
        }
        // A log an earlier build kept: its sections as they are.
        if log.plan == nil {
            for sec in log.sections where !used.contains(sec.label) {
                let t = timing(sec.label)
                steps.append(.init(title: title(ofStep: sec.label, agentTitle: agentTitle), name: sec.label, user: "", environment: [],
                                   runner: nil, script: [], files: [], seconds: t?.seconds,
                                   result: t.map { $0.kind == "failed" ? "failed" : "ran" } ?? "ran", error: t?.error.map(verbatim), output: sec.lines.map(verbatim)))
            }
        }
        return BuildLogDocument(image: log.image, state: log.state, finishedAt: log.finishedAt, seconds: log.seconds, error: log.error.map(verbatim),
                                inputs: inputs, policy: policy, early: early, steps: steps, checks: checks, closing: closing,
                                trimCommand: log.plan.map { $0.trimCommand.map(shellWord).joined(separator: " ") }, recorded: log.plan != nil)
    }

    /// One argv word as a shell would need it to be written (only when it has to be quoted).
    static func shellWord(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:@=,%".contains($0)) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The text with every control character removed (tabs kept) — the indentation and spacing exactly as written.
    public static func verbatim(_ s: String) -> String {
        // Whole escape sequences first (an OSC/DCS/APC/PM/SOS string to its BEL or ST, a CSI to its final byte, else ESC
        // and one character), so nothing of one is left as text either.
        var t = s
        for (re, _) in escapeSequences { t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "") }
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { u in
            !((u.value < 0x20 && u.value != 0x09) || (0x7F...0x9F).contains(u.value)) }))
    }

    static let escapeSequences: [(NSRegularExpression, String)] = [
        #"\x{1B}[\]P_^X][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)?"#, #"\x{1B}\[[0-?]*[ -/]*[@-~]"#, #"\x{1B}."#,
    ].compactMap { p in (try? NSRegularExpression(pattern: p)).map { ($0, p) } }

    // MARK: as plain text (doz image log), and for a terminal

    static func secs(_ s: Double) -> String { s >= 60 ? String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) : String(format: "%.1f s", s) }

    /// The document as plain text — what `doz image log IMAGE` prints. Every guest byte is inert.
    public static func plainText(_ d: BuildLogDocument) -> String {
        // Verbatim (indentation kept), but never a control character: no sequence from a script or a guest reaches a terminal.
        func t(_ s: String) -> String { verbatim(s) }
        var o: [String] = []
        let when = d.finishedAt.formatted(date: .abbreviated, time: .shortened)
        o.append("How \(d.image) was built — " + (d.state == "done" ? "built" : d.state) + " in \(secs(d.seconds)) · \(when)")
        if let e = d.error, d.state != "done" { o.append("  " + t(e)) }
        if !d.recorded { o.append("  (kept by an earlier doz: the commands were not recorded — the next build of \(d.image) records them)") }
        if !d.inputs.isEmpty || !d.early.isEmpty {
            o.append(""); o.append("== Inputs ==")
            for f in d.inputs { o.append("  \(f.label): \(t(f.value))") }
            if !d.policy.isEmpty {
                o.append("  Bake network policy:")
                for r in d.policy { o.append("    \(t(r))") }
            }
            for e in d.early { o.append("  " + (e.ok ? "✓" : "✗") + " \(t(e.label))  \(secs(e.seconds))" + (e.cached ? "  (cached)" : "")) }
        }
        for (n, s) in d.steps.enumerated() {
            o.append(""); o.append("== \(n + 1). \(t(s.title)) ==")
            o.append("  step: \(t(s.name)) · as \(s.user) · " + (s.result == "ran" ? "ran" + (s.seconds.map { " in \(secs($0))" } ?? "") : s.result)
                     + (s.error.map { " — \(t($0))" } ?? ""))
            if !s.environment.isEmpty {
                o.append("  environment:")
                for e in s.environment { o.append("    \(t(e.label))=\(t(e.value))") }
            }
            if let r = s.runner { o.append("  command: \(r) <<'SCRIPT'") } else if !s.script.isEmpty { o.append("  command:") }
            for l in s.script { o.append("    " + t(l)) }
            if s.runner != nil { o.append("  SCRIPT") }
            for f in s.files {
                o.append("  writes \(t(f.path)) (\(f.lines.count) lines):")
                for l in f.lines { o.append("    | " + t(l)) }
            }
            if !s.output.isEmpty {
                o.append("  output:")
                for l in s.output { o.append("    " + t(l)) }
            }
        }
        if !d.checks.isEmpty {
            o.append(""); o.append("== Checks ==")
            for c in d.checks {
                o.append("  " + (c.result == "passed" ? "✓" : c.result == "failed" ? "✗" : "·") + " \(t(c.title))" + (c.seconds.map { "  \(secs($0))" } ?? ""))
                o.append("    command: \(t(c.command))")
                o.append("    expects: \(t(c.expect))")
                o.append("    got: " + (c.got.isEmpty ? "(nothing)" : t(c.got[0])))
                for l in c.got.dropFirst() { o.append("         " + t(l)) }
                if let e = c.error { o.append("    error: \(t(e))") }
            }
        }
        if !d.closing.isEmpty {
            o.append(""); o.append("== After the steps ==")
            for e in d.closing { o.append("  " + (e.ok ? "✓" : "✗") + " \(t(e.label))  \(secs(e.seconds))") }
            if let c = d.trimCommand { o.append("  the trim, as root: \(t(c))") }
        }
        return o.joined(separator: "\n") + "\n"
    }
}
