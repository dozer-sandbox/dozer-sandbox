#!/bin/bash
# publish.sh — 611: put a built release on the update feed and the Homebrew tap (`make publish`).
#
#   make publish VERSION=0.31.0 NOTES=notes.md                   # → canary (the default channel)
#   make publish VERSION=0.31.0 NOTES=notes.md CHANNEL=stable
#   make publish … DRY_RUN=1                                     # show what would change, write nothing
#   make promote BUILD=4 CHANNEL=beta                            # Scripts/promote.sh — never rebuilds
#
# It never builds (make release made the tarball) and never creates the GitHub release — it PRINTS that command
# (the release assets live on the public repository; `Distribution.repository`). In order:
#
#   1. the exact tarball dist/doz-V-macos-arm64.tar.gz: its .sha256 matches, it unpacks to a doz that says V,
#      carries the RELEASE marker, verifies (codesign --strict) and — unless TEST_PUBLISH=1 — is the public flavor,
#      signed by Dozer's Developer ID team and notarised (its ticket published — Scripts/notary-ticket.sh);
#   2. the entry is signed with Dozer's update key (the login keychain; a test passes UPDATE_KEY_FILE) and the
#      signature is checked against the public key doz carries (Distribution.updatePublicKey; a test:
#      UPDATE_PUBLIC_KEY) — a key that does not match what doz trusts is refused before anything is written;
#   3. UPDATES_DIR (the Pages repo's checkout): v1/items/build-N.json, v1/notes/V.html, v1/feed.json, CNAME;
#   4. TAP_DIR (the tap's checkout): Formula/doz.rb, doz-beta.rb, doz-canary.rb — each channel's newest build;
#   5. a commit in each that is a git checkout (nothing changed → no commit); pushed only with PUSH=1.
#
# Idempotent: re-running it for a published version changes nothing. A published version is never re-cut.
# UPDATES_DIR and TAP_DIR default to scratch folders until the repositories exist. macOS bash 3.2 — no bash 4.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
say() { printf '%s\n' "$*"; }
fail() { printf 'x publish: %s\n' "$*" >&2; exit 1; }

VERSION="${VERSION:-}"; CHANNEL="${CHANNEL:-canary}"; NOTES="${NOTES:-}"; DIST="${DIST:-dist}"
DRY_RUN="${DRY_RUN:-}"; PUSH="${PUSH:-}"; TEST_PUBLISH="${TEST_PUBLISH:-}"
UPDATES_DIR="${UPDATES_DIR:-${TMPDIR:-/tmp/}doz-updates-site}"
TAP_DIR="${TAP_DIR:-${TMPDIR:-/tmp/}doz-homebrew-tap}"
dist_value() { sed -n "s/.*static let $1 = \"\\([^\"]*\\)\".*/\\1/p" Sources/DozerHost/Updates.swift | head -1; }
FEED_URL="$(dist_value feedURL)"
REPOSITORY="${REPOSITORY:-$(dist_value repository)}"
TEAM_ID="$(dist_value teamID)"
PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-$(dist_value updatePublicKey)}"
SITE="$(sed -E 's#^https://([^/]+)/.*#\1#' <<<"$FEED_URL")"         # updates.dozersandbox.com
FEED_DIR="$(sed -E 's#^https://[^/]+/(.*)/feed\.json$#\1#' <<<"$FEED_URL")"   # v1

[[ -n "$VERSION" ]] || fail "VERSION=X.Y.Z (the release make release built)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || fail "VERSION must be semver, not $VERSION"
case "$CHANNEL" in stable|beta|canary) ;; *) fail "CHANNEL is stable, beta or canary (not $CHANNEL)";; esac
[[ -n "$NOTES" && -f "$NOTES" ]] || fail "NOTES=<a markdown file> — release notes are mandatory (the feed links them)"
[[ "$FEED_DIR" == v1 && -n "$SITE" ]] || fail "cannot read the feed URL from Sources/DozerHost/Updates.swift"
[[ -n "$PUBLIC_KEY" ]] || fail "doz carries no update public key yet (Distribution.updatePublicKey) — run make doz-update-keys once, commit the key, rebuild"
if [[ -n "$PUSH" ]]; then
    for d in "$UPDATES_DIR" "$TAP_DIR"; do
        git -C "$d" remote get-url origin >/dev/null 2>&1 || fail "PUSH=1 but $d is not a git checkout with an origin (UPDATES_DIR / TAP_DIR in Makefile.config)"
    done
