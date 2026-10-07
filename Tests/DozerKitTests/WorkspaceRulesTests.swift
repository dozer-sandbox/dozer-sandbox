import DozMatch
import Foundation
import XCTest
@testable import DozerKit

/// 599g — workspace rules on the Mac side, and the ONE contract with the guest's C matcher: the Swift
/// matcher passes the same real-Docker vectors the C one does (DozMatchCTests), and the two agree on a
/// differential fuzz over the characters Docker treats specially (the C one was fuzzed against Go itself).
final class WorkspaceRulesTests: XCTestCase {
    static let root = DozMatchCTests.packageRoot

    // MARK: the vectors, through Swift

    func testEveryVectorThroughTheSwiftMatcher() throws {
        let root = try XCTUnwrap(try DozMatchCTests.fixture("dozignore-vectors.json") as? [String: Any])
        var pass = 0, ppass = 0, wpass = 0
        var failures: [String] = []
        for v in root["match"] as! [[String: Any]] {
            let id = v["id"] as! String, path = v["path"] as! String
            var pats = v["patterns"] as! [String]
            if let f = v["ignorefile"] as? String {
                let parsed = DockerIgnore.parse(f)
                if parsed == pats { ppass += 1 } else { failures.append("PARSE \(id)") }
                pats = parsed
            }
            let want = (v["newError"] as! Bool) ? "newError" : (v["matchError"] as! Bool) ? "matchError" : "\(v["excluded"] as! Bool)"
            let wantPR = v["excludedParentResults"] as! Bool
            var got: String, gotPR: Bool? = nil
            do {
                let d = try DockerIgnore(patterns: pats)
                do { got = "\(try d.isExcluded(path))" } catch { got = "matchError" }
                let file = goClean(path)
                if file != "." {
                    var info: [Bool]? = nil
                    for a in goAncestors(file) { info = (try? d.matchUsingParent(a, info))?.info ?? info }
                    gotPR = (try? d.matchUsingParent(file, info))?.excluded ?? false
                } else { gotPR = false }
            } catch { got = "newError" }
            if got == want && (want == "newError" || gotPR == wantPR) { pass += 1 } else { failures.append("\(id) \(pats) \(path) got \(got)/\(String(describing: gotPR)) want \(want)/\(wantPR)") }
        }
        for w in root["walk"] as! [[String: Any]] {
            let d = try DockerIgnore(patterns: w["patterns"] as! [String])
            if try d.walk(w["tree"] as! [String]) == (w["included"] as! [String]) { wpass += 1 } else { failures.append("WALK \(w["id"]!)") }
        }
        print("dozignore Swift: \(pass) match, \(ppass) parse, \(wpass) walk vectors pass")
        XCTAssertEqual(failures, [], "first: \(failures.prefix(10).joined(separator: "\n"))")
        XCTAssertEqual(pass, (root["match"] as! [Any]).count)
        XCTAssertEqual(wpass, (root["walk"] as! [Any]).count)
    }

    /// The cases the vectors do not pin, with Go's answers (DozMatchCTests pins the same for C).
    func testRawAlternationAndCountedRepetitionAsDockerDoes() throws {
        func ex(_ p: [String], _ path: String) -> String {
            guard let d = try? DockerIgnore(patterns: p) else { return "newError" }
            do { return "\(try d.isExcluded(path))" } catch { return "matchError" }
        }
        XCTAssertEqual(ex(["a|b?"], "zzbq"), "true")
        XCTAssertEqual(ex(["a|b?"], "a-anything"), "true")
        XCTAssertEqual(ex(["a|b?"], "zz"), "false")
        XCTAssertEqual(ex(["a|b"], "a|b"), "true")
        XCTAssertEqual(ex(["a|b"], "ab"), "false")
        XCTAssertEqual(ex(["x{2}?"], "xxq"), "true")
        XCTAssertEqual(ex(["x{2}?"], "x{2}q"), "false")
        XCTAssertEqual(ex(["x{2}"], "xx"), "false")
        XCTAssertEqual(ex(["x{1001}?"], "x"), "matchError")
        XCTAssertEqual(ex(["x{01}?"], "x{01}q"), "true")
    }

