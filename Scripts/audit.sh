#!/usr/bin/env bash
# audit.sh — DozerKit's neutrality gate (workspace template, allowlist form borrowed
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
#      and (585) swift-argument-parser for the `doz` CLI — imported only by its command targets.
#   4. No app-brand literal (a bundle id, a product or storage directory name) survives.
#   5. The committed deckhold binary is the one Guest/deckhold/PROVENANCE.md records.
#   6. The committed doznet binary is the one Guest/doznet/PROVENANCE.md records (6b: dozview's, and no libfuse).
#   7. (590) The web UI's committed assets are exactly what Sources/DozerWeb/WebSource builds, and
#      its modules stay where they belong (NIOHTTP1 in DozerWeb; LaunchServices in `doz ui`).
#   8. (592) The product's OLD name is gone: no file in the repo (sources, tests, scripts, docs, CI)
#      carries it, in any case, nor its short `snz` prefixes. Nothing is allow-listed — the rename
#      kept no compatibility (owner ruling) and this repo holds no history file. Only third-party
#      vendored bytes are skipped (they are pinned by VENDOR.json and never edited).
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
# 585: + the CLI's own targets (DozerHost, DozerCLI), the system SQLite3 (the host's metrics) and
# ArgumentParser — each confined below to where it belongs.
# 590: + DozerWeb (the `doz ui` target), NIOHTTP1 (swift-nio's own HTTP/1.1 codec — the same
# package, no new dependency) and CoreServices (LaunchServices opens the browser without putting the
# one-use link in a process argument) — each confined in step 1b.
# 591: + NIOWebSocket (swift-nio's own WebSocket codec — the same package) for `doz ui`'s
# browser terminals, confined to Sources/DozerWeb in step 1b.
# 594: + Yams (the project file doz_project.yaml — owner ruling D9), confined to Sources/DozerCLI in step 1b.
# 606: + dnssd (the system's Bonjour client — `doz serve` announces itself), confined in step 1b.
ALLOWED='Foundation|Darwin|os|CryptoKit|Security|NIOCore|NIOEmbedded|NIOPosix|NIOSSL|X509|SwiftASN1|Virtualization|Containerization|ContainerizationArchive|ContainerizationEXT4|SystemPackage|ContainerizationError|ContainerizationExtras|ContainerizationOCI|ContainerizationOS|DozerKit|DozerHost|DozerCLI|SQLite3|ArgumentParser|DozerWeb|NIOHTTP1|NIOWebSocket|CoreServices|Yams|dnssd'
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
LEAK=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+(ArgumentParser|SQLite3|DozerHost|DozerCLI|DozerWeb|NIOHTTP1|NIOWebSocket|CoreServices|Yams)([[:space:]]|$)' \
        "$PACKAGE/Sources/DozerKit" || true)
[[ -z "$LEAK" ]] || fail "the library imports a CLI-only module:
$LEAK"
AP=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+ArgumentParser([[:space:]]|$)' "$PACKAGE/Sources" \
      | grep -vE "/Sources/(DozerCLI|doz)/" || true)
[[ -z "$AP" ]] || fail "ArgumentParser is imported outside Sources/DozerCLI and Sources/doz:
$AP"
# 594: Yams reads the project file — the CLI's commands only (never the library, the host or the web UI).
YA=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+Yams([[:space:]]|$)' "$PACKAGE/Sources" \
      | grep -vE "/Sources/DozerCLI/" || true)
[[ -z "$YA" ]] || fail "Yams is imported outside Sources/DozerCLI:
$YA"

