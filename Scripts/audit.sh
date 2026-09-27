#!/usr/bin/env bash
# audit.sh — SnoozeContainerKit's neutrality gate (workspace template, allowlist form borrowed
# from repo/lib/GhosttyTerminalKit/Scripts/audit.sh).
#
# The package's promise: a Linux sandbox for ANY macOS host — an app, a CLI, a test runner — that
# depends on Apple's Containerization and nothing else, and carries no host's identity. Checked,
# not asserted:
#   1. Every import under Sources/ is on the allowlist (no UI framework, no host module).
#   2. No denylisted import (Scripts/import-denylist.txt) — belt and braces for the UI frameworks.
#   3. The manifest's remote dependencies are on an allowlist: apple/containerization pinned EXACT,
#      plus (580) swift-nio, swift-nio-ssl, swift-certificates, swift-asn1 — apple/* packages that
#      containerization already resolves, used by the egress proxy's TLS (README "Dependencies"),
#      and (585) swift-argument-parser for the `snooze` CLI — imported only by its command targets.
#   4. No app-brand literal (a bundle id, a product or storage directory name) survives.
#   5. The committed deckhold binary is the one Guest/deckhold/PROVENANCE.md records.
#   6. The committed snoozenet binary is the one Guest/snoozenet/PROVENANCE.md records.
#   7. (590) The web UI's committed assets are exactly what Sources/SnoozeWeb/WebSource builds, and
#      its modules stay where they belong (NIOHTTP1 in SnoozeWeb; LaunchServices in `snooze ui`).
# (No Linux seam check: this package is macOS-only by nature — Virtualization.framework + vmnet.)
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

# ── 1. Import allowlist ──────────────────────────────────────────────────────
# 585: + the CLI's own targets (SnoozeHost, SnoozeCLI), the system SQLite3 (the host's metrics) and
# ArgumentParser — each confined below to where it belongs.
# 590: + SnoozeWeb (the `snooze ui` target), NIOHTTP1 (swift-nio's own HTTP/1.1 codec — the same
# package, no new dependency) and CoreServices (LaunchServices opens the browser without putting the
# one-use link in a process argument) — each confined in step 1b.
ALLOWED='Foundation|Darwin|os|CryptoKit|Security|NIOCore|NIOEmbedded|NIOPosix|NIOSSL|X509|SwiftASN1|Virtualization|Containerization|ContainerizationArchive|ContainerizationEXT4|SystemPackage|ContainerizationError|ContainerizationExtras|ContainerizationOCI|ContainerizationOS|SnoozeContainerKit|SnoozeHost|SnoozeCLI|SQLite3|ArgumentParser|SnoozeWeb|NIOHTTP1|CoreServices'
BAD=$(grep -rhoE --include='*.swift' '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*(public[[:space:]]+)?import[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*' \
        "$PACKAGE/Sources" \
      | sed -E 's/.*import[[:space:]]+//' \
      | sort -u \
      | grep -vE "^(${ALLOWED})$" || true)
if [[ -n "$BAD" ]]; then
    printf 'x audit: import outside the allowlist:\n' >&2
    printf '    %s\n' $BAD >&2
    exit 1
fi

# ── 1b. (585) Confinement: the LIBRARY imports none of the CLI's additions, and only the CLI's
#        command targets import ArgumentParser (the host needs no argument parsing) ─────────────
LEAK=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+(ArgumentParser|SQLite3|SnoozeHost|SnoozeCLI|SnoozeWeb|NIOHTTP1|CoreServices)([[:space:]]|$)' \
        "$PACKAGE/Sources/SnoozeContainerKit" || true)
[[ -z "$LEAK" ]] || fail "the library imports a CLI-only module:
$LEAK"
AP=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+ArgumentParser([[:space:]]|$)' "$PACKAGE/Sources" \
      | grep -vE "/Sources/(SnoozeCLI|snooze)/" || true)
[[ -z "$AP" ]] || fail "ArgumentParser is imported outside Sources/SnoozeCLI and Sources/snooze:
$AP"

# 590: the HTTP codec only in the web target; LaunchServices only in the `snooze ui` command; the
#      host never imports the web layer (the UI is a CLIENT of the host, never inside it).
H1=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+NIOHTTP1([[:space:]]|$)' "$PACKAGE/Sources" | grep -vE "/Sources/SnoozeWeb/" || true)
[[ -z "$H1" ]] || fail "NIOHTTP1 is imported outside Sources/SnoozeWeb:
$H1"
CS=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+CoreServices([[:space:]]|$)' "$PACKAGE/Sources" | grep -vE "/Sources/SnoozeCLI/UICommand.swift$" || true)
[[ -z "$CS" ]] || fail "CoreServices is imported outside Sources/SnoozeCLI/UICommand.swift:
$CS"
WH=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+SnoozeWeb([[:space:]]|$)' "$PACKAGE/Sources/SnoozeHost" || true)
[[ -z "$WH" ]] || fail "the host imports the web UI (the UI is a client of the host):
$WH"

