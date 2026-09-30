import Darwin
import Foundation
import DozerKit

// 596 (B7) — Dockerfiles are built with Apple's `container` tool (`container build`), installed on
// demand. Dozer never runs sudo and never starts Apple's services without being asked:
//
//   · missing        → "Install it?" → Apple's SIGNED installer package, a pinned version checked by
//                      its sha256, opened in macOS Installer (the user approves it there).
//   · too old/new    → the same prompt ("update it").
//   · services off   → "Start them?" → `container system start --enable-kernel-install` (it registers
//                      Apple's launchd services and installs its default kernel once).
//   · ready          → `container build … -o type=oci,dest=…`, the archive imported into Dozer's store.
//
// B9: the build runs in Apple's builder VM with its own network — OUTSIDE Dozer's policy — and is
// said so wherever a Dockerfile is chosen or built.
//
// Test seams: DOZ_TEST_CONTAINER (a fake `container` executable, or a path that does not exist =
// not installed); DOZ_TEST_CONTAINER_INSTALL (a log file: the install flow records what it would
// download and open — it never downloads, never opens Installer).

public struct ContainerToolStatus: Codable, Equatable, Sendable {
    /// `missing` · `unsupported` (a version outside the range) · `stopped` (installed, services not
    /// running) · `ready`.
    public var state: String
    public var version: String?
    public var path: String?
    /// What to tell a person, plainly.
    public var note: String
    /// The versions Dozer builds with.
    public var supported: String
    /// What starting the services does (said before asking).
    public var startNote: String
    /// What installing does, and the package (version, size).
    public var installNote: String
}

public enum ContainerTool {
    /// The versions Dozer builds with: `container build -o type=oci,dest=` (1.2.0+); 2.x unknown.
    public static let minimumVersion = "1.2.0"
    public static let belowVersion = "2.0.0"

    /// Apple's signed installer package, pinned (596 probe `pins.sh`: the GitHub release asset's digest).
    public struct Package: Sendable {
        public var version: String
        public var url: String
        public var sha256: String
        public var bytes: Int64
    }
    public static let package = Package(
        version: "1.5.0",
        url: "https://github.com/apple/container/releases/download/1.5.0/container-1.5.0-installer-signed.pkg",
        sha256: "a24808cb202318fa1c3bbee0c6c6887fe1225fe899d7b687a0ddd939bd6573f8",
        bytes: 118_045_087)

    public static let startNote =
        "Starting it runs Apple's `container system start --enable-kernel-install`: it registers Apple's container services with launchd (they run in the background, for your user, until `container system stop`) and, the first time, installs Apple's default Linux kernel for its builder. Dozer does not use sudo."
    public static var installNote: String {
        "Dockerfiles are built with Apple's container tool (free, from Apple, \(package.bytes / 1_000_000) MB). Installing downloads Apple's signed installer package (container \(package.version), checked against its published sha256) and opens it in macOS Installer, where you approve it with your password — Dozer never uses sudo. It adds a background service once started."
    }

