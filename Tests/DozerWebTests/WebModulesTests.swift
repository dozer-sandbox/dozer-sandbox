import Foundation
import XCTest
@testable import DozerWeb

/// 607 — the page script as native ES modules (`WebSource/app.js` + `WebSource/app/<layer>/*.js`): what ships
/// (every module hashed, served immutable, imported by its hashed RELATIVE name, the graph layered and closed),
/// and what the asset compiler refuses (a cycle, an import up a layer, a bare/absolute/missing specifier, a
/// dynamic import(), an orphan, an unprovided upcall, innerHTML in a module).
final class WebModulesTests: XCTestCase {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static let layers = ["dom": 0, "core": 1, "components": 2, "views": 3]

    /// The specifiers a served page script imports (static imports only — the compiler allows nothing else).
    static func specifiers(_ text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"(?m)^[ \t]*(?:import|export)\b[^'";=()]*?\bfrom[ \t]*'([^'\n]*)'|^[ \t]*import[ \t]*'([^'\n]*)'"#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            ns.substring(with: m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2))
        }
    }

    /// A specifier resolved like a browser does, against the importing script's public path.
    static func resolve(_ spec: String, against path: String) -> String {
        URL(string: spec, relativeTo: URL(string: "http://127.0.0.1:1" + path)!)!.path
    }

    func testEveryModuleIsServedHashedAndImportedOnlyFromItsOwnLayerOrBelow() throws {
        let a = try WebAssets.load()
        let src = Self.root.appendingPathComponent("Sources/DozerWeb/WebSource/app")
        let sources = (FileManager.default.enumerator(atPath: src.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".js") }
        let modules = a.assets.keys.filter { $0.hasPrefix("/assets/app/") }
        XCTAssertEqual(modules.count, sources.count, "one served module per source module")
        let entry = try XCTUnwrap(a.pageScript)
        var reached = Set<String>()
        var queue = [entry]
        while let p = queue.popLast() {
            let asset = try XCTUnwrap(a.assets[p], p)
            XCTAssertEqual(asset.mimeType, "application/javascript; charset=utf-8", p)
            XCTAssertEqual(asset.cachePolicy, WebAssets.immutable, p)
            let text = String(decoding: asset.data, as: UTF8.self)
            XCTAssertFalse(text.contains("innerHTML") || text.contains("insertAdjacentHTML"), p)
            for spec in Self.specifiers(text) {
                XCTAssertTrue(spec.hasPrefix("./") || spec.hasPrefix("../"), "\(p) imports \(spec) relatively")
                let target = Self.resolve(spec, against: p)
                XCTAssertTrue(target.hasPrefix("/assets/app/"), "\(p) → \(target)")
                XCTAssertNotNil(a.assets[target], "\(p) imports \(target), which is served")
                XCTAssertTrue(target.range(of: #"-[0-9a-f]{16}\.js$"#, options: .regularExpression) != nil, "\(target) is a hashed name")
                if p != entry {
                    let from = p.split(separator: "/")[2], to = target.split(separator: "/")[2]
                    XCTAssertLessThanOrEqual(Self.layers[String(to)]!, Self.layers[String(from)]!, "\(p) imports \(target): never up a layer")
                }
                if reached.insert(target).inserted { queue.append(target) }
            }
        }
        XCTAssertEqual(reached, Set(modules), "the entry reaches every module, and nothing else")
        if !modules.isEmpty {
            let index = String(decoding: a.assets["/"]!.data, as: UTF8.self)
            XCTAssertTrue(index.contains("<script type=\"module\" src=\"\(entry)\"></script>"), "index.html loads the entry as a module")
        }
    }

    /// A served module is its source with ONLY the import specifiers changed (to the hashed names).
    func testAServedModuleIsItsSourceWithHashedSpecifiersOnly() throws {
        let a = try WebAssets.load()
        let src = Self.root.appendingPathComponent("Sources/DozerWeb/WebSource")
        let unhash = { (t: String) in t.replacingOccurrences(of: #"-[0-9a-f]{16}\.js'"#, with: ".js'", options: .regularExpression) }
        for (path, asset) in a.assets where path.hasPrefix("/assets/app/") {
            let rel = String(path.dropFirst("/assets/app/".count)).replacingOccurrences(of: #"-[0-9a-f]{16}\.js$"#, with: ".js", options: .regularExpression)
            let source = try String(contentsOf: src.appendingPathComponent("app/" + rel), encoding: .utf8)
            XCTAssertEqual(unhash(String(decoding: asset.data, as: UTF8.self)), source, rel)
        }
        let entry = String(decoding: a.assets[a.pageScript!]!.data, as: UTF8.self)
        XCTAssertEqual(unhash(entry), try String(contentsOf: src.appendingPathComponent("app.js"), encoding: .utf8))
    }

    // MARK: the compiler's refusals, on a scratch copy of the sources

    func compileScratch(_ change: (URL) throws -> Void) throws -> (Int32, String) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("doz-webm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("Sources/DozerWeb"), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.root.appendingPathComponent("Scripts/build-web-assets.swift"), to: tmp.appendingPathComponent("Scripts/build-web-assets.swift"))
        try fm.copyItem(at: Self.root.appendingPathComponent("Sources/DozerWeb/WebSource"), to: tmp.appendingPathComponent("Sources/DozerWeb/WebSource"))
        try fm.copyItem(at: Self.root.appendingPathComponent("Sources/DozerWeb/Resources"), to: tmp.appendingPathComponent("Sources/DozerWeb/Resources"))
        try change(tmp.appendingPathComponent("Sources/DozerWeb/WebSource"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", tmp.appendingPathComponent("Scripts/build-web-assets.swift").path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Writes app/<rel> and makes the entry import it (index.html loads the entry as a module).
    static func add(_ src: URL, _ rel: String, _ text: String, importFromEntry: Bool = true) throws {
        let u = src.appendingPathComponent("app/" + rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        let index = src.appendingPathComponent("index.html")
        let html = try String(contentsOf: index, encoding: .utf8)
        try Data(html.replacingOccurrences(of: "<script src=\"/app.js\" defer></script>", with: "<script type=\"module\" src=\"/app.js\"></script>").utf8).write(to: index)
        if importFromEntry {
            let entry = src.appendingPathComponent("app.js")
            try Data(("import './app/\(rel)';\n" + (try String(contentsOf: entry, encoding: .utf8))).utf8).write(to: entry)
        }
    }

    func testTheCompilerRefusesABadModuleGraph() throws {
        func refused(_ what: String, _ expect: String, _ change: (URL) throws -> Void) throws {
            let (status, out) = try compileScratch(change)
            XCTAssertNotEqual(status, 0, what)
            XCTAssertTrue(out.contains(expect), "\(what): \(out)")
        }
        // A good graph compiles (a layered pair, imported by its hashed name).
        let ok = try compileScratch { src in
            try Self.add(src, "core/zz-b.js", "export const b = 1;\n", importFromEntry: false)
            try Self.add(src, "views/zz-a.js", "import { b } from '../core/zz-b.js';\nexport const a = b;\n")
        }
        XCTAssertEqual(ok.0, 0, ok.1)
        try refused("a cycle", "an import cycle") { src in
            try Self.add(src, "core/zz-a.js", "import { b } from './zz-b.js';\nexport function a() { return b(); }\n")
            try Self.add(src, "core/zz-b.js", "import { a } from './zz-a.js';\nexport function b() { return a(); }\n", importFromEntry: false)
        }
        try refused("an import up a layer", "up a layer") { src in
            try Self.add(src, "views/zz-v.js", "export const v = 1;\n", importFromEntry: false)
            try Self.add(src, "components/zz-c.js", "import { v } from '../views/zz-v.js';\nexport const c = v;\n")
        }
        try refused("a bare specifier", "only by a relative specifier") { src in
            try Self.add(src, "core/zz-a.js", "import x from 'lodash';\nexport const a = x;\n")
        }
        try refused("an absolute specifier", "only by a relative specifier") { src in
            try Self.add(src, "core/zz-a.js", "import { x } from '/assets/app/core/x.js';\nexport const a = x;\n")
        }
        try refused("a missing module", "which does not exist") { src in
            try Self.add(src, "core/zz-a.js", "import { x } from './zz-nope.js';\nexport const a = x;\n")
        }
        try refused("a dynamic import", "uses import()") { src in
            try Self.add(src, "core/zz-a.js", "export const a = () => import('./zz-a.js');\n")
        }
        try refused("an orphan module", "never loads") { src in
            try Self.add(src, "core/zz-a.js", "export const a = 1;\n", importFromEntry: false)
        }
        try refused("a module outside the layers", "only app/<dom|core|components|views>") { src in
            try Self.add(src, "core/Bad_Name.js", "export const a = 1;\n")
        }
        try refused("an unprovided upcall", "which app.js does not provide") { src in
            try Self.add(src, "core/zz-a.js", "const nowhere = upcall('nowhere');\nexport const a = nowhere;\n")
        }
        try refused("innerHTML in a module", "uses innerHTML") { src in
            try Self.add(src, "views/zz-a.js", "export function a(el, s) { el.innerHTML = s; }\n")
        }
        try refused("an external URL in a module", "references an external URL") { src in
            try Self.add(src, "views/zz-a.js", "export const a = 'https://example.com/x.js';\n")
        }
        try refused("a module loaded as a classic script", "must load app.js as a module") { src in
            try Self.add(src, "core/zz-a.js", "export const a = 1;\n")
            let index = src.appendingPathComponent("index.html")
            let html = try String(contentsOf: index, encoding: .utf8)
            try Data(html.replacingOccurrences(of: "<script type=\"module\" src=\"/app.js\"></script>", with: "<script src=\"/app.js\" defer></script>").utf8).write(to: index)
        }
    }
}
