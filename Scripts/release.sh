#!/usr/bin/env bash
# release.sh — 598 (H1): the prebuilt `doz` a release ships, and what Homebrew installs.
#
#   make release VERSION=0.12.0            # → dist/doz-0.12.0-macos-arm64.tar.gz (+ .sha256)
#   make release VERSION=0.12.0 DRY_RUN=1  # print every command, run none (the Developer ID plan)
#
# The tarball holds the install layout `make install-cli` makes, under one top directory:
#
#   doz-<version>/bin/doz                    → ../libexec/doz/doz   (a relative link)
#   doz-<version>/libexec/doz/doz            the executable, signed with Scripts/doz.entitlements
#   doz-<version>/libexec/doz/VERSION        the version it was built for (DozerCommand.version reads it)
#   doz-<version>/libexec/doz/DozerKit_*.bundle   its resources (guest binaries, web assets)
#   doz-<version>/libexec/doz/kernels/vmlinux-6.18.15-186-sound   EXPERIMENTAL audio sandboxes' kernel (see below)
#
# EXPERIMENTAL (604): the sound kernel (kata 6.18.15-186 + workspace probes/604-*/kernel/sound.conf) is NOT in git
# (16 MB). SOUND_KERNEL names the file (default: the 604 probe's build); it must have the sha256 pinned in
# Sources/DozerKit/Audio.swift (SoundKernel.sha256) or the release stops. NO_SOUND_KERNEL=1 ships without it
# (doz create --audio then says this doz does not carry one).
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
# Inputs (environment; the Makefile passes them): VERSION (default: the exact vX.Y.Z tag at HEAD),
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
SOUND_KERNEL="${SOUND_KERNEL:-/private/tmp/claude-502/-Users-jscott-Developer-deck-factory-A/cfb48c97-0265-4851-b0f8-ecd4082f0b1f/scratchpad/kbuild/vmlinux-6.18.15-186-sound}"
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
    [[ -f "$SOUND_KERNEL" ]] || fail "no sound kernel at SOUND_KERNEL=$SOUND_KERNEL (or NO_SOUND_KERNEL=1 to ship without — doz create --audio then refuses)"
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

say "release: doz $VERSION → $TARBALL ($MODE signature${NOTARY_PROFILE:+, notarised with profile $NOTARY_PROFILE})"
[[ -n "$DRY_RUN" ]] && say "release: DRY RUN — every command is printed, none is run"

# 1. Build (release).
if [[ -z "${SKIP_BUILD:-}" ]]; then
    # shellcheck disable=SC2086 — SWIFT_BUILD_SYSTEM is empty or two words, on purpose.
    run swift build ${SWIFT_BUILD_SYSTEM:-} -j "$JOBS" -c release --product doz
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
run ln -s ../libexec/doz/doz "$STAGE/bin/doz"

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
    grep -q 'com.apple.security.virtualization' <<<"$ents" || fail "the signed doz does not carry com.apple.security.virtualization"
    say "  entitlement: com.apple.security.virtualization"
    [[ "$("$STAGE/bin/doz" --version)" == "$VERSION" ]] || fail "the packed doz says $("$STAGE/bin/doz" --version), not $VERSION"
    say "  doz --version: $VERSION"
    if [[ -z "${NO_SOUND_KERNEL:-}" ]]; then
        grep -q 'com.apple.security.device.audio-input' <<<"$ents" || fail "the signed doz does not carry com.apple.security.device.audio-input"
        [[ "$(shasum -a 256 "$STAGE/libexec/doz/kernels/$SOUND_KERNEL_NAME" | cut -d' ' -f1)" == "$SOUND_KERNEL_SHA" ]] || fail "the staged sound kernel's sha256 is wrong"
        say "  sound kernel (experimental): kernels/$SOUND_KERNEL_NAME, sha256 ${SOUND_KERNEL_SHA:0:12}…"
    fi
fi

# 5. Notarise (Developer ID with a profile only).
if [[ -n "$SIGN_IDENTITY" && -n "$NOTARY_PROFILE" ]]; then
    ZIP="$OUT/${NAME}-notarize.zip"
    run ditto -c -k --keepParent "$STAGE/libexec/doz" "$ZIP"
    run xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    run spctl --assess --type install --verbose=4 "$STAGE/libexec/doz/doz"
    run codesign -dv --verbose=4 "$STAGE/libexec/doz/doz"
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
    (cd "$OUT" && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256")
    say "release: $TARBALL"
    say "         sha256 $(cut -d' ' -f1 "$TARBALL.sha256")  ($(du -h "$TARBALL" | cut -f1 | tr -d ' '))"
else
    say "  [dry-run] (cd $OUT && shasum -a 256 ${NAME}.tar.gz > ${NAME}.tar.gz.sha256)"
fi
