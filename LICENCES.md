# Licences

Dozer Sandbox (`doz`) itself is **MIT** — see [`LICENSE`](LICENSE). [`NOTICE`](NOTICE) carries the
attributions its Apache-2.0 dependencies require.

Every release ships, in `libexec/doz/licences/`, `LICENSE`, `NOTICE` and `THIRD-PARTY-LICENSES.txt` — the
complete licence text and the verbatim NOTICE file of every Swift package below, taken from the exact
checkout the release was built from, plus the guest binaries' and the dashboard's vendored components'
licences. `Scripts/third-party-licences.sh` writes them and **fails the release** when a pin in
`Package.resolved` has no licence file.

**Licence texts no checkout carries** — BoringSSL's and LibYAML's, and those of the code this project ports (Go,
moby/patternmatcher, fsutil) — are in [`Licences/`](Licences/SOURCES.md), fetched verbatim from upstream at the exact
revision named there with each file's sha256 (`make audit` checks them).

**How this table was checked** (2026-10-08, for 0.31.0): each row against `Package.resolved` (the version),
the licence file in the resolved checkout (`.build/checkouts/<name>`), whether a `NOTICE` file exists there,
and whether the component is actually linked into `doz` (its symbols in the binary). **Verified** means all of
that was looked at; **UNVERIFIED** names exactly what was not, and is a release follow-up — never read it as
"probably fine". (None is left: the three found on 2026-10-08 — BoringSSL's text, LibYAML's notice, the ported matcher — are
resolved below.)

## What the `doz` program links (Swift packages, host side)

