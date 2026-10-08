#!/bin/bash
# Build `deckhold` — the guest-side PTY holder on headless libghostty-vt — as ONE static
# aarch64-linux-musl binary: Guest/deckhold/out/deckhold. Idempotent: every step is skipped when
# its output already exists, so a rebuild with nothing changed takes well under a second.
#
# The COMMITTED binary is Sources/DozerKit/Resources/deckhold (the pin, like a vendored
# xcframework); `make deckhold` runs this and installs the result there + refreshes PROVENANCE.md,
# `make deckhold-verify` rebuilds from scratch and checks the committed bytes match.
#
# Inputs (all pinned here; nothing is installed system-wide, nothing comes from Homebrew):
#   ZIG_VERSION   0.16.0 — ghostty's build.zig.zon `minimum_zig_version` at the pinned commit.
#                 Tarball + sha256 from https://ziglang.org/download/index.json (aarch64-macos).
#   GHOSTTY_SHA   b988efcfe584e88a3d0330e2c17c386ffa419d72 (2026-07-22, "fix some 0.16
#                 translation regressions"). Why this commit: the macOS xcframework we vendor in
#                 repo/lib/GhosttyTerminalKit (Vendor/GhosttyVt, `tip` captured 2026-07-21) has
#                 headers byte-identical to f2a7652..a77c706; b988efc is the next commit and
#                 changes include/ghostty/vt only in the kitty temp-file-medium option (unused
#                 here), while fixing Terminal.resize() on the ALTERNATE screen under Zig 0.16 —
#                 exactly the path deckhold takes when a client attaches at a new size while a
#                 full-screen program runs. The next include/ change (03d5fa2, 2026-07-27) moves
#                 the scrollback limit out of GhosttyTerminalOptions, i.e. breaks our API shape.
#   Network       first run only: Zig (~52 MB) + a blobless ghostty clone + zig package fetches
#                 (into .tools/zig-cache, not ~/.cache).
# Outputs (TOOLS defaults to <package>/.tools; DECKHOLD_TOOLS=<dir> points it at an existing
# toolchain directory of the same layout, e.g. a probe's, to skip the ~3.5 min first download):
#   $TOOLS/zig-0.16.0/          the toolchain          (gitignored)
#   $TOOLS/ghostty-src/         ghostty at GHOSTTY_SHA (gitignored)
#   $TOOLS/ghostty-vt-linux/    lib/libghostty-vt.a + include/ for aarch64-linux-musl
#   Guest/deckhold/out/deckhold the static guest binary (gitignored)
#
# Usage: Guest/deckhold/build.sh    (FORCE=1 rebuilds deckhold; delete $TOOLS/ghostty-vt-linux
#                                    to rebuild the library)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
TOOLS="${DECKHOLD_TOOLS:-$PKG/.tools}"
OUT="$HERE/out"

ZIG_VERSION="0.16.0"
ZIG_TARBALL="zig-aarch64-macos-$ZIG_VERSION.tar.xz"
ZIG_URL="https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL"
ZIG_SHA256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_SHA="b988efcfe584e88a3d0330e2c17c386ffa419d72"

TARGET="aarch64-linux-musl"
ZIG_DIR="$TOOLS/zig-$ZIG_VERSION"
ZIG="$ZIG_DIR/zig"
SRC="$TOOLS/ghostty-src"
VT="$TOOLS/ghostty-vt-linux"
# Keep Zig's global package cache inside .tools too, so the build leaves nothing in ~/.cache.
export ZIG_GLOBAL_CACHE_DIR="$TOOLS/zig-cache"
# ghostty's build.zig shells out to a bare `zig env`, so the pinned zig must be first on PATH.
export PATH="$ZIG_DIR:$PATH"

mkdir -p "$TOOLS" "$OUT"

# 1. Zig, pinned, checksum-verified.
if [ ! -x "$ZIG" ]; then
  echo "==> downloading Zig $ZIG_VERSION"
  curl -fsSL -o "$TOOLS/$ZIG_TARBALL" "$ZIG_URL"
  GOT="$(shasum -a 256 "$TOOLS/$ZIG_TARBALL" | awk '{print $1}')"
  [ "$GOT" = "$ZIG_SHA256" ] || { echo "Zig tarball sha256 mismatch: $GOT"; exit 1; }
  tar -xJf "$TOOLS/$ZIG_TARBALL" -C "$TOOLS"
  mv "$TOOLS/zig-aarch64-macos-$ZIG_VERSION" "$ZIG_DIR"
  rm -f "$TOOLS/$ZIG_TARBALL"
fi

# 2. ghostty source at the pinned commit (blobless clone; checkout fetches only what it needs).
if [ ! -d "$SRC/.git" ]; then
  echo "==> cloning ghostty (blobless)"
  git clone -q --filter=blob:none --no-checkout "$GHOSTTY_REPO" "$SRC"
fi
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$GHOSTTY_SHA" ]; then
  echo "==> checking out ghostty $GHOSTTY_SHA"
  git -C "$SRC" fetch -q origin "$GHOSTTY_SHA" 2>/dev/null || true
  git -C "$SRC" -c advice.detachedHead=false checkout -q "$GHOSTTY_SHA"
  rm -rf "$VT"                                  # a different source means a different library
fi

# 3. libghostty-vt as a static library for the guest. `-Demit-lib-vt=true` is ghostty's own
#    "libghostty-vt only" mode (no app, no xcframework, no docs); the install step then writes
#    lib/libghostty-vt.a (its SIMD deps — simdutf, highway — combined into the one archive) and
#    include/ghostty/vt/*.h. ReleaseFast: the holder is on the hot path of every output byte.
if [ ! -f "$VT/lib/libghostty-vt.a" ]; then
  echo "==> building libghostty-vt for $TARGET (first time: a few minutes)"
  T0=$(date +%s)
  ( cd "$SRC" && "$ZIG" build -Demit-lib-vt=true -Dtarget="$TARGET" -Doptimize=ReleaseFast \
      --prefix "$VT" -j8 )
  echo "==> libghostty-vt built in $(( $(date +%s) - T0 )) s"
fi

# 4. deckhold itself: one C file, statically linked against musl + libghostty-vt. The archive
#    carries simdutf (C++), hence -lc++ (zig ships a static libc++ for the target).
if [ "${FORCE:-0}" = 1 ] || [ ! -x "$OUT/deckhold" ] || [ "$HERE/deckhold.c" -nt "$OUT/deckhold" ] \
   || [ "$VT/lib/libghostty-vt.a" -nt "$OUT/deckhold" ]; then
  echo "==> compiling deckhold"
  "$ZIG" cc -target "$TARGET" -static -O2 -s -Wall -Wextra -Wno-unused-parameter \
    -I"$VT/include" "$HERE/deckhold.c" "$VT/lib/libghostty-vt.a" -lc++ -o "$OUT/deckhold"
  echo "==> $OUT/deckhold ($(wc -c < "$OUT/deckhold" | tr -d ' ') bytes)"
fi
echo "$OUT/deckhold"
