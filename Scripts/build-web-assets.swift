#!/usr/bin/env swift
// build-web-assets.swift — `doz ui`'s front end compiler (590; the technique of DeckStack 503's
// Scripts/build-web-assets.swift). Dependency-free and deterministic: no Node, no package manager,
// no network.
//
//   Sources/DozerWeb/WebSource/{index.html, app.css, app.js}   the page's OWN code (what people edit)
//   Sources/DozerWeb/WebSource/vendor/<package>/               591: VENDORED third-party files, each
//                                                               byte-identical to its registry tarball
//                                                               and pinned in that directory's VENDOR.json
//   Sources/DozerWeb/Resources/Web/                           what ships (COMMITTED, generated):
//       index.html                  referencing the hashed names
//       assets/app-<sha16>.css      content-hashed
//       assets/app-<sha16>.js
//       assets/<publicName>-<sha16>.{js,wasm}   vendored, content-hashed, bytes unchanged
//       licences/<package>-<file>   each vendored package's licence (in the bundle, not served)
//       manifest.json               every served file's public path, type, cache policy, sha256, class
//
//   swift Scripts/build-web-assets.swift           regenerate Resources/Web (make web-assets)
//   swift Scripts/build-web-assets.swift --check   fail when Resources/Web is not exactly what the
//                                                  sources produce (make web-assets-check — run by
//                                                  make test and Scripts/audit.sh)
//
// Two classes of file, two sets of rules (591.01-DESIGN.md §3):
//   · the page's own code must be what the CSP and the XSS rule allow: no inline script, inline
//     style or event-handler attribute in index.html, no external URL anywhere, no innerHTML in app.js;
//   · a vendored file is admitted by PROVENANCE, not content: its sha256 must equal VENDOR.json's
//     pin, its licence must be on the allowlist, and no unlisted file may sit in its directory. Its
//     bytes are never rewritten. The page's rules are not applied to it (minified third-party code
//     would fail them) and are not loosened for the page's own files either.
import CryptoKit
import Foundation

enum Failure: Error, CustomStringConvertible {
    case usage, source(String), stale(String)
    var description: String {
        switch self {
        case .usage: "usage: build-web-assets.swift [--check]"
        case .source(let s), .stale(let s): s
        }
    }
}

struct Asset: Codable {
    let publicPath: String
    let resourcePath: String
    let mimeType: String
    let sha256: String
    let cachePolicy: String
    /// `page` (this package's own code) or `vendor` (a pinned third-party file).
    let `class`: String
}

struct Manifest: Codable {
    let version: Int
    let assets: [Asset]
}

/// `WebSource/vendor/<package>/VENDOR.json`.
struct Vendor: Decodable {
    struct File: Decodable {
        let file: String
        let fromTarball: String
        let sha256: String
        /// `script` (served as JavaScript), `wasm` (served as application/wasm), `licence` (bundled only),
        /// `icon` (593: an SVG icon, served only inside the package's generated sprite).
        let serve: String
        let publicName: String?
        /// What index.html writes for it (rewritten to the hashed public path).
        let indexReference: String?
    }
    /// 593: the package's `icon` files, as ONE generated SVG sprite (a `<symbol id="NAME">` per
    /// file, holding that file's drawing elements byte for byte) — `assets/<publicName>-<sha16>.svg`.
    struct Sprite: Decodable {
        let publicName: String
        let indexReference: String
    }
    let sprite: Sprite?
    let package: String
    let version: String
    let tarball: String
    let tarballIntegrity: String
    let tarballSha256: String
    let licence: String
    let licenceFile: String
    let files: [File]
}

