import Foundation
import DozerKit

// 593 — Images › Lineage: the store's disks as a tree, from 587's `DiskAccounting` (each disk's
// lineage parent, its unique bytes and the bytes it shares with that parent):
//
//     OCI base → baked image → template (a custom image, saved from a sandbox) → the sandboxes on each
//
// The lab's prepared disk (`golden/…`) is a root of its own (no base in the store). A sandbox's state
// disk is folded into its node; its restore points are its children (their "shared" is against the
// image in 587's measure, so it is not shown under the sandbox). The `image-tree` host op answers it;
// `doz image ls --tree` and the UI's Lineage view draw it. No host path is in it.

/// One node, in depth-first order.
public struct ImageTreeNode: Codable, Equatable, Sendable {
    public var id: Int
    public var parent: Int?
    public var depth: Int
    /// `base`, `image`, `template`, `prepared`, `sandbox`, `restorePoint`.
    public var kind: String
    public var name: String
    /// The key of an image or base, "from SANDBOX" for a template, and the like.
    public var detail: String?
    /// The sandbox a sandbox or restore-point node belongs to.
    public var sandbox: String?
    public var allocatedBytes: Int64
    /// What deleting it would free (no other disk of the store references these bytes).
    public var uniqueBytes: Int64
    /// Shared with its parent node's disk (nil: no parent, or not measured against it).
    public var sharedWithParentBytes: Int64?
    /// A sandbox's state disk, allocated (nil: none).
    public var stateAllocatedBytes: Int64?
}

public struct ImageTree: Codable, Equatable, Sendable {
    public var nodes: [ImageTreeNode]
    /// Every disk of the store together, shared blocks counted once.
    public var unionBytes: Int64
    public var milliseconds: Double

    /// What the tree needs of a measured disk (`DiskAccounting.DiskUsage`), so the tree is testable
    /// without a store.
    public struct Disk: Sendable, Equatable {
        public var path: String
        public var kind: DiskAccounting.Kind
        public var name: String
        public var sandbox: String?
        public var parentPath: String?
        public var allocatedBytes: Int64
        public var uniqueBytes: Int64
        public var sharedWithParentBytes: Int64?

        public init(path: String, kind: DiskAccounting.Kind, name: String, sandbox: String? = nil, parentPath: String? = nil,
                    allocatedBytes: Int64, uniqueBytes: Int64, sharedWithParentBytes: Int64? = nil) {
            self.path = path
            self.kind = kind
            self.name = name
            self.sandbox = sandbox
            self.parentPath = parentPath
            self.allocatedBytes = allocatedBytes
            self.uniqueBytes = uniqueBytes
            self.sharedWithParentBytes = sharedWithParentBytes
        }

        public init(_ u: DiskAccounting.DiskUsage) {
            self.init(path: u.url.standardizedFileURL.path, kind: u.kind, name: u.name, sandbox: u.sandbox,
                      parentPath: u.parent?.standardizedFileURL.path, allocatedBytes: u.allocatedBytes,
                      uniqueBytes: u.uniqueBytes, sharedWithParentBytes: u.sharedWithParentBytes)
        }
    }