# 590: the HTTP codec only in the web target; LaunchServices only in the `doz ui` command; the
#      host never imports the web layer (the UI is a CLIENT of the host, never inside it).
H1=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+NIOHTTP1([[:space:]]|$)' "$PACKAGE/Sources" | grep -vE "/Sources/DozerWeb/" || true)
[[ -z "$H1" ]] || fail "NIOHTTP1 is imported outside Sources/DozerWeb:
$H1"
WS=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+NIOWebSocket([[:space:]]|$)' "$PACKAGE/Sources" | grep -vE "/Sources/DozerWeb/" || true)
[[ -z "$WS" ]] || fail "NIOWebSocket is imported outside Sources/DozerWeb:
$WS"
# 599b: + Sources/DozerHost/MacDefaultApp.swift — LaunchServices asked, read-only, which app is a file's
#       default (the notice names it); it opens nothing.
CS=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+CoreServices([[:space:]]|$)' "$PACKAGE/Sources" | grep -vE "/Sources/DozerCLI/UICommand.swift$|/Sources/DozerHost/MacDefaultApp.swift$" || true)
[[ -z "$CS" ]] || fail "CoreServices is imported outside Sources/DozerCLI/UICommand.swift and Sources/DozerHost/MacDefaultApp.swift:
$CS"
# 606: Bonjour only in doz serve's announcer.
DN=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+dnssd([[:space:]]|$)' "$PACKAGE/Sources" | grep -vE "/Sources/DozerWeb/WebBonjour.swift$" || true)
[[ -z "$DN" ]] || fail "dnssd is imported outside Sources/DozerWeb/WebBonjour.swift:
$DN"
# 606: only doz serve binds beyond loopback — doz ui (590) never constructs the network profile.
BS=$(grep -rlE --include='*.swift' 'bindServe\(|WebServeState\(' "$PACKAGE/Sources" | grep -vE "/Sources/DozerWeb/(WebServer|WebServeState)\.swift$|/Sources/DozerCLI/ServeCommand\.swift$" || true)
[[ -z "$BS" ]] || fail "the network (doz serve) profile is constructed outside DozerWeb and ServeCommand.swift:
$BS"
grep -qE 'bindServe|WebServeState|WebServeConfig' "$PACKAGE/Sources/DozerCLI/UICommand.swift" && fail "doz ui (UICommand.swift) must stay loopback-only — it may not reach the doz serve profile"
WH=$(grep -rlE --include='*.swift' '^[[:space:]]*import[[:space:]]+DozerWeb([[:space:]]|$)' "$PACKAGE/Sources/DozerHost" || true)
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
# 585: + swift-argument-parser (apple/*, also already resolved by containerization) for the doz
# CLI's command targets only — step 1b keeps it out of the library and the host.
ALLOWED_DEPS='https://github.com/apple/containerization.git
https://github.com/apple/swift-argument-parser.git
https://github.com/apple/swift-asn1.git
https://github.com/apple/swift-certificates.git
https://github.com/apple/swift-nio-ssl.git
https://github.com/apple/swift-nio.git
https://github.com/jpsim/Yams.git'
DEPS=$(grep -oE '\.package\(url: "[^"]+"' "$MANIFEST" | sed -E 's/.*"(.*)"/\1/' | sort -u)
EXTRA=$(comm -23 <(printf '%s\n' "$DEPS") <(printf '%s\n' "$ALLOWED_DEPS" | sort -u))
[[ -z "$EXTRA" ]] || fail "the manifest declares dependencies outside the allowlist (Scripts/audit.sh step 3):
$EXTRA"
grep -qE '\.package\(url: "https://github.com/apple/containerization.git", exact: "[0-9]+\.[0-9]+\.[0-9]+"\)' "$MANIFEST" \
    || fail "apple/containerization must be pinned with exact: (the sleep design depends on its internals' shape)"
grep -qE '\.package\(url: "https://github.com/jpsim/Yams.git", exact: "[0-9]+\.[0-9]+\.[0-9]+"\)' "$MANIFEST" \
    || fail "jpsim/Yams must be pinned with exact: (594, owner ruling D9 — the one non-apple dependency)"

# ── 4. No host brand ─────────────────────────────────────────────────────────
BRAND=$(grep -rnE --include='*.swift' 'com\.deckosaurus\.|com\.roundrect\.|"[^"]*(Deckosaurus|SandboxLab)[^"]*"|sandboxlab' \
        "$PACKAGE/Sources" | head -10 || true)
[[ -z "$BRAND" ]] || fail "a host brand literal survives in the package:
$BRAND"