    /// The `container` to run: the test seam, else /usr/local/bin/container (Apple's installer's), else PATH.
    public static func executable(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let t = env["DOZ_TEST_CONTAINER"], !t.isEmpty { return FileManager.default.isExecutableFile(atPath: t) ? t : nil }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/container") { return "/usr/local/bin/container" }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/container"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// `container CLI version 1.2.2 (build: release, commit: 0190097)` → `1.2.2`.
    public static func parseVersion(_ s: String) -> String? {
        guard let r = s.range(of: #"\b\d+\.\d+\.\d+\b"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    public static func isSupported(_ v: String) -> Bool {
        !AgentRelease.isNewer(minimumVersion, than: v) && AgentRelease.isNewer(belowVersion, than: v)
    }

    public static func status(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ContainerToolStatus {
        let range = "\(minimumVersion) up to (not including) \(belowVersion)"
        func s(_ state: String, _ v: String?, _ p: String?, _ note: String) -> ContainerToolStatus {
            ContainerToolStatus(state: state, version: v, path: p, note: note, supported: range, startNote: startNote, installNote: installNote)
        }
        guard let exe = executable(env) else {
            return s("missing", nil, nil, "Apple's container tool is not installed — Dockerfile images need it (installed on demand).")
        }
        let out = run(exe, ["--version"], env: env, timeout: 20)
        guard let v = parseVersion(out.output) else {
            return s("unsupported", nil, exe, "\(exe) --version did not say its version (\(out.output.prefix(120))) — reinstall Apple's container tool.")
        }
        guard isSupported(v) else {
            return s("unsupported", v, exe, "Apple's container \(v) is installed; Dozer builds with \(range) — update it (Install offers \(package.version)).")
        }
        let st = run(exe, ["system", "status"], env: env, timeout: 20)
        if st.status != 0 {
            let said = st.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
            return s("stopped", v, exe, "Apple's container \(v) is installed but its services are not running" + (said.isEmpty ? "" : " (\(said))")
                     + " — they must be started once before a Dockerfile builds.")
        }
        return s("ready", v, exe, "Apple's container \(v) is installed and its services are running.")
    }

    /// Why a Dockerfile cannot be built now (nil: it can), for errors and banners.
    public static func problem(_ st: ContainerToolStatus) -> String? {
        switch st.state {
        case "ready": return nil
        case "missing": return "Dockerfiles are built with Apple's container tool, which is not installed — `doz builder install` (or Install in the web UI's New Sandbox). \(installNote)"
        case "stopped": return "Apple's container tool is installed but its services are not running — `doz builder start` starts them. \(startNote)"
        default: return st.note
        }
    }

    /// `container system start --enable-kernel-install` — only ever because a person asked.
    public static func startServices(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                     onLine: @escaping @Sendable (String) -> Void = { _ in }) throws -> String {
        guard let exe = executable(env) else { throw HostError(.unavailable, "Apple's container tool is not installed") }
        let r = run(exe, ["system", "start", "--enable-kernel-install", "--timeout", "120"], env: env, timeout: 300, onLine: onLine)
        guard r.status == 0 else {
            throw HostError(.failed, "container system start failed (exit \(r.status)): \(r.output.suffix(400))")
        }
        return r.output
    }

    /// Install on demand: download the pinned package, check its sha256, open it in macOS Installer.
    /// Under DOZ_TEST_CONTAINER_INSTALL only the plan is written to that file.
    public static func install(_ env: [String: String] = ProcessInfo.processInfo.environment,
                               onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/dozer-sandbox")
        let pkg = cache.appendingPathComponent("container-\(package.version)-installer-signed.pkg")
        if let log = env["DOZ_TEST_CONTAINER_INSTALL"], !log.isEmpty {
            let plan = "download \(package.url)\nverify sha256 \(package.sha256)\ncheck-signature pkgutil --check-signature \(pkg.path)\nopen /usr/bin/open -b com.apple.installer \(pkg.path)\n"
            let h = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log) }()
            h?.seekToEndOfFile(); h?.write(Data(plan.utf8)); try? h?.close()
            onLine("(test) would download container \(package.version) and open it in Installer — recorded in \(log)")
            return "recorded"
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if Dockerfiles.sha256(of: pkg) != package.sha256 {
            onLine("downloading Apple's container \(package.version) installer (\(package.bytes / 1_000_000) MB)…")
            let (tmp, response) = try await URLSession.shared.download(from: URL(string: package.url)!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HostError(.failed, "GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for the installer") }
            try? FileManager.default.removeItem(at: pkg)
            try FileManager.default.moveItem(at: tmp, to: pkg)
        }
        guard let got = Dockerfiles.sha256(of: pkg), got == package.sha256 else {
            try? FileManager.default.removeItem(at: pkg)
            throw HostError(.failed, "the downloaded installer's sha256 is not the published one — not opened")
        }
        onLine("sha256 matches Apple's published package (\(package.sha256.prefix(12)))")
        let sig = run("/usr/sbin/pkgutil", ["--check-signature", pkg.path], env: env, timeout: 60)
        guard sig.status == 0 else { throw HostError(.failed, "pkgutil --check-signature refused the package: \(sig.output.prefix(300))") }
        onLine(sig.output.split(separator: "\n").prefix(3).joined(separator: " · "))
        let open = run("/usr/bin/open", ["-b", "com.apple.installer", pkg.path], env: env, timeout: 30)
        guard open.status == 0 else { throw HostError(.failed, "could not open macOS Installer: \(open.output.prefix(200))") }
        return "opened \(pkg.lastPathComponent) in macOS Installer — approve it there, then start its services"
    }

    /// `container build` (into Apple's image store, tagged `tag`), then `container image save` of its
    /// linux/arm64 image as an OCI archive at `output`. Output lines go to `onLine` as they come.
    /// (596: `build -o type=oci,dest=…` of container 1.2.2 fails after exporting — "The file … doesn't
    /// exist" — so the image is saved from Apple's store instead; it stays there under `tag`, which
    /// Resources counts as Dozer's share of Apple's storage.)
    public static func build(dockerfile: String, context: String, tag: String, output: URL,
                             env: [String: String] = ProcessInfo.processInfo.environment,
                             isCancelled: @escaping @Sendable () -> Bool = { false },
                             onLine: @escaping @Sendable (String) -> Void) throws {
        guard let exe = executable(env) else { throw HostError(.unavailable, "Apple's container tool is not installed") }
        let r = run(exe, ["build", "--platform", "linux/arm64", "--progress", "plain", "-f", dockerfile, "-t", tag, context],
                    env: env, timeout: 3600, onLine: onLine, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        guard r.status == 0 else {
            throw HostError(.failed, "container build failed (exit \(r.status)): " + r.output.split(separator: "\n").suffix(6).joined(separator: " | "))
        }
        let s = run(exe, ["image", "save", "--platform", "linux/arm64", "-o", output.path, tag], env: env, timeout: 900, onLine: onLine, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        guard s.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw HostError(.failed, "container image save \(tag) failed (exit \(s.status)): " + s.output.split(separator: "\n").suffix(4).joined(separator: " | "))
        }
    }

    // MARK: running it

    struct Ran { var status: Int32; var output: String }

    /// Run `exe` with ONLY stdin/stdout/stderr (stdin /dev/null), stdout+stderr merged, lines streamed;
    /// killed after `timeout` or when the task is cancelled.
    static func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval,
                    onLine: (@Sendable (String) -> Void)? = nil, isCancelled: @Sendable () -> Bool = { false }) -> Ran {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var e = env
        e["NO_COLOR"] = "1"
        p.environment = e
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = pipe
        let collected = LineCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collected.add(d) }
        }
        do { try p.run() } catch { return Ran(status: -1, output: "\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline || Task.isCancelled || isCancelled() { p.terminate(); break }
            usleep(50_000)
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.add(pipe.fileHandleForReading.readDataToEndOfFile())
        collected.flush()
        return Ran(status: p.terminationReason == .uncaughtSignal ? -2 : p.terminationStatus, output: collected.text)
    }

    final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var all = Data()
        let onLine: (@Sendable (String) -> Void)?
        init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }
        func add(_ d: Data) {
            let lines: [String] = lock.withLock {
                all.append(d.prefix(max(0, 4 << 20 - all.count)))
                buffer.append(d)
                var out: [String] = []
                while let nl = buffer.firstIndex(of: 0x0A) {
                    out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                return out
            }
            for l in lines { onLine?(l) }
        }
        func flush() {
            let rest: String? = lock.withLock {
                defer { buffer.removeAll() }
                return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
            }
            if let rest { onLine?(rest) }
        }
        var text: String { lock.withLock { String(decoding: all, as: UTF8.self) } }
    }
}

/// A flag a cancelled task sets and a blocking loop polls.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

/// 596 (B7, B8): a built OCI archive → Dozer's image store, and the base a Dockerfile's image uses.
public enum DockerfileImport {
    public struct Result: Sendable, Equatable {
        public var reference: String
        public var layers: String
        public var environment: [String: String]
        public var path: [String]
        /// The layers are the previous build's: its reference is kept, nothing is re-baked.
        public var unchanged: Bool
    }

