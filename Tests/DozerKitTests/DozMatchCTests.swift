// DozMatchCTests — the guest's C matcher (Guest/dozview/match, target DozMatch) against the vectors the
// REAL Go code generated (Tests/Fixtures/dozignore-vectors.json: moby/patternmatcher v0.6.1 + fsutil),
// and the folding (dm_fold, dm_fold_pattern AND the Swift DozFold) against Tests/Fixtures/dozfold-vectors.json
// (computed by Scripts/gen-dozfold-tables.py). How each field is checked follows the reference runner in
// the workspace's probes/599g-*/patterns/DozIgnore.swift line for line.
import DozMatch
import Foundation
import XCTest

@testable import DozerKit

final class DozMatchCTests: XCTestCase {
    // MARK: fixtures

    static let packageRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" {
            u.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) { return u }
        }
        fatalError("no Package.swift above \(#filePath)")
    }()

    static func fixture(_ name: String) throws -> Any {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Tests/Fixtures/\(name)"))
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: C helpers

    /// A dm_set owned by Swift (the struct lives at a stable heap address for the C calls). Sendable
    /// because a set is read-only once dm_set_compile_all has run — which is what the thread test checks.
    final class CSet: @unchecked Sendable {
        let ptr: UnsafeMutablePointer<dm_set>
        let rc: Int32
        let bad: Int32
        private(set) var reported: [(Int32, String)] = []

        init(_ patterns: [String], lenient: Bool = false) {
            let ptr = UnsafeMutablePointer<dm_set>.allocate(capacity: 1)
            ptr.initialize(to: dm_set())
            self.ptr = ptr
            var bad: Int32 = -1
            let cstrs = patterns.map { strdup($0) }
            defer { cstrs.forEach { free($0) } }
            var ptrs: [UnsafePointer<CChar>?] = cstrs.map { UnsafePointer($0) }
            let box = Box()
            let ctx = Unmanaged.passUnretained(box).toOpaque()
            let rc = ptrs.withUnsafeMutableBufferPointer { b in
                dm_set_init(ptr, b.baseAddress, Int32(patterns.count), lenient ? 1 : 0, &bad, { ctx, i, p, _ in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                    box.items.append((i, String(cString: p!)))
                }, ctx)
            }
            self.rc = rc
            self.bad = bad
            reported = box.items
        }

        deinit {
            dm_set_free(ptr)
            ptr.deallocate()
        }

        var count: Int { Int(ptr.pointee.n) }

        func isExcluded(_ path: String) -> Int32 { dm_is_excluded(ptr, path) }

        func matchParent(_ path: String, _ parent: [UInt8]?) -> (Int32, [UInt8], Int32) {
            var out = [UInt8](repeating: 0, count: max(count, 1))
            var decider: Int32 = -2
            let r: Int32
            if let parent {
                r = parent.withUnsafeBufferPointer { p in dm_match_parent(ptr, path, p.baseAddress, &out, &decider) }
            } else {
                r = dm_match_parent(ptr, path, nil, &out, &decider)
            }
            return (r, Array(out.prefix(count)), decider)
        }

        func mayReincludeInside(_ dir: String) -> Bool { dm_may_reinclude_inside(ptr, dir) != 0 }
    }

    final class Box { var items: [(Int32, String)] = [] }

    static func cString(_ p: UnsafePointer<CChar>) -> [UInt8] {
        Array(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)))
    }

    static func clean(_ s: String) -> String {
        let p = dm_clean(s)!
        defer { free(p) }
        return String(decoding: cString(p), as: UTF8.self)
    }

    /// Go filepath.Dir on a cleaned path.
    static func goDir(_ p: String) -> String {
        guard let i = p.utf8.lastIndex(of: 0x2F) else { return "." }
        return clean(String(p[...i]))
    }

    /// patternmatcher's parent list: prefixes of strings.Split(Dir(file), "/"); none when Dir is ".".
    static func ancestors(_ file: String) -> [String] {
        let d = goDir(file)
        if d == "." { return [] }
        let parts = d.split(separator: "/", omittingEmptySubsequences: false)
        return (1...parts.count).map { parts[..<$0].joined(separator: "/") }
    }

    static func parse(_ text: String) -> (patterns: [[UInt8]], lines: [Int32]) {
        var out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var lines: UnsafeMutablePointer<Int32>?
        let n = text.withCString { dm_parse_file($0, strlen($0), &out, &lines) }
        precondition(n >= 0)
        defer { dm_free_lines(out, lines, n) }
        return ((0..<Int(n)).map { cString(out![$0]!) }, (0..<Int(n)).map { lines![$0] })
    }

    /// The probe's walk(): fsutil.Walk(ExcludePatterns) over a path list (dirs end in "/"), through the C
    /// primitives dm_match_parent / dm_may_reinclude_inside; the emitted paths in walk order.
    static func walk(_ set: CSet, _ tree: [String]) -> [String] {
        var dirs = Set<String>(), children: [String: Set<String>] = [:]
        for t in tree {
            let isDir = t.hasSuffix("/")
            let p = isDir ? String(t.dropLast()) : t
            let comps = p.split(separator: "/").map(String.init)
            for i in 1...comps.count {
                let sub = comps[..<i].joined(separator: "/")
                children[i == 1 ? "" : comps[..<(i - 1)].joined(separator: "/"), default: []].insert(sub)
                if i < comps.count || isDir { dirs.insert(sub) }
            }
        }
        let onlyPrefix = set.ptr.pointee.only_prefix_exceptions != 0
        var out: [String] = []
        var stack: [(sep: String, path: String, info: [UInt8], called: Bool)] = []
        func visit(_ parent: String) {
            let kids = (children[parent] ?? []).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for path in kids {
                let isDir = dirs.contains(path)
                while let last = stack.last, !path.hasPrefix(last.sep) { stack.removeLast() }
                let (r, info, _) = set.matchParent(path, stack.last?.info)
                precondition(r != DM_MATCH_ERROR)
                let m = r == DM_YES
                if m && isDir && onlyPrefix && !set.mayReincludeInside(path) { continue }
                if !m {
                    for i in stack.indices where !stack[i].called { stack[i].called = true; out.append(stack[i].path) }
                    out.append(path)
                }
                if isDir { stack.append((path + "/", path, info, !m)); visit(path) }
            }
        }
        visit("")
        return out
    }

    static func fold(_ s: String, pattern: Bool) -> [UInt8] {
        let p = pattern ? dm_fold_pattern(s)! : dm_fold(s)!
        defer { free(p) }
        return cString(p)
    }

    // MARK: the vectors

    func testEveryVectorThroughTheCMatcherAndFold() throws {
        let root = try Self.fixture("dozignore-vectors.json") as! [String: Any]
        var matchPass = 0, parsePass = 0, walkPass = 0, foldPass = 0
        var failures: [String] = []

        for v in root["match"] as! [[String: Any]] {
            let id = v["id"] as! String, path = v["path"] as! String
            var pats = v["patterns"] as! [String]
            if let f = v["ignorefile"] as? String {
                let (parsed, lines) = Self.parse(f)
                if parsed == pats.map({ Array($0.utf8) }) { parsePass += 1 } else { failures.append("PARSE \(id)") }
                // each kept pattern's source line: strictly increasing, within the file
                let lineCount = f.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).count
                if !(zip(lines, lines.dropFirst()).allSatisfy { $0 < $1 } && lines.allSatisfy { $0 >= 1 && $0 <= lineCount }) {
                    failures.append("LINES \(id): \(lines)")
                }
                pats = parsed.map { String(decoding: $0, as: UTF8.self) }
            }
            let want = (v["newError"] as! Bool) ? "newError" : (v["matchError"] as! Bool) ? "matchError" : "\(v["excluded"] as! Bool)"
            let wantPR = v["excludedParentResults"] as! Bool
            var got = "newError", gotPR = false
            let set = CSet(pats)
            if set.rc == 0 {
                let r = set.isExcluded(path)
                got = r == DM_MATCH_ERROR ? "matchError" : "\(r == DM_YES)"
                let file = Self.clean(path)
                if file != "." {
                    var info: [UInt8]? = nil
                    for a in Self.ancestors(file) {
                        let (r, i, _) = set.matchParent(a, info)
                        if r != DM_MATCH_ERROR { info = i }
                    }
                    gotPR = set.matchParent(file, info).0 == DM_YES
                }
            } else if set.bad < 0 {
                failures.append("NEW \(id): failed without an index")
            }
            if got == want && (want == "newError" || gotPR == wantPR) { matchPass += 1 } else {
                failures.append("MATCH \(id) patterns=\(pats) path=\(path) got=\(got)/\(gotPR) want=\(want)/\(wantPR)")
            }
        }

        for w in root["walk"] as! [[String: Any]] {
            let id = w["id"] as! String
            let set = CSet(w["patterns"] as! [String])
            XCTAssertEqual(set.rc, 0, id)
            let got = Self.walk(set, w["tree"] as! [String]), want = w["included"] as! [String]
            if got == want { walkPass += 1 } else { failures.append("WALK \(id): got \(got) want \(want)") }
        }

        for v in try Self.fixture("dozfold-vectors.json") as! [[String: Any]] {
            let input = v["in"] as! String, out = Array((v["out"] as! String).utf8)
            let pattern = v["pattern"] as? Bool ?? false
            let c = Self.fold(input, pattern: pattern)
            let swift = Array((pattern ? DozFold.foldPattern(input) : DozFold.fold(input)).utf8)
            if c == out && swift == out { foldPass += 1 } else {
                failures.append("FOLD \(input.unicodeScalars.map { String($0.value, radix: 16) }) pattern=\(pattern): C ok \(c == out), Swift ok \(swift == out)")
            }
        }

        print("dozmatch C: \(matchPass) match, \(parsePass) parse, \(walkPass) walk, \(foldPass) fold vectors pass")
        XCTAssertEqual(failures, [], "\(failures.count) failures; first: \(failures.prefix(20).joined(separator: "\n"))")
        XCTAssertEqual(matchPass, (root["match"] as! [Any]).count)
        XCTAssertGreaterThan(parsePass, 3000)
        XCTAssertEqual(walkPass, (root["walk"] as! [Any]).count)
        XCTAssertGreaterThan(foldPass, 500)
    }

    // MARK: behaviour the vectors do not pin

    /// Go's shouldEscape overflows its bitset for bytes >= 64, so `|`, `{`, `}` reach RE2 RAW once a
    /// pattern is a regexp (a `*`, `?`, `\\`, `[` or `]` makes it one). Each expectation below was taken from
    /// Go's patternmatcher (and the differential fuzz agrees on 180k more), surprising as it is.
    func testRawAlternationAndCountedRepetitionAsDockerDoes() {
        let alt = CSet(["a|b?"])                      // ^a|b[^/]$ : starts with a, OR ends with b + one char
        XCTAssertEqual(alt.isExcluded("zzbq"), DM_YES)
        XCTAssertEqual(alt.isExcluded("a-anything"), DM_YES)
        XCTAssertEqual(alt.isExcluded("zz"), DM_NO)
        XCTAssertEqual(CSet(["a|b"]).isExcluded("a|b"), DM_YES) // no glob: an exact match, `|` literal
        XCTAssertEqual(CSet(["a|b"]).isExcluded("ab"), DM_NO)
        let rep = CSet(["x{2}?"])                     // ^x{2}[^/]$
        XCTAssertEqual(rep.isExcluded("xxq"), DM_YES)
        XCTAssertEqual(rep.isExcluded("x{2}q"), DM_NO)
        XCTAssertEqual(CSet(["x{2}"]).isExcluded("xx"), DM_NO)             // exact
        XCTAssertEqual(CSet(["x{1001}?"]).isExcluded("x"), DM_MATCH_ERROR) // RE2: invalid repeat size
        XCTAssertEqual(CSet(["x{01}?"]).isExcluded("x{01}q"), DM_YES)      // not a repeat form: literal
    }

    func testLenientAndStrict() {
        let strict = CSet(["ok", "!", "a["])
        XCTAssertEqual(strict.rc, -1)
        XCTAssertEqual(strict.bad, 1)
        XCTAssertEqual(strict.count, 0)

        let lenient = CSet(["ok", "!", "a[", "!keep"], lenient: true)
        XCTAssertEqual(lenient.rc, 0)
        XCTAssertEqual(lenient.count, 2)
        XCTAssertEqual(lenient.reported.map(\.0), [1, 2])
        XCTAssertEqual(String(cString: dm_pattern_text(lenient.ptr, 1)), "keep")
        XCTAssertEqual(dm_pattern_is_exclusion(lenient.ptr, 1), 1)

        // New accepts it (filepath.Match), RE2 does not compile it: an error when strict, never a match when lenient
        let bad = ["\\8x*", "k"]
        XCTAssertEqual(CSet(bad).isExcluded("8x"), DM_MATCH_ERROR)
        let len = CSet(bad, lenient: true)
        let box = Box()
        let n = dm_set_compile_all(len.ptr, { ctx, i, p, _ in
            Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue().items.append((i, String(cString: p!)))
        }, Unmanaged.passUnretained(box).toOpaque())
        XCTAssertEqual(n, 1)
        XCTAssertEqual(box.items.map(\.0), [0])
        XCTAssertEqual(len.isExcluded("8x"), DM_NO)
        XCTAssertEqual(len.isExcluded("k"), DM_YES)
        let (r, info, decider) = len.matchParent("k/inner", nil)
        XCTAssertEqual(r, DM_YES)
        XCTAssertEqual(info, [0, 1])
        XCTAssertEqual(decider, 1)
    }

    func testDeciderAndHelpers() {
        let set = CSet(["*.log", "!keep.log", "build/**"])
        XCTAssertEqual(set.matchParent("a.log", nil).2, 0)
        XCTAssertEqual(set.matchParent("keep.log", nil).0, DM_NO)
        XCTAssertEqual(set.matchParent("keep.log", nil).2, 1)
        XCTAssertEqual(set.matchParent("src", nil).2, -1)
        XCTAssertEqual(set.ptr.pointee.has_exclusions, 1)
        XCTAssertEqual(set.ptr.pointee.only_prefix_exceptions, 1)
        XCTAssertTrue(set.mayReincludeInside("keep.log"))
        XCTAssertFalse(set.mayReincludeInside("build"))
        for (i, o) in [("", "."), ("a//b/./c/..", "a/b"), ("/../x", "/x"), ("../../a", "../../a"), ("a/../..", "..")] {
            XCTAssertEqual(Self.clean(i), o, i)
        }
        // ReadAll: BOM on line 1 only, '#' in column 1 only, CRLF, '!' + spaces, leading '/'
        let (p, lines) = Self.parse("\u{FEFF}a\r\n # not a comment\n#comment\n\u{FEFF}b\n!  /c/./d \n\u{2003}\n")
        XCTAssertEqual(p.map { String(decoding: $0, as: UTF8.self) }, ["a", "# not a comment", "\u{FEFF}b", "!c/d"])
        XCTAssertEqual(lines, [1, 2, 4, 5])
    }

    func testOneCompiledSetIsSafeToShareBetweenThreads() {
        let set = CSet(["**/*.tmp", "node_modules", "docs/*.md", "!docs/README.md", "a|b", "x{2,3}y", "[a-c]?[[:digit:]]*", "**/cache/**"])
        XCTAssertEqual(dm_set_compile_all(set.ptr, nil, nil), 0)
        let paths = ["src/a.tmp", "node_modules/x", "docs/a.md", "docs/README.md", "zb", "xxxy", "b9z", "q/cache/z", "src/main.c",
                     String(repeating: "deep/", count: 40) + "f.tmp"]
        let expected = paths.map { set.isExcluded($0) }
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
            func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
        }
        let mismatches = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            var bad = 0
            for i in 0..<3000 {
                let k = (i + t) % paths.count
                if set.isExcluded(paths[k]) != expected[k] { bad += 1 }
                if set.matchParent(paths[k], nil).0 != expected[k] { bad += 1 }
            }
            mismatches.add(bad)
        }
        XCTAssertEqual(mismatches.value, 0)
    }
}