    /// Swift and C give the same answer — the contract between `doz ignore check` and the guest's view.
    /// Random patterns over the characters that matter (glob, class, escape, RE2 raw `|{}`, `!`, `/`, a
    /// non-ASCII letter) and random paths; strict mode (errors compared too) and the walker chain.
    func testSwiftAndCAgreeOnADifferentialFuzz() {
        var rng = SplitMix(seed: 0x599A)
        let patAlphabet = Array("ab-*?[]^\\|{}02,é/.!$ ")
        let pathAlphabet = Array("ab-|{}0é.")
        var disagreements: [String] = [], cases = 0
        for _ in 0..<6000 {
            let np = 1 + rng.next(3)
            let pats = (0..<np).map { _ in String((0..<(1 + rng.next(6))).map { _ in patAlphabet[rng.next(patAlphabet.count)] }) }
            let comps = 1 + rng.next(3)
            let path = (0..<comps).map { _ in String((0..<(1 + rng.next(4))).map { _ in pathAlphabet[rng.next(pathAlphabet.count)] }) }.joined(separator: "/")
            cases += 1
            let c = DozMatchCTests.CSet(pats)
            let swift: String
            if let d = try? DockerIgnore(patterns: pats) {
                do { swift = "\(try d.isExcluded(path))" } catch { swift = "matchError" }
                if c.rc != 0 { disagreements.append("New: Swift accepts, C refuses \(pats)"); continue }
                // the walker chain
                var si: [Bool]? = nil, ci: [UInt8]? = nil
                var sr = false, cr: Int32 = 0
                var chainError = false
                for a in goAncestors(path) + [path] {
                    if let r = try? d.matchUsingParent(a, si) { si = r.info; sr = r.excluded } else { chainError = true }
                    let x = c.matchParent(a, ci)
                    if x.0 != DM_MATCH_ERROR { ci = x.1; cr = x.0 }
                }
                if !chainError, sr != (cr == DM_YES) { disagreements.append("chain \(pats) \(path): Swift \(sr) C \(cr)") }
            } else {
                swift = "newError"
            }
            let cs = c.rc != 0 ? "newError" : { let r = c.isExcluded(path); return r == DM_MATCH_ERROR ? "matchError" : "\(r == DM_YES)" }()
            if swift != cs { disagreements.append("\(pats) \(path): Swift \(swift) C \(cs)") }
        }
        print("dozignore Swift vs C: \(cases) fuzz cases, \(disagreements.count) disagreements")
        XCTAssertEqual(disagreements, [], "first: \(disagreements.prefix(10).joined(separator: "\n"))")
    }

    // MARK: workspace rules

    func rules(_ ignore: String?, _ readOnly: String? = nil, mode: WorkspaceRuleMode = .lock, fold: Bool = true) -> WorkspaceRules {
        WorkspaceRules(ignoreText: ignore, readOnlyText: readOnly, mode: mode, fold: fold)
    }
    func decide(_ r: WorkspaceRules, _ p: String, dirs: Set<String> = []) -> WorkspaceRules.Decision {
        r.decide(p) { dirs.contains($0) || $0 != p }
    }