    /// `customNames`: a template's key (`<name>/<id>`) → its name; `customFrom`: → the sandbox it was saved from.
    public init(disks: [Disk], customNames: [String: String] = [:], customFrom: [String: String] = [:], unionBytes: Int64 = 0,
                milliseconds: Double = 0) {
        struct Draft {
            var disk: Disk
            var kind: String
            var name: String
            var detail: String?
            var parentPath: String?
            var shared: Int64?
            var state: Int64?
        }
        var drafts: [String: Draft] = [:]
        var order: [String] = []
        let sandboxRoots = Dictionary(disks.filter { $0.kind == .sandboxRoot && $0.sandbox != nil }.map { ($0.sandbox!, $0.path) },
                                      uniquingKeysWith: { a, _ in a })
        for d in disks {
            var draft = Draft(disk: d, kind: "", name: d.name, detail: nil, parentPath: d.parentPath, shared: d.sharedWithParentBytes, state: nil)
            switch d.kind {
            case .base:
                draft.kind = "base"
                draft.name = "OCI base"
                draft.detail = d.name.hasPrefix("base ") ? String(d.name.dropFirst(5)) : d.name
            case .image:
                draft.kind = "image"
                if let at = d.name.firstIndex(of: "@") {
                    draft.name = String(d.name[..<at])
                    draft.detail = String(d.name[d.name.index(after: at)...])
                }
            case .customImage:
                draft.kind = "template"
                let key = d.name.hasPrefix("custom:") ? String(d.name.dropFirst(7)) : d.name
                draft.name = customNames[key] ?? String(key.split(separator: "/").first ?? Substring(key))
                draft.detail = customFrom[key].map { "from \($0)" } ?? key
            case .preparedDisk:
                draft.kind = "prepared"
                let file = d.name.hasPrefix("prepared ") ? String(d.name.dropFirst(9)) : d.name
                let stem = file.hasSuffix(".ext4") ? String(file.dropLast(5)) : file
                // `<slug>-<hex12>`: the slug names it ("lab-…" is the lab's prepared disk).
                if let dash = stem.lastIndex(of: "-"), stem.distance(from: dash, to: stem.endIndex) == 13 {
                    draft.name = String(stem[..<dash])
                    draft.detail = "prepared disk " + String(stem[stem.index(after: dash)...])
                } else {
                    draft.name = stem
                    draft.detail = "prepared disk"
                }
            case .sandboxRoot:
                draft.kind = "sandbox"
                draft.name = d.sandbox ?? d.name
            case .restorePointRoot:
                draft.kind = "restorePoint"
                var n = d.name.hasPrefix("restore point ") ? String(d.name.dropFirst(14)) : d.name
                if let s = d.sandbox, n.hasSuffix(" of \(s)") { n = String(n.dropLast(s.count + 4)) }
                draft.name = n
                draft.parentPath = d.sandbox.flatMap { sandboxRoots[$0] }
                draft.shared = nil
            case .sandboxState, .restorePointState, .other:
                continue
            }
            if drafts[d.path] == nil { order.append(d.path) }
            drafts[d.path] = draft
        }
        // A sandbox's state disk is part of its node.
        for d in disks where d.kind == .sandboxState {
            if let s = d.sandbox, let root = sandboxRoots[s], drafts[root] != nil {
                drafts[root]!.state = (drafts[root]!.state ?? 0) + d.allocatedBytes
            }
        }
        // A parent that is not a node (gone, or not measured) makes a root.
        for p in order where drafts[p]!.parentPath.map({ drafts[$0] == nil }) ?? false {
            drafts[p]!.parentPath = nil
            drafts[p]!.shared = nil
        }
        let rank = ["base": 0, "prepared": 1, "image": 2, "template": 3, "sandbox": 4, "restorePoint": 5]
        func sorted(_ paths: [String]) -> [String] {
            paths.sorted {
                let a = drafts[$0]!, b = drafts[$1]!
                return (rank[a.kind] ?? 9, a.name, $0) < (rank[b.kind] ?? 9, b.name, $1)
            }
        }
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for p in order {
            if let parent = drafts[p]!.parentPath { children[parent, default: []].append(p) } else { roots.append(p) }
        }
        var nodes: [ImageTreeNode] = []
        func visit(_ p: String, parent: Int?, depth: Int) {
            let d = drafts[p]!
            let id = nodes.count
            nodes.append(ImageTreeNode(id: id, parent: parent, depth: depth, kind: d.kind, name: d.name, detail: d.detail,
                                       sandbox: d.disk.sandbox, allocatedBytes: d.disk.allocatedBytes, uniqueBytes: d.disk.uniqueBytes,
                                       sharedWithParentBytes: parent == nil ? nil : d.shared, stateAllocatedBytes: d.state))
            for c in sorted(children[p] ?? []) { visit(c, parent: id, depth: depth + 1) }
        }
        for r in sorted(roots) { visit(r, parent: nil, depth: 0) }
        self.nodes = nodes
        self.unionBytes = unionBytes
        self.milliseconds = milliseconds
    }

    /// Measure the store (every disk's extent map — milliseconds to about a second).
    public static func measure(store: DozerStore) throws -> ImageTree {
        guard FileManager.default.fileExists(atPath: store.root.path) else { return ImageTree(disks: []) }
        let report = try DiskAccounting.measure(store: store.root)
        let customs = store.layout("_").customImages()
        let names = Dictionary(customs.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        let from = Dictionary(customs.map { ($0.key, $0.fromSandbox) }, uniquingKeysWith: { a, _ in a })
        return ImageTree(disks: report.disks.map(Disk.init), customNames: names, customFrom: from, unionBytes: report.unionBytes,
                         milliseconds: report.milliseconds)
    }
}
