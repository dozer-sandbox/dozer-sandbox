import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 596 — base × agent images in the host: composed specs, the base's registries in the policy, base
/// digests (hourly, offline-tolerant), native checksums, Dockerfiles registered, Apple's container tool
/// through its seams (never the real one), its storage shown outside the store.
final class BaseImagesHostTests: XCTestCase {
    var root: URL!
    var store: DozerStore { DozerStore(root: root.appendingPathComponent("store")) }
    let settings = DozerSettings(text: nil)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/dzbi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAPairIsComposedFromTheStoresRecords() throws {
        let py = try XCTUnwrap(try AgentVersions.spec("python-claude-code", purpose: .prepare, store: store, settings: settings))
        XCTAssertEqual(py.base, BaseCatalogue.base("python")!.pinnedReference, "never asked: the catalogue's pin")
        XCTAssertEqual(py.agent?.version, AgentImages.claudeCodePinned.version)
        XCTAssertTrue(py.steps.contains { $0.name.hasPrefix("install Claude Code 2.1.227 (native build") })
        // A resolved digest is what the next preparation uses.
        let d = "sha256:" + String(repeating: "e", count: 64)
        BaseDigests.update("python", store) { $0.digest = d; $0.checkedAt = Date() }
        XCTAssertEqual(try AgentVersions.spec("python-claude-code", purpose: .prepare, store: store, settings: settings)?.base,
                       "docker.io/library/python@" + d)
        // No agent: no version, no agent package.
        let go = try XCTUnwrap(try AgentVersions.spec("go", purpose: .prepare, store: store, settings: settings))
        XCTAssertNil(go.agent)
        XCTAssertNil(try AgentVersions.spec("lab", purpose: .prepare, store: store, settings: settings), "the lab keeps its own path")
        // Claude Code at a version whose native checksums are unknown: a clear error, not a guess.
        let s = DozerSettings(text: "[images]\nclaude_code_version = \"2.1.300\"\n")
        var rec = AgentVersionRecord()
        rec.remember(AgentRelease(version: "2.1.300", integrity: "sha512-" + String(repeating: "C", count: 86) + "=="))
        AgentVersions.save(["claude-code": rec], store)
        XCTAssertThrowsError(try AgentVersions.spec("go-claude-code", purpose: .prepare, store: store, settings: s)) { e in
            XCTAssertTrue(HostError.from(e).message.contains("native build"), HostError.from(e).message)
        }
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .prepare, store: store, settings: s)?.agent?.version, "2.1.300",
                       "the Node image needs no native build")
    }

    func testTheSandboxSpecCarriesTheBaseAndItsRegistries() throws {
        let (spec, image) = try DozerImages.spec(name: "g1", options: CreateOptions(image: "go-claude-code"), store: store, environment: [:])
        XCTAssertEqual(image, "go-claude-code")
        let p = try XCTUnwrap(spec.network.policy)
        XCTAssertEqual(p.preset, "agent")
        XCTAssertEqual(p.evaluateConnection(host: "proxy.golang.org", port: 443).kind, .allow)
        XCTAssertEqual(p.evaluateConnection(host: "api.anthropic.com", port: 443).kind, .allow)
        XCTAssertTrue(spec.bakePackages.isEmpty)
        // Aliases: the long form of an old name is the old image.
        XCTAssertEqual(try DozerImages.spec(name: "n1", options: CreateOptions(image: "node-claude-code"), store: store, environment: [:]).1, "claude-code")
        XCTAssertEqual(try DozerImages.spec(name: "a1", options: CreateOptions(image: "alpine"), store: store, environment: [:]).1, "lab")
        // No agent: the claude-code section's memory (a toolchain wants 2 GiB), a shell session.
        let (deb, _) = try DozerImages.spec(name: "d1", options: CreateOptions(image: "debian"), store: store, environment: [:])
        XCTAssertEqual(deb.memoryMiB, 2048)
        XCTAssertEqual(SandboxConfig(name: "d1", image: "debian", spec: deb, workspace: nil).defaultSession.argv, ["bash", "-l"])
        let (pgo, _) = try DozerImages.spec(name: "p1", options: CreateOptions(image: "go-pi"), store: store, environment: [:])
        XCTAssertEqual(SandboxConfig(name: "p1", image: "go-pi", spec: pgo, workspace: nil).defaultSession.name, "pi")
        XCTAssertEqual(AgentImages.credentials("go-pi"), AgentImages.credentials("pi"))
        XCTAssertThrowsError(try DozerImages.spec(name: "x1", options: CreateOptions(image: "cobol-pi"), store: store, environment: [:]))
    }

    func testBaseDigestsAreAskedHourlyAndAFailureIsTolerated() async throws {
        final class Count: @unchecked Sendable { let l = NSLock(); var n = 0; var fail = false }
        let c = Count()
        let reg = NpmRegistry(lookup: nil, digest: { ref in
            try c.l.withLock {
                c.n += 1
                if c.fail { throw HostError(.unavailable, "offline") }
                XCTAssertEqual(ref, "docker.io/library/golang:1.25-bookworm")
                return "sha256:" + String(repeating: "1", count: 64)
            }
        })
        let t0 = Date()
        let e1 = await BaseDigests.refresh("go", store: store, registry: reg, now: t0)
        XCTAssertNil(e1)
        XCTAssertEqual(BaseDigests.digest("go", store), "sha256:" + String(repeating: "1", count: 64))
        let e2 = await BaseDigests.refresh("go", store: store, registry: reg, now: t0.addingTimeInterval(60))
        XCTAssertNil(e2)
        XCTAssertEqual(c.n, 1, "cached for an hour")
        c.l.withLock { c.fail = true }
        let e3 = await BaseDigests.refresh("go", store: store, registry: reg, now: t0.addingTimeInterval(4000))
        XCTAssertNotNil(e3)
        XCTAssertEqual(BaseDigests.digest("go", store), "sha256:" + String(repeating: "1", count: 64), "the last digest is kept")
        let e4 = await BaseDigests.refresh("cobol", store: store, registry: reg)
        XCTAssertNil(e4)
        // The seam: `pinned` answers the catalogue's pin, `offline` fails — never the network.
        let pinned = NpmRegistry.fromEnvironment(["DOZ_TEST_BASE_REGISTRY": "pinned", "DOZ_TEST_NPM_REGISTRY": "offline", "DOZ_TEST_CLAUDE_DOWNLOADS": "offline"])
        let d = try await pinned.digest!("docker.io/library/python:3.13-bookworm")
        XCTAssertEqual(d, BaseCatalogue.base("python")!.pinnedDigest)
        let offline = NpmRegistry.fromEnvironment(["DOZ_TEST_BASE_REGISTRY": "offline"])
        do { _ = try await offline.digest!("docker.io/library/python:3.13-bookworm"); XCTFail("offline answered") } catch {}
    }

    func testNativeChecksumsAreRememberedPerVersion() async throws {
        final class Count: @unchecked Sendable { let l = NSLock(); var asked: [String] = [] }
        let c = Count()
        let v = AgentRelease(version: "2.1.285", integrity: "sha512-" + String(repeating: "D", count: 86) + "==")
        let reg = NpmRegistry(lookup: { _, _ in v }, native: { version in
            c.l.withLock { c.asked.append(version) }
            return NativeClaudeBuild(version: version, sha256: ["linux-arm64": String(repeating: "a", count: 64), "linux-arm64-musl": String(repeating: "b", count: 64)])
        })
        await AgentVersions.refresh("claude-code", store: store, settings: settings, registry: reg, force: true)
        XCTAssertEqual(c.asked, ["2.1.285"])
        XCTAssertNotNil(AgentVersions.knownNative("2.1.285", store: store))
        await AgentVersions.refresh("claude-code", store: store, settings: settings, registry: reg, force: true)
        XCTAssertEqual(c.asked, ["2.1.285"], "once per version")
        let spec = try XCTUnwrap(try AgentVersions.spec("alpine-claude-code", purpose: .prepare, store: store, settings: settings))
        let script = spec.steps.map { $0.argv.joined(separator: " ") }.joined()
        XCTAssertTrue(script.contains("linux-arm64-musl") && script.contains(String(repeating: "b", count: 64)))
        XCTAssertEqual(spec.sessionEnvironment["USE_BUILTIN_RIPGREP"], "0")
    }

    /// 594 W28 × 596: an older recipe on a composed base is named, the current one is not.
    func testTheRecipeOfAComposedImage() throws {
        let py = try XCTUnwrap(try AgentVersions.spec("python-pi", purpose: .prepare, store: store, settings: settings))
        XCTAssertTrue(AgentVersions.isCurrentRecipe(py))
        var old = py
        old.steps.removeAll { $0.name.hasPrefix("install the pi wrapper") }
        XCTAssertFalse(AgentVersions.isCurrentRecipe(old))
        XCTAssertEqual(AgentVersions.recipeChanges(old), ["install the pi wrapper (/usr/local/bin/pi)"])
        for name in ["debian", "alpine-claude-code", "rust-pi", "claude-code", "pi"] {
            let s = try XCTUnwrap(try AgentVersions.spec(name, purpose: .prepare, store: store, settings: settings))
            XCTAssertTrue(AgentVersions.isCurrentRecipe(s), name)
        }
    }

    func testADockerfileIsRegisteredAndItsImageHasAPlaceholderUntilBuilt() throws {
        let dir = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = dir.appendingPathComponent("Dockerfile")
        try Data("FROM debian:bookworm\nRUN apt-get update\n".utf8).write(to: df)
        let rec = try Dockerfiles.register(df.path, store: store)
        XCTAssertEqual(rec.base, ImageChoice.dockerfileBase(path: df.resolvingSymlinksInPath().path))
        XCTAssertEqual(rec.context, dir.resolvingSymlinksInPath().path)
        XCTAssertTrue(DozerImages.isPreparable(rec.base + "-claude-code", store: store))
        XCTAssertFalse(DozerImages.isPreparable("df-000000000000-pi", store: store), "an unknown Dockerfile is not")
        let spec = try XCTUnwrap(try AgentVersions.spec(rec.base + "-claude-code", purpose: .create, store: store, settings: settings))
        XCTAssertTrue(Dockerfiles.isPlaceholder(spec.base))
        XCTAssertTrue(spec.steps.contains { $0.argv.last?.contains("command -v apt-get") == true }, "the package manager is looked for")
        XCTAssertFalse(rec.changedSinceBuild, "never built")
        // Refused: a folder, a missing file, the store itself, a relative path.
        XCTAssertThrowsError(try Dockerfiles.validate(dir.path, store: store))
        XCTAssertThrowsError(try Dockerfiles.validate(dir.appendingPathComponent("nope").path, store: store))
        XCTAssertThrowsError(try Dockerfiles.validate("Dockerfile", store: store))
        let inStore = store.root.appendingPathComponent("images/Dockerfile")
        try FileManager.default.createDirectory(at: inStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("FROM x\n".utf8).write(to: inStore)
        XCTAssertThrowsError(try Dockerfiles.validate(inStore.path, store: store))
        // A build recorded: its reference and environment; a change to the file is noticed.
        var built = rec
        built.reference = "dozer.local/\(rec.base)@sha256:" + String(repeating: "f", count: 64)
        built.dockerfileSHA256 = Dockerfiles.sha256(of: df)
        built.environment = ["APP_ENV": "dev"]
        built.path = ["/opt/app/bin"]
        try Dockerfiles.save(built, store)
        let spec2 = try XCTUnwrap(try AgentVersions.spec(rec.base, purpose: .prepare, store: store, settings: settings))
        XCTAssertEqual(spec2.base, built.reference)
        XCTAssertEqual(spec2.sessionEnvironment["APP_ENV"], "dev")
        XCTAssertTrue(spec2.sessionEnvironment["PATH"]!.contains("/opt/app/bin"))
        XCTAssertTrue(AgentVersions.isCurrentRecipe(spec2))
        XCTAssertFalse(Dockerfiles.record(rec.base, store)!.changedSinceBuild)
        try Data("FROM debian:bookworm\nRUN apt-get update && apt-get install -y make\n".utf8).write(to: df)
        XCTAssertTrue(Dockerfiles.record(rec.base, store)!.changedSinceBuild)
    }

    /// Apple's `container` through the seam: missing, unsupported, services stopped (said plainly, with
    /// what starting does), ready; the install flow records its plan and never downloads or opens anything.
    func testTheContainerToolThroughItsSeam() async throws {
        func fake(_ version: String, statusExit: Int32) throws -> String {
            let p = root.appendingPathComponent("container-\(UUID().uuidString.prefix(6))").path
            let script = """
                #!/bin/sh
                case "$1 $2" in
                  "--version "*) echo "container CLI version \(version) (build: release, commit: 0000000)";;
                  "system status") echo "apiserver is not running and not registered with launchd"; exit \(statusExit);;
                  "system start") echo "started"; exit 0;;
                esac
                """
            try Data(script.utf8).write(to: URL(fileURLWithPath: p))
            chmod(p, 0o755)
            return p
        }
        XCTAssertEqual(ContainerTool.status(["DOZ_TEST_CONTAINER": "/nonexistent/container"]).state, "missing")
        let stopped = ContainerTool.status(["DOZ_TEST_CONTAINER": try fake("1.2.2", statusExit: 1)])
        XCTAssertEqual(stopped.state, "stopped")
        XCTAssertEqual(stopped.version, "1.2.2")
        XCTAssertTrue(stopped.note.contains("not running"))
        XCTAssertTrue(stopped.startNote.contains("launchd") && stopped.startNote.contains("kernel"))
        XCTAssertTrue(ContainerTool.problem(stopped)!.contains("doz builder start"))
        XCTAssertEqual(ContainerTool.status(["DOZ_TEST_CONTAINER": try fake("1.2.2", statusExit: 0)]).state, "ready")
        XCTAssertEqual(ContainerTool.status(["DOZ_TEST_CONTAINER": try fake("0.9.0", statusExit: 0)]).state, "unsupported")
        XCTAssertEqual(ContainerTool.status(["DOZ_TEST_CONTAINER": try fake("2.0.0", statusExit: 0)]).state, "unsupported")
        XCTAssertEqual(ContainerTool.parseVersion("container CLI version 1.2.2 (build: release, commit: 0190097)"), "1.2.2")
        XCTAssertTrue(ContainerTool.isSupported("1.5.0"))
        let log = root.appendingPathComponent("install.log").path
        let said = try await ContainerTool.install(["DOZ_TEST_CONTAINER_INSTALL": log])
        XCTAssertEqual(said, "recorded")
        let plan = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(plan.contains(ContainerTool.package.url) && plan.contains(ContainerTool.package.sha256) && plan.contains("com.apple.installer"))
        XCTAssertTrue(ContainerTool.installNote.contains("never uses sudo"))
        XCTAssertTrue(Dockerfiles.outsidePolicyNote.contains("OUTSIDE Dozer's network policy"))
    }

    /// 596 addendum: Apple's container storage is a row OUTSIDE the store — measured, broken down,
    /// never in Dozer's total, never deletable, with its own commands named.
    func testAppleContainerStorageIsShownOutside() throws {
        let data = root.appendingPathComponent("apple")
        for (dir, bytes) in [("snapshots/abc", 64 << 10), ("content/blobs/sha256", 16 << 10), ("kernels", 8 << 10), ("builder", 4 << 10)] {
            let d = data.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: d.appendingPathComponent("f"))
        }
        // An image tagged dozer/… : its index, manifest, a layer and its snapshot count as Dozer's.
        let blobs = data.appendingPathComponent("content/blobs/sha256")
        func blob(_ name: String, _ body: String) throws -> String {
            try Data(body.utf8).write(to: blobs.appendingPathComponent(name)); return "sha256:" + name
        }
        let layer = try blob(String(repeating: "3", count: 64), String(repeating: "x", count: 5000))
        let manifest = try blob(String(repeating: "2", count: 64), #"{"config":{"digest":"\#(layer)"},"layers":[{"digest":"\#(layer)"}]}"#)
        let index = try blob(String(repeating: "1", count: 64), #"{"manifests":[{"digest":"\#(manifest)"}]}"#)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("snapshots/" + String(repeating: "2", count: 64)), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 32 << 10).write(to: data.appendingPathComponent("snapshots/" + String(repeating: "2", count: 64) + "/rootfs"))
        try Data(#"{"dozer/df-0123456789ab:latest":{"digest":"\#(index)"},"docker.io/library/alpine:3.20":{"digest":"sha256:9"}}"#.utf8)
            .write(to: data.appendingPathComponent("state.json"))
        let status = ContainerToolStatus(state: "stopped", version: "1.2.2", path: nil, note: "", supported: "", startNote: "", installNote: "")
        let items = Resources.appleContainerItems(AppleContainerFacts(dataRoot: data, program: [], status: status))
        let top = try XCTUnwrap(items.first { $0.id == "outside:apple-container" })
        XCTAssertEqual(top.group, "outside")
        XCTAssertFalse(top.deletable)
        XCTAssertTrue(top.refusal!.contains("container image prune") && top.refusal!.contains("Never deleted by Dozer"))
        XCTAssertTrue(top.detail!.contains("container 1.2.2") && top.detail!.contains("services not running"))
        let parts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertGreaterThan(parts["outside:apple-container/data/snapshots"]!.sizeBytes!, 64 << 10)
        XCTAssertGreaterThan(parts["outside:apple-container/data/other"]!.sizeBytes!, 0, "builder + state.json")
        XCTAssertEqual(top.sizeBytes, parts["outside:apple-container/data"]!.sizeBytes, "no program here")
        let dozer = try XCTUnwrap(parts["outside:apple-container/dozer"])
        XCTAssertTrue(dozer.detail!.contains("1 image"))
        XCTAssertGreaterThan(dozer.sizeBytes!, 32 << 10)
        XCTAssertTrue(items.allSatisfy { !$0.deletable && $0.group == "outside" })
        // Not installed and no data: one row, 0 B, the on-demand note.
        let none = Resources.appleContainerItems(AppleContainerFacts(dataRoot: nil, program: [],
            status: ContainerToolStatus(state: "missing", version: nil, path: nil, note: "", supported: "", startNote: "", installNote: "")))
        XCTAssertEqual(none.count, 1)
        XCTAssertEqual(none[0].sizeBytes, 0)
        XCTAssertEqual(none[0].detail, "not installed — Dockerfile images install it on demand")
        // In the inventory: outside, and NOT in the store's total or the unattributed check.
        var facts = ResourceFacts(kernelCache: root.appendingPathComponent("kernels"), currentKernel: root.appendingPathComponent("kernels/k"))
        facts.appleContainer = AppleContainerFacts(dataRoot: data, program: [], status: status)
        let report = Resources.inventory(store: store, facts: facts)
        XCTAssertNotNil(report.items.first { $0.id == "outside:apple-container" })
        XCTAssertEqual(report.unattributedBytes, 0)
        XCTAssertLessThan(report.totalBytes, 64 << 10, "Apple's bytes are not Dozer's")
    }
}