# ── 2. Denylist ──────────────────────────────────────────────────────────────
ALTS=$(grep -v '^#' "$DENYLIST" | grep -v '^$' | paste -sd'|' -)
if [[ -n "$ALTS" ]]; then
    DENIED=$(grep -rnE --include='*.swift' \
        "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(${ALTS})([[:space:]]|$|\.)" \
        "$PACKAGE/Sources" | head -20 || true)
    [[ -z "$DENIED" ]] || fail "denylisted import:
$DENIED"
fi

# ── 3. The dependency allowlist: containerization pinned exactly, plus (580) the four apple/*
#       packages containerization already resolves, for the egress proxy's TLS ────────────────
# 585: + swift-argument-parser (apple/*, also already resolved by containerization) for the snooze
# CLI's command targets only — step 1b keeps it out of the library and the host.
ALLOWED_DEPS='https://github.com/apple/containerization.git
https://github.com/apple/swift-argument-parser.git
https://github.com/apple/swift-asn1.git
https://github.com/apple/swift-certificates.git
https://github.com/apple/swift-nio-ssl.git
https://github.com/apple/swift-nio.git'
DEPS=$(grep -oE '\.package\(url: "[^"]+"' "$MANIFEST" | sed -E 's/.*"(.*)"/\1/' | sort -u)
EXTRA=$(comm -23 <(printf '%s\n' "$DEPS") <(printf '%s\n' "$ALLOWED_DEPS" | sort -u))
[[ -z "$EXTRA" ]] || fail "the manifest declares dependencies outside the allowlist (Scripts/audit.sh step 3):
$EXTRA"
grep -qE '\.package\(url: "https://github.com/apple/containerization.git", exact: "[0-9]+\.[0-9]+\.[0-9]+"\)' "$MANIFEST" \
    || fail "apple/containerization must be pinned with exact: (the sleep design depends on its internals' shape)"

# ── 4. No host brand ─────────────────────────────────────────────────────────
BRAND=$(grep -rnE --include='*.swift' 'com\.deckosaurus\.|com\.roundrect\.|"[^"]*(Deckosaurus|Deckolite|SandboxLab|Codeck)[^"]*"|sandboxlab' \
        "$PACKAGE/Sources" | head -10 || true)
[[ -z "$BRAND" ]] || fail "a host brand literal survives in the package:
$BRAND"

# ── 5. The committed guest binary matches its provenance ─────────────────────
BIN="$PACKAGE/Sources/SnoozeContainerKit/Resources/deckhold"
[[ -f "$BIN" ]] || fail "missing the committed deckhold binary ($BIN)"
SHA=$(shasum -a 256 "$BIN" | awk '{print $1}')
grep -qF "| sha256 (auto) | \`$SHA\` |" "$PACKAGE/Guest/deckhold/PROVENANCE.md" \
    || fail "Resources/deckhold ($SHA) is not the binary Guest/deckhold/PROVENANCE.md records — run make deckhold"

# ── 6. The committed snoozenet binary (580) matches its provenance ───────────
NBIN="$PACKAGE/Sources/SnoozeContainerKit/Resources/snoozenet"
[[ -f "$NBIN" ]] || fail "missing the committed snoozenet binary ($NBIN)"
NSHA=$(shasum -a 256 "$NBIN" | awk '{print $1}')
grep -qF "| sha256 (auto) | \`$NSHA\` |" "$PACKAGE/Guest/snoozenet/PROVENANCE.md" \
    || fail "Resources/snoozenet ($NSHA) is not the binary Guest/snoozenet/PROVENANCE.md records — run make snoozenet"

# ── 7. (590) The web UI's committed assets match their sources ───────────────
swift "$PACKAGE/Scripts/build-web-assets.swift" --check >/dev/null || fail "Sources/SnoozeWeb/Resources/Web is stale — run make web-assets and commit it"

printf 'ok audit: SnoozeContainerKit imports only its allowlist (Foundation/Security/Virtualization/Containerization/NIO/X509),\n'
printf '          depends only on apple/containerization (exact) + the apple/* packages it already resolves\n'
printf '          (TLS; ArgumentParser for the CLI targets only),\n'
printf '          carries no host brand, deckhold + snoozenet match their provenance,\n'
printf '          and the web UI (NIOHTTP1, confined) ships exactly the assets its sources build\n'
