# deckhold — provenance of the committed binary

`Sources/DozerKit/Resources/deckhold` is a **committed build artefact**: the guest-side
PTY holder every sandbox installs at `/usr/local/bin/deckhold` on start. It is the pin, the way a
vendored xcframework is — consumers never need Zig or the ghostty source. This file records exactly
what produced it; `make deckhold` rewrites the two lines marked (auto) after a rebuild, and
`make deckhold-verify` rebuilds from scratch and checks the committed bytes match.

| | |
|---|---|
| sha256 (auto) | `dff796d37bbc2973ebbd646c23fc32ecb9fc426ffa3ba1c5a6f751b9804ffc53` |
| size (auto) | 1604264 bytes |
| format | ELF 64-bit LSB executable, ARM aarch64, statically linked (musl), stripped |
| source | [`deckhold.c`](deckhold.c) (this directory) |
| Zig | 0.16.0 — `zig-aarch64-macos-0.16.0.tar.xz`, sha256 `b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489` |
| ghostty | `b988efcfe584e88a3d0330e2c17c386ffa419d72` (2026-07-22) — why this commit: see [`build.sh`](build.sh) |
| libghostty-vt | `zig build -Demit-lib-vt=true -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast` |
| deckhold | `zig cc -target aarch64-linux-musl -static -O2 -s -Wall -Wextra -Wno-unused-parameter -I<vt>/include deckhold.c <vt>/lib/libghostty-vt.a -lc++` |
| reproducible | yes — two `FORCE=1` rebuilds on the M3 (2026-09-25) produced identical bytes; 610 (2026-10-08, M4): `make deckhold` then `make deckhold-verify` (a `FORCE=1` rebuild; Zig and ghostty fetched fresh into `.tools/` that day) — identical |
| tested | `make deckhold-snapshot-check` (610): this source against a Mac build of the same ghostty commit — every SNAPSHOT replayed on a fresh emulator equals the holder's screen cell by cell (fixed cases + 20,000 seeded fuzz screens × size changes; 0.30.1's source: ~45 % of them a row off) |

Rebuild: `make deckhold` (first run downloads Zig and a blobless ghostty clone into the gitignored
`.tools/`, ~3.5 min; `DECKHOLD_TOOLS=<dir>` reuses an existing toolchain directory of the same
layout). Built on macOS (arm64) for the Linux guest; nothing is installed system-wide.

Licences of what the binary contains: deckhold itself (MIT, this package), libghostty-vt and its
bundled simdutf/highway (MIT / Apache-2.0 / MIT — see `LICENCES.md`), musl libc (MIT), LLVM libc++
(Apache-2.0 with LLVM exception), all statically linked by Zig.
