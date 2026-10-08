// manual-check.swift — the user manual (docs/manual) checked against the real `doz`:
//
//   1. the Settings reference's table (between <!-- settings:begin --> and <!-- settings:end -->) is
//      exactly what `doz config show --json` says — every key, its default, when it applies, its
//      description (`--write` regenerates it);
//   2. every setting key the manual names (in code) is a real one — or one of the agent prompt's
//      {{variables}}, which page 09 must list in full;
//   3. every `doz …` command in code (blocks and inline spans) names real commands and subcommands,
//      and each of its flags is one that command's --help lists;
//   4. every relative link and image resolves;
//   5. no internal feature or walkthrough numbers leak into the prose.
//
// Usage: swift Scripts/manual-check.swift --doz .build/debug/doz --manual docs/manual [--write]
// (Scripts/docs-drift-check.sh runs it; `--help` and `config show` need no entitlement.)
import Foundation

var args = CommandLine.arguments.dropFirst()
var dozPath = ".build/debug/doz", manualDir = "docs/manual", write = false
while let a = args.first {
    args = args.dropFirst()
    switch a {
    case "--doz": dozPath = args.first ?? dozPath; args = args.dropFirst()
    case "--manual": manualDir = args.first ?? manualDir; args = args.dropFirst()
    case "--write": write = true
    default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(64)
    }
}

var problems: [String] = []
func problem(_ s: String) { problems.append(s) }

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("doz-manual-check-\(getpid())")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

/// `doz ARGS` with a throwaway settings folder and store (nothing real is read or written).
func doz(_ a: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: dozPath)
    p.arguments = a
    var env = ProcessInfo.processInfo.environment
    env["XDG_CONFIG_HOME"] = scratch.appendingPathComponent("xdg").path
    env["DOZ_STORE"] = scratch.appendingPathComponent("store").path
    env.removeValue(forKey: "DOZ_PROGRESS"); env.removeValue(forKey: "DOZ_HOST_IDLE"); env.removeValue(forKey: "DOZ_SUBNET")
    env.removeValue(forKey: "DOZ_KERNEL"); env.removeValue(forKey: "DOZ_KERNEL_CACHE"); env.removeValue(forKey: "DOZ_SCREEN_CAPTURE")
    env.removeValue(forKey: "DOZ_BOOT_LOGS")
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { FileHandle.standardError.write(Data("cannot run \(dozPath): \(error)\n".utf8)); exit(1) }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

// MARK: the pages

let manualURL = URL(fileURLWithPath: manualDir)
let pageNames = ((try? FileManager.default.contentsOfDirectory(atPath: manualDir)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
guard !pageNames.isEmpty else { FileHandle.standardError.write(Data("no pages in \(manualDir)\n".utf8)); exit(1) }
var pages: [String: String] = [:]
for n in pageNames { pages[n] = (try? String(contentsOf: manualURL.appendingPathComponent(n), encoding: .utf8)) ?? "" }

/// Code: fenced blocks (whole lines) and inline `spans`.
func codeFragments(_ text: String) -> [String] {
    var out: [String] = []
    var inFence = false, mermaid = false
    var prose: [String] = []
    for line in text.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") || t.hasPrefix("````") {
            inFence.toggle()
            mermaid = inFence && t.hasSuffix("mermaid")
            continue
        }
        if inFence && mermaid {
            // A Mermaid diagram: its edge labels (`a --> b: doz start`) are checked as commands, the rest
            // is the diagram's own syntax.
            if let colon = t.range(of: ": doz ") {
                let label = String(t[t.index(colon.lowerBound, offsetBy: 2)...])
                out.append(label.components(separatedBy: " (").first ?? label)
            }
            continue
        }
        if inFence { out.append(line) } else { prose.append(line) }
    }
    let joined = prose.joined(separator: "\n")
    let spans = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    for m in spans.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)) {
        if let r = Range(m.range(at: 1), in: joined) { out.append(String(joined[r])) }
    }
    return out
}

// MARK: 1. the settings

struct Setting: Decodable {
    let key: String, section: String, name: String, typeName: String, description: String, applies: String
    let environment: String?, flag: String?
    let defaultValue: JSONValue
    var whenShort: String {
        switch applies {
        case "now": "at once"
        case "next-command": "next command"
        case "next-create": "new sandboxes"
        case "next-session": "next session"
        case "host-restart": "after `doz host stop`"
        case "new-store": "a store that hasn't chosen"
        case "next-boot": "next boot"
        case "next-start-or-wake": "next start or wake"
        default: applies
        }
    }
}
enum JSONValue: Decodable {
    case string(String), bool(Bool), int(Int)
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
    }
    var shown: String {
        switch self {
        case .string(let s): s.isEmpty ? "`\"\"`" : "`\(s)`"
        case .bool(let b): "`\(b)`"
        case .int(let i): "`\(i)`"
        }
    }
}
struct Report: Decodable { let settings: [Setting] }
let configJSON = doz(["config", "show", "--json"])
guard let report = try? JSONDecoder().decode(Report.self, from: Data(configJSON.utf8)) else {
    FileHandle.standardError.write(Data("doz config show --json did not parse:\n\(configJSON.prefix(400))\n".utf8)); exit(1)
}
let keys = Set(report.settings.map(\.key))

