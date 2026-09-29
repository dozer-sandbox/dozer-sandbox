#!/usr/bin/env bash
# Rewrite the (auto) lines of Guest/deckhold/PROVENANCE.md from the committed deckhold binary.
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$PKG/Sources/DozerKit/Resources/deckhold"
DOC="$PKG/Guest/deckhold/PROVENANCE.md"
SHA=$(shasum -a 256 "$BIN" | awk '{print $1}')
SIZE=$(wc -c < "$BIN" | tr -d ' ')
sed -i '' -E "s/^\| sha256 \(auto\) \| .*/| sha256 (auto) | \`$SHA\` |/; s/^\| size \(auto\) \| .*/| size (auto) | $SIZE bytes |/" "$DOC"
echo "ok deckhold: $SHA ($SIZE bytes) recorded in Guest/deckhold/PROVENANCE.md"