# ── 4b. (611) The licence texts in Licences/ are the ones Licences/SOURCES.md records ───────────
for f in "$PACKAGE"/Licences/*.LICENSE "$PACKAGE"/Licences/*.NOTICE; do
    b="$(basename "$f")"
    want="$(grep -F "\`$b\`" "$PACKAGE/Licences/SOURCES.md" | grep -oE '`[0-9a-f]{64}`' | tr -d '`')"
    [[ -n "$want" && "$(shasum -a 256 "$f" | cut -d' ' -f1)" == "$want" ]] \
        || fail "Licences/$b is not the text Licences/SOURCES.md records (fetch it again from the URL there)"
done

# ── 4c. (611) CI on a public repository: a fork's code never reaches a self-hosted runner ─────────
python3 - "$PACKAGE/.github/workflows" <<'PY' || fail "CI: a self-hosted job could run a fork's pull request, or pull_request_target is used (see .github/workflows/ci.yml's header)"
import os, re, sys
GUARD = "github.event.pull_request.head.repo.full_name == github.repository"
bad = []
for name in sorted(os.listdir(sys.argv[1])):
    if not name.endswith((".yml", ".yaml")): continue
    text = open(os.path.join(sys.argv[1], name)).read()
    if re.search(r"^\s*pull_request_target\s*:", text, re.M) or "pull_request_target" in re.sub(r"#.*", "", text):
        bad.append(f"{name}: pull_request_target")
    jobs = text.split("\njobs:\n", 1)[1] if "\njobs:\n" in text else ""
    for block in re.split(r"\n(?=  [A-Za-z0-9_-]+:\n)", "\n" + jobs):
        m = re.match(r"\n?  ([A-Za-z0-9_-]+):", block)
        runs_on = " ".join(re.findall(r"^    runs-on:.*$", block, re.M))
        if not m or "self-hosted" not in runs_on: continue
        if GUARD not in block: bad.append(f"{name}: job {m.group(1)} runs self-hosted without the fork guard")
for b in bad: print("  " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

# ── 5. The committed guest binary matches its provenance ─────────────────────
BIN="$PACKAGE/Sources/DozerKit/Resources/deckhold"
[[ -f "$BIN" ]] || fail "missing the committed deckhold binary ($BIN)"
SHA=$(shasum -a 256 "$BIN" | awk '{print $1}')
grep -qF "| sha256 (auto) | \`$SHA\` |" "$PACKAGE/Guest/deckhold/PROVENANCE.md" \
    || fail "Resources/deckhold ($SHA) is not the binary Guest/deckhold/PROVENANCE.md records — run make deckhold"

# ── 6. The committed doznet binary (580) matches its provenance ───────────
NBIN="$PACKAGE/Sources/DozerKit/Resources/doznet"
[[ -f "$NBIN" ]] || fail "missing the committed doznet binary ($NBIN)"
NSHA=$(shasum -a 256 "$NBIN" | awk '{print $1}')
grep -qF "| sha256 (auto) | \`$NSHA\` |" "$PACKAGE/Guest/doznet/PROVENANCE.md" \
    || fail "Resources/doznet ($NSHA) is not the binary Guest/doznet/PROVENANCE.md records — run make doznet"

# ── 6b. (599g) The committed dozview binary matches its provenance ───────────
VBIN="$PACKAGE/Sources/DozerKit/Resources/dozview"
[[ -f "$VBIN" ]] || fail "missing the committed dozview binary ($VBIN)"
VSHA=$(shasum -a 256 "$VBIN" | awk '{print $1}')
grep -qF "| sha256 (auto) | \`$VSHA\` |" "$PACKAGE/Guest/dozview/PROVENANCE.md" \
    || fail "Resources/dozview ($VSHA) is not the binary Guest/dozview/PROVENANCE.md records — run make dozview"
# 599g: no libfuse in the guest view (LGPL-2.1): the raw /dev/fuse protocol only.
grep -rqE '#include[[:space:]]*[<"]fuse(_lowlevel)?\.h[>"]|-lfuse' "$PACKAGE/Guest/dozview" && fail "Guest/dozview must not use libfuse (LGPL) — the raw /dev/fuse protocol only"

# ── 7. (590) The web UI's committed assets match their sources ───────────────
swift "$PACKAGE/Scripts/build-web-assets.swift" --check >/dev/null || fail "Sources/DozerWeb/Resources/Web is stale — run make web-assets and commit it"

# ── 8. (592) The old product name is gone ─────────────────────────────────────
# The pattern is assembled, so this script does not match itself.
OLD_NAME="sn""ooze"
OLD_SHORT="sn""z(_|1|-)"
STRAY=$(git -C "$PACKAGE" grep --untracked -nIiE "${OLD_NAME}|${OLD_SHORT}" -- . \
          ':(exclude)Sources/DozerWeb/WebSource/vendor/**' \
          ':(exclude)Sources/DozerWeb/Resources/Web/assets/vendor-*' \
          ':(exclude)Sources/DozerWeb/Resources/Web/licences/**' | head -20 || true)
[[ -z "$STRAY" ]] || fail "the old product name survives (592 renamed everything to doz / DozerKit / Dozer Sandbox):
$STRAY"

printf 'ok audit: DozerKit imports only its allowlist (Foundation/Security/Virtualization/Containerization/NIO/X509),\n'
printf '          depends only on apple/containerization (exact) + the apple/* packages it already resolves\n'
printf '          (TLS; ArgumentParser for the CLI targets only) and Yams (exact; the CLI'"'"'s project file only),\n'
printf '          carries no host brand, deckhold + doznet + dozview match their provenance (no libfuse),\n'
printf '          the web UI (NIOHTTP1, confined) ships exactly the assets its sources build,\n'
printf '          doz ui stays loopback-only and only doz serve binds the LAN (dnssd confined to its announcer),\n'
printf '          and no file carries the pre-592 product name\n'