func settingsTable() -> String {
    var s = ""
    var sections: [String] = []
    for r in report.settings where !sections.contains(r.section) { sections.append(r.section) }
    for sec in sections {
        s += "\n### `[\(sec)]`\n\n| key | default | values | applies | overridden by | what it does |\n|---|---|---|---|---|---|\n"
        for r in report.settings where r.section == sec {
            let cell = { (t: String) in t.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            let over = [r.environment.map { "`$\($0)`" }, r.flag.map { "`\($0)`" }].compactMap { $0 }.joined(separator: ", ")
            s += "| `\(r.key)` | \(r.defaultValue.shown) | \(cell(r.typeName)) | \(r.whenShort) | \(cell(over.isEmpty ? "—" : over)) | \(cell(r.description)) |\n"
        }
    }
    return s + "\n"
}
let settingsPage = "15-settings-reference.md"
let begin = "<!-- settings:begin -->", end = "<!-- settings:end -->"
if let page = pages[settingsPage], let b = page.range(of: begin), let e = page.range(of: end), b.upperBound <= e.lowerBound {
    let table = settingsTable()
    if String(page[b.upperBound..<e.lowerBound]) != table {
        if write {
            let updated = String(page[..<b.upperBound]) + table + String(page[e.lowerBound...])
            try! updated.write(to: manualURL.appendingPathComponent(settingsPage), atomically: true, encoding: .utf8)
            pages[settingsPage] = updated
            print("wrote the settings table into \(settingsPage)")
        } else {
            problem("\(settingsPage): the settings table is not what `doz config show` says — run: swift Scripts/manual-check.swift --doz \(dozPath) --manual \(manualDir) --write")
        }
    }
} else {
    problem("\(settingsPage): missing, or without \(begin) … \(end)")
}

// MARK: 2. setting keys named in code

let promptSource = (try? String(contentsOfFile: "Sources/DozerHost/AgentPrompt.swift", encoding: .utf8)) ?? ""
var promptVariables: Set<String> = []
if let start = promptSource.range(of: "public static let variables:"), let stop = promptSource[start.upperBound...].range(of: "\n    ]") {
    let block = String(promptSource[start.upperBound..<stop.lowerBound])
    let rx = try! NSRegularExpression(pattern: "\\(\"([a-z._]+)\"")
    for m in rx.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
        if let r = Range(m.range(at: 1), in: block) { promptVariables.insert(String(block[r])) }
    }
}
if promptVariables.isEmpty { problem("could not read the agent prompt's variables from Sources/DozerHost/AgentPrompt.swift") }
let notKeys: Set<String> = Set(["host.log", "host.sock"]).union(report.settings.map(\.section))   // `[images.lab]` is a section
let keyRX = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_./-])((ui|host|store|claude|defaults|agent|resources|sandbox|sessions|images|kernel)\\.[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_]*)?)(?![A-Za-z0-9_/-])")
for (name, text) in pages {
    for frag in codeFragments(text) {
        for m in keyRX.matches(in: frag, range: NSRange(frag.startIndex..., in: frag)) {
            guard let r = Range(m.range(at: 1), in: frag) else { continue }
            let k = String(frag[r])
            if keys.contains(k) || promptVariables.contains(k) || notKeys.contains(k) { continue }
            problem("\(name): `\(k)` is not a setting (doz config show) nor an agent prompt variable")
        }
    }
}
if let agents = pages["09-agents-and-accounts.md"] {
    for v in promptVariables.sorted() where !agents.contains("`\(v)`") {
        problem("09-agents-and-accounts.md: the agent prompt variable `\(v)` is not listed")
    }
}
if let ref = pages[settingsPage] {
    for k in keys.sorted() where !ref.contains("`\(k)`") { problem("\(settingsPage): `\(k)` is missing") }
}

// MARK: 3. commands and flags