    /// The tag an import gives the image in Dozer's store (the digest-pinned reference is added beside it).
    public static func tag(_ base: String) -> String { "dozer.local/\(base):latest" }

    /// Import `archive` (an OCI image-layout tar, as `container build -o type=oci` writes it).
    public static func importArchive(_ archive: URL, base: String, store: DozerStore, previous: DockerfileRecord?) async throws -> Result {
        let fm = FileManager.default
        let dir = store.root.appendingPathComponent(".dockerfile-import-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let tar = ContainerTool.run("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path], env: [:], timeout: 600)
        guard tar.status == 0 else { throw HostError(.failed, "the build's archive could not be unpacked: \(tar.output.prefix(200))") }
        // The image's name in Dozer's store is our tag (a build's own annotation names Apple's store).
        let imported: OCIImport.Imported
        do { imported = try await OCIImport.load(layoutDirectory: dir, tag: tag(base), storeRoot: store.root) } catch let e as SandboxError {
            throw HostError.from(e)
        }
        let layers = imported.layers
        var env: [String: String] = [:]
        var path: [String] = []
        for kv in imported.environment {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let k = String(kv[..<eq]), v = String(kv[kv.index(after: eq)...])
            guard k.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil, !BakeEnvironment.isCredential(k), k != "HOME", k != "USER" else { continue }
            if k == "PATH" {
                path = v.split(separator: ":").map(String.init).filter { !["/usr/local/bin", "/usr/bin", "/bin", "/usr/local/sbin", "/usr/sbin", "/sbin", ""].contains($0) && $0.hasPrefix("/") }
            } else if v.count <= 1024 {
                env[k] = v
            }
        }
        if let prev = previous, prev.layers == layers, let ref = prev.reference, await OCIImport.has(ref, storeRoot: store.root) {
            return Result(reference: ref, layers: layers, environment: env, path: path, unchanged: true)
        }
        let reference = "dozer.local/\(base)@\(imported.digest)"
        try await OCIImport.tag(tag(base), as: reference, storeRoot: store.root)
        return Result(reference: reference, layers: layers, environment: env, path: path, unchanged: false)
    }
}
