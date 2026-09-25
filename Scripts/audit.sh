#!/usr/bin/env bash
# placeholder: SnoozeContainerKit this package's name · edit ALLOWLIST_EXTRA / BRAND_PATTERNS below for
# this library's actual needs. Derived from repo/lib/DeckKit's real Scripts/audit.sh.
#
# audit.sh — SnoozeContainerKit's own app-neutrality audit. Three checks, all of which have
# caught a real regression somewhere in this family of libraries:
#   1. No denylisted (platform-UI / app-only) import anywhere under Sources/.
#   2. Every Darwin-only conditional import sits behind a `#if canImport(...)`
#      seam — a bare one silently breaks the Linux build.
#   3. No app-brand literal (a bundle id, a product name) survives — storage
#      location and identity are the HOST's decision, never this package's.
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$PACKAGE/Package.swift"
DENYLIST="$PACKAGE/Scripts/import-denylist.txt"

fail() {
    printf 'x audit: %s\n' "$1" >&2
    exit 1
}

[[ -f "$MANIFEST" ]] || fail "missing Package.swift"
[[ -f "$DENYLIST" ]] || fail "missing import denylist"

ALTS=$(grep -v '^#' "$DENYLIST" | grep -v '^$' | paste -sd'|' -)
if [[ -n "$ALTS" ]]; then
    BAD=$(grep -rnE --include='*.swift' \
        "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(${ALTS})([[:space:]]|$|\.)" \
        "$PACKAGE/Sources" | head -20 || true)
    if [[ -n "$BAD" ]]; then
        printf 'x audit: denylisted import in %s:\n%s\n' "$(basename "$PACKAGE")" "$BAD" >&2
        exit 1
    fi
fi

# Darwin-only imports that need a canImport seam so the Linux build (if this
# package supports one) does not break silently. Trim this list to what the
# package actually imports.
SEAMBAD=$(for m in Combine CryptoKit os; do
    grep -rlE --include='*.swift' "^import $m(\.|$)" "$PACKAGE/Sources" 2>/dev/null | while read -r f; do
        grep -q "#if canImport($m)" "$f" \
            || echo "$f: bare 'import $m' without a canImport seam (breaks the Linux build)"
    done
done)
if [[ -n "$SEAMBAD" ]]; then
    printf 'x audit: unseamed Linux-conditional import:\n%s\n' "$SEAMBAD" >&2
    exit 1
fi

# No consumer's bundle id or product name may be hardcoded here. Extend this
# pattern list with any brand string this library must never carry.
BRAND=$(grep -rnE --include='*.swift' 'com\.[a-z0-9]+\.[a-z0-9]+\.mac' "$PACKAGE/Sources" | head -10 || true)
if [[ -n "$BRAND" ]]; then
    printf 'x audit: bundle-id literal survives in the package:\n%s\n' "$BRAND" >&2
    exit 1
fi

printf 'ok audit: %s is import-neutral and app-brand free\n' "$(basename "$PACKAGE")"
