import Darwin
import Foundation
import DozerKit

// 596 addendum (owner, 2026-10-01: "yes, have Resources show Apple's container storage as an
// 'outside Dozer' row"). Dockerfile images make Dozer a user of Apple's `container` tool, so its
// storage is accounted for — OUTSIDE the store: never in Dozer's total or the unattributed check,
// never deleted by Dozer (no checkbox; the commands to inspect and prune it are named instead).
//
//   outside:apple-container                the tool (version, services running or not)
//     outside:apple-container/data         ~/Library/Application Support/com.apple.container
//       …/snapshots · …/content · …/kernels · …/other
//     outside:apple-container/program      /usr/local/bin/container + /usr/local/libexec/container
//     outside:apple-container/dozer        what Dozer's own builds (images tagged dozer/…) account for

/// What the Resources inventory needs to know of Apple's container tool.
public struct AppleContainerFacts: Sendable {
    /// Its data folder (nil: none on this Mac).
    public var dataRoot: URL?
    /// Its program files (the executable and its libexec folder) that exist.
    public var program: [URL]
    public var status: ContainerToolStatus

    public init(dataRoot: URL?, program: [URL], status: ContainerToolStatus) {
        self.dataRoot = dataRoot
        self.program = program
        self.status = status
    }

    /// This Mac's (the seam DOZ_TEST_APPLE_CONTAINER_ROOT points the data folder elsewhere — tests).
    public static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> AppleContainerFacts {
        let status = ContainerTool.status(env)
        let root = env["DOZ_TEST_APPLE_CONTAINER_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.container")
        var program: [URL] = []
        if let exe = status.path {
            let resolved = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
            program.append(resolved)
            let api = resolved.deletingLastPathComponent().appendingPathComponent("container-apiserver")
            if FileManager.default.fileExists(atPath: api.path) { program.append(api) }
            let libexec = resolved.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec/container")
            if FileManager.default.fileExists(atPath: libexec.path) { program.append(libexec) }
        }
        return AppleContainerFacts(dataRoot: FileManager.default.fileExists(atPath: root.path) ? root : nil, program: program, status: status)
    }
}

extension Resources {
    /// The notes column: it is Apple's, and how to inspect and prune it with its own commands.
    static let appleContainerRefusal = "Apple's container tool — managed with its own commands: `container image ls` / `container image prune`, `container system df` (what it uses), `container builder delete` (the builder and its cache), `container system stop` (its services). Never deleted by Dozer."

    static let appleContainerPart = "Apple's — never deleted by Dozer (its commands are on the row above)"

