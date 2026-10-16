// swift-tools-version: 6.2
// DozerKit — the library behind Dozer Sandbox ("Fast, suspendable micro-VMs for your Mac"): one
// container in its own VM, built on Apple's Containerization framework, with pause/resume in ~1 ms,
// sleep to disk that frees the RAM, wake in ~0.35 s, restore after a host crash, and terminal
// sessions (the `deckhold` guest PTY holder) that survive every one of those.
//
// Stand-alone: no knowledge of any host app. macOS 26+ only — Virtualization.framework and vmnet
// have no Linux equivalent, so there is no Linux build of this package at all.
//
// apple/containerization 0.47.0, pinned EXACTLY: the sleep design leans on its internals' shape (a
// `VZVirtualMachineInstance` behind `withVirtualMachineInstance`, the `VZInstanceExtension` hook,
// the `VirtualMachineManager`/`VirtualMachineAgent` protocols), so a minor bump is a deliberate
// re-verification (run `make test-vm`), never a silent resolve. Since 580, also four apple/*
// packages that containerization already resolves (NIO, NIOSSL, X509, ASN1) — for the egress
// proxy's TLS; Scripts/audit.sh holds the allowlist.
import PackageDescription

// The official builds' closed package (anonymous usage statistics and the sign-up — Sources/DozerHost/Usage.swift is
// the open half and decides everything that may be sent). It joins ONLY when DOZ_CLOUD_PACKAGE names it — a local
// path, or a git URL with DOZ_CLOUD_REF (an exact version, or a commit) — which `make release` passes from the
// gitignored Makefile.config. Every other build (contributors, CI, forks, `make cli`) has no such dependency, its
// `doz` installs no sender, and nothing is ever sent. The package must depend on Foundation only.
let cloudSource = Context.environment["DOZ_CLOUD_PACKAGE"].flatMap { $0.isEmpty ? nil : $0 }
let cloudPackage: Package.Dependency? = cloudSource.map { src in
    guard src.contains("://") || src.hasPrefix("git@") else { return .package(path: src) }
    let ref = Context.environment["DOZ_CLOUD_REF"] ?? ""
    if let v = Version(ref) { return .package(url: src, exact: v) }
    return .package(url: src, revision: ref.isEmpty ? "main" : ref)
}
/// SwiftPM's identity of that package: the last path component, without `.git`, lower-cased.
let cloudIdentity: String? = cloudSource.map { src in
    var last = src.split(separator: "/").last.map(String.init) ?? src
    if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
    return last.lowercased()
}

