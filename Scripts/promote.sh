#!/bin/bash
# promote.sh — 611: move a published build to a wider channel (`make promote BUILD=N CHANNEL=beta|stable`).
#
# PROMOTE, DON'T REBUILD. A build is built, signed and notarised once; it moves canary → beta → stable by editing ONE
# field of its fragment (the entry's signature does not cover the channel, so the key is not needed). The bytes a
# stable user installs are the bytes that soaked on canary. So this never builds, signs, re-uploads or touches the
# GitHub release: it edits the fragment, re-renders v1/feed.json, rewrites the channel formulas (each channel's newest
# build) and commits (PUSH=1 pushes). Refused: a build that was never published, and NARROWING a channel.
# Idempotent: promoting a build to where it already is changes nothing. macOS bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
say() { printf '%s\n' "$*"; }
fail() { printf 'x promote: %s\n' "$*" >&2; exit 1; }

BUILD="${BUILD:-}"; VERSION="${VERSION:-}"; CHANNEL="${CHANNEL:-}"; PUSH="${PUSH:-}"
UPDATES_DIR="${UPDATES_DIR:-${TMPDIR:-/tmp/}doz-updates-site}"
TAP_DIR="${TAP_DIR:-${TMPDIR:-/tmp/}doz-homebrew-tap}"
REPOSITORY="${REPOSITORY:-$(sed -n 's/.*static let repository = "\([^"]*\)".*/\1/p' Sources/DozerHost/Updates.swift | head -1)}"
ITEMS="$UPDATES_DIR/v1/items"
# VERSION= instead of BUILD= (the ship knows the version, not the build number).
if [[ -z "$BUILD" && -n "$VERSION" ]]; then
    BUILD="$(python3 Scripts/feed.py build-of --items "$ITEMS" --version "$VERSION" 2>/dev/null || true)"
    [[ -n "$BUILD" ]] || fail "doz $VERSION is not in the feed ($ITEMS) — make publish puts it there first"
fi
case "$BUILD" in ''|*[!0-9]*) fail "BUILD=<n> or VERSION=<published version> (make promote BUILD=4 CHANNEL=beta; the feed's builds: ls $UPDATES_DIR/v1/items)";; esac
case "$CHANNEL" in stable|beta|canary) ;; *) fail "CHANNEL is stable, beta or canary";; esac
# PUSH=1 means a real feed: both must be git checkouts with an origin (checked before anything is written).
if [[ -n "$PUSH" ]]; then
    for d in "$UPDATES_DIR" "$TAP_DIR"; do
        git -C "$d" remote get-url origin >/dev/null 2>&1 || fail "PUSH=1 but $d is not a git checkout with an origin (UPDATES_DIR / TAP_DIR in Makefile.config)"
    done
fi
[[ -f "$ITEMS/build-$BUILD.json" ]] || fail "build $BUILD is not in the feed ($ITEMS) — make publish puts a build there first"

VERSION="$(python3 Scripts/feed.py show --items "$ITEMS" --build "$BUILD" --field version)"
say "━━━ promote doz $VERSION (build $BUILD) → $CHANNEL"
python3 Scripts/feed.py set-channel --items "$ITEMS" --build "$BUILD" --channel "$CHANNEL" --date "$(date -u +%Y-%m-%d)"
python3 Scripts/feed.py render --items "$ITEMS" --out "$UPDATES_DIR/v1/feed.json"
python3 Scripts/feed.py formulas --items "$ITEMS" --tap-dir "$TAP_DIR" --template Scripts/homebrew/doz.rb.tmpl \
    --homepage "https://github.com/$REPOSITORY" | sed 's/^/  ✓ formula /'

commit() {
    local dir="$1" msg="$2"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { say "  • $dir is not a git checkout — written, not committed"; return 0; }
    git -C "$dir" add -A
    if [[ -z "$(git -C "$dir" status --porcelain)" ]]; then say "  • $dir already says this — no commit"; return 0; fi
    git -C "$dir" commit --quiet -m "$msg"
    say "  ✓ committed in $dir: $(git -C "$dir" log --oneline -1)"
    if [[ -n "$PUSH" ]]; then git -C "$dir" push --quiet origin HEAD && say "  ✓ pushed $dir"; else say "  • not pushed (PUSH=1 pushes)"; fi
}
commit "$UPDATES_DIR" "promote doz $VERSION (build $BUILD) → $CHANNEL"
commit "$TAP_DIR" "doz $VERSION (build $BUILD) → $CHANNEL"
say ""
say "✓ doz $VERSION (build $BUILD) is on $CHANNEL — nothing was rebuilt, re-signed or re-uploaded."
python3 Scripts/feed.py show --items "$ITEMS" --build "$BUILD" --field history | sed 's/^/  /'
