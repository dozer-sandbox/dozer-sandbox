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
    public static let bundleName = "SnoozeContainerKit_SnoozeWeb.bundle"
    public let assets: [String: WebAsset]

    static let allowedTypes: Set<String> = [
        "text/html; charset=utf-8", "text/css; charset=utf-8", "application/javascript; charset=utf-8", "image/svg+xml",
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
            guard e.publicPath == "/" ? e.cachePolicy == "no-store" : e.cachePolicy == immutable else { throw WebAssetError.malformedManifest }
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

    public init(assets: [String: WebAsset]) { self.assets = assets }

    public static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func isSafePublicPath(_ p: String) -> Bool {
        guard p == "/" || p.hasPrefix("/assets/"), !p.contains(".."), !p.contains("//") else { return false }
        return p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/.-_".contains($0)) }
    }

    static func isSafeResourcePath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/") else { return false }
        return p.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
        }
    }
}