let package = Package(
    name: "DozerKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DozerKit", targets: ["DozerKit"]),
        // 585: the `doz` command-line tool. `make cli` builds it and signs it with the
        // virtualization entitlement (an unsigned build can do everything but boot a VM).
        .executable(name: "doz", targets: ["doz"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.47.0"),
        // 580 — the egress proxy's TLS for credential injection. All four are apple/* packages
        // that containerization 0.47.0 ALREADY pulls into every build (Package.resolved is
        // unchanged by declaring them): NIOSSL (BoringSSL) terminates TLS with in-memory keys — no
        // keychain, no prompts — driven synchronously through NIOEmbedded; swift-certificates
        // issues the per-sandbox CA and its leaves. See README "Dependencies".
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.3"),
        // 585 — the `doz` CLI's argument parsing (subcommands, aliases, --help). Another apple/*
        // package containerization 0.47.0 already resolves (Package.resolved is unchanged by
        // declaring it); only the CLI target imports it, never the library. README "Dependencies".
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // 594 (owner ruling D9) — the project file `doz_project.yaml` (like dbt's dbt_project.yml) is
        // YAML, parsed with Yams (MIT; libyaml inside), pinned EXACTLY. The one dependency that is not
        // an apple/* package; only the CLI's command target imports it (Scripts/audit.sh).
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ] + [cloudPackage].compactMap { $0 },
    targets: [
        .target(
            name: "DozerKit",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                // 583: one shared MultiThreadedEventLoopGroup for every VM instance (SharedEventLoop).
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Sources/DozerKit",
            // 617: the YAML recipe sources — compiled to Recipes/compiled/ (DozerKit embeds the JSON, never parses YAML).
            exclude: ["Recipes/agents", "Recipes/parked"],
            resources: [
                // The guest PTY holder: a static aarch64-linux-musl ELF, committed as the pin
                // (Resources/PROVENANCE.md records sha256, toolchain and command; the C source
                // and build script live in Guest/deckhold/). Copied, never processed.
                .copy("Resources/deckhold"),
                // 580: the guest half of a proxied sandbox's network (Guest/doznet/).
                .copy("Resources/doznet"),
                // 599g: workspace rules' view of a share — a filtering FUSE daemon (Guest/dozview/).
                .copy("Resources/dozview"),
                // 617: the agent recipes and the key providers, compiled in (`PackageResources.<basename>_json`,
                // no Bundle.module). ONE line per file, and every basename unique across Recipes/ — the
                // identifier is the basename (`AgentRecipeTests` checks the list against the folder). A recipe's
                // source is Recipes/agents/VENDOR/PRODUCT.yaml (excluded below); Recipes/compiled/PRODUCT.json is
                // that YAML as JSON (make recipes; RecipeSourceTests checks they agree).
                .embedInCode("Recipes/compiled/claude-code.json"),
                .embedInCode("Recipes/compiled/pi.json"),
                .embedInCode("Recipes/compiled/codex.json"),
                .embedInCode("Recipes/compiled/antigravity.json"),
                .embedInCode("Recipes/compiled/gemini.json"),
                .embedInCode("Recipes/compiled/grok.json"),
                .embedInCode("Recipes/compiled/fabric.json"),
                .embedInCode("Recipes/compiled/openclaw.json"),
                .embedInCode("Recipes/compiled/nanobot.json"),
                .embedInCode("Recipes/compiled/gptme.json"),
                .embedInCode("Recipes/compiled/llm.json"),
                .embedInCode("Recipes/compiled/shell-gpt.json"),
                .embedInCode("Recipes/compiled/zeroclaw.json"),
                .embedInCode("Recipes/compiled/aichat.json"),
                .embedInCode("Recipes/compiled/tgpt.json"),
                .embedInCode("Recipes/compiled/opencode.json"),
                .embedInCode("Recipes/compiled/smolagents.json"),
                .embedInCode("Recipes/compiled/adk.json"),
                .embedInCode("Recipes/compiled/promptfoo.json"),
                .embedInCode("Recipes/compiled/clai.json"),
                .embedInCode("Recipes/compiled/copilot.json"),
                .embedInCode("Recipes/compiled/qwen-code.json"),
                .embedInCode("Recipes/compiled/goose.json"),
                .embedInCode("Recipes/compiled/kilo.json"),
                .embedInCode("Recipes/compiled/mistral-vibe.json"),
                .embedInCode("Recipes/compiled/droid.json"),
                .embedInCode("Recipes/compiled/dirac.json"),
                .embedInCode("Recipes/compiled/kimi-code.json"),
                .embedInCode("Recipes/compiled/cline.json"),
                .embedInCode("Recipes/compiled/openhands.json"),
                .embedInCode("Recipes/compiled/letta-code.json"),
                .embedInCode("Recipes/compiled/docker-agent.json"),
                .embedInCode("Recipes/compiled/nanocoder.json"),
                .embedInCode("Recipes/compiled/mini-swe-agent.json"),
                .embedInCode("Recipes/compiled/open-interpreter.json"),
                .embedInCode("Recipes/compiled/crush.json"),
                .embedInCode("Recipes/compiled/mimo-code.json"),
                .embedInCode("Recipes/compiled/codewhale.json"),
                .embedInCode("Recipes/compiled/maki.json"),
                .embedInCode("Recipes/compiled/omp.json"),
                .embedInCode("Recipes/compiled/tau.json"),
                .embedInCode("Recipes/compiled/stitch.json"),
                .embedInCode("Recipes/compiled/opencode2.json"),
                .embedInCode("Recipes/providers.json"),
                .embedInCode("Recipes/gateways.json"),
                .embedInCode("Recipes/tags.json"),
                .embedInCode("Recipes/known.json"),
                // 617: the icon registry (Recipes/icons/: icons.json + one mono SVG per entry; AgentIconsTests ties it to the folder).
                .embedInCode("Recipes/icons/icons.json"),
                .embedInCode("Recipes/icons/anthropic.svg"),
                .embedInCode("Recipes/icons/openai.svg"),
                .embedInCode("Recipes/icons/google.svg"),
                .embedInCode("Recipes/icons/xai.svg"),
                .embedInCode("Recipes/icons/claude-code.svg"),
                .embedInCode("Recipes/icons/codex.svg"),
                .embedInCode("Recipes/icons/antigravity.svg"),
                .embedInCode("Recipes/icons/gemini-cli.svg"),
                .embedInCode("Recipes/icons/grok-build.svg"),
                .embedInCode("Recipes/icons/pi.svg"),
                .embedInCode("Recipes/icons/fabric.svg"),
                .embedInCode("Recipes/icons/openclaw.svg"),
                .embedInCode("Recipes/icons/nanobot.svg"),
                .embedInCode("Recipes/icons/gptme.svg"),
                .embedInCode("Recipes/icons/llm.svg"),
                .embedInCode("Recipes/icons/shell-gpt.svg"),
                .embedInCode("Recipes/icons/zeroclaw.svg"),
                .embedInCode("Recipes/icons/aichat.svg"),
                .embedInCode("Recipes/icons/tgpt.svg"),
                .embedInCode("Recipes/icons/opencode.svg"),
                .embedInCode("Recipes/icons/smolagents.svg"),
                .embedInCode("Recipes/icons/adk.svg"),
                .embedInCode("Recipes/icons/promptfoo.svg"),
                .embedInCode("Recipes/icons/clai.svg"),
                .embedInCode("Recipes/icons/copilot.svg"),
                .embedInCode("Recipes/icons/qwen-code.svg"),
                .embedInCode("Recipes/icons/goose.svg"),
                .embedInCode("Recipes/icons/kilo.svg"),
                .embedInCode("Recipes/icons/mistral-vibe.svg"),
                .embedInCode("Recipes/icons/droid.svg"),
                .embedInCode("Recipes/icons/dirac.svg"),
                .embedInCode("Recipes/icons/kimi-code.svg"),
                .embedInCode("Recipes/icons/every-code.svg"),
                .embedInCode("Recipes/icons/cline.svg"),
                .embedInCode("Recipes/icons/openhands.svg"),
                .embedInCode("Recipes/icons/codebuddy.svg"),
                .embedInCode("Recipes/icons/letta-code.svg"),
                .embedInCode("Recipes/icons/docker-agent.svg"),
                .embedInCode("Recipes/icons/nanocoder.svg"),
                .embedInCode("Recipes/icons/mini-swe-agent.svg"),
                .embedInCode("Recipes/icons/open-interpreter.svg"),
                .embedInCode("Recipes/icons/crush.svg"),
                .embedInCode("Recipes/icons/mimo-code.svg"),
                .embedInCode("Recipes/icons/codewhale.svg"),
                .embedInCode("Recipes/icons/maki.svg"),
                .embedInCode("Recipes/icons/omp.svg"),
                .embedInCode("Recipes/icons/tau.svg"),
                .embedInCode("Recipes/icons/stitch.svg"),
            ]
        ),
        // 599g — the `.dozignore` matcher in C (Docker's patternmatcher + an RE2-subset engine + Unicode
        // folding), compiled into the guest's dozview and tested here against the same vectors as Swift.
        .target(name: "DozMatch", path: "Guest/dozview/match"),
        // The ENTITLED test host. `swift test` binaries cannot carry
        // `com.apple.security.virtualization`, so the VM integration tests live in this small
        // executable, which `make test-vm` builds, ad-hoc signs with
        // `Scripts/vmtest.entitlements`, and runs under a watchdog. See CLAUDE.md.
        .executableTarget(
            name: "doz-vmtest",
            // DozerHost (585): the `cli` mode decodes the real binary's --json output with its types.
            dependencies: ["DozerKit", "DozerHost", .product(name: "Containerization", package: "containerization")],
            path: "Sources/doz-vmtest"
        ),
        // 585 — the per-user host behind the `doz` CLI: it owns every running VM, the egress
        // proxies, the metrics writer and the shared event-loop group, and serves `<store>/host.sock`
        // (JSON lines + a raw attach relay). Also the client side of that socket. Not a product.
        .target(
            name: "DozerHost",
            dependencies: ["DozerKit"],
            path: "Sources/DozerHost"
        ),
        // 590 — `doz ui`: the local web UI. A CLIENT of the host (host.sock), served by swift-nio's
        // own HTTP/1.1 codec (NIOHTTP1 — part of swift-nio, already resolved; no new package) on
        // 127.0.0.1 only. The page is vanilla HTML/CSS/JS from WebSource/, compiled into the
        // content-hashed, digest-manifested Resources/Web by Scripts/build-web-assets.swift and
        // committed (`make web-assets`; `make web-assets-check` fails on drift). Not a product.
        // 591: + NIOWebSocket (also a module of swift-nio — Package.resolved unchanged) for the
        // browser terminals' socket; the audit confines it to Sources/DozerWeb.
        .target(
            name: "DozerWeb",
            dependencies: ["DozerHost", "DozerKit",
                           .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOPosix", package: "swift-nio"),
                           .product(name: "NIOHTTP1", package: "swift-nio"),
                           .product(name: "NIOWebSocket", package: "swift-nio")],
            path: "Sources/DozerWeb",
            exclude: ["WebSource"],
            resources: [.copy("Resources/Web")]
        ),
        // 585 — the commands (swift-argument-parser), the attach client, the human/JSON output.
        .target(
            name: "DozerCLI",
            dependencies: ["DozerHost", "DozerKit", "DozerWeb",
                           .product(name: "ArgumentParser", package: "swift-argument-parser"),
                           .product(name: "Yams", package: "Yams")],
            path: "Sources/DozerCLI"
        ),
        .executableTarget(
            name: "doz",
            // DozerHost: `Usage.install` — the bridge `main` builds when the official package is present.
            dependencies: ["DozerCLI", "DozerHost", .product(name: "ArgumentParser", package: "swift-argument-parser")]
                + (cloudIdentity.map { [.product(name: "DozerCloud", package: $0)] } ?? []),
            path: "Sources/doz",
            // The bridge in main is compiled ONLY with the package (`#if DOZ_CLOUD`): `canImport` alone is not enough —
            // a module left in .build by an earlier official build would make it true in a build that does not link it.
            swiftSettings: cloudIdentity == nil ? [] : [.define("DOZ_CLOUD")]
        ),
        .testTarget(
            name: "DozerCLITests",
            dependencies: ["DozerCLI", "DozerHost", "DozerKit"],
            path: "Tests/DozerCLITests"
        ),
        // 590 — the web UI's security rules as unit tests, and a real listener driven over HTTP.
        .testTarget(
            name: "DozerWebTests",
            dependencies: ["DozerWeb", "DozerHost", "DozerKit"],
            path: "Tests/DozerWebTests"
        ),
        .testTarget(
            name: "DozerKitTests",
            dependencies: ["DozerKit", "DozMatch",
                           // 587: real ext4 disks, made on the host, for the EXT4Inspector / accounting tests.
                           .product(name: "ContainerizationEXT4", package: "containerization"),
                           .product(name: "ContainerizationArchive", package: "containerization"),
                           .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOEmbedded", package: "swift-nio"),
                           .product(name: "NIOSSL", package: "swift-nio-ssl")],
            path: "Tests/DozerKitTests"
        ),
    ]
)
