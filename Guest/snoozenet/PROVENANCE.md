# snoozenet — provenance of the committed binary

`Sources/SnoozeContainerKit/Resources/snoozenet` is a **committed build artefact**: the guest half of
a proxied sandbox's network (feature 580), installed at `/usr/local/bin/snoozenet` on every fresh
boot of a sandbox whose `SandboxSpec.network` is `.proxied(…)` (and in a proxied bake VM). It is the
pin, like `deckhold`; consumers never need Zig. `make snoozenet` rewrites the (auto) lines after a
rebuild; `make snoozenet-verify` rebuilds from scratch and checks the committed bytes match.

| | |
|---|---|
| sha256 (auto) | `8dc024378b8a855fe4e930f41956c451b2c89caf3bae6c3c53708954c2c063df` |
| size (auto) | 70872 bytes |
| format | ELF 64-bit LSB executable, ARM aarch64, statically linked (musl), stripped |
| source | [`snoozenet.c`](snoozenet.c) (this directory) — libc and Linux UAPI headers only |
| Zig | 0.16.0 — the same pinned toolchain as deckhold (see `../deckhold/build.sh`) |
| command | `zig cc -target aarch64-linux-musl -static -O2 -s -Wall -Wextra -Wno-unused-parameter snoozenet.c` |
| reproducible | yes — two `FORCE=1` rebuilds on the M3 (2026-09-25) produced identical bytes |

What it does (details in the source header): listens on 127.0.0.1:3128 (HTTP proxy), :3129
(transparent TCP, via a nat OUTPUT REDIRECT it installs with `IPT_SO_SET_REPLACE` — no iptables
binary needed) and :53/udp (DNS); relays each over vsock to the host's `EgressProxy` (CID 2, port
5800); adds a default route via `lo` and REJECTs non-loopback UDP. It decides nothing — the host does.

Licences: snoozenet itself (MIT, this package) and musl libc (MIT), statically linked by Zig.
