// swift-tools-version: 6.2
// SnoozeContainerKit — a pausable Linux sandbox for macOS: one container in its own VM through
// Apple's Containerization package, with pause/resume in ~1 ms, sleep to disk that frees the RAM,
// wake in ~0.35 s, restore after a host crash, and terminal sessions (the `deckhold` guest PTY
// holder) that survive every one of those.
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

let package = Package(
    name: "SnoozeContainerKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SnoozeContainerKit", targets: ["SnoozeContainerKit"]),
        // 585: the `snooze` command-line tool. `make cli` builds it and signs it with the
        // virtualization entitlement (an unsigned build can do everything but boot a VM).
        .executable(name: "snooze", targets: ["snooze"]),
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
        // 585 — the `snooze` CLI's argument parsing (subcommands, aliases, --help). Another apple/*
        // package containerization 0.47.0 already resolves (Package.resolved is unchanged by
        // declaring it); only the CLI target imports it, never the library. README "Dependencies".
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SnoozeContainerKit",
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
            path: "Sources/SnoozeContainerKit",
            resources: [
                // The guest PTY holder: a static aarch64-linux-musl ELF, committed as the pin
                // (Resources/PROVENANCE.md records sha256, toolchain and command; the C source
                // and build script live in Guest/deckhold/). Copied, never processed.
                .copy("Resources/deckhold"),
                // 580: the guest half of a proxied sandbox's network (Guest/snoozenet/).
                .copy("Resources/snoozenet"),
            ]
        ),
        // The ENTITLED test host. `swift test` binaries cannot carry
        // `com.apple.security.virtualization`, so the VM integration tests live in this small
        // executable, which `make test-vm` builds, ad-hoc signs with
        // `Scripts/vmtest.entitlements`, and runs under a watchdog. See CLAUDE.md.
        .executableTarget(
            name: "snooze-vmtest",
            // SnoozeHost (585): the `cli` mode decodes the real binary's --json output with its types.
            dependencies: ["SnoozeContainerKit", "SnoozeHost", .product(name: "Containerization", package: "containerization")],
            path: "Sources/snooze-vmtest"
        ),
        // 585 — the per-user host behind the `snooze` CLI: it owns every running VM, the egress
        // proxies, the metrics writer and the shared event-loop group, and serves `<store>/host.sock`
        // (JSON lines + a raw attach relay). Also the client side of that socket. Not a product.
        .target(
            name: "SnoozeHost",
            dependencies: ["SnoozeContainerKit"],
            path: "Sources/SnoozeHost"
        ),
        // 590 — `snooze ui`: the local web UI. A CLIENT of the host (host.sock), served by swift-nio's
        // own HTTP/1.1 codec (NIOHTTP1 — part of swift-nio, already resolved; no new package) on
        // 127.0.0.1 only. The page is vanilla HTML/CSS/JS from WebSource/, compiled into the
        // content-hashed, digest-manifested Resources/Web by Scripts/build-web-assets.swift and
        // committed (`make web-assets`; `make web-assets-check` fails on drift). Not a product.
        .target(
            name: "SnoozeWeb",
            dependencies: ["SnoozeHost", "SnoozeContainerKit",
                           .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOPosix", package: "swift-nio"),
                           .product(name: "NIOHTTP1", package: "swift-nio")],
            path: "Sources/SnoozeWeb",
            exclude: ["WebSource"],
            resources: [.copy("Resources/Web")]
        ),
        // 585 — the commands (swift-argument-parser), the attach client, the human/JSON output.
        .target(
            name: "SnoozeCLI",
            dependencies: ["SnoozeHost", "SnoozeContainerKit", "SnoozeWeb",
                           .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/SnoozeCLI"
        ),
        .executableTarget(
            name: "snooze",
            dependencies: ["SnoozeCLI", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/snooze"
        ),
        .testTarget(
            name: "SnoozeCLITests",
            dependencies: ["SnoozeCLI", "SnoozeHost", "SnoozeContainerKit"],
            path: "Tests/SnoozeCLITests"
        ),
        // 590 — the web UI's security rules as unit tests, and a real listener driven over HTTP.
        .testTarget(
            name: "SnoozeWebTests",
            dependencies: ["SnoozeWeb", "SnoozeHost", "SnoozeContainerKit"],
            path: "Tests/SnoozeWebTests"
        ),
        .testTarget(
            name: "SnoozeContainerKitTests",
            dependencies: ["SnoozeContainerKit",
                           // 587: real ext4 disks, made on the host, for the EXT4Inspector / accounting tests.
                           .product(name: "ContainerizationEXT4", package: "containerization"),
                           .product(name: "ContainerizationArchive", package: "containerization"),
                           .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOEmbedded", package: "swift-nio"),
                           .product(name: "NIOSSL", package: "swift-nio-ssl")],
            path: "Tests/SnoozeContainerKitTests"
        ),
    ]
)
