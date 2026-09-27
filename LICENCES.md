# Licences

`SnoozeContainerKit` itself is MIT — see [`LICENSE`](LICENSE).

Two kinds of third-party material: the Swift packages the host-side library resolves, and what is
statically linked into the **committed guest binary** `Sources/SnoozeContainerKit/Resources/deckhold`
(a Linux executable the library copies into each sandbox; its build is recorded in
[`Guest/deckhold/PROVENANCE.md`](Guest/deckhold/PROVENANCE.md)).

## The guest binary (`deckhold`, vendored)

| Component | Licence | Notes |
|---|---|---|
| deckhold (`Guest/deckhold/deckhold.c`) | MIT | this package's own code |
| libghostty-vt ([ghostty](https://github.com/ghostty-org/ghostty) at `b988efc`) | MIT | Mitchell Hashimoto / Ghostty contributors; built with `-Demit-lib-vt=true`, statically linked |
| simdutf (bundled in libghostty-vt) | Apache-2.0 OR MIT | used under MIT |
| Highway (bundled in libghostty-vt) | Apache-2.0 OR BSD-3-Clause | used under Apache-2.0 |
| musl libc (Zig 0.16.0's aarch64-linux-musl) | MIT | statically linked |
| LLVM libc++ / libc++abi / libunwind (Zig's) | Apache-2.0 WITH LLVM-exception | statically linked (libghostty-vt's simdutf is C++) |
| Zig 0.16.0 | MIT | build tool only; not redistributed |

## Swift package dependencies (host side)

The direct dependencies are apple/containerization, pinned exactly, and five apple/* packages it
already resolves (declared so the code that imports them names them: swift-nio, swift-nio-ssl,
swift-certificates and swift-asn1 for the 580 egress proxy; swift-argument-parser for the 585
`snooze` CLI only). Declaring them added nothing to `Package.resolved`; everything below is the
same resolved set. The `snooze` executable additionally links the system `SQLite3` library (macOS,
public domain).

| Component | Licence | Notes |
|---|---|---|
| [apple/containerization](https://github.com/apple/containerization) 0.47.0 | Apache-2.0 | the VM + container runtime; the direct dependency |
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.8.2 | Apache-2.0 | 585: the `snooze` CLI's command line (direct for the CLI targets only) |
| grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf | Apache-2.0 | vminitd client transport |
| swift-nio, swift-nio-extras, swift-nio-http2, swift-nio-ssl, swift-nio-transport-services | Apache-2.0 | |
| swift-protobuf | Apache-2.0 | |
| async-http-client | Apache-2.0 | image pulls |
| swift-crypto, swift-certificates, swift-asn1 | Apache-2.0 | |
| swift-log, swift-distributed-tracing, swift-service-context, swift-service-lifecycle, swift-configuration | Apache-2.0 | |
| swift-collections, swift-algorithms, swift-async-algorithms, swift-atomics, swift-numerics, swift-system | Apache-2.0 | |
| swift-http-types, swift-http-structured-headers | Apache-2.0 | |
| [zstd](https://github.com/facebook/zstd) 1.5.7 | BSD-3-Clause OR GPL-2.0 | dual-licensed upstream; used under BSD-3-Clause |

## The Linux kernel (downloaded at run time, not in this repository)

| Component | Licence | Notes |
|---|---|---|
| Linux `vmlinux-6.18.15-186` from [kata-containers 3.28.0](https://github.com/kata-containers/kata-containers/releases/tag/3.28.0) (`kata-static-3.28.0-arm64.tar.zst`) | **GPL-2.0-only** (Linux, with the syscall note) | `KernelProvider` downloads the upstream release archive and uses the kernel **unmodified**, verified by sha256 (archive `f63d5450…0e66a91`, kernel `2fe4a58d…c47fc3a1`). It is not committed here or bundled into a consumer by this package. A host that ships the kernel (e.g. pre-seeds a cache in an app bundle) redistributes GPL-2.0 binaries and must offer the corresponding source: the kata-containers 3.28.0 kernel build (`tools/packaging/kernel` at that tag, config + patches) on top of Linux 6.18.15. The rest of the archive (kata runtime, other kernels) is discarded after extraction. |

Other run-time downloads (not redistributed by this package): the guest init image
`ghcr.io/apple/containerization/vminit` (Apache-2.0, Apple) and the OCI image a spec names (Alpine
by default: its packages carry their own licences).
