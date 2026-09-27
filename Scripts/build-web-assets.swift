#!/usr/bin/env swift
// build-web-assets.swift — `snooze ui`'s front end compiler (590; the technique of DeckStack 503's
// Scripts/build-web-assets.swift). Dependency-free and deterministic: no Node, no package manager,
// no network.
//
//   Sources/SnoozeWeb/WebSource/{index.html, app.css, app.js}   what people edit
//   Sources/SnoozeWeb/Resources/Web/                           what ships (COMMITTED, generated):
//       index.html                  referencing the hashed names
//       assets/app-<sha16>.css      content-hashed
//       assets/app-<sha16>.js
//       manifest.json               every file's public path, type, cache policy and sha256
//
//   swift Scripts/build-web-assets.swift           regenerate Resources/Web (make web-assets)
//   swift Scripts/build-web-assets.swift --check   fail when Resources/Web is not exactly what the
//                                                  sources produce (make web-assets-check — run by
//                                                  make test and Scripts/audit.sh, which DeckStack's
//                                                  never was)
//
// It also refuses a page the CSP would break: inline script, inline style or an event-handler
// attribute in index.html, and any external URL in the three sources.
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
}

struct Manifest: Codable {
    let version: Int
    let assets: [Asset]
}

func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.isEmpty || args == ["--check"] else { throw Failure.usage }
    let check = args == ["--check"]
    let package = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
    let sources = package.appendingPathComponent("Sources/SnoozeWeb/WebSource")
    let output = package.appendingPathComponent("Sources/SnoozeWeb/Resources/Web")

    func read(_ name: String) throws -> Data {
        guard let d = try? Data(contentsOf: sources.appendingPathComponent(name)) else { throw Failure.source("missing \(sources.path)/\(name)") }
        guard String(data: d, encoding: .utf8) != nil else { throw Failure.source("\(name) is not UTF-8") }
        return d
    }
    let css = try read("app.css"), js = try read("app.js"), indexSource = String(decoding: try read("index.html"), as: UTF8.self)

    // CSP conformance: `script-src 'self'; style-src 'self'` — so nothing inline, nothing external.
    guard indexSource.contains("href=\"/app.css\""), indexSource.contains("src=\"/app.js\"") else {
        throw Failure.source("index.html must reference /app.css and /app.js exactly")
    }
    let inline: [(String, String)] = [
        ("<script>", "an inline <script>"), ("<style", "a <style> element"), (" style=", "a style= attribute"),
        ("javascript:", "a javascript: URL"),
    ]
    for (needle, what) in inline where indexSource.lowercased().contains(needle) {
        throw Failure.source("index.html has \(what) — the CSP refuses it")
    }
    if indexSource.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) != nil {
        throw Failure.source("index.html has an event-handler attribute (on…=) — the CSP refuses it; use addEventListener in app.js")
    }
    for (name, text) in [("index.html", indexSource), ("app.css", String(decoding: css, as: UTF8.self)), ("app.js", String(decoding: js, as: UTF8.self))] {
        if text.range(of: #"(https?:)?//[a-z0-9.-]+\.[a-z]{2,}/"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw Failure.source("\(name) references an external URL — the UI loads nothing from outside its own origin")
        }
    }
    if String(decoding: js, as: UTF8.self).contains("innerHTML") || String(decoding: js, as: UTF8.self).contains("insertAdjacentHTML") {
        throw Failure.source("app.js uses innerHTML — render with textContent only (590.01-DESIGN.md: sandbox-controlled text is untrusted)")
    }

    let cssPath = "assets/app-\(sha256(css).prefix(16)).css"
    let jsPath = "assets/app-\(sha256(js).prefix(16)).js"
    let index = Data(indexSource
        .replacingOccurrences(of: "href=\"/app.css\"", with: "href=\"/\(cssPath)\"")
        .replacingOccurrences(of: "src=\"/app.js\"", with: "src=\"/\(jsPath)\"").utf8)
    let immutable = "public, max-age=31536000, immutable"
    let assets = [
        Asset(publicPath: "/", resourcePath: "index.html", mimeType: "text/html; charset=utf-8", sha256: sha256(index), cachePolicy: "no-store"),
        Asset(publicPath: "/" + cssPath, resourcePath: cssPath, mimeType: "text/css; charset=utf-8", sha256: sha256(css), cachePolicy: immutable),
        Asset(publicPath: "/" + jsPath, resourcePath: jsPath, mimeType: "application/javascript; charset=utf-8", sha256: sha256(js), cachePolicy: immutable),
    ].sorted { $0.publicPath < $1.publicPath }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var manifest = try enc.encode(Manifest(version: 1, assets: assets))
    manifest.append(10)
    let expected: [String: Data] = ["index.html": index, cssPath: css, jsPath: js, "manifest.json": manifest]

    var existing: [String: Data] = [:]
    let base = output.resolvingSymlinksInPath().path + "/"
    if let e = FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey]) {
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
            throw Failure.stale("x web assets are stale (missing \(want.subtracting(have).sorted()), changed \(changed), unexpected \(have.subtracting(want).sorted())) — run make web-assets and commit Sources/SnoozeWeb/Resources/Web")
        }
        print("ok web assets: Resources/Web is exactly what WebSource/ builds (\(expected.count) files)")
        return
    }
    let tmp = output.deletingLastPathComponent().appendingPathComponent(".Web.generating-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    for (path, data) in expected {
        let dest = tmp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }
    if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
    try FileManager.default.moveItem(at: tmp, to: output)
    print("generated \(expected.count) web assets in \(output.path)")
}

do { try main() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