    /// The rows (group `outside`): sizes by allocated blocks, as the rest of Resources measures.
    public static func appleContainerItems(_ f: AppleContainerFacts) -> [ResourceItem] {
        let st = f.status
        guard st.state != "missing" || f.dataRoot != nil else {
            return [ResourceItem(id: "outside:apple-container", group: "outside", name: "Apple container",
                                 detail: "not installed — Dockerfile images install it on demand", sizeBytes: 0, refusal: appleContainerRefusal)]
        }
        var rows: [ResourceItem] = []
        var total: Int64 = 0
        var dataRows: [ResourceItem] = []
        if let root = f.dataRoot {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            var parts: [String: Int64] = ["snapshots": 0, "content": 0, "kernels": 0, "other": 0]
            for n in names {
                let size = walk(root.appendingPathComponent(n)).total
                parts[["snapshots", "content", "kernels"].contains(n) ? n : "other", default: 0] += size
            }
            let dataTotal = parts.values.reduce(0, +)
            total += dataTotal
            dataRows.append(ResourceItem(id: "outside:apple-container/data", group: "outside", parent: "outside:apple-container", name: "its data folder (all of it)",
                                         detail: root.path, sizeBytes: dataTotal, refusal: appleContainerPart, path: root.path))
            // One level under the tool's row (the page shows a row's parts, not their parts).
            for (key, label) in [("snapshots", "its data — snapshots (unpacked images, containers)"), ("content", "its data — content (the image cache)"),
                                 ("kernels", "its data — kernels"), ("other", "its data — other (builder, networks, state)")] {
                dataRows.append(ResourceItem(id: "outside:apple-container/data/\(key)", group: "outside", parent: "outside:apple-container",
                                             name: label, sizeBytes: parts[key] ?? 0, refusal: appleContainerPart))
            }
            if let dozer = dozerShare(root) {
                dataRows.append(ResourceItem(id: "outside:apple-container/dozer", group: "outside", parent: "outside:apple-container",
                                             name: "of which Dozer's builds", detail: dozer.images == 0
                                                ? "no image tagged dozer/… in it (Dozer's builds are exported to its own store)"
                                                : "\(dozer.images) image\(dozer.images == 1 ? "" : "s") tagged dozer/… (their snapshots and layers)",
                                             sizeBytes: dozer.bytes, refusal: "`container image ls` lists them (dozer/…); `container image delete NAME` removes one — Dozer keeps its own copy in its store"))
            }
        }
        var programBytes: Int64 = 0
        for p in f.program { programBytes += walk(p).total }
        total += programBytes
        let state: String = switch st.state {
        case "ready": "services running"
        case "stopped": "services not running"
        case "missing": "not installed (its data folder remains)"
        default: st.note
        }
        rows.append(ResourceItem(id: "outside:apple-container", group: "outside", name: "Apple container",
                                 detail: [st.version.map { "container \($0)" }, state].compactMap { $0 }.joined(separator: " · ")
                                    + " — used by Dockerfile images (outside Dozer's store and total)",
                                 sizeBytes: total, refusal: appleContainerRefusal))
        rows += dataRows
        if !f.program.isEmpty {
            rows.append(ResourceItem(id: "outside:apple-container/program", group: "outside", parent: "outside:apple-container",
                                     name: "the installed program" + (st.version.map { " (container \($0))" } ?? ""),
                                     detail: f.program.map(\.path).joined(separator: " + "), sizeBytes: programBytes,
                                     refusal: "Apple's program — its own uninstaller, /usr/local/bin/uninstall-container.sh, removes it; never Dozer",
                                     path: f.program.first?.path))
        }
        return rows
    }

    /// What images tagged `dozer/…` in its store account for: their snapshots (named by each
    /// manifest's digest) and their blobs. nil: its store index cannot be read.
    static func dozerShare(_ root: URL) -> (images: Int, bytes: Int64)? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let index = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let blobs = root.appendingPathComponent("content/blobs/sha256")
        func blob(_ digest: String) -> URL { blobs.appendingPathComponent(String(digest.dropFirst(7))) }
        func json(_ digest: String) -> [String: Any]? {
            guard digest.hasPrefix("sha256:"), let d = try? Data(contentsOf: blob(digest)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        var digests = Set<String>()
        var snapshots = Set<String>()
        var count = 0
        for (ref, v) in index where ref.hasPrefix("dozer/") || ref.hasPrefix("docker.io/dozer/") {
            guard let desc = v as? [String: Any], let top = desc["digest"] as? String else { continue }
            count += 1
            digests.insert(top)
            var manifests: [String] = []
            if let idx = json(top), let ms = idx["manifests"] as? [[String: Any]] {
                manifests = ms.compactMap { $0["digest"] as? String }
            } else {
                manifests = [top]
            }
            for m in manifests {
                digests.insert(m)
                snapshots.insert(String(m.dropFirst(7)))
                guard let man = json(m) else { continue }
                if let c = (man["config"] as? [String: Any])?["digest"] as? String { digests.insert(c) }
                for l in (man["layers"] as? [[String: Any]]) ?? [] { if let ld = l["digest"] as? String { digests.insert(ld) } }
            }
        }
        var bytes: Int64 = 0
        for dg in digests { bytes += walk(blob(dg)).total }
        for s in snapshots { bytes += walk(root.appendingPathComponent("snapshots/\(s)")).total }
        return (count, bytes)
    }
}
