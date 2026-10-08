import CryptoKit
import Foundation

/// 599h: the tools layer's downloads, kept ONCE on the Mac (`<store>/tools`): gh's linux-arm64 release, at its
/// pinned version, accepted only when its sha256 is the pinned one, then extracted to
/// `<store>/tools/gh/<version>/gh`. One download at a time (callers join it). An offline Mac gets a plain
/// reason — never a failed boot.
///
/// Test seam: `DOZ_TEST_TOOLS_URL=http://127.0.0.1:PORT` — the tarball is fetched from `<that>/<tarball>` (plain
/// http allowed only there, and only to 127.0.0.1), so a test never reaches github.com.
public actor ToolsCache {
    public nonisolated let root: URL
    private var inFlight: Task<Result<URL, CheckFailure>, Never>?

    public init(root: URL) { self.root = root }

    /// What is cached, for doctor and Resources.
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var version: String
        public var path: String
        public var bytes: Int64
        public var sha256: String
    }

    public nonisolated var ghDirectory: URL { root.appendingPathComponent("gh/\(ToolsLayer.ghVersion)") }
    public nonisolated var ghBinary: URL { ghDirectory.appendingPathComponent("gh") }
    nonisolated var ghStamp: URL { ghDirectory.appendingPathComponent("SHA256") }

    /// The verified gh, when it is here.
    public nonisolated func cachedGh() -> URL? {
        guard let stamp = try? String(contentsOf: ghStamp, encoding: .utf8),
              stamp.trimmingCharacters(in: .whitespacesAndNewlines) == ToolsLayer.ghSHA256,
              FileManager.default.isExecutableFile(atPath: ghBinary.path) else { return nil }
        return ghBinary
    }

    public nonisolated func entries() -> [Entry] {
        guard let gh = cachedGh() else { return [] }
        let size = (try? FileManager.default.attributesOfItem(atPath: gh.path)[.size] as? NSNumber)?.int64Value ?? 0
        return [Entry(id: "gh", version: ToolsLayer.ghVersion, path: gh.path, bytes: size, sha256: ToolsLayer.ghSHA256)]
    }

    /// The tarball's URL: the release, or the test seam's server.
    public nonisolated static func ghSource(environment env: [String: String]) -> Result<URL, CheckFailure> {
        guard let base = env["DOZ_TEST_TOOLS_URL"], !base.isEmpty else { return .success(ToolsLayer.ghURL()) }
        guard let u = URL(string: base), u.scheme == "http" || u.scheme == "https", u.host == "127.0.0.1" else {
            return .failure("DOZ_TEST_TOOLS_URL must be http://127.0.0.1:PORT")
        }
        return .success(ToolsLayer.ghURL(base: base.hasSuffix("/") ? String(base.dropLast()) : base))
    }

    /// The verified gh — downloaded (once; callers join a download under way) when it is not here yet.
    public func ensureGh(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Result<URL, CheckFailure> {
        if let gh = cachedGh() { return .success(gh) }
        if let t = inFlight { return await t.value }
        let root = self.root, dir = ghDirectory, bin = ghBinary, stamp = ghStamp
        let t = Task.detached { () -> Result<URL, CheckFailure> in
            switch Self.ghSource(environment: environment) {
            case .failure(let f): return .failure(f)
            case .success(let url):
                return await Self.fetchGh(from: url, root: root, dir: dir, binary: bin, stamp: stamp)
            }
        }
        inFlight = t
        let r = await t.value
        inFlight = nil
        return r
    }

    static func fetchGh(from url: URL, root: URL, dir: URL, binary: URL, stamp: URL) async -> Result<URL, CheckFailure> {
        let fm = FileManager.default
        let work = root.appendingPathComponent(".download-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: work) }
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch {
            return .failure(CheckFailure("could not make \(work.path): \(error.localizedDescription)"))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        do {
            let (d, response) = try await session.data(from: url)
            if let h = response as? HTTPURLResponse, h.statusCode != 200 {
                return .failure(CheckFailure("could not download gh \(ToolsLayer.ghVersion): \(url.host ?? "the server") answered HTTP \(h.statusCode)"))
            }
            data = d
        } catch {
            return .failure(CheckFailure("could not download gh \(ToolsLayer.ghVersion) from \(url.host ?? "the server") (is this Mac offline?): \(error.localizedDescription)"))
        }
        let sum = sha256(data)
        guard sum == ToolsLayer.ghSHA256 else {
            return .failure(CheckFailure("refused the gh download: its sha256 is \(sum.prefix(16))…, not the pinned \(ToolsLayer.ghSHA256.prefix(16))… — not used"))
        }
        let tarball = work.appendingPathComponent(ToolsLayer.ghTarball)
        do { try data.write(to: tarball) } catch { return .failure(CheckFailure("could not write the download: \(error.localizedDescription)")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", tarball.path, "-C", work.path, ToolsLayer.ghMember]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(CheckFailure("could not run tar: \(error.localizedDescription)")) }
        p.waitUntilExit()
        let extracted = work.appendingPathComponent(ToolsLayer.ghMember)
        guard p.terminationStatus == 0, fm.fileExists(atPath: extracted.path) else {
            return .failure(CheckFailure("the gh download has no \(ToolsLayer.ghMember)"))
        }
        do {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: extracted, to: binary)
            chmod(binary.path, 0o755)
            try ToolsLayer.ghSHA256.write(to: stamp, atomically: true, encoding: .utf8)
        } catch {
            return .failure(CheckFailure("could not keep gh in \(dir.path): \(error.localizedDescription)"))
        }
        return .success(binary)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
