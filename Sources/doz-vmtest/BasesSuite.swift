// 596 — Dozer Base Images end to end, from separate processes of the REAL signed doz
// (`make test-cli-bases`; its cli, dockerfile and real parts are in `make test-cli` too):
//
//   · cli        — `doz base ls`; --agent/--base/--dockerfile and their refusals; a pair's name and
//                  its base's registries in the policy; `doz_project.yaml` agent/base/dockerfile via up
//   · matrix     — acceptance item 2: Node, Python, Go, Debian, Alpine × Claude Code and none, prepared
//                  and booted (network: the tags resolved now, the latest Claude Code); Claude Code on a
//                  base without Node is the native build (no Node at all); pi on Python gets Node under
//                  /opt/node (pi's only). Serially; the store is removed at the end.
//   · dockerfile — Apple's `container` through a FAKE (`DOZ_TEST_CONTAINER`, a script that answers
//                  --version / system status|start / build -o type=oci,dest= with an OCI archive this
//                  suite made from a real image): missing → the install flow recorded
//                  (`DOZ_TEST_CONTAINER_INSTALL`, never a download, never Installer); services stopped →
//                  said plainly, `doz builder start`; a Dockerfile sandbox: its folder is the workspace, the
//                  build + import + bake, "OUTSIDE Dozer's network policy" said; an unchanged rebuild
//                  bakes nothing; a changed Dockerfile → "rebuild available"; a new build → reset takes it;
//                  Claude Code added on top, the facts block and a credential through the proxy.
//   · real       — the REAL `container build` (owner-approved 2026-10-01): needs Apple's services running
//                  — SKIPs with a clear message when they are not (BASES_START_BUILDER=1 lets doz's own
//                  `doz builder start --yes` start them first); a Dockerfile FROM a catalogue base + a RUN
//                  apt-get install → build → import → Claude Code added → it boots, facts + credential.
//
// Stores: /tmp/dzb-<pid>-<part> (short: sockets), each with its own XDG_CONFIG_HOME and projects folder;
// accounts in the host's memory (DOZ_TEST_CREDENTIALS=memory). Never the owner's store or settings.
import Containerization
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import DozerKit
import DozerHost

func basesHarness(_ binary: String, _ tag: String) -> CLIHarness {
    let h = onboardingHarness(binary, "b\(tag)", seed: ["kernels", "content", "state.json", "initfs.ext4"])
    let projects = h.store.appendingPathComponent("projects")
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    h.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120)
    h.run(["config", "set", "defaults.projects_dir", projects.path])
    return h
}

func cliBasesSuite(binary: String, parts: Set<String>) async {
    print("cli: 596 base images — parts \(parts.sorted().joined(separator: ", "))")
    if parts.contains("cli") { await basesCLIPart(binary) }
    if parts.contains("dockerfile") { await basesDockerfilePart(binary) }
    if parts.contains("real") { await basesRealBuildPart(binary) }
    if parts.contains("matrix") { await basesMatrixPart(binary) }
}

// MARK: cli

