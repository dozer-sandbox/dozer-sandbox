#!/bin/bash
# Build `dozview` — the guest half of workspace rules (.dozignore / .dozreadonly): a filtering view of a
# virtio-fs share over the raw /dev/fuse protocol — as ONE static aarch64-linux-musl binary:
# Guest/dozview/out/dozview. libc, pthreads and Linux UAPI headers only (no libfuse, no third-party
# code), with the SAME pinned Zig as deckhold (Guest/deckhold/build.sh downloads it into
# $TOOLS/zig-0.16.0 on first use). The matcher (match/dozmatch.c) is the same file the unit tests run
# against the real-Docker vectors on the Mac.
#
# The COMMITTED binary is Sources/DozerKit/Resources/dozview; `make dozview` runs this, installs the
# result there and refreshes PROVENANCE.md; `make dozview-verify` rebuilds and compares.
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
SRC=("$HERE/dozview.c" "$HERE"/match/*.c)
newer=0
for s in "${SRC[@]}" "$HERE"/match/*.h "$HERE"/match/include/*.h; do
  [ "$s" -nt "$HERE/out/dozview" ] && newer=1
done
if [ "${FORCE:-0}" = 1 ] || [ ! -x "$HERE/out/dozview" ] || [ "$newer" = 1 ]; then
  echo "==> compiling dozview"
  # The paths are made relative so the binary does not record this checkout's location (reproducible).
  (cd "$HERE" && "$ZIG" cc -target aarch64-linux-musl -static -O2 -s -Wall -Wextra -Wno-unused-parameter \
    -I match/include dozview.c match/*.c -o out/dozview)
  echo "==> $HERE/out/dozview ($(wc -c < "$HERE/out/dozview" | tr -d ' ') bytes)"
fi
echo "$HERE/out/dozview"
