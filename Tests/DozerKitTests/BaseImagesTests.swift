import CryptoKit
import Foundation
import XCTest
@testable import DozerKit

/// 596: the base catalogue, base × agent names, and the composed image specs.
final class BaseImagesTests: XCTestCase {
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private let release = AgentRelease(version: "2.1.285", integrity: "sha512-AAAA")
    private let native = NativeClaudeBuild(version: "2.1.285", sha256: ["linux-arm64": String(repeating: "a", count: 64),
                                                                        "linux-arm64-musl": String(repeating: "b", count: 64)])

    /// The two Node images are EXACTLY what they were before 596 (canonical JSON sha256 captured from
    /// fe9e746, before any 596 change) — so every prepared image in every store keeps its key.
    /// 599 changed them ON PURPOSE (tmux joined the dev baseline; W28's warning names it — "adds: tmux"):
    /// before 599 they were 7dc167ad…, 39946455…, 04976cf1…. Change these only with a recipe change.
    func test_nodeImagesAreByteIdentical() throws {
        XCTAssertEqual(Self.sha(AgentImages.claudeCode.canonicalJSON), "c698b09dcb3020fa9336a4e455d400c454ea4ff0659de973c19d63aadea8ef73")
        XCTAssertEqual(Self.sha(AgentImages.pi.canonicalJSON), "33c6ed411162d35ebd8bc6594d0727f119e34071e55e43351f5bd4ebc47d3e47")
        XCTAssertEqual(Self.sha(AgentImages.claudeCode(release).canonicalJSON), "cffee713e6854e3d68618a1fceda00fd7af656471ef68c843bb1287a8a20bedb")
        // Composed from the catalogue's Node at its pin: the same spec.
        let node = BaseCatalogue.base("node")!
        XCTAssertEqual(node.pinnedReference, AgentImages.nodeBase)
        XCTAssertEqual(try ImageComposer.spec(name: "claude-code", base: node.source(), agent: .claudeCode, release: AgentImages.claudeCodePinned, native: nil),
                       AgentImages.claudeCode)
        XCTAssertEqual(try ImageComposer.spec(name: "pi", base: node.source(), agent: .pi, release: AgentImages.piPinned, native: nil), AgentImages.pi)
    }

    func test_catalogueIsTheDesignsTable() {
        XCTAssertEqual(BaseCatalogue.ids, ["node", "python", "go", "rust", "java", "ruby", "dotnet", "debian", "ubuntu", "alpine"])
        for b in BaseCatalogue.all {
            XCTAssertTrue(b.pinnedDigest.hasPrefix("sha256:") && b.pinnedDigest.count == 71, b.id)
            XCTAssertTrue(b.pinnedReference.contains("@sha256:"), b.id)
            XCTAssertFalse(b.reference.contains("slim"), "\(b.id): full variants for toolchains")
            XCTAssertFalse(b.repository.hasSuffix(":"), b.id)
            XCTAssertGreaterThan(b.downloadBytes, 0)
        }
        XCTAssertEqual(BaseCatalogue.base("dotnet")?.repository, "mcr.microsoft.com/dotnet/sdk")
        XCTAssertEqual(BaseCatalogue.base("python")?.shortReference, "python:3.13-bookworm")
        XCTAssertEqual(BaseCatalogue.base("go")?.registries.map(\.host).contains("proxy.golang.org"), true)
        XCTAssertEqual(BaseCatalogue.base("alpine")?.packageManager, .apk)
    }