func basesCLIPart(_ binary: String) async {
    let h = basesHarness(binary, "c")
    defer { h.run(["host", "stop"]); try? FileManager.default.removeItem(at: h.store) }
    print("cli: doz base ls, --agent/--base, the project file (596 B10)")
    var r = h.run(["base", "ls"])
    check(r.code == 0 && ["node — Node.js", "python — Python", "go — Go", "rust — Rust", "java — Java", "ruby — Ruby", ".NET", "debian — Debian", "ubuntu — Ubuntu", "alpine — Alpine"].allSatisfy(r.out.contains)
          && !r.out.contains("DeckStack"), "doz base ls: the ten recommended bases (and no internal teaser)")
    let rows = h.json(["base", "ls"], [BaseRow].self) ?? []
    check(rows.count == 10 && rows.first { $0.id == "go" }?.registries.contains("proxy.golang.org") == true && rows.allSatisfy { $0.digest.hasPrefix("sha256:") },
          "--json: ten rows, each with a digest; Go's registries")
    r = h.run(["create", "x1", "--agent", "claude-code", "--base", "cobol"])
    check(r.code != 0 && r.err.contains("--base: node, python"), "an unknown base is refused, the bases named")
    r = h.run(["create", "x1", "--image", "lab", "--agent", "pi"])
    check(r.code != 0 && r.err.contains("not both"), "--image with --agent: refused")
    r = h.run(["create", "x1", "--agent", "gemini"])      // codex is an agent since 599i
    check(r.code != 0 && r.err.contains("--agent: claude-code, pi, codex or none"), "an unknown agent is refused")
    r = h.run(["create", "g1", "--base", "go", "--agent", "none", "--isolated", "--json"])
    let g1 = try? HostWire.decoder.decode(SandboxInfo.self, from: r.outData)
    check(r.code == 0 && g1?.image == "go" && g1?.imageTitle == "Go · none" && g1?.base == "go", "create --base go --agent none: image go, Go · none")
    let pol = h.run(["net", "policy", "g1"]).out
    check(pol.contains("proxy.golang.org") && pol.contains("sum.golang.org"), "its policy allows Go's module proxy (B4)")
    r = h.run(["create", "p1", "--base", "python", "--isolated", "--account", "none", "--json"])
    check((try? HostWire.decoder.decode(SandboxInfo.self, from: r.outData))?.image == "python-claude-code", "--base python (agent defaults to claude-code): python-claude-code")
    r = h.run(["create", "n1", "--image", "node-claude-code", "--isolated", "--account", "none", "--json"])
    check((try? HostWire.decoder.decode(SandboxInfo.self, from: r.outData))?.image == "claude-code", "--image node-claude-code is claude-code (same image)")
    // The project file.
    let proj = h.store.appendingPathComponent("proj")
    try? FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    try? "name: prj1\nagent: none\nbase: debian\n".write(to: proj.appendingPathComponent("doz_project.yaml"), atomically: true, encoding: .utf8)
    r = runIn(h, proj, ["up", "--detach"], timeout: 1500)
    let prj = h.row("prj1")
    check(r.code == 0 && prj?.image == "debian" && [proj.resolvingSymlinksInPath().path, proj.path].contains(prj?.workspace ?? ""),
          "doz_project.yaml agent: none, base: debian → up: the debian image, the folder at /workspace (\(prj?.image ?? "none"), exit \(r.code))")
    check(h.run(["exec", "prj1", "--", "sh", "-c", "grep -c bookworm /etc/os-release; ls /workspace"]).out.contains("doz_project.yaml"), "it runs Debian with the project at /workspace")
    try? "name: prj2\nimage: lab\nagent: pi\n".write(to: proj.appendingPathComponent("doz_project.yaml"), atomically: true, encoding: .utf8)
    r = runIn(h, proj, ["up", "--detach"], timeout: 60)
    check(r.code != 0 && r.err.contains("not both"), "doz_project.yaml image + agent: refused with its line")
    r = h.run(["image", "ls"])
    check(r.out.contains("BASE · AGENT") && r.out.contains("Node.js · Claude Code") && r.out.contains("Alpine · none"), "image ls: the BASE · AGENT column")
}

// MARK: dockerfile (the fake container)