/// Licences a vendored file may carry (SPDX). Anything else needs this list changed on purpose.
let allowedLicences: Set<String> = ["MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "ISC"]

func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// 593: an icon file's drawing, checked: an optional `<!-- @license … -->`, then ONE `<svg …
/// viewBox="0 0 24 24" …>` whose children are only path / circle / ellipse / line / polyline /
/// polygon / rect elements with geometry attributes — no script, style, link, event handler or
/// reference of any kind. Returns the children as they are in the file.
func iconBody(_ file: String, _ text: String) throws -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("<!--") {
        guard let end = t.range(of: "-->") else { throw Failure.source("\(file): an unclosed comment") }
        guard t[..<end.lowerBound].contains("@license") else { throw Failure.source("\(file): only the licence comment is expected") }
        t = String(t[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard t.hasPrefix("<svg"), t.hasSuffix("</svg>"), let open = t.range(of: ">") else { throw Failure.source("\(file): not one <svg> element") }
    guard t[..<open.lowerBound].contains("viewBox=\"0 0 24 24\"") else { throw Failure.source("\(file): the viewBox is not 0 0 24 24") }
    let body = String(t[open.upperBound..<t.index(t.endIndex, offsetBy: -6)]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw Failure.source("\(file): an empty drawing") }
    let allowedTags: Set<String> = ["path", "circle", "ellipse", "line", "polyline", "polygon", "rect"]
    let allowedAttributes: Set<String> = ["d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2", "width", "height", "points"]
    let tag = try NSRegularExpression(pattern: #"<\s*(/?)\s*([A-Za-z:-]+)([^<>]*)>"#)
    let attr = try NSRegularExpression(pattern: #"([A-Za-z:_-]+)\s*=\s*"([^"]*)""#)
    let ns = body as NSString
    var covered = 0
    for m in tag.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
        guard ns.substring(with: NSRange(location: covered, length: m.range.location - covered)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.source("\(file): text outside an element")
        }
        covered = m.range.location + m.range.length
        let name = ns.substring(with: m.range(at: 2))
        guard allowedTags.contains(name) else { throw Failure.source("\(file): <\(name)> is not an allowed drawing element") }
        let attrs = ns.substring(with: m.range(at: 3)).replacingOccurrences(of: "/", with: " ")
        let an = attrs as NSString
        // What the matched attributes do not cover must be blank (by position — `x="2"` is also inside `rx="2"`).
        var rest = ""
        var at = 0
        for a in attr.matches(in: attrs, range: NSRange(location: 0, length: an.length)) {
            rest += an.substring(with: NSRange(location: at, length: a.range.location - at))
            at = a.range.location + a.range.length
            let key = an.substring(with: a.range(at: 1)), value = an.substring(with: a.range(at: 2))
            // A dot drawn filled (key-round's) takes the icon's colour: currentColor, or none.
            if key == "fill", value == "currentColor" || value == "none" { continue }
            guard allowedAttributes.contains(key) else { throw Failure.source("\(file): attribute \(key) is not allowed") }
            guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " .,-".contains($0)) }) else {
                throw Failure.source("\(file): \(key) holds more than geometry")
            }
        }
        rest += an.substring(from: at)
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.source("\(file): an attribute that is not name=\"value\"") }
    }
    guard ns.substring(from: covered).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.source("\(file): text after the drawing") }
    return body
}