var helpCache: [[String]: String] = [:]
func help(_ path: [String]) -> String {
    if let h = helpCache[path] { return h }
    let h = doz(path + ["--help"])
    helpCache[path] = h
    return h
}
/// A help text's subcommands: canonical names and aliases, and which one is the default.
func subcommands(_ path: [String]) -> (names: Set<String>, hasDefault: Bool, defaultName: String?) {
    var names: Set<String> = [], hasDefault = false, defaultName: String?
    var inList = false
    for line in help(path).components(separatedBy: "\n") {
        if line.hasPrefix("SUBCOMMANDS:") { inList = true; continue }
        guard inList else { continue }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { if !names.isEmpty { break } else { continue } }
        guard line.hasPrefix("  "), !line.hasPrefix("   ") else { continue }
        let head = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "  ").first ?? ""
        let parts = head.replacingOccurrences(of: "(default)", with: "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if head.contains("(default)") { hasDefault = true; defaultName = parts.first }
        for n in parts { names.insert(n) }
    }
    return (names, hasDefault, defaultName)
}
let top = subcommands([])
if top.names.isEmpty { problem("doz --help listed no subcommands") }
var commandsChecked = 0, flagsChecked = 0

func checkCommand(_ raw: String, page: String) {
    // Up to the first shell operator or comment; brackets and ellipses are notation.
    var line = raw
    for stop in [" #", " |", " &&", " ;", " <", " >", "  #"] { if let r = line.range(of: stop) { line = String(line[..<r.lowerBound]) } }
    let tokens = line.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]()…,.`'\"")) }.filter { !$0.isEmpty }
    guard tokens.first == "doz", tokens.count >= 2 else { return }
    var path: [String] = []
    var i = 1
    let first = tokens[1]
    if first.hasPrefix("-") {
        if first != "--version" && first != "--help" && first != "-h" { problem("\(page): `\(raw)` — `doz \(first)` is not a command") }
        return
    }
    guard top.names.contains(first) || first == "help" else { problem("\(page): `\(raw)` — `\(first)` is not a doz command"); return }
    if first == "help" { return }
    path = [first]
    i = 2
    // Descend into groups.
    while true {
        let subs = subcommands(path)
        if subs.names.isEmpty { break }
        if i < tokens.count, subs.names.contains(tokens[i]) { path.append(tokens[i]); i += 1; continue }
        if i < tokens.count, !tokens[i].hasPrefix("-"), !subs.hasDefault {
            problem("\(page): `\(raw)` — `\(tokens[i])` is not a subcommand of doz \(path.joined(separator: " "))")
            return
        }
        // Anything else goes to the group's default subcommand (`doz net NAME`, `doz resources --json`).
        if let d = subs.defaultName { path.append(d) }
        break
    }
    commandsChecked += 1
    let text = help(path)
    for t in tokens[i...] {
        if t == "--" { break }
        guard t.hasPrefix("-"), t.count > 1 else { continue }
        let flag = t.split(separator: "=").first.map(String.init) ?? t
        if flag.contains("|") || flag.contains("/") { continue }
        flagsChecked += 1
        let known: Bool
        if flag.hasPrefix("--no-") {
            known = text.contains("/\(flag)") || text.contains("\(flag) ") || text.contains("\(flag)\n")
        } else if flag.hasPrefix("--") {
            known = text.contains("\(flag) ") || text.contains("\(flag)\n") || text.contains("\(flag)/") || text.contains("\(flag),") || text.contains("[\(flag)]")
        } else {
            known = text.contains("  \(flag), ") || text.contains("[\(flag)")
        }
        if !known { problem("\(page): `\(raw)` — doz \(path.joined(separator: " ")) has no \(flag)") }
    }
}
for (name, text) in pages {
    for frag in codeFragments(text) {
        var s = frag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$ ") { s.removeFirst(2) }
        // A line may hold several commands (`doz a && doz b`, a table cell's `doz x` · `doz y`).
        if s.hasPrefix("doz ") || s == "doz" { checkCommand(s, page: name) }
    }
}

// MARK: 4. links and images

let linkRX = try! NSRegularExpression(pattern: "\\]\\(([^)#\\s]+)(#[^)\\s]*)?\\)")
for (name, text) in pages {
    for m in linkRX.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let r = Range(m.range(at: 1), in: text) else { continue }
        let target = String(text[r])
        if target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("mailto:") { continue }
        let path = manualURL.appendingPathComponent(target).standardizedFileURL.path
        if !FileManager.default.fileExists(atPath: path) { problem("\(name): link to \(target), which does not exist") }
    }
}

// MARK: 5. no internal numbers in the prose

let internalRX = try! NSRegularExpression(pattern: "\\b(W[0-9]{1,2}|(58|59|60)[0-9]([a-z]|\\.B[0-9]+)?|feature [0-9]+)\\b")
for (name, text) in pages {
    for m in internalRX.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let r = Range(m.range, in: text) { problem("\(name): an internal number in the manual: \(text[r])") }
    }
}

if problems.isEmpty {
    print("ok manual-check: \(pageNames.count) pages — \(commandsChecked) doz commands and \(flagsChecked) flags match --help, every setting (\(keys.count)) documented with its default, links resolve")
} else {
    for p in problems { FileHandle.standardError.write(Data("x manual-check: \(p)\n".utf8)) }
    exit(1)
}
