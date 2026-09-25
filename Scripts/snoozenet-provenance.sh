#!/usr/bin/env bash
# Rewrite the (auto) lines of Guest/snoozenet/PROVENANCE.md from the committed snoozenet binary.
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$PKG/Sources/SnoozeContainerKit/Resources/snoozenet"
DOC="$PKG/Guest/snoozenet/PROVENANCE.md"
SHA=$(shasum -a 256 "$BIN" | awk '{print $1}')
SIZE=$(wc -c < "$BIN" | tr -d ' ')
sed -i '' -E "s/^\| sha256 \(auto\) \| .*/| sha256 (auto) | \`$SHA\` |/; s/^\| size \(auto\) \| .*/| size (auto) | $SIZE bytes |/" "$DOC"
echo "ok snoozenet: $SHA ($SIZE bytes) recorded in Guest/snoozenet/PROVENANCE.md"
