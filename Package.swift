// swift-tools-version: 6.2
// SnoozeContainerKit — a pausable Linux sandbox for macOS: one container in its own VM through
// Apple's Containerization package, with pause/resume in ~1 ms, sleep to disk that frees the RAM,
// wake in ~0.35 s, restore after a host crash, and terminal sessions (the `deckhold` guest PTY
// holder) that survive every one of those.
//
// Stand-alone: no knowledge of any host app. macOS 26+ only — Virtualization.framework and vmnet
// have no Linux equivalent, so there is no Linux build of this package at all.
//
// ONE remote dependency, pinned EXACTLY: apple/containerization 0.47.0. The sleep design leans on
// its internals' shape (a `VZVirtualMachineInstance` behind `withVirtualMachineInstance`, the
// `VZInstanceExtension` hook, the `VirtualMachineManager`/`VirtualMachineAgent` protocols), so a
// minor bump is a deliberate re-verification (run `make test-vm`), never a silent resolve.
import PackageDescription

let package = Package(
    name: "SnoozeContainerKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SnoozeContainerKit", targets: ["SnoozeContainerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.47.0"),
    ],
    targets: [
        .target(
            name: "SnoozeContainerKit",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ],
            path: "Sources/SnoozeContainerKit",
            resources: [
                // The guest PTY holder: a static aarch64-linux-musl ELF, committed as the pin
                // (Resources/PROVENANCE.md records sha256, toolchain and command; the C source
                // and build script live in Guest/deckhold/). Copied, never processed.
                .copy("Resources/deckhold"),
            ]
        ),
        // The ENTITLED test host. `swift test` binaries cannot carry
        // `com.apple.security.virtualization`, so the VM integration tests live in this small
        // executable, which `make test-vm` builds, ad-hoc signs with
        // `Scripts/vmtest.entitlements`, and runs under a watchdog. See CLAUDE.md.
        .executableTarget(
            name: "snooze-vmtest",
            dependencies: ["SnoozeContainerKit"],
            path: "Sources/snooze-vmtest"
        ),
        .testTarget(
            name: "SnoozeContainerKitTests",
            dependencies: ["SnoozeContainerKit"],
            path: "Tests/SnoozeContainerKitTests"
        ),
    ]
)
