// user-text-check.swift — no internal feature numbers or walkthrough IDs in what a user reads.
//
// Feature numbers ("596:", "(591)", "584.B2") and walkthrough IDs ("W27") belong in code comments and the
// workspace's ledger, never in the text doz shows. Checked here:
//   1. every `doz … --help` (the top level and every subcommand, walked);
//   2. every setting's description (`doz config show --json`);
//   3. string literals in the CLI, the host and the web layer's Swift sources (one-line "…" strings and
//      the lines of """…""" blocks), comments excluded;
//   4. string literals in the dashboard's app.js and its modules (app/**, 607), comments excluded.
// The pattern: a number 580–609 standing alone (optionally `.B<n>`), or W<1–2 digits>. Sizes, versions,
// timeouts and HTTP codes do not fall in that range as words; `allowed` names the few that do.
//
// Usage: swift Scripts/user-text-check.swift --doz .build/debug/doz
import Foundation

var dozPath = ".build/debug/doz"
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() { if a == "--doz", let v = it.next() { dozPath = v } }

let pattern = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z.~×x-])((58|59|60)[0-9](\\.B[0-9]+)?|W[0-9]{1,2})(?![0-9A-Za-z%]|\\.[0-9]| ?(MiB|MB|GiB|GB|KiB|ms|s\\b|min|bytes))")
/// Internal identifiers that are data, not prose (written into files, never shown as text).
let allowed = ["587-base-clone-v1", "sleep 600"]

var problems: [String] = []
func scan(_ text: String, _ where_: String) {
    var t = text
    for a in allowed { t = t.replacingOccurrences(of: a, with: "") }
    for m in pattern.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
        guard let r = Range(m.range, in: t) else { continue }
        let lo = t.index(r.lowerBound, offsetBy: -40, limitedBy: t.startIndex) ?? t.startIndex
        let hi = t.index(r.upperBound, offsetBy: 40, limitedBy: t.endIndex) ?? t.endIndex
        problems.append("\(where_): \"\(t[r])\" in …\(t[lo..<hi].replacingOccurrences(of: "\n", with: " "))…")
    }
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("doz-user-text-\(getpid())")
defer { try? FileManager.default.removeItem(at: scratch) }
func doz(_ a: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: dozPath)
    p.arguments = a
    var env = ProcessInfo.processInfo.environment
    env["XDG_CONFIG_HOME"] = scratch.appendingPathComponent("xdg").path
    env["DOZ_STORE"] = scratch.appendingPathComponent("store").path
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { FileHandle.standardError.write(Data("cannot run \(dozPath)\n".utf8)); exit(1) }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

// 1. every help text
var helps = 0
func walk(_ path: [String]) {
    let h = doz(path + ["--help"])
    helps += 1
    scan(h, "doz \(path.joined(separator: " ")) --help")
    guard path.count < 3 else { return }
    var inList = false, names: [String] = []
    for line in h.components(separatedBy: "\n") {
        if line.hasPrefix("SUBCOMMANDS:") { inList = true; continue }
        guard inList else { continue }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { if names.isEmpty { continue } else { break } }
        guard line.hasPrefix("  "), !line.hasPrefix("   ") else { continue }
        let name = line.trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet(charactersIn: " ,")).first ?? ""
        if name.range(of: "^[a-z][a-z-]*$", options: .regularExpression) != nil, name != "help" { names.append(name) }
    }
    for n in names { walk(path + [n]) }
}
walk([])

// 2. every setting's description
struct Row: Decodable { let key: String; let description: String; let typeName: String }
struct Report: Decodable { let settings: [Row] }
if let r = try? JSONDecoder().decode(Report.self, from: Data(doz(["config", "show", "--json"]).utf8)) {
    for s in r.settings { scan(s.description + " " + s.typeName, "setting \(s.key)") }
} else { problems.append("doz config show --json did not parse") }

// 3. Swift string literals (user text is built from them)
var files = 0
let stringRX = try! NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
/// Cheap pre-filter: only a line with a candidate is worth the full pattern.
let candidateRX = try! NSRegularExpression(pattern: "(58|59|60)[0-9]|W[0-9]")
for dir in ["Sources/DozerCLI", "Sources/DozerHost", "Sources/DozerWeb", "Sources/DozerKit"] {
    guard let e = FileManager.default.enumerator(atPath: dir) else { continue }
    for case let f as String in e where f.hasSuffix(".swift") {
        let path = dir + "/" + f
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        files += 1
        var inBlock = false
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let quotes = line.components(separatedBy: "\"\"\"").count - 1
            if quotes == 0 && candidateRX.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if quotes % 2 == 1 { inBlock = false }
                // A shell comment inside a guest script is the script's (and part of an image's recipe:
                // changing it would rebuild every image) — not text a person reads.
                if !t.hasPrefix("//"), !t.hasPrefix("#") { scan(line, "\(path):\(n + 1)") }
                continue
            }
            if quotes % 2 == 1 { inBlock = true; continue }
            if t.hasPrefix("//") { continue }
            // One-line strings only (a trailing // comment is not in them).
            let rx = stringRX
            for m in rx.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let r = Range(m.range(at: 1), in: line) { scan(String(line[r]), "\(path):\(n + 1)") }
            }
        }
    }
}

// 4. the dashboard's own strings — app.js and (607) every module under app/
var jsFiles = ["Sources/DozerWeb/WebSource/app.js"]
if let e = FileManager.default.enumerator(atPath: "Sources/DozerWeb/WebSource/app") {
    while let f = e.nextObject() as? String { if f.hasSuffix(".js") { jsFiles.append("Sources/DozerWeb/WebSource/app/" + f) } }
}
var jsCount = 0
for path in jsFiles.sorted() {
    guard let js = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    jsCount += 1
    let name = String(path.dropFirst("Sources/DozerWeb/WebSource/".count))
    let rx = try! NSRegularExpression(pattern: "'((?:[^'\\\\]|\\\\.)*)'")
    for (n, line) in js.components(separatedBy: "\n").enumerated() {
        if candidateRX.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil { continue }
        var code = line
        if let c = code.range(of: "//") , !code[..<c.lowerBound].contains("'") || code[..<c.lowerBound].filter({ $0 == "'" }).count % 2 == 0 {
            code = String(code[..<c.lowerBound])
        }
        if code.trimmingCharacters(in: .whitespaces).hasPrefix("*") { continue }
        for m in rx.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            if let r = Range(m.range(at: 1), in: code) { scan(String(code[r]), "\(name):\(n + 1)") }
        }
    }
}

if problems.isEmpty {
    print("ok user-text-check: \(helps) help texts, every setting, \(files) Swift files and the dashboard's \(jsCount) scripts (app.js and its modules) carry no feature number or walkthrough ID")
} else {
    for p in problems { FileHandle.standardError.write(Data("x user-text-check: \(p)\n".utf8)) }
    FileHandle.standardError.write(Data("Keep feature numbers in code comments; say what the thing is instead.\n".utf8))
    exit(1)
}