    func test_namesRoundTrip() {
        XCTAssertEqual(ImageChoice(base: "node", agent: .claudeCode).name, "claude-code")
        XCTAssertEqual(ImageChoice(base: "node", agent: .pi).name, "pi")
        XCTAssertEqual(ImageChoice(base: "alpine", agent: .none).name, "lab")
        XCTAssertEqual(ImageChoice(base: "python", agent: .claudeCode).name, "python-claude-code")
        XCTAssertEqual(ImageChoice(base: "go", agent: .none).name, "go")
        for b in BaseCatalogue.ids {
            for a in AgentKind.allCases {
                let c = ImageChoice(base: b, agent: a)
                XCTAssertEqual(ImageChoice.parse(c.name), c, c.name)
                XCTAssertLessThanOrEqual(c.name.count, 40)
            }
        }
        XCTAssertEqual(ImageChoice.parse("node-claude-code")?.name, "claude-code")
        XCTAssertEqual(ImageChoice.parse("alpine")?.name, "lab")
        XCTAssertNil(ImageChoice.parse("my-template"))
        XCTAssertNil(ImageChoice.parse("cobol-claude-code"))
        let df = ImageChoice.dockerfileBase(path: "/Users/x/code/app/Dockerfile")
        XCTAssertTrue(ImageChoice.isDockerfileBase(df))
        XCTAssertEqual(df, ImageChoice.dockerfileBase(path: "/Users/x/code/app/./Dockerfile"))
        XCTAssertEqual(ImageChoice.parse(df + "-pi"), ImageChoice(base: df, agent: .pi))
        XCTAssertEqual(ImageChoice(base: "python", agent: .claudeCode).title, "Python · Claude Code")
    }

    /// Every catalogue base × every agent composes into a valid spec: the baseline for its package
    /// manager, the native Claude Code on a base without Node, pi's Node under /opt/node.
    func test_everyPairComposes() throws {
        for b in BaseCatalogue.all {
            for a in AgentKind.allCases {
                let name = ImageChoice(base: b.id, agent: a).name
                let s = try ImageComposer.spec(name: name, base: b.source(), agent: a, release: a == .none ? nil : release, native: native)
                XCTAssertNoThrow(try s.validate(), name)
                let script = s.steps.map { $0.argv.joined(separator: " ") }.joined(separator: "\n")
                XCTAssertEqual(s.user, "agent")
                XCTAssertTrue(s.sessionEnvironment["PATH"]!.hasPrefix("/home/agent/.local/bin:"), name)
                switch a {
                case .claudeCode where !b.hasNode:
                    XCTAssertTrue(script.contains("downloads.claude.ai/claude-code-releases/2.1.285/"), name)
                    XCTAssertFalse(script.contains("npm install"), "\(name): no Node for Claude Code's sake")
                    XCTAssertTrue(script.contains("python3 /usr/local/lib/dozer/claude-setup.py"), name)
                    XCTAssertEqual(s.bakeHosts, ["downloads.claude.ai"])
                    XCTAssertTrue(script.contains(b.musl ? String(repeating: "b", count: 64) : String(repeating: "a", count: 64)), name)
                case .claudeCode:
                    XCTAssertEqual(s, AgentImages.claudeCode(release))
                case .pi where !b.hasNode:
                    XCTAssertTrue(script.contains("/opt/node"), name)
                    XCTAssertTrue(script.contains("PATH=/opt/node/bin:$PATH exec /opt/node/bin/pi"), name)
                    XCTAssertFalse(s.sessionEnvironment["PATH"]!.contains("/opt/node"), "\(name): Node is pi's, not the sessions'")
                    if b.packageManager == .apt { XCTAssertTrue(script.contains(NodeRuntime.sha256)); XCTAssertEqual(s.bakeHosts, ["nodejs.org"]) }
                case .pi:
                    XCTAssertEqual(s, AgentImages.pi(release))
                case .codex:
                    // 599i: one recipe on every base — the registry's linux-arm64 tarball, integrity-checked.
                    XCTAssertTrue(script.contains("https://registry.npmjs.org/@openai/codex/-/codex-2.1.285-linux-arm64.tgz"), name)
                    XCTAssertTrue(script.contains("[ \"$got\" = 'sha512-AAAA' ]"), name)
                    XCTAssertEqual(s.persistDirs, ["~/.codex"])
                    XCTAssertEqual(s.sessionEnvironment["CODEX_HOME"], "/home/agent/.codex")
                    XCTAssertEqual(s.agent, AgentPackage(package: "@openai/codex", version: "2.1.285"))
                    XCTAssertNil(s.bakeHosts, "\(name): the npm registry is in the bake preset")
                case .none:
                    XCTAssertNil(s.agent)
                    XCTAssertTrue(s.persistDirs.isEmpty)
                }
                if let t = b.toolchain, !(b.id == "node" && a != .none) { XCTAssertTrue(s.verify.contains(t), name) }
                XCTAssertTrue(script.contains(b.packageManager == .apk ? "apk add" : "apt-get install"), name)
            }
        }
        XCTAssertThrowsError(try ImageComposer.spec(name: "go-claude-code", base: BaseCatalogue.base("go")!.source(), agent: .claudeCode,
                                                    release: release, native: nil))
    }

