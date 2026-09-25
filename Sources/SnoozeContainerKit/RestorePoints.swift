import Darwin
import Foundation

/// A restore point: a DISK-ONLY copy of a sandbox — its root disk and, for an image sandbox, its
/// state disk — made with APFS `clonefile`, so taking one is instant and costs only the blocks that
/// change afterwards. There is no memory in it (owner ruling 2026-09-25: no live forks): reverting
/// to one, or forking it, always COLD-boots.
///
///     <sandbox>/restore-points/<id>/root.ext4    clone of the root disk
///     <sandbox>/restore-points/<id>/state.ext4   clone of the state disk (image sandboxes)
///     <sandbox>/restore-points/<id>/meta.json    this struct
public struct RestorePoint: Sendable, Codable, Equatable, Identifiable {
    public enum TakenWhile: String, Sendable, Codable { case stopped, running }

    public var id: String
    public var name: String
    public var note: String
    public var createdAt: Date
    /// The restore point the sandbox's disk descended from when this one was taken (a chain).
    public var parent: String?
    /// Which prepared/baked/custom image the disk was first cloned from.
    public var sourceImage: String?
    /// `running`: taken from a live VM (sync → pause → clone → resume). The root ext4 has no
    /// journal, so that copy is crash-consistent at best — the first boot from it runs e2fsck.
    public var takenWhile: TakenWhile
    public var hasStateDisk: Bool
    /// Taken by the library itself (e.g. "before revert to …").
    public var automatic: Bool

    public var needsFsck: Bool { takenWhile == .running }

    public init(id: String, name: String, note: String, createdAt: Date, parent: String?, sourceImage: String?,
                takenWhile: TakenWhile, hasStateDisk: Bool, automatic: Bool) {
        self.id = id
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.parent = parent
        self.sourceImage = sourceImage
        self.takenWhile = takenWhile
        self.hasStateDisk = hasStateDisk
        self.automatic = automatic
    }

    /// Sortable, unique: `rp-20260925-171103-482-a3f9` (UTC, to the millisecond).
    public static func newID(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "rp-\(f.string(from: date))-\(String(UInt16.random(in: 0...UInt16.max), radix: 16))"
    }
}

/// An image made from a sandbox's disk rather than baked from a recipe. It is NOT reproducible, so
/// it says so (`origin: custom`) and says where it came from.
public struct CustomImage: Sendable, Codable, Equatable, Identifiable {
    public var id: String { key }
    /// `<name>/<restore point or snapshot id>` — its directory under `<store>/images/custom/`.
    public var key: String
    public var name: String
    public var note: String
    public var origin: String = "custom"
    public var createdAt: Date
    /// The sandbox it was saved from, the image that sandbox's disk came from, and the chain of
    /// restore points (newest first) it descends from.
    public var fromSandbox: String
    public var baseImage: String?
    public var restorePointChain: [String]
    /// The recipe of the sandbox it came from (its user, persist dirs, session environment), if any.
    public var recipe: ImageRecipe?
    /// Taken from a running VM: the first boot from it runs e2fsck.
    public var needsFsck: Bool
    public var apparentBytes: Int64
    public var allocatedBytes: Int64
}

extension StoreLayout {
    public var restorePointsDirectory: URL { sandboxDirectory.appendingPathComponent("restore-points") }
    public func restorePointDirectory(_ id: String) -> URL { restorePointsDirectory.appendingPathComponent(id) }

    public var customImagesDirectory: URL { root.appendingPathComponent("images/custom") }
    public func customImageDirectory(_ key: String) -> URL { customImagesDirectory.appendingPathComponent(key) }

    /// Every restore point of this sandbox, oldest first.
    public func restorePoints() -> [RestorePoint] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(atPath: restorePointsDirectory.path)) ?? []
        return ids.compactMap { id in
            guard let d = try? Data(contentsOf: restorePointDirectory(id).appendingPathComponent("meta.json")) else { return nil }
            return try? ImageBaker.decoder.decode(RestorePoint.self, from: d)
        }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The chain from `id` back through its parents (newest first). A deleted link ends the walk.
    public func restorePointChain(from id: String?) -> [String] {
        var chain: [String] = []
        var cur = id
        let all = Dictionary(uniqueKeysWithValues: restorePoints().map { ($0.id, $0) })
        while let c = cur, !chain.contains(c) {
            chain.append(c)
            cur = all[c]?.parent
        }
        return chain
    }

    /// Every custom image in this store, newest first.
    public func customImages() -> [CustomImage] {
        let fm = FileManager.default
        var out: [CustomImage] = []
        for name in (try? fm.contentsOfDirectory(atPath: customImagesDirectory.path)) ?? [] {
            let dir = customImagesDirectory.appendingPathComponent(name)
            for id in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                if let d = try? Data(contentsOf: dir.appendingPathComponent("\(id)/image.json")),
                   let img = try? ImageBaker.decoder.decode(CustomImage.self, from: d) { out.append(img) }
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }
}

/// APFS clone (copy-on-write, instant); falls back to a real copy off APFS.
func cloneFile(_ src: URL, to dst: URL) throws {
    try? FileManager.default.removeItem(at: dst)
    if clonefile(src.path, dst.path, 0) != 0 {
        try FileManager.default.copyItem(at: src, to: dst)
    }
    chmod(dst.path, 0o644)
}