All resolved through `apple/containerization` (pinned **exactly**) and the apple/* packages it already
resolves, plus Yams. The system `SQLite3` (macOS, public domain), `dnssd`, `CoreServices` and the Apple
frameworks are the OS's and are not redistributed.

| Component | Version | Licence | NOTICE | Checked |
|---|---|---|---|---|
| [apple/containerization](https://github.com/apple/containerization) | 0.47.0 | Apache-2.0 | — | Verified |
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | — | Verified |
| [jpsim/Yams](https://github.com/jpsim/Yams) (the CLI's `doz_project.yaml` only) | 6.2.2 | MIT; it vendors LibYAML (`Sources/CYaml`, MIT, linked) | — | Verified — Yams's own MIT text from the checkout; LibYAML's MIT licence (Copyright (c) 2006 Kirill Simonov) fetched from upstream at 0.1.7, the release current when Yams imported it (2016-11-19, Yams `f7165ec`; Yams records no version): `Licences/libyaml-0.1.7.LICENSE` (source + sha256 in `Licences/SOURCES.md`) |
| [grpc/grpc-swift-2](https://github.com/grpc/grpc-swift-2), grpc-swift-nio-transport, grpc-swift-protobuf | 2.4.3, 2.10.0, 2.4.1 | Apache-2.0 | yes (`NOTICES.txt`) | Verified |
| [apple/swift-nio](https://github.com/apple/swift-nio) | 2.103.0 | Apache-2.0; contains llhttp (MIT), FreeBSD `sha1.c` (BSD), uSHET `cpp_magic.h` (MIT) | yes | Verified |
| apple/swift-nio-extras, swift-nio-http2 | 1.35.1, 1.46.0 | Apache-2.0 | yes | Verified |
| [apple/swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | 2.37.5 | Apache-2.0; **contains BoringSSL** (`CNIOBoringSSL`, linked): OpenSSL + SSLeay licences for the OpenSSL-derived files, ISC for Google's, MIT for third_party/fiat | yes | Verified — BoringSSL's `LICENSE` fetched at the exact vendored revision `817ab07ebb53da35afea409ab9328f578492832d` (`Sources/CNIOBoringSSL/hash.txt`): `Licences/boringssl-817ab07e….LICENSE`, URL + sha256 in `Licences/SOURCES.md` |
| apple/swift-nio-transport-services | 1.28.0 | Apache-2.0 | — | Verified |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 | Apache-2.0; `_CryptoExtras` **contains BoringSSL** (`CCryptoBoringSSL`, linked via swift-certificates) — licences as above | yes | Verified — BoringSSL's `LICENSE` at the vendored revision `0226f30467f540a3f62ef48d453f93927da199b6`: `Licences/boringssl-0226f304….LICENSE` (`Licences/SOURCES.md`). Its XKCP (Keccak) is not linked. |
| apple/swift-certificates, swift-asn1 | 1.21.0, 1.7.3 | Apache-2.0 (swift-certificates contains code derived from musl libc, MIT) | yes | Verified |
| swift-server/async-http-client | 1.36.1 | Apache-2.0 | yes | Verified |
| apple/swift-protobuf | 1.38.1 | Apache-2.0 | — | Verified |
| apple/swift-log, swift-distributed-tracing, swift-service-context, swift-server/swift-service-lifecycle, apple/swift-configuration | 1.15.1, 1.5.0, 1.3.0, 2.12.0, 1.2.1 | Apache-2.0 | swift-log, service-context, service-lifecycle, configuration: yes | Verified |
| apple/swift-collections, swift-algorithms, swift-async-algorithms, swift-atomics, swift-numerics, swift-system | 1.7.0, 1.2.1, 1.1.6, 1.3.1, 1.1.1, 1.8.1 | Apache-2.0 | — | Verified |
| apple/swift-http-types, swift-http-structured-headers | 1.8.0, 1.7.0 | Apache-2.0 | swift-http-types: yes | Verified |
| [facebook/zstd](https://github.com/facebook/zstd) | 1.5.7 | BSD-3-Clause OR GPL-2.0 — **used under BSD-3-Clause** (the `LICENSE` file is bundled, not `COPYING`) | — | Verified |
| `Sources/DozerKit/DockerIgnore.swift` — Docker's `.dockerignore` semantics, in `doz` | — | a port of moby/patternmatcher v0.6.1 (**Apache-2.0**, Docker, Inc. — its NOTICE), tonistiigi/fsutil's filter rule (**MIT**) and Go's `path`/`path/filepath` (**BSD-3-Clause**) | moby: yes | Verified — header states it; texts in `Licences/` at pinned revisions (`Licences/SOURCES.md`) and in the release bundle |
| The case-folding tables (`Sources/DozerKit/DozFoldTables.swift`, generated by `Scripts/gen-dozfold-tables.py`) | — | data derived from the Unicode Character Database: Unicode License v3 | — | Verified (attribution in THIRD-PARTY-LICENSES.txt) |

## The guest binaries (committed, copied into each sandbox)

Static aarch64-linux-musl executables built with the pinned Zig 0.16.0 (`make deckhold|doznet|dozview`;
`make *-verify` rebuilds and compares bytes). Each has a `PROVENANCE.md` beside its source.

| Component | Licence | Checked |
|---|---|---|
| deckhold (`Guest/deckhold/deckhold.c`) — the session holder | MIT (this project) | Verified |
| doznet (`Guest/doznet/doznet.c`) — the proxied network's guest half | MIT (this project) | Verified |
| dozview (`Guest/dozview/`) — the workspace-rules view | MIT (this project) **except its matcher**: `match/dozre.c` is a port of Go's `regexp/syntax` — **BSD-3-Clause**, Copyright 2009 The Go Authors; `match/dozmatch.c` ports moby/patternmatcher v0.6.1 (**Apache-2.0**, Docker, Inc.; its NOTICE) and Go's `path`/`path/filepath` (BSD-3-Clause) | Verified — the licence texts are in each file's header and in `Licences/` (fetched at pinned revisions, `Licences/SOURCES.md`), and in every release's bundle. The header change was proved not to change the committed binary (`make dozview-verify`: byte-identical). |
| libghostty-vt ([Ghostty](https://github.com/ghostty-org/ghostty) at `b988efc`), in deckhold | MIT | Verified (statically linked, `-Demit-lib-vt=true`) |
| simdutf (bundled in libghostty-vt) | Apache-2.0 OR MIT — used under MIT | Verified |
| Highway (bundled in libghostty-vt) | Apache-2.0 OR BSD-3-Clause — used under Apache-2.0 | Verified |
| LLVM libc++ / libc++abi / libunwind (Zig's), in deckhold | Apache-2.0 WITH LLVM-exception | Verified |
| musl libc (Zig 0.16.0's aarch64-linux-musl), in all three | MIT | Verified |
| Zig 0.16.0 | MIT | build tool only — not redistributed |

## The dashboard (vendored, served to the browser by `doz ui` / `doz serve`)

| Component | Licence | Checked |
|---|---|---|
| [ghostty-web](https://github.com/coder/ghostty-web) 0.4.0 (Coder) — `WebSource/vendor/ghostty-web/`, embedding Ghostty's VT parser as WebAssembly | MIT (ghostty-web); MIT (Ghostty) | Verified — byte-identical to the npm tarball (`VENDOR.json` pins its integrity and each file's sha256); the licence ships in `Resources/Web/licences/` and the bundle |
| [Lucide](https://lucide.dev) icons — `lucide-static` 1.48.0, 49 SVGs compiled into one sprite | ISC | Verified — as above |
| The app icons (`WebSource/icons/`) | MIT (this project) | Verified — drawn here (`PROVENANCE.json`) |

## Downloaded at run time — not in this repository, not in a release

| Component | Licence | How |
|---|---|---|
| Linux `vmlinux-6.18.15-186` from [kata-containers 3.28.0](https://github.com/kata-containers/kata-containers/releases/tag/3.28.0) | **GPL-2.0-only** (with the syscall note) | `KernelProvider` downloads the upstream release archive (`kata-static-3.28.0-arm64.tar.zst`) on the Mac that runs doz and uses the kernel **unmodified**, verified by sha256. Dozer does not redistribute it: no release carries it. (A public build also carries no other kernel: the experimental sound kernel is only in private builds.) Its source: the kata-containers 3.28.0 kernel build (`tools/packaging/kernel`) on Linux 6.18.15. |
| `ghcr.io/apple/containerization/vminit` (the guest init image) | Apache-2.0 (Apple) | pulled from its registry by Containerization |
| The base images a sandbox uses (`node`, `debian`, `alpine`, `python`, `golang` … from Docker Hub) and the packages installed in them | their own | pulled from their registries into your store |
| The agents installed into images: Claude Code, pi, Codex — from npm / downloads.claude.ai | their own (Claude Code is Anthropic's, under its own terms) | installed by your Mac into your sandboxes; never bundled |
| `gh` 2.102.0 (the tools layer), Node.js tarballs (pi on a base without Node), Apple's `container` installer (asked for) | MIT; MIT; Apache-2.0 | downloaded, checksum-verified, on request or when a setting needs them |

## Test data

`Tests/Fixtures/dozignore-vectors.json` and `dozfold-vectors.json` are outputs recorded from running real
Docker/BuildKit and the Unicode data — facts about their behaviour, not their code.