/// An OCI image-layout tar of `reference` (pulled into `scratch`, linux/arm64), optionally with its
/// config's `created` changed — the same layers, a different image digest (B8's "unchanged").
func ociArchive(_ reference: String, scratch: URL, out: URL, newCreated: String? = nil) async throws {
    let store = try ImageStore(path: scratch)
    let arm = Platform(arch: "arm64", os: "linux")
    if (try? await store.get(reference: reference)) == nil { _ = try await store.pull(reference: reference, platform: arm) }
    let dir = scratch.appendingPathComponent("layout-\(UUID().uuidString.prefix(6))")
    try await store.save(references: [reference], out: dir, platform: arm)
    if let created = newCreated { try rewriteCreated(dir, created) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    p.arguments = ["-cf", out.path, "-C", dir.path, "."]
    try p.run()
    p.waitUntilExit()
    try? FileManager.default.removeItem(at: dir)
}

/// Change the config's `created` in an OCI layout (index → [index →] manifest → config), rewriting each
/// blob it touches and the digests that name them.
func rewriteCreated(_ dir: URL, _ created: String) throws {
    let blobs = dir.appendingPathComponent("blobs/sha256")
    func read(_ digest: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: blobs.appendingPathComponent(String(digest.dropFirst(7))))) as! [String: Any]
    }
    func write(_ obj: [String: Any]) throws -> (String, Int) {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let hex = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        try d.write(to: blobs.appendingPathComponent(hex))
        return ("sha256:" + hex, d.count)
    }
    func fix(_ desc: [String: Any]) throws -> [String: Any] {
        var desc = desc
        var obj = try read(desc["digest"] as! String)
        if var ms = obj["manifests"] as? [[String: Any]] {
            ms = try ms.map(fix)
            obj["manifests"] = ms
        } else if var cfg = obj["config"] as? [String: Any] {
            var c = try read(cfg["digest"] as! String)
            c["created"] = created
            let (cd, cs) = try write(c)
            cfg["digest"] = cd
            cfg["size"] = cs
            obj["config"] = cfg
        }
        let (d, s) = try write(obj)
        desc["digest"] = d
        desc["size"] = s
        return desc
    }
    let indexURL = dir.appendingPathComponent("index.json")
    var index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
    index["manifests"] = try (index["manifests"] as! [[String: Any]]).map(fix)
    try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
}