func isPlainName(_ s: String) -> Bool {
    !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.isEmpty || args == ["--check"] else { throw Failure.usage }
    let check = args == ["--check"]
    let package = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
    let sources = package.appendingPathComponent("Sources/DozerWeb/WebSource")
    let output = package.appendingPathComponent("Sources/DozerWeb/Resources/Web")
    let fm = FileManager.default

    // The page's own documents, each with its one stylesheet and one script (591: the terminal
    // engine's sandboxed frame is the second document).
    let documents: [(file: String, publicPath: String, css: String, js: String)] = [
        ("index.html", "/", "app", "app"),
        ("terminal.html", "/terminal-frame", "frame", "frame"),
    ]
    // Nothing but those files and vendor/ lives in WebSource: a stray file is a mistake.
    let top = Set((try? fm.contentsOfDirectory(atPath: sources.path)) ?? []).subtracting([".DS_Store"])
    let known = Set(documents.flatMap { [$0.file, $0.css + ".css", $0.js + ".js"] } + ["vendor"])
    let unexpectedTop = top.subtracting(known)
    guard unexpectedTop.isEmpty else { throw Failure.source("unexpected files in WebSource: \(unexpectedTop.sorted())") }

    func read(_ name: String) throws -> Data {
        guard let d = try? Data(contentsOf: sources.appendingPathComponent(name)) else { throw Failure.source("missing \(sources.path)/\(name)") }
        guard String(data: d, encoding: .utf8) != nil else { throw Failure.source("\(name) is not UTF-8") }
        return d
    }

    // ── The page's own code: CSP conformance (`script-src 'self'; style-src 'self'`), nothing inline,
    //    nothing external, no innerHTML.
    var docText: [String: String] = [:]
    var styles: [String: Data] = [:], scripts: [String: Data] = [:]
    let inline: [(String, String)] = [
        ("<script>", "an inline <script>"), ("<style", "a <style> element"), (" style=", "a style= attribute"),
        ("javascript:", "a javascript: URL"),
    ]
    for d in documents {
        let text = String(decoding: try read(d.file), as: UTF8.self)
        guard text.contains("href=\"/\(d.css).css\""), text.contains("src=\"/\(d.js).js\"") else {
            throw Failure.source("\(d.file) must reference /\(d.css).css and /\(d.js).js exactly")
        }
        for (needle, what) in inline where text.lowercased().contains(needle) {
            throw Failure.source("\(d.file) has \(what) — the CSP refuses it")
        }
        if text.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) != nil {
            throw Failure.source("\(d.file) has an event-handler attribute (on…=) — the CSP refuses it; use addEventListener")
        }
        docText[d.file] = text
        styles[d.css] = try read(d.css + ".css")
        scripts[d.js] = try read(d.js + ".js")
    }
    let pageFiles = docText.map { ($0.key, $0.value) } + styles.map { ($0.key + ".css", String(decoding: $0.value, as: UTF8.self)) }
        + scripts.map { ($0.key + ".js", String(decoding: $0.value, as: UTF8.self)) }
    for (name, text) in pageFiles {
        // 593: the SVG namespace is a name, not a URL anything loads (createElementNS).
        let scanned = text.replacingOccurrences(of: "\"http://www.w3.org/2000/svg\"", with: "\"svg-ns\"")
            .replacingOccurrences(of: "'http://www.w3.org/2000/svg'", with: "'svg-ns'")
        if scanned.range(of: #"(https?:)?//[a-z0-9.-]+\.[a-z]{2,}/"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw Failure.source("\(name) references an external URL — the UI loads nothing from outside its own origin")
        }
        if name.hasSuffix(".js"), text.contains("innerHTML") || text.contains("insertAdjacentHTML") {
            throw Failure.source("\(name) uses innerHTML — render with textContent only (590.01-DESIGN.md: sandbox-controlled text is untrusted)")
        }
    }

    let immutable = "public, max-age=31536000, immutable"
    var expected: [String: Data] = [:]
    var assets: [Asset] = []

    // ── Vendored packages (591): provenance, not content.
    let vendorRoot = sources.appendingPathComponent("vendor")
    let packages = ((try? fm.contentsOfDirectory(atPath: vendorRoot.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    for pkg in packages {
        guard isPlainName(pkg) else { throw Failure.source("vendor/\(pkg): not a plain directory name") }
        let dir = vendorRoot.appendingPathComponent(pkg)
        guard let vd = try? Data(contentsOf: dir.appendingPathComponent("VENDOR.json")) else {
            throw Failure.source("vendor/\(pkg) has no VENDOR.json — a vendored file is admitted only with its pin")
        }
        let v: Vendor
        do { v = try JSONDecoder().decode(Vendor.self, from: vd) } catch { throw Failure.source("vendor/\(pkg)/VENDOR.json: \(error)") }
        guard v.package == pkg else { throw Failure.source("vendor/\(pkg)/VENDOR.json names package \(v.package)") }
        guard allowedLicences.contains(v.licence) else { throw Failure.source("vendor/\(pkg): licence \(v.licence) is not on the allowlist") }
        guard v.tarball.hasPrefix("https://registry.npmjs.org/"), v.tarballIntegrity.hasPrefix("sha512-"), v.tarballSha256.count == 64 else {
            throw Failure.source("vendor/\(pkg): the tarball must be the registry's, with its sha512 integrity and sha256")
        }
        guard v.files.contains(where: { $0.file == v.licenceFile && $0.serve == "licence" }) else {
            throw Failure.source("vendor/\(pkg): the licence file must be listed (serve: licence)")
        }
        var symbols: [String] = []
        let listed = Set(v.files.map(\.file))
        let present = Set(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" })
        let unlisted = present.subtracting(listed).subtracting(["VENDOR.json"])
        guard unlisted.isEmpty else { throw Failure.source("vendor/\(pkg) holds files VENDOR.json does not pin: \(unlisted.sorted())") }
        for f in v.files {
            guard isPlainName(f.file) else { throw Failure.source("vendor/\(pkg): bad file name \(f.file)") }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f.file)) else { throw Failure.source("vendor/\(pkg)/\(f.file) is missing") }
            guard sha256(data) == f.sha256 else {
                throw Failure.source("vendor/\(pkg)/\(f.file) is not the pinned file (sha256 differs from VENDOR.json) — vendored bytes are never edited")
            }
            switch f.serve {
            case "licence":
                expected["licences/\(pkg)-\(f.file)"] = data
            case "script", "wasm":
                guard let name = f.publicName, isPlainName(name), name.hasPrefix("vendor-"), let ref = f.indexReference, ref.hasPrefix("/vendor/") else {
                    throw Failure.source("vendor/\(pkg)/\(f.file): a served file needs publicName (vendor-…) and indexReference (/vendor/…)")
                }
                guard docText.values.contains(where: { $0.contains("\"\(ref)\"") }) else { throw Failure.source("no document references \(ref)") }
                let ext = f.serve == "script" ? "js" : "wasm"
                let path = "assets/\(name)-\(f.sha256.prefix(16)).\(ext)"
                for (k, v) in docText { docText[k] = v.replacingOccurrences(of: "\"\(ref)\"", with: "\"/\(path)\"") }
                expected[path] = data
                assets.append(Asset(publicPath: "/" + path, resourcePath: path,
                                    mimeType: f.serve == "script" ? "application/javascript; charset=utf-8" : "application/wasm",
                                    sha256: f.sha256, cachePolicy: immutable, class: "vendor"))
            case "icon":
                guard f.file.hasSuffix(".svg"), v.sprite != nil else { throw Failure.source("vendor/\(pkg)/\(f.file): an icon is an .svg of a package with a sprite") }
                let id = String(f.file.dropLast(4))
                guard id.allSatisfy({ ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }) else { throw Failure.source("vendor/\(pkg)/\(f.file): an icon name is a-z 0-9 -") }
                symbols.append("<symbol id=\"\(id)\" viewBox=\"0 0 24 24\">\(try iconBody("vendor/\(pkg)/\(f.file)", String(decoding: data, as: UTF8.self)))</symbol>")
            default:
                throw Failure.source("vendor/\(pkg)/\(f.file): serve must be script, wasm, icon or licence")
            }
        }
        if let s = v.sprite {
            guard !symbols.isEmpty, isPlainName(s.publicName), s.publicName.hasPrefix("vendor-"), s.indexReference.hasPrefix("/vendor/") else {
                throw Failure.source("vendor/\(pkg): a sprite needs icons, a publicName (vendor-…) and an indexReference (/vendor/…)")
            }
            guard docText.values.contains(where: { $0.contains("\"\(s.indexReference)\"") }) else { throw Failure.source("no document references \(s.indexReference)") }
            // Generated from the pinned files (sorted by name), deterministic: a changed pin is a changed sprite.
            let sprite = Data(("<svg xmlns=\"http://www.w3.org/2000/svg\">\n<!-- \(v.package) \(v.version) (\(v.licence)), generated by Scripts/build-web-assets.swift from the files VENDOR.json pins -->\n"
                + symbols.sorted().joined(separator: "\n") + "\n</svg>\n").utf8)
            let digest = sha256(sprite)
            let path = "assets/\(s.publicName)-\(digest.prefix(16)).svg"
            for (k, t) in docText { docText[k] = t.replacingOccurrences(of: "\"\(s.indexReference)\"", with: "\"/\(path)\"") }
            expected[path] = sprite
            assets.append(Asset(publicPath: "/" + path, resourcePath: path, mimeType: "image/svg+xml", sha256: digest, cachePolicy: immutable, class: "vendor"))
        }
    }
    for (file, text) in docText {
        if let stray = text.range(of: #""/vendor/[^"]*""#, options: .regularExpression) {
            throw Failure.source("\(file) references \(text[stray]), which no VENDOR.json serves")
        }
    }

    // ── The page's own files.
    for d in documents {
        let css = styles[d.css]!, js = scripts[d.js]!
        let cssPath = "assets/\(d.css)-\(sha256(css).prefix(16)).css"
        let jsPath = "assets/\(d.js)-\(sha256(js).prefix(16)).js"
        let docData = Data(docText[d.file]!
            .replacingOccurrences(of: "href=\"/\(d.css).css\"", with: "href=\"/\(cssPath)\"")
            .replacingOccurrences(of: "src=\"/\(d.js).js\"", with: "src=\"/\(jsPath)\"").utf8)
        assets += [
            Asset(publicPath: d.publicPath, resourcePath: d.file, mimeType: "text/html; charset=utf-8", sha256: sha256(docData), cachePolicy: "no-store", class: "page"),
            Asset(publicPath: "/" + cssPath, resourcePath: cssPath, mimeType: "text/css; charset=utf-8", sha256: sha256(css), cachePolicy: immutable, class: "page"),
            Asset(publicPath: "/" + jsPath, resourcePath: jsPath, mimeType: "application/javascript; charset=utf-8", sha256: sha256(js), cachePolicy: immutable, class: "page"),
        ]
        expected[d.file] = docData
        expected[cssPath] = css
        expected[jsPath] = js
    }
    assets.sort { $0.publicPath < $1.publicPath }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var manifest = try enc.encode(Manifest(version: 1, assets: assets))
    manifest.append(10)
    expected["manifest.json"] = manifest

    var existing: [String: Data] = [:]
    let base = output.resolvingSymlinksInPath().path + "/"
    if let e = fm.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey]) {
        while let u = e.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = u.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { throw Failure.source("unexpected path \(path)") }
            existing[String(path.dropFirst(base.count))] = try Data(contentsOf: u)
        }
    }
    if check {
        guard existing == expected else {
            let want = Set(expected.keys), have = Set(existing.keys)
            let changed = want.intersection(have).filter { expected[$0] != existing[$0] }.sorted()
            throw Failure.stale("x web assets are stale (missing \(want.subtracting(have).sorted()), changed \(changed), unexpected \(have.subtracting(want).sorted())) — run make web-assets and commit Sources/DozerWeb/Resources/Web")
        }
        print("ok web assets: Resources/Web is exactly what WebSource/ builds (\(expected.count) files, \(packages.count) vendored package(s) at their pins)")
        return
    }
    let tmp = output.deletingLastPathComponent().appendingPathComponent(".Web.generating-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    for (path, data) in expected {
        let dest = tmp.appendingPathComponent(path)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }
    if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
    try fm.moveItem(at: tmp, to: output)
    print("generated \(expected.count) web assets in \(output.path)")
}

do { try main() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
