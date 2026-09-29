import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 593: Images › Lineage — the tree built from measured disks (no store, no VM), and the ops'
/// read-only and workspace rules.
final class ImageTreeTests: XCTestCase {
    private func mib(_ n: Int64) -> Int64 { n << 20 }

    private var disks: [ImageTree.Disk] {
        [
            .init(path: "/s/sandboxes/b/root.ext4", kind: .sandboxRoot, name: "sandbox b", sandbox: "b",
                  parentPath: "/s/golden/lab-0123456789ab.ext4", allocatedBytes: mib(40), uniqueBytes: mib(5), sharedWithParentBytes: mib(35)),
            .init(path: "/s/golden/lab-0123456789ab.ext4", kind: .preparedDisk, name: "prepared lab-0123456789ab.ext4",
                  allocatedBytes: mib(110), uniqueBytes: mib(70)),
            .init(path: "/s/sandboxes/a/root.ext4", kind: .sandboxRoot, name: "sandbox a", sandbox: "a",
                  parentPath: "/s/golden/lab-0123456789ab.ext4", allocatedBytes: mib(36), uniqueBytes: mib(6), sharedWithParentBytes: mib(30)),
            .init(path: "/s/sandboxes/a/state.ext4", kind: .sandboxState, name: "sandbox a (state)", sandbox: "a",
                  allocatedBytes: mib(4), uniqueBytes: mib(4)),
            .init(path: "/s/sandboxes/a/rp/r1/root.ext4", kind: .restorePointRoot, name: "restore point good of a", sandbox: "a",
                  parentPath: "/s/golden/lab-0123456789ab.ext4", allocatedBytes: mib(36), uniqueBytes: mib(1), sharedWithParentBytes: mib(30)),
            .init(path: "/s/images/bases/f9/root.ext4", kind: .base, name: "base f97ac66c1d54", allocatedBytes: mib(300), uniqueBytes: mib(10)),
            .init(path: "/s/images/pi/bf/root.ext4", kind: .image, name: "pi@bf46815674ce", parentPath: "/s/images/bases/f9/root.ext4",
                  allocatedBytes: mib(900), uniqueBytes: mib(600), sharedWithParentBytes: mib(290)),
            .init(path: "/s/images/custom/tpl/x/root.ext4", kind: .customImage, name: "custom:tpl/disk-1", parentPath: "/s/images/pi/bf/root.ext4",
                  allocatedBytes: mib(950), uniqueBytes: mib(40), sharedWithParentBytes: mib(900)),
            .init(path: "/s/sandboxes/c/root.ext4", kind: .sandboxRoot, name: "sandbox c", sandbox: "c",
                  parentPath: "/s/images/custom/tpl/x/root.ext4", allocatedBytes: mib(960), uniqueBytes: mib(10), sharedWithParentBytes: mib(950)),
            .init(path: "/s/sandboxes/d/root.ext4", kind: .sandboxRoot, name: "sandbox d", sandbox: "d",
                  parentPath: "/s/images/gone/root.ext4", allocatedBytes: mib(20), uniqueBytes: mib(20), sharedWithParentBytes: mib(3)),
            .init(path: "/s/initfs.ext4", kind: .other, name: "guest init disk", allocatedBytes: mib(8), uniqueBytes: mib(8)),
        ]
    }

    func testTheChainBaseImageTemplateSandbox() throws {
        let t = ImageTree(disks: disks, customNames: ["tpl/disk-1": "tpl"], unionBytes: mib(1500), milliseconds: 3)
        let lines = t.nodes.map { String(repeating: "  ", count: $0.depth) + "\($0.kind) \($0.name)" }
        XCTAssertEqual(lines, [
            "base OCI base",
            "  image pi",
            "    template tpl",
            "      sandbox c",
            "prepared lab",
            "  sandbox a",
            "    restorePoint good",
            "  sandbox b",
            "sandbox d",
        ])
        let byName = Dictionary(uniqueKeysWithValues: t.nodes.map { ($0.name, $0) })
        XCTAssertEqual(byName["pi"]?.detail, "bf46815674ce")
        XCTAssertEqual(byName["pi"]?.sharedWithParentBytes, mib(290))
        XCTAssertEqual(byName["tpl"]?.detail, "tpl/disk-1")
        XCTAssertEqual(byName["lab"]?.detail, "prepared disk 0123456789ab")
        XCTAssertEqual(byName["a"]?.stateAllocatedBytes, mib(4), "the state disk is folded into its sandbox")
        XCTAssertEqual(byName["a"]?.sharedWithParentBytes, mib(30))
        XCTAssertNil(byName["good"]?.sharedWithParentBytes, "a point's shared bytes are against the image — not shown under its sandbox")
        XCTAssertEqual(byName["good"]?.parent, byName["a"]?.id)
        XCTAssertNil(byName["d"]?.parent, "a parent that is gone makes a root")
        XCTAssertNil(byName["d"]?.sharedWithParentBytes)
        XCTAssertNil(byName["OCI base"]?.sharedWithParentBytes)
        XCTAssertFalse(t.nodes.contains { $0.name.contains("init") }, "other disks are not in the lineage")
        XCTAssertEqual(t.nodes.map(\.id), Array(0..<t.nodes.count), "ids are depth-first order")
        for n in t.nodes { if let p = n.parent { XCTAssertLessThan(p, n.id); XCTAssertEqual(t.nodes[p].depth + 1, n.depth) } }
        XCTAssertEqual(t.unionBytes, mib(1500))
    }

    func testAnEmptyStoreIsAnEmptyTree() throws {
        let store = DozerStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("doz-tree-\(UUID().uuidString)"))
        XCTAssertEqual(try ImageTree.measure(store: store).nodes, [])
        XCTAssertEqual(ImageTree(disks: []).nodes, [])
    }

    func testTheNewOpsAndTheirRules() throws {
        XCTAssertTrue(HostOp.imageTree.isReadOnly, "looking never starts a host")
        XCTAssertFalse(HostOp.templateCreate.isReadOnly)
        XCTAssertFalse(HostOp.duplicate.isReadOnly)
        XCTAssertEqual(HostOp(rawValue: "image-tree"), .imageTree)
        XCTAssertEqual(HostOp(rawValue: "template-create"), .templateCreate)
        var r = HostRequest(.duplicate, name: "a")
        r.newName = "b"
        r.duplicate = DuplicateOptions(workspace: "/tmp", cpus: 4, copyState: true)
        let back = try HostWire.decoder.decode(HostRequest.self, from: HostWire.encoder.encode(r))
        XCTAssertEqual(back, r)
    }

    func testAWorkspaceMustExistBeADirectoryAndReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try HostCore.validatedWorkspace(root.path), root.standardizedFileURL.path)
        XCTAssertThrowsError(try HostCore.validatedWorkspace("relative/dir"))
        XCTAssertThrowsError(try HostCore.validatedWorkspace(root.appendingPathComponent("missing").path)) {
            XCTAssertTrue(($0 as? HostError)?.message.contains("never creates") == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path), "never created")
        let file = root.appendingPathComponent("f")
        try Data().write(to: file)
        XCTAssertThrowsError(try HostCore.validatedWorkspace(file.path))
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o700) }
        XCTAssertThrowsError(try HostCore.validatedWorkspace(locked.path), "not readable")
    }
}
