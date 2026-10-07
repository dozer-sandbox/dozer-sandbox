import CryptoKit
import Foundation

/// One asset the UI may serve — declared at build time in `Resources/Web/manifest.json`
/// (`Scripts/build-web-assets.swift`). The server routes only by `publicPath` and never derives a
/// file path from a request.
public struct WebAsset: Equatable, Sendable {
    public let publicPath: String
    public let mimeType: String
    public let cachePolicy: String
    public let sha256: String
    public let data: Data
}

public enum WebAssetError: Error, Equatable, Sendable {
    case bundleMissing, manifestMissing, malformedManifest, unsafePath, unsupportedType, digestMismatch(String), resourceMissing(String)
}

/// The manifest, loaded ONCE at start and digest-checked: a changed or added file in the resource
/// bundle is never served (a mismatch refuses to start rather than serve it).
public struct WebAssets: Sendable {
    public static let bundleName = "DozerKit_DozerWeb.bundle"
    public let assets: [String: WebAsset]

    static let allowedTypes: Set<String> = [
        "text/html; charset=utf-8", "text/css; charset=utf-8", "application/javascript; charset=utf-8", "image/svg+xml",
        // 605: the web app manifest, and the app icons' PNGs (only under /assets/icon-*: `isIconPNG`).
        "application/manifest+json", "image/png",
    ]
    /// 591: types only a VENDORED file may have (the terminal engine's WebAssembly). The page's own
    /// code is never WebAssembly.
    static let vendorOnlyTypes: Set<String> = ["application/wasm"]
    static let immutable = "public, max-age=31536000, immutable"

    /// From the resource bundle beside the executable (or the test bundle), like `DeckholdBinary` —
    /// never SwiftPM's `Bundle.module`, which traps when the bundle is not where the build put it.
    public static func load() throws -> WebAssets {
        for dir in candidateBundles() {
            for rel in ["Contents/Resources/Web", "Web"] {
                let url = dir.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) { return try load(webRoot: url) }
            }
        }
        throw WebAssetError.bundleMissing
    }

    static func candidateBundles() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() { dirs.append(exe.deletingLastPathComponent()) }
        for b in Bundle.allBundles where b.bundleURL.pathExtension == "xctest" { dirs.append(b.bundleURL.deletingLastPathComponent()) }
        var seen = Set<String>()
        return dirs.map { $0.appendingPathComponent(bundleName) }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let publicPath, resourcePath, mimeType, sha256, cachePolicy: String
            /// 591: `page` or `vendor` (absent in a 590 manifest: page).
            let `class`: String?
        }
        let version: Int
        let assets: [Entry]
    }

    /// From a `Web` directory holding `manifest.json`.
    public static func load(webRoot: URL) throws -> WebAssets {
        let murl = webRoot.appendingPathComponent("manifest.json")
        guard let d = try? Data(contentsOf: murl) else { throw WebAssetError.manifestMissing }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: d), m.version == 1, !m.assets.isEmpty else {
            throw WebAssetError.malformedManifest
        }
        var out: [String: WebAsset] = [:]
        for e in m.assets {
            guard isSafePublicPath(e.publicPath), isSafeResourcePath(e.resourcePath) else { throw WebAssetError.unsafePath }
            let vendor: Bool
            switch e.class ?? "page" {
            case "page": vendor = false
            case "vendor": vendor = true
            default: throw WebAssetError.malformedManifest
            }
            guard allowedTypes.contains(e.mimeType) || (vendor && vendorOnlyTypes.contains(e.mimeType)) else { throw WebAssetError.unsupportedType }
            guard !vendor || e.publicPath.hasPrefix("/assets/vendor-") else { throw WebAssetError.unsafePath }
            // 605: a PNG is an app icon of the page's own (rendered from its SVG master), nothing else.
            guard e.mimeType != "image/png" || (!vendor && isIconPNG(e.publicPath)) else { throw WebAssetError.unsupportedType }
            guard documents.contains(e.publicPath) ? e.cachePolicy == "no-store" : e.cachePolicy == immutable else { throw WebAssetError.malformedManifest }
            guard out[e.publicPath] == nil else { throw WebAssetError.malformedManifest }
            guard let data = try? Data(contentsOf: webRoot.appendingPathComponent(e.resourcePath)) else {
                throw WebAssetError.resourceMissing(e.resourcePath)
            }
            guard sha256Hex(data) == e.sha256 else { throw WebAssetError.digestMismatch(e.resourcePath) }
            out[e.publicPath] = WebAsset(publicPath: e.publicPath, mimeType: e.mimeType, cachePolicy: e.cachePolicy, sha256: e.sha256, data: data)
        }
        guard out["/"] != nil else { throw WebAssetError.malformedManifest }
        return WebAssets(assets: out)
    }

    public init(assets: [String: WebAsset]) {
        self.assets = assets
        // 605: this build's page script and style — `hello` names them, so an open page of an OLDER build
        // (its own <script src> differs) knows doz ui was updated underneath it.
        pageScript = assets.keys.filter { $0.hasPrefix("/assets/app-") && $0.hasSuffix(".js") }.sorted().first
        pageStyle = assets.keys.filter { $0.hasPrefix("/assets/app-") && $0.hasSuffix(".css") }.sorted().first
    }

    public let pageScript: String?
    public let pageStyle: String?

    /// 607: the page script's modules are served from one directory per layer, /assets/app/<layer>/.
    public static let moduleLayers: Set<String> = ["dom", "core", "components", "views"]

    static func isIconPNG(_ publicPath: String) -> Bool {
        publicPath.hasPrefix("/assets/icon-") && publicPath.hasSuffix(".png")
    }

    public static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// 591: the two documents — the page, and the terminal engine's sandboxed frame. 605: the offline
    /// page (what the service worker shows while doz ui is down) and the service worker itself — both at
    /// stable paths, no-store, served without a session (they hold no data).
    public static let frameDocument = "/terminal-frame"
    public static let offlineDocument = "/offline"
    public static let serviceWorker = "/sw.js"
    static let documents: Set<String> = ["/", frameDocument, offlineDocument, serviceWorker]

    /// 591: what the sandboxed (opaque-origin) terminal frame loads: its own script and style and the
    /// engine's script. Those requests come from an opaque origin — `Sec-Fetch-Site: cross-site`, no
    /// cookie — so they are answered without the Origin/Fetch-Metadata checks and with
    /// `Cross-Origin-Resource-Policy: cross-origin`. They are public, static and hold no secret; the
    /// frame fetches nothing else (its CSP has `connect-src 'none'`: the WASM bytes come from the page).
    public static func isFrameAsset(_ publicPath: String) -> Bool {
        publicPath.hasPrefix("/assets/frame-") || publicPath.hasPrefix("/assets/vendor-ghostty-web-")
    }

    static func isSafePublicPath(_ p: String) -> Bool {
        guard documents.contains(p) || p.hasPrefix("/assets/"), !p.contains(".."), !p.contains("//") else { return false }
        return p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/.-_".contains($0)) }
    }

    static func isSafeResourcePath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/") else { return false }
        return p.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
        }
    }
}
