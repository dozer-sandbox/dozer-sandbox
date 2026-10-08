#!/usr/bin/env bash
# docs-drift-check.sh — cheap check that the CLI reference (589) still names every real `doz`
# subcommand, and nothing it no longer has.
#
# Cheap on purpose: it diffs COMMAND NAMES only (not flags or help text — that would need a real
# ArgumentParser --help parser, and the name is the part that actually goes stale: 585 added the
# whole CLI, 588 added `account` and `key policy`, both exactly new names this check would catch).
#
# It builds the UNSIGNED debug `doz` — `--help` needs no entitlement, only booting a VM does —
# and walks the top level plus every subcommand group's --help, extracting each subcommand's
# canonical name (aliases ignored) from ArgumentParser's own SUBCOMMANDS listing. That set is
# diffed against Scripts/docs-known-commands.txt, the list the CLI reference article documents.
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWN="$PACKAGE/Scripts/docs-known-commands.txt"
BIN="$PACKAGE/.build/debug/doz"
CMD_GROUPS="sessions image base builder template point net key account access host ui serve config resources ignore"   # NOT "GROUPS" — bash reserves that name for the
                                                  # caller's group-membership array; assigning to
                                                  # it silently no-ops and $GROUPS then reads back
                                                  # as one numeric gid (macOS: 20, "staff").

fail() {
    printf 'x docs-drift-check: %s\n' "$1" >&2
    exit 1
}

[[ -f "$KNOWN" ]] || fail "missing $KNOWN"

echo "docs-drift-check: building the CLI (unsigned — --help needs no entitlement) …"
(cd "$PACKAGE" && swift build -j "${JOBS:-8}" --product doz) >/dev/null

[[ -x "$BIN" ]] || fail "missing $BIN after build"

# Extract subcommand names from a `--help` SUBCOMMANDS: block: lines indented exactly two spaces,
# name is the leading identifier (a following comma or "(default)" — an alias or the default
# marker — is dropped, so only the canonical name is tracked). Portable (BSD) sed, no gawk-only
# 3-arg match().
names_from_help() {
    "$BIN" "$@" --help 2>&1 \
      | sed -n '/^SUBCOMMANDS:/,/^[[:space:]]*$/p' \
      | sed -n 's/^  \([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p'
}

actual=$(mktemp)
trap 'rm -f "$actual"' EXIT

names_from_help >> "$actual"
for g in $CMD_GROUPS; do
    names_from_help "$g" | sed "s#^#${g}/#" >> "$actual"
done
sort -u "$actual" -o "$actual"

known=$(grep -v '^#' "$KNOWN" | grep -v '^[[:space:]]*$' | sort -u)

missing_from_docs=$(comm -23 "$actual" <(printf '%s\n' "$known"))
stale_in_docs=$(comm -13 "$actual" <(printf '%s\n' "$known"))

if [[ -n "$missing_from_docs" || -n "$stale_in_docs" ]]; then
    [[ -z "$missing_from_docs" ]] || printf 'x docs-drift-check: the CLI has commands the reference does not document:\n%s\n' "$missing_from_docs" >&2
    [[ -z "$stale_in_docs" ]] || printf 'x docs-drift-check: the reference documents commands the CLI no longer has:\n%s\n' "$stale_in_docs" >&2
    printf 'Update Articles/CLIReference.md and Scripts/docs-known-commands.txt together.\n' >&2
    exit 1
fi

printf 'ok docs-drift-check: %d command names match the CLI exactly (top level + %s)\n' "$(wc -l < "$actual" | tr -d ' ')" "$CMD_GROUPS"

# The user manual (docs/manual): its commands, flags, setting keys, settings table and links, checked
# against this build (Scripts/manual-check.swift; --write regenerates the settings table).
if [[ -d "$PACKAGE/docs/manual" ]]; then
    (cd "$PACKAGE" && swift Scripts/manual-check.swift --doz "$BIN" --manual docs/manual)
fi

# What a person reads — every --help, every setting's description, the user-facing strings in the
# sources and the dashboard — carries no internal feature number or walkthrough ID.
(cd "$PACKAGE" && swift Scripts/user-text-check.swift --doz "$BIN")

# 611: the distribution names live in ONE place (Distribution in Sources/DozerHost/Updates.swift). Every
# `brew install|tap OWNER/NAME…` and every github.com/OWNER/REPO naming Dozer in what a reader sees must agree,
# so renaming the organisation is: change the constants, then fix exactly what this lists.
TAP="$(sed -n 's/.*static let tap = "\([^"]*\)".*/\1/p' "$PACKAGE/Sources/DozerHost/Updates.swift" | head -1)"
REPO="$(sed -n 's/.*static let repository = "\([^"]*\)".*/\1/p' "$PACKAGE/Sources/DozerHost/Updates.swift" | head -1)"
docs=("$PACKAGE/README.md" "$PACKAGE/CONTRIBUTING.md" "$PACKAGE/docs" "$PACKAGE/Sources/DozerKit/DozerKit.docc" "$PACKAGE/Scripts/homebrew")
wrong="$(grep -rnoE 'brew (install|tap|untap|trust|uninstall|upgrade|reinstall) [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "${docs[@]}" 2>/dev/null \
    | grep -v -- " $TAP\$" | grep -vE " $TAP/doz(-beta|-canary)?\$" || true)"
wrong+="$(grep -rnoE 'github\.com/[A-Za-z0-9_.-]+/(dozer|Dozer|doz|homebrew-)[A-Za-z0-9_.-]*' "${docs[@]}" 2>/dev/null \
    | grep -vE "github\.com/$REPO(\.git)?(\$|/)" | grep -vE "github\.com/${TAP%%/*}/homebrew-${TAP##*/}\$" || true)"
if [[ -n "$wrong" ]]; then
    printf 'x distribution-names: these name another tap or repository than Distribution (tap %s, repository %s):\n%s\n' "$TAP" "$REPO" "$wrong" >&2
    exit 1
fi
printf 'ok distribution-names: every brew command and GitHub link in the docs names %s / %s\n' "$TAP" "$REPO"
