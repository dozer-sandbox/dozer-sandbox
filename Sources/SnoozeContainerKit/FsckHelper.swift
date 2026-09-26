import Containerization
import ContainerizationExtras
import Foundation

/// Runs `e2fsck -fy` on an ext4 disk image in a small helper VM, so a disk copied while its VM ran
/// (a running restore point, a custom image saved from one) is checked before anything boots from
/// it. The sandboxes' ext4 disks have NO journal, so a crash-consistent copy may need repair.
///
/// The helper is an Alpine VM from a prepared disk with `e2fsprogs` (baked once per store, like the
/// lab's prepared disk). The disk IMAGE FILE's directory is shared into it over virtio-fs and
/// e2fsck runs on the file itself — never mounted, and no block device: a container's device
/// cgroup refuses a raw block node even to a privileged exec (measured: "Operation not permitted").
struct FsckHelper {
    let storeRoot: URL
    let kernel: Kernel
    let initfsReference: String
    let dnsServers: [String]
    let events: @Sendable (SandboxEvent) -> Void

    static let image = "docker.io/library/alpine:3.20"

    private var helperSpec: SandboxSpec {
        // journalMiB nil: the helper's own disk keeps its pre-587 key (it never needs a journal).
        SandboxSpec(name: "fsck-helper", storeRoot: storeRoot, rootfsMiB: 512, bakePackages: ["e2fsprogs"], journalMiB: nil)
    }

    /// e2fsck `disk`; returns its report. Throws when the file system could not be repaired
    /// (exit code ≥ 2 other than "fixed, reboot").
    func check(_ disk: URL) async throws -> String {
        let script = """
            e2fsck -fy '/fsck/\(disk.lastPathComponent)'; rc=$?; echo "e2fsck-exit=$rc"; [ $rc -le 2 ]
            """
        let r = try await run(script, sharing: disk.deletingLastPathComponent())
        let out = (r.output + r.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.exitCode == 0 else {
            throw SandboxError.commandFailed(command: "e2fsck \(disk.lastPathComponent)", exitCode: r.exitCode, output: out)
        }
        return out
    }

    /// 587: `e2fsck -fn` — a read-only check that changes nothing. Returns e2fsck's exit code (0:
    /// clean) and its report.
    func checkReadOnly(_ disk: URL) async throws -> (exitCode: Int32, report: String) {
        let r = try await run("e2fsck -fn '/fsck/\(disk.lastPathComponent)' 2>&1; echo \"e2fsck-exit=$?\"", sharing: disk.deletingLastPathComponent())
        let out = (r.output + r.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        let code = out.split(separator: "\n").last { $0.hasPrefix("e2fsck-exit=") }.flatMap { Int32($0.dropFirst(12)) } ?? -1
        return (code, out)
    }

    /// Run `script` as root in the helper VM, with `directory` shared at /fsck.
    func run(_ script: String, sharing directory: URL) async throws -> ExecResult {
        let store = try ImageStore(path: storeRoot)
        var mgr = try await ContainerManager(kernel: kernel, initfsReference: initfsReference, imageStore: store, network: nil)
        let image = try await store.get(reference: Self.image, pull: true)
        let golden = StoreLayout(spec: helperSpec).golden(for: helperSpec).deletingPathExtension()
            .appendingPathExtension("fsck.ext4")
        if !FileManager.default.fileExists(atPath: golden.path) {
            let net = try SubnetPool.makeNetwork()                  // 583: a free subnet, never vmnet's default
            defer { SubnetPool.release(net.subnet.description) }
            var bakeMgr = try await ContainerManager(kernel: kernel, initfsReference: initfsReference, imageStore: store, network: net)
            try await bakeHelperDisk(&bakeMgr, image: image, into: golden)
        }
        let id = "fsck-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = storeRoot.appendingPathComponent("containers/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = dir.appendingPathComponent("root.ext4")
        try cloneFile(golden, to: root)
        let c = try await mgr.create(id, image: image, rootfs: .block(format: "ext4", source: root.path, destination: "/"),
                                     networking: false, vm: VMResources(cpus: 1, memoryInBytes: 256 * 1_048_576 + VMResources.guestMemoryOverhead)) { cfg in
            cfg.cpus = 1
            cfg.memoryInBytes = 256 * 1_048_576
            cfg.process.arguments = ["sleep", "infinity"]
            cfg.mounts.append(.share(source: directory.path, destination: "/fsck"))
        }
        defer { try? mgr.delete(id) }
        do {
            try await c.create()
            try await c.start()
            let r = try await Sandbox.exec(on: c, ["sh", "-c", script], environment: [:], workingDirectory: "/",
                                           privileged: true, timeout: 300)
            try await c.stop()
            return r
        } catch {
            try? await c.stop()
            throw error
        }
    }

    private func bakeHelperDisk(_ mgr: inout ContainerManager, image: Containerization.Image, into golden: URL) async throws {
        events(.note("fsck: preparing the helper disk (Alpine + e2fsprogs; one-time per store, needs network)…"))
        let id = "fsck-helper-bake"
        try? mgr.delete(id)
        let dns = dnsServers
        let b = try await mgr.create(id, image: image, rootfsSizeInBytes: 512 * 1_048_576, readOnly: false, networking: true,
                                     vm: VMResources(cpus: 1, memoryInBytes: 512 * 1_048_576 + VMResources.guestMemoryOverhead)) { cfg in
            cfg.cpus = 1
            cfg.memoryInBytes = 512 * 1_048_576
            cfg.process.arguments = ["sleep", "infinity"]
            cfg.dns = DNS(nameservers: dns)
        }
        do {
            try await b.create()
            try await b.start()
            let r = try await Sandbox.exec(on: b, ["sh", "-c", "apk add --no-cache e2fsprogs >/dev/null && sync"], environment: [:],
                                           workingDirectory: "/", privileged: false, timeout: 300)
            guard r.exitCode == 0 else { throw SandboxError.commandFailed(command: "apk add e2fsprogs", exitCode: r.exitCode, output: r.errorOutput) }
            try await b.stop()
        } catch {
            try? await b.stop()
            try? mgr.delete(id)
            throw error
        }
        try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: storeRoot.appendingPathComponent("containers/\(id)/rootfs.ext4"), to: golden)
        try? mgr.delete(id)
    }
}