    func testVerdictsAndWhichLineDecides() {
        let r = rules("# comment\nsecret.env\nlogs\n!logs/keep.txt\n**/*.key\n", "config\n")
        XCTAssertEqual(r.ignore.map(\.line), [2, 3, 4, 5])
        var d = decide(r, "secret.env")
        XCTAssertEqual(d.verdict, .locked)
        XCTAssertEqual(d.rule?.label, ".dozignore line 2 (`secret.env`)")
        d = decide(r, "a/b/c.key")
        XCTAssertEqual(d.verdict, .locked)
        XCTAssertEqual(d.rule?.line, 5)
        d = decide(r, "logs", dirs: ["logs"])
        XCTAssertEqual(d.verdict, .visible)
        XCTAssertTrue(d.skeleton, "a folder an exception re-includes from is shown")
        XCTAssertEqual(decide(r, "logs/keep.txt").verdict, .visible)
        d = decide(r, "logs/other.log")
        XCTAssertEqual(d.verdict, .locked)
        XCTAssertEqual(d.rule?.line, 3)
        XCTAssertEqual(d.matched, "logs")
        d = decide(r, "config/app.yaml")
        XCTAssertEqual(d.verdict, .readOnly)
        XCTAssertEqual(d.rule?.label, ".dozreadonly line 1 (`config`)")
        XCTAssertEqual(decide(r, "src/main.c").verdict, .visible)
        XCTAssertEqual(decide(rules("secret.env", mode: .hide), "secret.env").verdict, .hidden)
    }

    func testImplicitAndAlwaysReadOnly() {
        let r = rules("doz_project.yaml\n.dozignore\n")
        XCTAssertEqual(decide(r, ".dozignore").verdict, .readOnly, "a rule file is never locked")
        XCTAssertTrue(decide(r, ".dozignore").ruleFile)
        XCTAssertEqual(decide(r, ".DozReadOnly").verdict, .readOnly, "folded on a case-insensitive volume")
        XCTAssertEqual(decide(r, "doz_project.yaml").verdict, .locked, "the user's .dozignore wins over the implicit read-only")
        let ro = rules(nil, "!.git/hooks\n")
        XCTAssertEqual(decide(ro, "doz_project.yml").verdict, .readOnly)
        XCTAssertNil(decide(ro, "doz_project.yml").rule?.file, "implicit")
        XCTAssertEqual(decide(ro, ".git/hooks/pre-commit").verdict, .visible, "a ! line re-allows an implicit one")
        XCTAssertEqual(decide(rules(nil, ""), ".git/hooks/pre-commit").verdict, .readOnly)
        XCTAssertEqual(decide(rules(nil, ""), ".git/config").verdict, .visible)
    }

    func testFoldingSelectsMoreNeverLess() {
        let r = rules("secret.env\ncafe\u{301}.env\n")
        let d = decide(r, "SECRET.ENV")
        XCTAssertEqual(d.verdict, .locked)
        XCTAssertTrue(d.folded)
        XCTAssertEqual(decide(r, "caf\u{E9}.env").verdict, .locked, "NFC file, NFD rule")
        XCTAssertEqual(decide(rules("secret.env", fold: false), "SECRET.ENV").verdict, .visible, "a case-sensitive volume compares bytes, as Docker")
        // an exception spelled in another case does not un-select: either comparison selecting is enough
        let e = rules("Secret.env\n!secret.env\n")
        XCTAssertEqual(decide(e, "Secret.env").verdict, .locked)
    }

    func testBadLinesAreSkippedAndSaid() {
        let r = rules("ok\n!\na[\n\\8x*\n")
        XCTAssertEqual(r.ignore.map(\.pattern), ["ok"])
        XCTAssertEqual(r.problems.map(\.line), [2, 3, 4])
        XCTAssertEqual(decide(r, "ok").verdict, .locked)
        XCTAssertEqual(decide(r, "8x").verdict, .visible)
        XCTAssertEqual(r.summary.problems, 3)
    }

