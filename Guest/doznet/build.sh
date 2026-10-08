#!/bin/bash
# Build `doznet` — the guest half of a proxied sandbox's network (feature 580) — as ONE static
# aarch64-linux-musl binary: Guest/doznet/out/doznet. libc + Linux UAPI headers only (no
# ghostty, no third-party code), with the SAME pinned Zig as deckhold (Guest/deckhold/build.sh
# downloads it into $TOOLS/zig-0.16.0 on first use).
#
# The COMMITTED binary is Sources/DozerKit/Resources/doznet; `make doznet` runs this,
# installs the result there and refreshes PROVENANCE.md; `make doznet-verify` rebuilds and compares.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
TOOLS="${DECKHOLD_TOOLS:-$PKG/.tools}"
ZIG="$TOOLS/zig-0.16.0/zig"
if [ ! -x "$ZIG" ]; then
  echo "==> the pinned Zig is missing — running Guest/deckhold/build.sh once downloads it (checksum-verified)"
  exit 1
fi
export ZIG_GLOBAL_CACHE_DIR="$TOOLS/zig-cache" ZIG_LOCAL_CACHE_DIR="$TOOLS/zig-cache-local"
mkdir -p "$HERE/out"
if [ "${FORCE:-0}" = 1 ] || [ ! -x "$HERE/out/doznet" ] || [ "$HERE/doznet.c" -nt "$HERE/out/doznet" ]; then
  echo "==> compiling doznet"
  "$ZIG" cc -target aarch64-linux-musl -static -O2 -s -Wall -Wextra -Wno-unused-parameter \
    "$HERE/doznet.c" -o "$HERE/out/doznet"
  echo "==> $HERE/out/doznet ($(wc -c < "$HERE/out/doznet" | tr -d ' ') bytes)"
fi
echo "$HERE/out/doznet"