fi
if [[ -n "${UPDATE_KEY_FILE:-}" && -z "$TEST_PUBLISH" ]]; then fail "UPDATE_KEY_FILE is for tests (TEST_PUBLISH=1) — a real publish signs with the keychain's key"; fi

ASSET="doz-${VERSION}-macos-arm64.tar.gz"
TARBALL="$DIST/$ASSET"
[[ -f "$TARBALL" && -f "$TARBALL.sha256" ]] || fail "no $TARBALL (+ .sha256) — make release VERSION=$VERSION first"
SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
[[ "$SHA" == "$(cut -d' ' -f1 "$TARBALL.sha256")" ]] || fail "$TARBALL does not match its .sha256"
SIZE="$(stat -f %z "$TARBALL")"
say "━━━ publish doz $VERSION → $CHANNEL (${DRY_RUN:+dry run, }sha256 ${SHA:0:12}…, $SIZE bytes)"

# 1. The tarball, unpacked afresh.
work="$(mktemp -d "${TMPDIR:-/tmp/}doz-publish.XXXXXX")"
trap 'rm -rf "$work"' EXIT
tar -xzf "$TARBALL" -C "$work"
doz="$work/doz-$VERSION/libexec/doz/doz"
[[ -x "$doz" ]] || fail "the tarball has no doz-$VERSION/libexec/doz/doz"
[[ "$("$work/doz-$VERSION/bin/doz" --version)" == "$VERSION" ]] || fail "the tarball's doz does not say $VERSION"
[[ -f "$work/doz-$VERSION/libexec/doz/RELEASE" ]] || fail "the tarball has no RELEASE marker (an older release.sh?)"
codesign --verify --strict "$doz" || fail "the tarball's doz does not verify"
if [[ -z "$TEST_PUBLISH" ]]; then
    [[ "$(cat "$work/doz-$VERSION/libexec/doz/RELEASE")" == public ]] || fail "the tarball is not the PUBLIC flavor (make release PUBLIC=1)"
    codesign -dv --verbose=2 "$doz" 2>&1 | grep -q "^TeamIdentifier=$TEAM_ID\$" || fail "the tarball's doz is not signed by team $TEAM_ID"
    "$ROOT/Scripts/notary-ticket.sh" "$doz" 60 >/dev/null || fail "the tarball's doz has no published notary ticket (Scripts/notary-ticket.sh)"
fi
say "  ✓ tarball: doz $VERSION, verifies$([[ -z "$TEST_PUBLISH" ]] && echo ", public, Developer ID $TEAM_ID, notarised")"

# 2. The signature.
ARCHIVE_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/$ASSET"
[[ -n "${ARCHIVE_BASE:-}" ]] && ARCHIVE_URL="${ARCHIVE_BASE%/}/$ASSET"          # a test serves it from 127.0.0.1
NOTES_URL="https://$SITE/$FEED_DIR/notes/$VERSION.html"
ITEMS="$UPDATES_DIR/$FEED_DIR/items"
BUILD="$(python3 Scripts/feed.py build-of --items "$ITEMS" --version "$VERSION" 2>/dev/null || true)"
NEXT="${BUILD:-$(( $(ls "$ITEMS" 2>/dev/null | sed -n 's/^build-\([0-9]*\)\.json$/\1/p' | sort -n | tail -1 || echo 0) + 1 ))}"
keyargs=()
[[ -n "${UPDATE_KEY_FILE:-}" ]] && keyargs=(--key-file "$UPDATE_KEY_FILE")
SIG="$(swift Scripts/update-key.swift sign-entry --version "$VERSION" --build "$NEXT" --archive "$ASSET" --sha256 "$SHA" --size "$SIZE" ${keyargs[@]+"${keyargs[@]}"})"
swift Scripts/update-key.swift verify-entry --version "$VERSION" --build "$NEXT" --archive "$ASSET" --sha256 "$SHA" --size "$SIZE" \
    --signature "$SIG" --public-key "$PUBLIC_KEY" >/dev/null \
    || fail "the signing key does not match the public key doz carries — nothing published (a doz would refuse this entry)"
