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
            dependencies: ["SnoozeContainerKit", .product(name: "Containerization", package: "containerization")],
            path: "Sources/snooze-vmtest"
        ),
        .testTarget(
            name: "SnoozeContainerKitTests",
            dependencies: ["SnoozeContainerKit",
                           .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOEmbedded", package: "swift-nio"),
                           .product(name: "NIOSSL", package: "swift-nio-ssl")],
            path: "Tests/SnoozeContainerKitTests"
        ),
    ]
)
