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

One direct dependency, pinned exactly; everything below it is transitive.

| Component | Licence | Notes |
|---|---|---|
| [apple/containerization](https://github.com/apple/containerization) 0.47.0 | Apache-2.0 | the VM + container runtime; the direct dependency |
| grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf | Apache-2.0 | vminitd client transport |
| swift-nio, swift-nio-extras, swift-nio-http2, swift-nio-ssl, swift-nio-transport-services | Apache-2.0 | |
| swift-protobuf | Apache-2.0 | |
| async-http-client | Apache-2.0 | image pulls |
| swift-crypto, swift-certificates, swift-asn1 | Apache-2.0 | |
| swift-log, swift-distributed-tracing, swift-service-context, swift-service-lifecycle, swift-configuration | Apache-2.0 | |
| swift-collections, swift-algorithms, swift-async-algorithms, swift-atomics, swift-numerics, swift-system | Apache-2.0 | |
| swift-argument-parser, swift-http-types, swift-http-structured-headers | Apache-2.0 | |
| [zstd](https://github.com/facebook/zstd) 1.5.7 | BSD-3-Clause OR GPL-2.0 | dual-licensed upstream; used under BSD-3-Clause |

Run-time downloads (not redistributed by this package): the guest init image
`ghcr.io/apple/containerization/vminit` (Apache-2.0, Apple), the OCI image a spec names (Alpine by
default: its packages carry their own licences), and the Linux kernel Apple's `container` CLI
installs (GPL-2.0, supplied by the host, never bundled here).