/// A fake `container`: --version, system status (exit per the state file), system start (→ running),
/// build (copies `next.tar` to the -o dest, prints a few plain-progress lines). Every call is logged.
func fakeContainer(_ dir: URL, state: String) -> String {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? state.write(to: dir.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    let script = """
        #!/bin/sh
        d='\(dir.path)'
        echo "$*" >> "$d/calls.log"
        case "$1" in
          --version) echo "container CLI version 1.2.2 (build: release, commit: fake000)"; exit 0;;
          system)
            case "$2" in
              status) if [ "$(cat "$d/state")" = running ]; then echo "apiserver is running"; exit 0; else echo "apiserver is not running and not registered with launchd"; exit 1; fi;;
              start) echo running > "$d/state"; echo "Verifying apiserver is running..."; exit 0;;
            esac;;
          build)
            echo "#1 [internal] load build definition from Dockerfile"
            echo "#2 [1/2] FROM (fake)"
            echo "#3 exporting to oci image format"
            echo "#3 DONE 0.1s"
            exit 0;;
          image)
            [ "$2" = save ] || exit 2
            out=""; prev=""
            for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
            cp "$d/next.tar" "$out" && exit 0
            exit 1;;
        esac
        exit 2
        """
    let p = dir.appendingPathComponent("container").path
    try? script.write(toFile: p, atomically: true, encoding: .utf8)
    chmod(p, 0o755)
    return p
}

func basesDockerfilePart(_ binary: String) async {
    let h = basesHarness(binary, "d")
    let fake = h.store.appendingPathComponent("fake")
    defer { h.run(["host", "stop"]); try? FileManager.default.removeItem(at: h.store) }
    print("cli: Dockerfile bases — Apple's container through a fake (596 B5–B9)")
    let scratch = h.store.appendingPathComponent("oci-scratch")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let debian = BaseCatalogue.base("debian")!.pinnedReference, alpine = BaseCatalogue.base("alpine")!.pinnedReference
    let a = fake.appendingPathComponent("a.tar"), a2 = fake.appendingPathComponent("a2.tar"), b = fake.appendingPathComponent("b.tar")
    do {
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try await ociArchive(debian, scratch: scratch, out: a)
        try await ociArchive(debian, scratch: scratch, out: a2, newCreated: "2026-10-01T00:00:00Z")
        try await ociArchive(alpine, scratch: scratch, out: b)
    } catch {
        check(false, "the fake's OCI archives could not be made: \(error)")
        return
    }
    try? FileManager.default.removeItem(at: scratch)
    // Beside the store (a Dockerfile inside Dozer's store is refused).
    let app = URL(fileURLWithPath: h.store.path + "-app")
    try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app) }
    let df = app.appendingPathComponent("Dockerfile")
    try? "FROM debian:bookworm\nRUN echo built > /built\n".write(to: df, atomically: true, encoding: .utf8)
    let base = ImageChoice.dockerfileBase(path: df.resolvingSymlinksInPath().path)

    // Missing: said, and the install flow only RECORDED.
    h.env["DOZ_TEST_CONTAINER"] = "/nonexistent/container"
    let log = fake.appendingPathComponent("install.log")
    h.env["DOZ_TEST_CONTAINER_INSTALL"] = log.path
    h.run(["host", "stop"])
    var st = h.json(["builder", "status"], ContainerToolStatus.self)
    check(st?.state == "missing" && (st?.installNote ?? "").contains("never uses sudo"), "builder status: missing, the install said plainly (\(st?.state ?? "?"))")
    var r = h.run(["create", "dx", "--dockerfile", df.path, "--agent", "none", "--start"])
    check(r.code != 0 && r.err.contains("doz builder install") && h.row("dx") == nil, "create --start with no container, off a terminal: refused before anything is made, the next step said")
    r = h.run(["builder", "install", "--yes"], timeout: 60)
    let plan = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check(r.code == 0 && plan.contains(ContainerTool.package.url) && plan.contains(ContainerTool.package.sha256) && plan.contains("com.apple.installer"),
          "builder install --yes: the pinned signed package, its sha256, macOS Installer — recorded (the seam), nothing downloaded or opened")

    // Installed, services stopped: said plainly; `doz builder start` (asked) starts them.
    h.env["DOZ_TEST_CONTAINER"] = fakeContainer(fake, state: "stopped")
    h.run(["host", "stop"])
    st = h.json(["builder", "status"], ContainerToolStatus.self)
    check(st?.state == "stopped" && (st?.note ?? "").contains("not running") && (st?.startNote ?? "").contains("launchd"), "builder status: stopped — what starting does is said")
    r = h.run(["builder", "start"])
    check(r.code != 0, "builder start with no terminal and no --yes: not started (asks first)")
    r = h.run(["builder", "start", "--yes"], timeout: 120)
    check(r.code == 0 && r.out.contains("running"), "builder start --yes: ready (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(((try? String(contentsOf: fake.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").contains("system start --enable-kernel-install"),
          "it ran container system start --enable-kernel-install")

    // A Dockerfile sandbox: its folder is the workspace; the first start builds, imports, bakes.
    try? FileManager.default.copyItem(at: a, to: fake.appendingPathComponent("next.tar"))
    r = h.run(["create", "d1", "--dockerfile", df.path, "--agent", "none", "--json"], timeout: 60)
    if r.code != 0 { info("create d1: \(r.out.prefix(400))") }
    let d1 = try? HostWire.decoder.decode(SandboxInfo.self, from: r.outData)
    check(r.code == 0 && d1?.image == base && d1?.workspace == app.resolvingSymlinksInPath().path && d1?.dockerfile == df.resolvingSymlinksInPath().path,
          "create --dockerfile: image \(d1?.image ?? "?") (its base id), the workspace is its folder (B6)")
    check(r.err.contains("OUTSIDE Dozer's network policy"), "the CLI says the build runs outside Dozer's network policy (B9)")
    let t0 = Date()
    r = h.run(["start", "d1", "-v"], timeout: 1500)
    let firstSeconds = Date().timeIntervalSince(t0)
    let said = r.out + r.err
    check(r.code == 0 && said.contains("built the Dockerfile with Apple's container build") && said.contains("imported the built image into Dozer's store"),
          "start d1: built + imported (\(Int(firstSeconds)) s)")
    check(said.contains("OUTSIDE Dozer's network policy"), "the preparation says it too (the Operations log records it)")
    let calls = (try? String(contentsOf: fake.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
    check(calls.contains("build --platform linux/arm64 --progress plain -f \(df.resolvingSymlinksInPath().path) -t dozer/\(base):latest \(app.resolvingSymlinksInPath().path)")
          && calls.contains("image save --platform linux/arm64 -o ") && calls.contains(" dozer/\(base):latest"),
          "container build --platform linux/arm64 -f … -t dozer/<base>:latest <its folder>, then container image save -o … (linux/arm64)")
    check(h.run(["exec", "d1", "--", "cat", "/etc/os-release"]).out.contains("Debian"), "d1 boots the Dockerfile's base (Debian)")
    check(h.run(["exec", "d1", "--", "sh", "-c", "id -un; sudo -n true && echo sudo-ok"]).out == "agent\nsudo-ok\n", "the agent user and its sudo are added (the baseline)")
    check(h.run(["exec", "d1", "--", "cat", "/workspace/Dockerfile"]).out.contains("FROM debian"), "/workspace is the Dockerfile's folder")
    let rec = Dockerfiles.record(base, DozerStore(root: h.store))
    check(rec?.reference?.hasPrefix("dozer.local/\(base)@sha256:") == true && rec?.builds == 1, "dockerfiles.json: the build's reference (\(rec?.reference?.suffix(20) ?? "none"))")

    // Unchanged (same layers, a new config): nothing re-baked — seconds (B8).
    try? FileManager.default.removeItem(at: fake.appendingPathComponent("next.tar"))
    try? FileManager.default.copyItem(at: a2, to: fake.appendingPathComponent("next.tar"))
    let t1 = Date()
    r = h.run(["image", "bake", base, "-v"], timeout: 600)
    let again = Date().timeIntervalSince(t1)
    check(r.code == 0 && (r.out + r.err).contains("unchanged (same layers)") && !(r.out + r.err).contains("baking image"),
          "an unchanged Dockerfile re-prepares without a bake (\(String(format: "%.1f", again)) s vs \(Int(firstSeconds)) s)")
    check(Dockerfiles.record(base, DozerStore(root: h.store))?.reference == rec?.reference, "the same reference is kept")
    check(h.row("d1")?.rebuildAvailable == nil, "d1: nothing to rebuild")

    // The Dockerfile changes: said on the sandbox and the image — never rebuilt by itself.
    try? "FROM alpine:3.20\nRUN echo built > /built\n".write(to: df, atomically: true, encoding: .utf8)
    check((h.row("d1")?.rebuildAvailable ?? "").contains("Dockerfile changed — rebuild available"), "d1: \"Dockerfile changed — rebuild available\" (B8)")
    check((h.json(["image", "ls"], [ImageRow].self)?.first { $0.name == base }?.baseUpdate ?? "").contains("the Dockerfile changed"), "image ls: the Dockerfile changed")
    try? FileManager.default.removeItem(at: fake.appendingPathComponent("next.tar"))
    try? FileManager.default.copyItem(at: b, to: fake.appendingPathComponent("next.tar"))
    r = h.run(["image", "bake", base], timeout: 900)
    check(r.code == 0 && Dockerfiles.record(base, DozerStore(root: h.store))?.reference != rec?.reference, "a rebuild with new layers: a new base, baked")
    check((h.row("d1")?.rebuildAvailable ?? "").contains("reset the sandbox to take it"), "d1 keeps its disk until reset: \(h.row("d1")?.rebuildAvailable ?? "nil")")
    check(h.run(["reset", "d1", "--yes"]).code == 0 && h.run(["start", "d1"], timeout: 600).code == 0, "reset d1, start it")
    check(h.run(["exec", "d1", "--", "cat", "/etc/os-release"]).out.contains("Alpine"), "d1 now boots the new build (Alpine)")
    check(h.row("d1")?.rebuildAvailable == nil, "nothing to rebuild now")

    // Claude Code added on top of a Dockerfile's image: native, the facts, a credential through the proxy.
    try? "FROM debian:bookworm\nRUN echo two > /built\n".write(to: app.appendingPathComponent("Dockerfile.cc"), atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(at: fake.appendingPathComponent("next.tar"))
    try? FileManager.default.copyItem(at: a, to: fake.appendingPathComponent("next.tar"))
    let fk = "sk-ant-api03-DOZFAKE" + String(repeating: "d", count: 40)
    check(h.run(["account", "add", "fk", "--api-key", "--no-verify", "--force"], stdin: Data((fk + "\n").utf8)).code == 0, "account add fk (fake key, memory keychain)")
    r = h.run(["create", "d2", "--dockerfile", app.appendingPathComponent("Dockerfile.cc").path, "--agent", "claude-code", "--account", "fk", "--isolated"], timeout: 60)
    check(r.code == 0, "create d2 --dockerfile … --agent claude-code --account fk")
    r = h.run(["start", "d2", "-v"], timeout: 1800)
    check(r.code == 0 && (r.out + r.err).contains("(native build"), "start d2: Claude Code's native build added on the Dockerfile's image (exit \(r.code))")
    check(h.run(["exec", "d2", "--", "sh", "-c", "claude --version; command -v node || echo no-node"]).out.contains("no-node"), "claude runs; no Node was added for it")
    h.run(["run", "d2", "--detach", "--session", "s1", "--", "sleep", "60"])
    let facts = h.run(["exec", "d2", "--", "cat", "/run/dozer/agent-prompt.md"]).out
    check(facts.contains("base: the user's Dockerfile \(app.resolvingSymlinksInPath().path)/Dockerfile.cc") && facts.contains("adds the account's credential (fk)"),
          "the facts block: the Dockerfile as the base, the account's credential")
    let seen = h.run(["exec", "d2", "--", "sh", "-c", "echo $ANTHROPIC_API_KEY"]).out
    check(seen.hasPrefix(CredentialVault.placeholderPrefix) && !seen.contains(fk), "the guest sees a placeholder, never the key")
}

// MARK: real (Apple's container, owner-approved)

func basesRealBuildPart(_ binary: String) async {
    guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/container") else {
        print("  SKIP  the real container build — Apple's container tool is not installed (doz builder install)")
        return
    }
    let h = basesHarness(binary, "r")
    defer { h.run(["host", "stop"]); try? FileManager.default.removeItem(at: h.store) }
    print("cli: the REAL container build (596 B7; owner-approved 2026-10-01)")
    var st = h.json(["builder", "status"], ContainerToolStatus.self)
    if st?.state == "stopped" {
        guard ProcessInfo.processInfo.environment["BASES_START_BUILDER"] == "1" else {
            print("  SKIP  the real container build — Apple's container services are not running: `doz builder start` (or BASES_START_BUILDER=1 to let this run start them through doz)")
            return
        }
        // The owner's consent (2026-10-01) — given explicitly here, through doz's own flow.
        let r = h.run(["builder", "start", "--yes"], timeout: 900)
        print("  doz builder start --yes (owner-approved):\n" + (r.out + r.err).split(separator: "\n").suffix(12).map { "    │ " + $0 }.joined(separator: "\n"))
        st = h.json(["builder", "status"], ContainerToolStatus.self)
        check(r.code == 0 && st?.state == "ready", "doz builder start --yes: Apple's services started through doz (\(st?.note ?? "?"))")
    }
    guard st?.state == "ready" else {
        print("  SKIP  the real container build — \(st?.note ?? "no status")")
        return
    }
    let app = URL(fileURLWithPath: h.store.path + "-app")
    try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let df = app.appendingPathComponent("Dockerfile")
    defer {
        try? FileManager.default.removeItem(at: app)
        // This run's image in Apple's store (doz keeps a Dockerfile's tag there; a test does not).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        p.arguments = ["image", "delete", "dozer/\(ImageChoice.dockerfileBase(path: df.resolvingSymlinksInPath().path)):latest"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
    try? "FROM docker.io/library/debian:bookworm\nRUN apt-get update && apt-get install -y --no-install-recommends cowsay && rm -rf /var/lib/apt/lists/*\nENV APP_GREETING=hello-from-dockerfile\n"
        .write(to: df, atomically: true, encoding: .utf8)
    let fk = "sk-ant-api03-DOZFAKE" + String(repeating: "r", count: 40)
    check(h.run(["account", "add", "fk", "--api-key", "--no-verify", "--force"], stdin: Data((fk + "\n").utf8)).code == 0, "account add fk (fake key)")
    var r = h.run(["create", "rb", "--dockerfile", df.path, "--agent", "claude-code", "--account", "fk"], timeout: 60)
    check(r.code == 0, "create rb --dockerfile (FROM debian + RUN apt-get install cowsay) --agent claude-code")
    let t0 = Date()
    r = h.run(["start", "rb", "-v"], timeout: 3000)
    let first = Date().timeIntervalSince(t0)
    print("  start rb (container build + import + bake): exit \(r.code) in \(Int(first)) s")
    if r.code != 0 { print((r.out + r.err).split(separator: "\n").suffix(30).map { "    │ " + $0 }.joined(separator: "\n")) }
    check(r.code == 0 && (r.out + r.err).contains("built the Dockerfile with Apple's container build"), "the real build ran, was imported and baked (\(Int(first)) s)")
    check(h.run(["exec", "rb", "--", "/usr/games/cowsay", "moo"]).out.contains("moo"), "the Dockerfile's RUN is in the sandbox (/usr/games/cowsay)")
    check(h.run(["exec", "rb", "--", "sh", "-c", "echo $APP_GREETING"]).out == "hello-from-dockerfile\n", "its ENV reaches sessions")
    check(h.run(["exec", "rb", "--", "claude", "--version"]).out.contains("Claude Code"), "Claude Code was added by Dozer")
    h.run(["run", "rb", "--detach", "--session", "s1", "--", "sleep", "60"])
    let facts = h.run(["exec", "rb", "--", "cat", "/run/dozer/agent-prompt.md"]).out
    check(facts.contains("the user's Dockerfile") && facts.contains("adds the account's credential (fk)"), "the facts block and the credential")
    let seen = h.run(["exec", "rb", "--", "sh", "-c", "echo $ANTHROPIC_API_KEY"]).out
    check(seen.hasPrefix(CredentialVault.placeholderPrefix) && !seen.contains(fk), "a placeholder, never the key")
    let t1 = Date()
    r = h.run(["image", "bake", ImageChoice(base: ImageChoice.dockerfileBase(path: df.resolvingSymlinksInPath().path), agent: .claudeCode).name, "-v"], timeout: 900)
    let again = Date().timeIntervalSince(t1)
    print("  an unchanged rebuild: exit \(r.code) in \(String(format: "%.1f", again)) s")
    check(r.code == 0 && (r.out + r.err).contains("unchanged (same layers)"), "an unchanged Dockerfile re-prepares in seconds, nothing re-baked (\(String(format: "%.1f", again)) s)")
}

// MARK: matrix (acceptance item 2)

func basesMatrixPart(_ binary: String) async {
    let h = basesHarness(binary, "m")
    defer { h.run(["host", "stop"]); try? FileManager.default.removeItem(at: h.store) }
    print("cli: the base × agent matrix (596 acceptance 2) — Node, Python, Go, Debian, Alpine × Claude Code and none; pi on Python")
    let npmLatest = await registryLatest(AgentImages.claudeCodePackage)
    var pairs: [(String, AgentKind)] = []
    for b in ["node", "python", "go", "debian", "alpine"] { for a in [AgentKind.claudeCode, .none] { pairs.append((b, a)) } }
    pairs.append(("python", .pi))
    // BASES_ONLY=alpine,python — only those bases (a re-run of part of the matrix).
    if let only = ProcessInfo.processInfo.environment["BASES_ONLY"], !only.isEmpty {
        let keep = Set(only.split(separator: ",").map(String.init))
        pairs = pairs.filter { keep.contains($0.0) }
    }
    for (b, a) in pairs {
        let base = BaseCatalogue.base(b)!
        let name = "m-\(b)-\(a == .claudeCode ? "cc" : a == .pi ? "pi" : "none")"
        let image = ImageChoice(base: b, agent: a).name
        var r = h.run(["create", name, "--base", b, "--agent", a.rawValue, "--isolated", "--account", "none"], timeout: 60)
        guard r.code == 0 else { check(false, "\(name): create failed: \(r.err.suffix(200))"); continue }
        let t0 = Date()
        r = h.run(["start", name, "-v"], timeout: 2400)
        let secs = Int(Date().timeIntervalSince(t0))
        guard r.code == 0 else {
            check(false, "\(name): \(image) prepared and booted (exit \(r.code) after \(secs) s): " + (r.out + r.err).split(separator: "\n").suffix(8).joined(separator: " | "))
            continue
        }
        check(true, "\(name): \(image) prepared and booted in \(secs) s")
        if image == "lab" {
            // Alpine · none is the lab, unchanged by 596 (its own prepared disk; sessions run as root).
            check(h.run(["exec", name, "--", "sh", "-c", "grep -c Alpine /etc/os-release; command -v bash"]).out.contains("/bin/bash"), "\(name): the lab (Alpine + bash), as before")
        } else {
            let who = h.run(["exec", name, "--", "sh", "-c", "id -un; sudo -n true && echo sudo-ok"]).out
            check(who == "agent\nsudo-ok\n", "\(name): the agent user, passwordless sudo")
        }
        if let t = base.toolchain, !(b == "node" && a != .none) {
            let out = h.run(["exec", name, "--"] + t.argv).out + h.run(["exec", name, "--", "sh", "-c", t.argv.joined(separator: " ") + " 2>&1"]).out
            check(t.expect.map(out.contains) ?? true, "\(name): the toolchain answers (\(t.argv.joined(separator: " ")) → \(out.split(separator: "\n").first ?? ""))")
        }
        let digest = BaseDigests.all(DozerStore(root: h.store))[b]?.digest
        check(digest != nil, "\(name): \(base.shortReference) resolved to a digest at preparation (\(digest?.dropFirst(7).prefix(12) ?? "none"))")
        switch a {
        case .claudeCode:
            let v = h.run(["exec", name, "--", "claude", "--version"]).out
            check(npmLatest.map { v.contains($0) } ?? v.contains("Claude Code"), "\(name): claude --version → \(v.trimmingCharacters(in: .whitespacesAndNewlines)) (latest: \(npmLatest ?? "?"))")
            if !base.hasNode {
                check((r.out + r.err).contains("(native build, latest, resolved now)"), "\(name): Claude Code's native build, latest, checksum-verified")
                check(h.run(["exec", name, "--", "sh", "-c", "command -v node || echo no-node"]).out == "no-node\n", "\(name): no Node for Claude Code's sake")
            }
            h.run(["run", name, "--detach", "--session", "s1", "--", "sleep", "30"])
            let facts = h.run(["exec", name, "--", "cat", "/run/dozer/agent-prompt.md"]).out
            check(facts.contains("(base: \(base.title) (\(base.shortReference)))"), "\(name): the facts block names the base")
        case .pi:
            check(h.run(["exec", name, "--", "pi", "--version"]).code == 0, "\(name): pi runs")
            check(h.run(["exec", name, "--", "sh", "-c", "test -x /opt/node/bin/node && /opt/node/bin/node --version"]).out.hasPrefix("v\(NodeRuntime.version)"),
                  "\(name): Node \(NodeRuntime.version) under /opt/node")
            check(h.run(["exec", name, "--", "sh", "-c", "command -v node || echo no-node"]).out == "no-node\n", "\(name): Node is pi's, not on the sessions' PATH")
        case .codex:
            // 599i: the static binary on every base (`make test-cli-codex` checks the rest).
            let v = h.run(["exec", name, "--", "codex", "--version"]).out
            check(v.contains("codex-cli "), "\(name): codex --version → \(v.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .none:
            check(h.run(["exec", name, "--", "sh", "-c", "command -v claude || command -v pi || command -v codex || echo no-agent"]).out == "no-agent\n", "\(name): no agent")
        }
        if b == "go" {
            check(h.run(["net", "policy", name]).out.contains("proxy.golang.org"), "\(name): Go's module proxy is allowed")
        }
        h.run(["rm", name, "--yes"], timeout: 120)
        info("\(name): removed")
    }
    let rows = h.json(["image", "ls"], [ImageRow].self) ?? []
    info("images: " + rows.map { "\($0.name) \($0.allocatedBytes.map(DozerImages.formatBytes) ?? "—")" }.joined(separator: ", "))
}
