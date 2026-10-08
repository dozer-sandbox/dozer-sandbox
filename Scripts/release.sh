#!/usr/bin/env bash
# release.sh — 598 (H1): the prebuilt `doz` a release ships, and what Homebrew installs.
#
#   make release VERSION=0.12.0            # → dist/doz-0.12.0-macos-arm64.tar.gz (+ .sha256)
#   make release VERSION=0.12.0 DRY_RUN=1  # print every command, run none (the Developer ID plan)
#   make release VERSION=0.31.0-dev.1 TEST_BUILD=1  # a local test of the pipeline: signing/notarising optional (never published)
#
# The tarball holds the install layout `make install-cli` makes, under one top directory:
#
#   doz-<version>/bin/doz                    → ../libexec/doz/doz   (a relative link)
#   doz-<version>/libexec/doz/doz            the executable, signed with Scripts/doz.entitlements
#   doz-<version>/libexec/doz/VERSION        the version it was built for (DozerCommand.version reads it)
#   doz-<version>/libexec/doz/DozerKit_*.bundle   its resources (guest binaries, web assets)
#   doz-<version>/libexec/doz/kernels/vmlinux-6.18.15-186-sound   PRIVATE builds only: the audio sandboxes' kernel
#
# PUBLIC=1 (the default — every real release from 0.31.0 on) builds the PUBLIC flavor (`-DDOZ_PUBLIC_BUILD`,
# Sources/DozerHost/BuildFlavor.swift): no experimental sound kernel in the tarball (doz create --audio says this
# build does not include it) and no Dozer-own ChatGPT sign-in (doz account add --chatgpt says so; the Mac's Codex
# login and OpenAI API keys stay). It checks both in the packed tarball.
#
# PUBLIC=0 (a private rc only) builds the full flavor. Its EXPERIMENTAL sound kernel (kata 6.18.15-186 + a
# sound.conf) is NOT in git (16 MB): SOUND_KERNEL=<file> names it and it must have the sha256 pinned in
# Sources/DozerKit/Audio.swift (SoundKernel.sha256) or the release stops; NO_SOUND_KERNEL=1 ships without it.
#
# SIGNING. With SIGN_IDENTITY (a "Developer ID Application: …" identity, from a gitignored
# Makefile.config — see Makefile.config.example) the executable and every Mac (Mach-O) binary in its
# resources are signed with it, the hardened runtime and a secure timestamp; the guest binaries are
# Linux ELF and are left alone. With NOTARY_PROFILE too (`xcrun notarytool store-credentials`, once),
# the signed tree is submitted to Apple's notary service and waited for. A bare command-line tool
# cannot be stapled (only bundles, disk images and packages can): Gatekeeper looks its ticket up
# online the first time. Without SIGN_IDENTITY it signs ad hoc, as today, and says so — which is
# enough for Homebrew (a formula's download is never quarantined).
#
# Inputs (environment; the Makefile passes them): PUBLIC (default 1), VERSION (default: the exact vX.Y.Z tag at HEAD),
# OUT (default dist), JOBS (default 4), SWIFT_BUILD_SYSTEM, SIGN_IDENTITY, NOTARY_PROFILE,
# HARDENED=1 (the hardened runtime even when signing ad hoc — to test the entitlement under it),
# DRY_RUN=1, SKIP_BUILD=1 (package the release build already in .build/release).
# It never reads, prints or stores a password, and never calls notarytool without a profile.
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PACKAGE"
OUT="${OUT:-dist}"
JOBS="${JOBS:-4}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DRY_RUN="${DRY_RUN:-}"
ENTITLEMENTS="Scripts/doz.entitlements"
PUBLIC="${PUBLIC:-1}"
[[ "$PUBLIC" == 1 || "$PUBLIC" == 0 ]] || { printf 'x release: PUBLIC is 1 (a public release, the default) or 0 (a private rc), not %s\n' "$PUBLIC" >&2; exit 1; }
SOUND_KERNEL="${SOUND_KERNEL:-}"
# A public build never carries the sound kernel.
if [[ "$PUBLIC" == 1 ]]; then NO_SOUND_KERNEL=1; fi
SOUND_KERNEL_NAME="$(sed -n 's/.*static let fileName = "\(vmlinux-[^"]*\)".*/\1/p' Sources/DozerKit/Audio.swift)"
SOUND_KERNEL_SHA="$(sed -n 's/.*static let sha256 = "\([0-9a-f]\{64\}\)".*/\1/p' Sources/DozerKit/Audio.swift)"

say() { printf '%s\n' "$*"; }
fail() { printf 'x release: %s\n' "$*" >&2; exit 1; }
# Run a command — or, in a dry run, print it (quoted, so it can be pasted) and run nothing.
run() {
    if [[ -n "$DRY_RUN" ]]; then printf '  [dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

if [[ -z "${VERSION:-}" ]]; then
    tag="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
    [[ -n "$tag" ]] || fail "which version? make release VERSION=X.Y.Z (HEAD carries no vX.Y.Z tag)"
    VERSION="${tag#v}"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || fail "VERSION must be semver (X.Y.Z), not '$VERSION'"
[[ "$(uname -m)" == "arm64" ]] || fail "doz is Apple silicon only (this is $(uname -m))"

if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
    [[ -n "$SOUND_KERNEL_NAME" && -n "$SOUND_KERNEL_SHA" ]] || fail "cannot read SoundKernel.fileName/sha256 from Sources/DozerKit/Audio.swift"
    [[ -n "$SOUND_KERNEL" && -f "$SOUND_KERNEL" ]] || fail "a private build (PUBLIC=0) needs SOUND_KERNEL=<the sound kernel file> (or NO_SOUND_KERNEL=1 to ship without — doz create --audio then refuses)"
    got="$(shasum -a 256 "$SOUND_KERNEL" | cut -d' ' -f1)"
    [[ "$got" == "$SOUND_KERNEL_SHA" ]] || fail "the sound kernel at $SOUND_KERNEL has sha256 $got, not the pinned $SOUND_KERNEL_SHA"
fi

NAME="doz-${VERSION}-macos-arm64"
STAGE="$OUT/stage/doz-${VERSION}"
TARBALL="$OUT/${NAME}.tar.gz"

MODE="ad hoc"
SIGN_ARGS=(--force --sign -)
if [[ -n "$SIGN_IDENTITY" ]]; then
    [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] || fail "SIGN_IDENTITY must be a \"Developer ID Application: …\" identity (it is '$SIGN_IDENTITY')"
    MODE="Developer ID"
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
elif [[ -n "${HARDENED:-}" ]]; then
    MODE="ad hoc, hardened runtime"
    SIGN_ARGS=(--force --sign - --options runtime)
fi
if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
    fail "NOTARY_PROFILE is set but SIGN_IDENTITY is not — Apple notarises Developer ID signatures only"
fi
# 611: a PUBLIC release is Developer ID signed AND notarised — always. TEST_BUILD=1 is the explicit way to make an
# unsigned or unnotarised build that is never distributed (a local test of the pipeline).
if [[ "$PUBLIC" == 1 && -z "${TEST_BUILD:-}" && ( -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" ) ]]; then
    fail "a public release is signed with a Developer ID and notarised: set SIGN_IDENTITY and NOTARY_PROFILE in Makefile.config (see Makefile.config.example), or TEST_BUILD=1 for a local test build that is never published"
fi
# 611: a public release can verify its own updates: the update public key must be compiled in (make doz-update-keys).
if [[ "$PUBLIC" == 1 && -z "${TEST_BUILD:-}" ]]; then
    upk="$(sed -n 's/.*static let updatePublicKey = "\([^"]*\)".*/\1/p' Sources/DozerHost/Updates.swift | head -1)"
    [[ -n "$upk" ]] || fail "doz carries no update public key (Distribution.updatePublicKey is empty) — make doz-update-keys once, commit the key it prints"
fi
# The team the identity belongs to — "Developer ID Application: Name (TEAMID)" — checked on the signed binary.
TEAM_ID="$(sed -n -E 's/^Developer ID Application: .* \(([A-Z0-9]{10})\)$/\1/p' <<<"$SIGN_IDENTITY")"
if [[ -n "$SIGN_IDENTITY" && -z "$DRY_RUN" ]]; then
    # Preflight, before a 10-minute build: the identity is in the keychain, and the notary profile authenticates.
    # (Only names are read: `find-identity` lists certificates; `notarytool history` uses the profile's stored
    # credential itself — nothing secret is printed or kept.)
    security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\"" \
        || fail "the identity \"$SIGN_IDENTITY\" is not in the keychain (security find-identity -v -p codesigning)"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1 \
            || fail "the notarytool profile '$NOTARY_PROFILE' does not authenticate (xcrun notarytool store-credentials '$NOTARY_PROFILE' … creates it once)"
    fi
fi

FLAVOR="$([[ "$PUBLIC" == 1 ]] && echo public || echo private)"
say "release: doz $VERSION ($FLAVOR build) → $TARBALL ($MODE signature${NOTARY_PROFILE:+, notarised with profile $NOTARY_PROFILE})"
[[ -n "$DRY_RUN" ]] && say "release: DRY RUN — every command is printed, none is run"

# 1. Build (release).
if [[ -z "${SKIP_BUILD:-}" ]]; then
    # shellcheck disable=SC2086 — SWIFT_BUILD_SYSTEM is empty or two words, on purpose.
    PUBLIC_FLAGS=()
    [[ "$PUBLIC" == 1 ]] && PUBLIC_FLAGS=(-Xswiftc -DDOZ_PUBLIC_BUILD)
    run swift build ${SWIFT_BUILD_SYSTEM:-} -j "$JOBS" -c release --product doz ${PUBLIC_FLAGS[@]+"${PUBLIC_FLAGS[@]}"}
fi

# 2. The install layout.
run rm -rf "$OUT/stage"
run mkdir -p "$STAGE/bin" "$STAGE/libexec/doz"
for b in .build/release/DozerKit_*.bundle; do
    [[ -n "$DRY_RUN" || -d "$b" ]] || fail "missing $b — build first"
    run cp -R "$b" "$STAGE/libexec/doz/"
done
run cp .build/release/doz "$STAGE/libexec/doz/doz"
if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
    run mkdir -p "$STAGE/libexec/doz/kernels"
    run cp "$SOUND_KERNEL" "$STAGE/libexec/doz/kernels/$SOUND_KERNEL_NAME"
fi
if [[ -n "$DRY_RUN" ]]; then say "  [dry-run] echo $VERSION > $STAGE/libexec/doz/VERSION"; else printf '%s\n' "$VERSION" > "$STAGE/libexec/doz/VERSION"; fi
# 611: the release marker — what tells an installed release (Homebrew, or the tarball unpacked by hand: `doz update`
# swaps it) from a development build (`make install-cli`, which has VERSION but no marker, and is never updated).
if [[ -n "$DRY_RUN" ]]; then say "  [dry-run] echo $FLAVOR > $STAGE/libexec/doz/RELEASE"; else printf '%s\n' "$FLAVOR" > "$STAGE/libexec/doz/RELEASE"; fi
run ln -s ../libexec/doz/doz "$STAGE/bin/doz"
# 611: the licences a binary distribution must carry — LICENSE, NOTICE and every dependency's licence + NOTICE, from
# the exact checkouts this build used (it fails when a resolved package has no licence file).
run Scripts/third-party-licences.sh "$STAGE/libexec/doz/licences"

# 3. Sign: every Mac binary in the resources first (none today — the guest binaries are Linux ELF and
#    are left alone), then the executable with the virtualization entitlement.
if [[ -z "$DRY_RUN" ]]; then
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q '^Mach-O'; then
            say "  signing $f (Mach-O)"
            codesign "${SIGN_ARGS[@]}" "$f"
        fi
    done < <(find "$STAGE/libexec/doz" -path '*.bundle/*' -type f -print0)
else
    say "  [dry-run] for each Mach-O file under $STAGE/libexec/doz/*.bundle: codesign ${SIGN_ARGS[*]} <file>"
fi
run codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$STAGE/libexec/doz/doz"

# 4. Verify the signature and the entitlement.
run codesign --verify --strict --verbose=2 "$STAGE/libexec/doz/doz"
if [[ -z "$DRY_RUN" ]]; then
    ents="$(codesign -d --entitlements - --xml "$STAGE/libexec/doz/doz" 2>/dev/null || true)"
    for e in com.apple.security.virtualization com.apple.security.device.audio-input; do
        grep -q "$e" <<<"$ents" || fail "the signed doz does not carry $e"
    done
    say "  entitlements: com.apple.security.virtualization, com.apple.security.device.audio-input"
    if [[ -n "$SIGN_IDENTITY" ]]; then
        info="$(codesign -dv --verbose=4 "$STAGE/libexec/doz/doz" 2>&1)"
        grep -q "^Authority=$SIGN_IDENTITY\$" <<<"$info" || fail "the doz is not signed by $SIGN_IDENTITY"
        [[ -z "$TEAM_ID" ]] || grep -q "^TeamIdentifier=$TEAM_ID\$" <<<"$info" || fail "the doz's TeamIdentifier is not $TEAM_ID"
        grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' <<<"$info" || fail "the doz is not signed with the hardened runtime"
        grep -q '^Timestamp=' <<<"$info" || fail "the doz's signature has no secure timestamp"
        say "  signed: $SIGN_IDENTITY · hardened runtime · secure timestamp"
    fi
    [[ "$("$STAGE/bin/doz" --version)" == "$VERSION" ]] || fail "the packed doz says $("$STAGE/bin/doz" --version), not $VERSION"
    say "  doz --version: $VERSION"
    # The flavor, as the binary itself says it. Public: `doz account add x --chatgpt` is refused in argument
    # validation — before any store, host or browser is touched (a scratch store and settings dir all the same) —
    # and there is no kernels/ folder. Private: --chatgpt is in `doz account add --help` (never RUN: it would sign in).
    chk="$(mktemp -d "${TMPDIR:-/tmp/}doz-release-check.XXXXXX")"
    if [[ "$PUBLIC" == 1 ]]; then
        said="$(env -u DOZ_TEST_PUBLIC_BUILD XDG_CONFIG_HOME="$chk/xdg" DOZ_STORE="$chk/store" "$STAGE/bin/doz" account add x --chatgpt --store "$chk/store" 2>&1 </dev/null || true)"
        rm -rf "$chk"
        grep -q "does not include Dozer's own ChatGPT sign-in" <<<"$said" || fail "the packed doz is not the public flavor (doz account add --chatgpt did not refuse: $said)"
        [[ ! -e "$STAGE/libexec/doz/kernels" ]] || fail "a public build carries no sound kernel"
        say "  flavor: public (no ChatGPT sign-in of its own, no sound kernel)"
    else
        help="$(env -u DOZ_TEST_PUBLIC_BUILD XDG_CONFIG_HOME="$chk/xdg" "$STAGE/bin/doz" account add --help 2>&1 || true)"
        rm -rf "$chk"
        grep -q -- "--chatgpt" <<<"$help" || fail "PUBLIC=0 but the packed doz is the public flavor (no --chatgpt in doz account add --help)"
        say "  flavor: private"
    fi
    if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
        [[ "$(shasum -a 256 "$STAGE/libexec/doz/kernels/$SOUND_KERNEL_NAME" | cut -d' ' -f1)" == "$SOUND_KERNEL_SHA" ]] || fail "the staged sound kernel's sha256 is wrong"
        say "  sound kernel (experimental): kernels/$SOUND_KERNEL_NAME, sha256 ${SOUND_KERNEL_SHA:0:12}…"
    fi
fi

# 5. Notarise (Developer ID with a profile only).
if [[ -n "$SIGN_IDENTITY" && -n "$NOTARY_PROFILE" ]]; then
    ZIP="$OUT/${NAME}-notarize.zip"
    run ditto -c -k --keepParent "$STAGE/libexec/doz" "$ZIP"
    if [[ -n "$DRY_RUN" ]]; then
        run xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
        run spctl --assess --type install --verbose=4 "$STAGE/libexec/doz/doz"
    else
        say "  notarising (Apple's notary service; usually a few minutes)…"
        result="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json 2>"$OUT/notarytool.err" || true)"
        status="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("status",""))' <<<"$result" 2>/dev/null || true)"
        sid="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("id",""))' <<<"$result" 2>/dev/null || true)"
        if [[ "$status" != "Accepted" ]]; then
            [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" "$OUT/notarytool-$sid.json" >/dev/null 2>&1 || true
            fail "notarisation: ${status:-no answer} (submission ${sid:-?}; $(head -c 300 "$OUT/notarytool.err" 2>/dev/null)) — the log, when Apple gave one: $OUT/notarytool-$sid.json"
        fi
        rm -f "$OUT/notarytool.err"
        say "  notarised: Accepted (submission $sid)"
        # Gatekeeper's verdict on the executable (it asks Apple for the ticket: a bare CLI cannot be stapled).
        verdict="$(spctl --assess --type install --verbose=4 "$STAGE/libexec/doz/doz" 2>&1 || true)"
        grep -q 'accepted' <<<"$verdict" && grep -q 'Notarized Developer ID' <<<"$verdict" \
            || fail "Gatekeeper does not accept the notarised doz: $verdict"
        say "  spctl: accepted — source=Notarized Developer ID"
    fi
    run rm -f "$ZIP"
    say "  ${DRY_RUN:+[dry-run] would be }notarised (a command-line tool cannot be stapled: Gatekeeper checks its ticket online on first run)"
elif [[ -n "$SIGN_IDENTITY" ]]; then
    say "note: signed with $SIGN_IDENTITY but NOT notarised — set NOTARY_PROFILE (see Makefile.config.example)"
else
    say "note: signed ad hoc (no SIGN_IDENTITY in Makefile.config) — fine for Homebrew, not for a download outside it"
fi

# 6. Pack + checksum (no macOS metadata files in the archive).
run env COPYFILE_DISABLE=1 tar --no-mac-metadata -C "$OUT/stage" -czf "$TARBALL" "doz-${VERSION}"
if [[ -z "$DRY_RUN" ]]; then
    # 611: what people install is the TARBALL — unpack it afresh and check what comes out of it.
    unpack="$(mktemp -d "${TMPDIR:-/tmp/}doz-release-unpack.XXXXXX")"
    tar -xzf "$TARBALL" -C "$unpack"
    packed="$unpack/doz-${VERSION}"
    codesign --verify --strict "$packed/libexec/doz/doz" || fail "the doz unpacked from the tarball does not verify"
    [[ "$("$packed/bin/doz" --version)" == "$VERSION" ]] || fail "the doz unpacked from the tarball says $("$packed/bin/doz" --version), not $VERSION"
    [[ -L "$packed/bin/doz" ]] || fail "bin/doz in the tarball is not a link"
    for f in LICENSE NOTICE THIRD-PARTY-LICENSES.txt; do [[ -s "$packed/libexec/doz/licences/$f" ]] || fail "the tarball has no licences/$f"; done
    rm -rf "$unpack"
    say "  from the tarball: codesign --verify --strict ok, doz --version $VERSION"
    (cd "$OUT" && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256")
    say "release: $TARBALL"
    say "         sha256 $(cut -d' ' -f1 "$TARBALL.sha256")  ($(du -h "$TARBALL" | cut -f1 | tr -d ' '))"
else
    say "  [dry-run] (cd $OUT && shasum -a 256 ${NAME}.tar.gz > ${NAME}.tar.gz.sha256)"
fi
