import Containerization
import ContainerizationOCI
import CryptoKit
import Foundation

/// 596 (B7, B8): an OCI image layout (a directory, as `container build -o type=oci` archives it) →
/// the store's image store, so a bake finds its base by a digest-pinned reference like any pulled one.
public enum OCIImport {
    public struct Imported: Sendable, Equatable {
        /// The imported image's digest, and the digest-pinned reference a spec names (`<name>@<digest>`).
        public var digest: String
        /// sha256 over the linux/arm64 manifest's layer digests, in order — what the base disk is made
        /// of (a rebuild that changed only the config's timestamps has the same value).
        public var layers: String
        /// The image config's `Env` (`KEY=value`) and `User`.
        public var environment: [String]
        public var user: String?
    }

    /// Load `layoutDirectory` into the image store at `storeRoot` under `tag` (the layout's first
    /// manifest is renamed to it; the directory is edited in place).
    public static func load(layoutDirectory dir: URL, tag: String, storeRoot: URL) async throws -> Imported {
        let indexURL = dir.appendingPathComponent("index.json")
        guard var index = (try? JSONSerialization.jsonObject(with: Data(contentsOf: indexURL))) as? [String: Any],
              let manifests = index["manifests"] as? [[String: Any]], var first = manifests.first else {
            throw SandboxError.invalidSpec("the archive has no OCI index")
        }
        var a = (first["annotations"] as? [String: String]) ?? [:]
        for k in ["com.apple.containerization.image.name", "io.containerd.image.name", "org.opencontainers.image.ref.name"] { a[k] = tag }
        first["annotations"] = a
        index["manifests"] = [first]
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
        let store = try ImageStore(path: storeRoot)
        guard let image = try await store.load(from: dir).first else { throw SandboxError.invalidSpec("the archive held no image") }
        let arm = Platform(arch: "arm64", os: "linux")
        let manifest: Manifest
        do { manifest = try await image.manifest(for: arm) } catch {
            throw SandboxError.invalidSpec("the image has no linux/arm64 variant — Dozer's sandboxes are arm64")
        }
        let layers = SHA256.hash(data: Data(manifest.layers.map(\.digest).joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        let config = try await image.config(for: arm)
        return Imported(digest: image.digest, layers: layers, environment: config.config?.env ?? [], user: config.config?.user)
    }

    /// Whether the store has `reference`.
    public static func has(_ reference: String, storeRoot: URL) async -> Bool {
        guard let store = try? ImageStore(path: storeRoot) else { return false }
        return (try? await store.get(reference: reference)) != nil
    }

    /// Name an image the store has by another reference (a digest-pinned one).
    public static func tag(_ existing: String, as new: String, storeRoot: URL) async throws {
        let store = try ImageStore(path: storeRoot)
        if (try? await store.get(reference: new)) != nil { return }
        _ = try await store.tag(existing: existing, new: new)
    }
}
