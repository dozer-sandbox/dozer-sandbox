# doznet — provenance of the committed binary

`Sources/DozerKit/Resources/doznet` is a **committed build artefact**: the guest half of
a proxied sandbox's network (feature 580), installed at `/usr/local/bin/doznet` on every fresh
boot of a sandbox whose `SandboxSpec.network` is `.proxied(…)` (and in a proxied bake VM). It is the
pin, like `deckhold`; consumers never need Zig. `make doznet` rewrites the (auto) lines after a
rebuild; `make doznet-verify` rebuilds from scratch and checks the committed bytes match.

| | |
|---|---|
| sha256 (auto) | `160107d3f8143d2b1a4390491fcdb420ef8b1999b410fd1960194ceef6153cfb` |
| size (auto) | 73360 bytes |
| format | ELF 64-bit LSB executable, ARM aarch64, statically linked (musl), stripped |
| source | [`doznet.c`](doznet.c) (this directory) — libc and Linux UAPI headers only |
| Zig | 0.16.0 — the same pinned toolchain as deckhold (see `../deckhold/build.sh`) |
| command | `zig cc -target aarch64-linux-musl -static -O2 -s -Wall -Wextra -Wno-unused-parameter doznet.c` |
| reproducible | yes — two `FORCE=1` rebuilds (2026-09-25 on the M3; 2026-09-29 after the 592 rename to doznet) produced identical bytes |

What it does (details in the source header): listens on 127.0.0.1:3128 (HTTP proxy), :3129
(transparent TCP, via a nat OUTPUT REDIRECT it installs with `IPT_SO_SET_REPLACE` — no iptables
binary needed) and :53/udp (DNS); relays each over vsock to the host's `EgressProxy` (CID 2, port
5800); adds a default route via `lo` and REJECTs non-loopback UDP. It decides nothing — the host does.
`doznet agent -s SOCKET` (599d) is the guest half of the user's forwarded SSH agent, started only while
`sandbox.ssh_agent` is on: a unix socket whose every connection is relayed as it is over vsock (port
5801) to the host, which connects it to the Mac's ssh-agent.

Licences: doznet itself (MIT, this package) and musl libc (MIT), statically linked by Zig.