    /// A Dockerfile's base (package manager unknown): the bake looks for apt-get, else apk, and for musl.
    func test_dockerfileBaseDetects() throws {
        let src = BaseSource(reference: "dozer.local/df-0123456789ab@sha256:" + String(repeating: "c", count: 64), packageManager: .auto,
                             hasNode: false, musl: nil, rootfsMiB: 4096)
        let s = try ImageComposer.spec(name: "df-0123456789ab-claude-code", base: src, agent: .claudeCode, release: release, native: native)
        let script = s.steps.map { $0.argv.joined(separator: " ") }.joined(separator: "\n")
        XCTAssertTrue(script.contains("command -v apt-get"))
        XCTAssertTrue(script.contains("ld-musl-aarch64.so.1"))
        XCTAssertTrue(script.contains(String(repeating: "a", count: 64)) && script.contains(String(repeating: "b", count: 64)))
    }

    /// The Python launcher writes the same keys the Node one does.
    func test_nativeLauncherWritesTheSameKeys() {
        let js = AgentImages.launcherScript(.node), py = AgentImages.launcherScript(.python)
        for k in ["hasCompletedOnboarding", "customApiKeyResponses", "hasTrustDialogAccepted", "skipDangerousModePermissionPrompt", "approved", "rejected"] {
            XCTAssertTrue(js.contains(k) && py.contains(k), k)
        }
        XCTAssertTrue(py.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(py.contains("require('fs')"))
        XCTAssertFalse(py.contains("ANTHROPIC_API_KEY"), "spelled apart")
    }

    func test_nativeManifestParses() throws {
        let doc = #"{"version":"2.1.285","platforms":{"linux-arm64":{"checksum":"\#(String(repeating: "A", count: 64))"},"linux-arm64-musl":{"checksum":"\#(String(repeating: "b", count: 64))"},"darwin-arm64":{"checksum":"x"}}}"#
        let b = try NativeClaudeBuild.parse(Data(doc.utf8), version: "2.1.285")
        XCTAssertEqual(b.sha256["linux-arm64"], String(repeating: "a", count: 64))
        XCTAssertThrowsError(try NativeClaudeBuild.parse(Data(doc.utf8), version: "2.1.286"))
        XCTAssertThrowsError(try NativeClaudeBuild.parse(Data(#"{"version":"2.1.285","platforms":{"linux-arm64":{"checksum":"'; rm -rf /"}}}"#.utf8), version: "2.1.285"))
        XCTAssertTrue(NativeClaudeBuild.pinned.isWellFormed)
        XCTAssertEqual(NativeClaudeBuild.pinned.version, AgentImages.claudeCodePinned.version)
    }

    func test_policies() {
        let bake = NetworkPolicy.bake(adding: ["downloads.claude.ai"])
        XCTAssertEqual(bake.preset, "bake")
        XCTAssertEqual(bake.evaluateConnection(host: "downloads.claude.ai", port: 443).kind, .allow)
        XCTAssertEqual(NetworkPolicy.bake.evaluateConnection(host: "downloads.claude.ai", port: 443).kind, .deny)
        let go = NetworkPolicy.agent.adding(registries: BaseCatalogue.base("go")!.registries)
        XCTAssertEqual(go.preset, "agent")
        XCTAssertEqual(go.evaluateConnection(host: "proxy.golang.org", port: 443).kind, .allow)
        XCTAssertEqual(NetworkPolicy.locked.adding(registries: BaseCatalogue.base("go")!.registries), .locked)
        XCTAssertEqual(NetworkPolicy.open.adding(registries: BaseCatalogue.base("go")!.registries), .open)
        var bad = AgentImages.pi
        bad.bakeHosts = ["*.evil.com"]
        XCTAssertThrowsError(try bad.validate())
    }
}