say "  ✓ signed (build $NEXT) — verifies with the key doz carries"

if [[ -n "$DRY_RUN" ]]; then
    say "  • DRY RUN — would write $UPDATES_DIR/$FEED_DIR/{items/build-$NEXT.json,notes/$VERSION.html,feed.json} and $TAP_DIR/Formula/*.rb"
    say "  • archive URL: $ARCHIVE_URL"
    exit 0
fi

# 3. The updates site.
mkdir -p "$ITEMS" "$UPDATES_DIR/$FEED_DIR/notes"
[[ -f "$UPDATES_DIR/CNAME" ]] || printf '%s\n' "$SITE" > "$UPDATES_DIR/CNAME"
TODAY="$(date -u +%Y-%m-%d)"
GOT="$(python3 Scripts/feed.py write-item --items "$ITEMS" --version "$VERSION" --channel "$CHANNEL" --archive-url "$ARCHIVE_URL" \
    --size "$SIZE" --sha256 "$SHA" --signature "$SIG" --notes-url "$NOTES_URL" --date "$TODAY")"
[[ "$GOT" == "$NEXT" ]] || fail "the feed gave build $GOT, the signature names $NEXT"
python3 Scripts/feed.py render-notes --markdown "$NOTES" --out "$UPDATES_DIR/$FEED_DIR/notes/$VERSION.html" --title "doz $VERSION"
python3 Scripts/feed.py render --items "$ITEMS" --out "$UPDATES_DIR/$FEED_DIR/feed.json"
[[ -n "$BUILD" ]] && say "  • $VERSION was already published as build $BUILD — unchanged (promote moves it: make promote BUILD=$BUILD CHANNEL=…)"
say "  ✓ feed: $UPDATES_DIR/$FEED_DIR/feed.json"

# 4. The tap.
python3 Scripts/feed.py formulas --items "$ITEMS" --tap-dir "$TAP_DIR" --template Scripts/homebrew/doz.rb.tmpl \
    --homepage "https://github.com/$REPOSITORY" | sed 's/^/  ✓ formula /'

# 5. Commit (and push, with PUSH=1) where these are git checkouts.
commit() {
    local dir="$1" msg="$2"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { say "  • $dir is not a git checkout — written, not committed"; return 0; }
    git -C "$dir" add -A
    if [[ -z "$(git -C "$dir" status --porcelain)" ]]; then say "  • $dir already says this — no commit"; return 0; fi
    git -C "$dir" commit --quiet -m "$msg"
    say "  ✓ committed in $dir: $(git -C "$dir" log --oneline -1)"
    if [[ -n "$PUSH" ]]; then git -C "$dir" push --quiet origin HEAD && say "  ✓ pushed $dir"; else say "  • not pushed (PUSH=1 pushes)"; fi
}
commit "$UPDATES_DIR" "publish doz $VERSION (build $NEXT) → $CHANNEL"
commit "$TAP_DIR" "doz $VERSION (build $NEXT) on $CHANNEL"

cat <<DONE

✓ doz $VERSION (build $NEXT) is in the feed on $CHANNEL.
  The archive URL the feed and formulas name — its release must exist before anyone upgrades:
    gh release create v$VERSION "$TARBALL" "$TARBALL.sha256" --repo $REPOSITORY --title "doz $VERSION" --notes-file "$NOTES"$([[ "$CHANNEL" != stable ]] && echo " --prerelease")
DONE