    func testLoadFromAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(WorkspaceRules.present(in: dir))
        XCTAssertFalse(WorkspaceRules.load(folder: dir, mode: .lock).active)
        try "a\nb\n".write(to: dir.appendingPathComponent(".dozignore"), atomically: true, encoding: .utf8)
        XCTAssertTrue(WorkspaceRules.present(in: dir))
        let r = WorkspaceRules.load(folder: dir, mode: .hide)
        XCTAssertTrue(r.active && r.ignorePresent && !r.readOnlyPresent)
        XCTAssertEqual(r.summary.ignorePatterns, 2)
        XCTAssertEqual(r.summary.readOnlyPatterns, 0)
        XCTAssertEqual(r.mode, .hide)
        XCTAssertTrue(WorkspaceRules.caseInsensitive(dir), "the default macOS volume")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".dozreadonly"), withIntermediateDirectories: true)
        XCTAssertFalse(WorkspaceRules.load(folder: dir, mode: .lock).readOnlyPresent, "a folder is not a rule file")
    }

    // MARK: the guest scripts

    func testTheWakeRebindsTheRawPathAndSignalsInTheSameScript() {
        let v = WorkspaceViewConfig(tag: "abc123", guestPath: "/workspace", mode: .hide, fold: true)
        let s = GuestCommand.remountShares([(tag: "abc123", guestPath: "/workspace")], views: ["abc123": v])
        let viewBranch = s.range(of: "if [ -f '/run/doz/view/abc123.conf' ]; then")!
        let rebindRaw = s.range(of: "mount --bind '/run/dozer-vfs/abc123' '/run/doz/raw/abc123'")!
        let signal = s.range(of: "kill -USR1")!
        let rawList = s.range(of: "ls -a '/run/doz/raw/abc123' >/dev/null")!
        XCTAssertLessThan(viewBranch.lowerBound, rebindRaw.lowerBound)
        XCTAssertLessThan(rebindRaw.lowerBound, rawList.lowerBound)
        XCTAssertLessThan(rawList.lowerBound, signal.lowerBound, "the daemon is signalled only after the bind and its listing")
        XCTAssertLessThan(s.range(of: "ls -a /run/dozer-vfs")!.lowerBound, rebindRaw.lowerBound, "the refreshing listing first")
        XCTAssertFalse(s[viewBranch.lowerBound..<s.range(of: "; else ")!.lowerBound].contains("mount --bind '/run/dozer-vfs/abc123' '/workspace'"),
                       "a view's share is never bound back at /workspace")
        XCTAssertTrue(s.contains("mode=hide\\nfold=1\\n"), "the conf follows the host's choice")
        XCTAssertTrue(s.contains("mount --bind '/run/dozer-vfs/abc123' '/workspace'"), "without a view: the plain re-bind")
        XCTAssertTrue(s.contains("dozview' start --raw '/run/doz/raw/abc123' --mount '/workspace'"), "a share that gained rules gets its view at the wake")
        // no views wanted: the old script, plus only the guest-side check
        let plain = GuestCommand.remountShares([(tag: "abc123", guestPath: "/workspace")])
        let elseBranch = plain[plain.range(of: "; else umount -l '/workspace'", options: .backwards)!.upperBound...]
        XCTAssertFalse(elseBranch.contains("dozview' start"), "no turn-on unless the host wants a view")
        XCTAssertTrue(plain.contains("if [ -f '/run/doz/view/abc123.conf' ]"), "a guest's existing view is kept whatever the host says")
    }

    func testTheStartScriptBindsPrivatelyFirstAndNeverStacksOnTheShare() {
        let s = WorkspaceView.startScript(WorkspaceViewConfig(tag: "t1", guestPath: "/workspace", mode: .lock, fold: false))
        let order = ["chmod 0700 '/run/doz/raw'", "mount --bind '/workspace' '/run/doz/raw/t1'", "umount -l '/workspace'",
                     "! mountpoint -q '/workspace'", "mode=lock\\nfold=0\\n", "dozview' start"]
        var last = s.startIndex
        for o in order {
            guard let r = s.range(of: o, range: last..<s.endIndex) else { return XCTFail("missing or out of order: \(o)") }
            last = r.upperBound
        }
        XCTAssertTrue(s.contains("chmod 0755 /run/doz "), "/run/doz stays 0755 (the SSH agent's socket lives there)")
        XCTAssertFalse(s.contains("set -e"), "set -e is ignored in a tested list — the script chains with &&")
        XCTAssertTrue(s.hasSuffix("|| { echo 'doz-view t1 failed: the view could not start'; }"))
        XCTAssertFalse(s.contains("mount --bind '/run/doz/raw/t1' '/workspace'"), "a view with rules that cannot start leaves the guest path EMPTY")
    }

    /// BUG cwd-after-wake: a passthrough view (no rule file) that cannot start leaves the SHARE at the guest
    /// path — there are no rules to keep — in the boot's start and in the wake's restart alike.
    func testAPassthroughViewThatCannotStartLeavesTheShare() {
        let c = WorkspaceViewConfig(tag: "t1", guestPath: "/workspace", mode: .lock, fold: false, passthrough: true)
        XCTAssertTrue(c.isPassthrough)
        let s = WorkspaceView.startScript(c)
        let fallback = "{ mountpoint -q '/workspace' || mount --bind '/run/doz/raw/t1' '/workspace' 2>/dev/null || mount --bind '/run/dozer-vfs/t1' '/workspace' 2>/dev/null; } ; "
        XCTAssertTrue(s.hasSuffix("|| { " + fallback + "echo 'doz-view t1 failed: the view could not start'; }"))
        let w = GuestCommand.remountShares([(tag: "t1", guestPath: "/workspace")], views: ["t1": c])
        XCTAssertTrue(w.contains("else " + fallback + "echo \"doz-view t1 failed: $pid\""), "the wake's restart falls back to the share too")
        XCTAssertTrue(w.contains(fallback + "echo 'doz-view t1 failed: the view could not start'"), "a share without a view gets one at the wake, with the fallback")
        let old = try? JSONDecoder().decode(WorkspaceViewConfig.self, from: Data(#"{"tag":"t","guestPath":"/w","mode":"lock","fold":true}"#.utf8))
        XCTAssertEqual(old?.isPassthrough, false, "a record without the field is a view with rules")
        XCTAssertTrue(WorkspaceView.startScript(WorkspaceViewConfig(tag: "a'b", guestPath: "/workspace", mode: .lock, fold: true)).contains("failed: unsafe name"))
    }

    /// /run is on the root disk (Stop keeps it): a fresh boot forgets the last boot's view, and never
    /// deletes recursively where a share could be bound.
    func testAFreshBootForgetsTheLastBootsView() {
        let s = GuestCommand.prepareGuest(imageSpec: nil)
        XCTAssertTrue(s.contains("rm -rf '/run/doz/view'"))
        XCTAssertTrue(s.contains("! mountpoint -q \"$d\" && rmdir \"$d\""))
        XCTAssertFalse(s.contains("rm -rf '/run/doz/raw"), "never a recursive delete under the raw mount points")
    }

    func testTheGuestsAnswersAreParsed() {
        let out = "doz-view t1 started 42\ndoz-view t2 failed: the view could not start\ndoz-view t3 running 7\ndoz-state t3 requests=9\ndoz-state t3 mode=lock\nnoise"
        let st = WorkspaceView.parse(out)
        XCTAssertEqual(st.map(\.state), [.started, .failed, .running])
        XCTAssertEqual(st.map(\.pid), [42, nil, 7])
        XCTAssertEqual(WorkspaceView.parseState(out, tag: "t3"), ["requests": "9", "mode": "lock"])
    }

    func testTheBinaryIsCommittedAndFoundWithoutBundleModule() throws {
        let url = try XCTUnwrap(DozviewBinary.locate(environment: [:]))
        let d = try Data(contentsOf: url)
        XCTAssertEqual(Array(d.prefix(4)), [0x7F, 0x45, 0x4C, 0x46], "an ELF")
        XCTAssertEqual(d[18], 0xB7, "aarch64")
        XCTAssertEqual(DozviewBinary.locate(environment: ["DOZ_DOZVIEW": "/nonexistent"]), nil)
    }
}

/// A small deterministic generator (the fuzz is reproducible).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ n: Int) -> Int {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Int((z ^ (z >> 31)) % UInt64(n))
    }
}
