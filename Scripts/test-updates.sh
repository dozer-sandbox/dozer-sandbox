#!/bin/bash
# test-updates.sh — 611 (`make test-updates`): the update pipeline end to end, offline, with a THROWAWAY key.
#
#   release-shaped tarballs of this build (versions A < B < C, ad hoc signed) → make publish (canary) → promote →
#   a local feed server (python3 http.server on 127.0.0.1, conditional requests) → an INSTALLED copy of doz (A, a
#   tarball install in a scratch prefix) asked through the seams: doz update --check, the notify line, --json/-q
#   silence, mode off, channels, never a downgrade, a tampered entry ignored and said once, auto (the atomic swap,
#   the previous kept), and the Homebrew path through a FAKE brew (upgrade, a channel switch = uninstall + install).
#
# Never the network, never the real key, never the owner's store/settings/Homebrew: everything under one scratch
# folder; DOZ_TEST_GUARD=1 is set (a slip that reaches the default store stops the doz that made it).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILT="${1:?the built doz (.build/debug/doz)}"
R="$(mktemp -d "${TMPDIR:-/tmp/}doz-test-updates.XXXXXX")"
PORT=$(( 17611 + RANDOM % 300 ))
pass=0; failn=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$*"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
server=""
cleanup() { [[ -n "$server" ]] && kill "$server" 2>/dev/null || true; [[ -n "${KEEP:-}" ]] || rm -rf "$R"; }
trap cleanup EXIT

A=0.31.0-t.1; B=0.31.0-t.2; C=0.31.0-t.3; Z=9.9.9
# ── a release-shaped tarball of this build at version $1 ─────────────────────
tarball() {
    local v="$1" s="$R/stage/doz-$1"
    mkdir -p "$s/bin" "$s/libexec/doz" "$R/dist"
    for b in "$(dirname "$BUILT")"/DozerKit_*.bundle; do cp -cR "$b" "$s/libexec/doz/"; done
    cp -c "$BUILT" "$s/libexec/doz/doz"
    codesign --force --sign - --entitlements Scripts/doz.entitlements "$s/libexec/doz/doz" 2>/dev/null
    printf '%s\n' "$v" > "$s/libexec/doz/VERSION"
    printf 'public\n' > "$s/libexec/doz/RELEASE"
    ln -s ../libexec/doz/doz "$s/bin/doz"
    COPYFILE_DISABLE=1 tar --no-mac-metadata -C "$R/stage" -czf "$R/dist/doz-$v-macos-arm64.tar.gz" "doz-$v"
    (cd "$R/dist" && shasum -a 256 "doz-$v-macos-arm64.tar.gz" > "doz-$v-macos-arm64.tar.gz.sha256")
}
for v in $A $B $C; do tarball $v; done
mkdir -p "$R/prefix" && tar -xzf "$R/dist/doz-$A-macos-arm64.tar.gz" -C "$R/prefix" --strip-components 1
DOZ="$R/prefix/bin/doz"
check "the installed copy is $A" [ "$("$DOZ" --version)" = "$A" ]

# ── the test key, publish, promote ───────────────────────────────────────────
PUB="$(swift Scripts/update-key.swift test-key "$R/key")"
printf '## doz test\n\n- a **test** build — `doz update`\n' > "$R/notes.md"
pub() { TEST_PUBLISH=1 UPDATE_KEY_FILE="$R/key" UPDATE_PUBLIC_KEY="$PUB" ARCHIVE_BASE="http://127.0.0.1:$PORT/dl" \
        UPDATES_DIR="$R/site" TAP_DIR="$R/tap" DIST="$R/dist" NOTES="$R/notes.md" VERSION="$1" CHANNEL="$2" Scripts/publish.sh >"$R/publish.log" 2>&1; }
check "publish $B → canary" pub $B canary
check "publish $C → canary" pub $C canary
cp "$R/site/v1/feed.json" "$R/feed.before"
check "a re-publish is idempotent (no diff)" pub $B canary
check "  … the feed is byte-identical" cmp -s "$R/feed.before" "$R/site/v1/feed.json"
check "a re-cut of a published version (other bytes) is refused" bash -c "cp '$R/dist/doz-$C-macos-arm64.tar.gz' '$R/c.tgz'; cp '$R/dist/doz-$A-macos-arm64.tar.gz' '$R/dist/doz-$C-macos-arm64.tar.gz'; (cd '$R/dist' && shasum -a 256 doz-$C-macos-arm64.tar.gz > doz-$C-macos-arm64.tar.gz.sha256); ! TEST_PUBLISH=1 UPDATE_KEY_FILE='$R/key' UPDATE_PUBLIC_KEY='$PUB' UPDATES_DIR='$R/site' TAP_DIR='$R/tap' DIST='$R/dist' NOTES='$R/notes.md' VERSION=$C CHANNEL=canary Scripts/publish.sh >/dev/null 2>&1; rc=\$?; cp '$R/c.tgz' '$R/dist/doz-$C-macos-arm64.tar.gz'; (cd '$R/dist' && shasum -a 256 doz-$C-macos-arm64.tar.gz > doz-$C-macos-arm64.tar.gz.sha256); exit \$rc"
check "a key that doz does not trust is refused" bash -c "! TEST_PUBLISH=1 UPDATE_KEY_FILE='$R/key' UPDATE_PUBLIC_KEY=$(swift Scripts/update-key.swift test-key "$R/other") UPDATES_DIR='$R/site' TAP_DIR='$R/tap' DIST='$R/dist' NOTES='$R/notes.md' VERSION=$B CHANNEL=canary Scripts/publish.sh >/dev/null 2>&1"
check "promote B → beta" env UPDATES_DIR="$R/site" TAP_DIR="$R/tap" BUILD=1 CHANNEL=beta Scripts/promote.sh >/dev/null
check "promote B → stable (by VERSION, as the ship does)" env UPDATES_DIR="$R/site" TAP_DIR="$R/tap" VERSION=$B CHANNEL=stable Scripts/promote.sh >/dev/null
check "PUSH=1 refuses a feed that is not a git checkout" bash -c "! PUSH=1 UPDATES_DIR='$R/site' TAP_DIR='$R/tap' BUILD=1 CHANNEL=stable Scripts/promote.sh >/dev/null 2>&1"
check "promote never narrows (stable → canary refused)" bash -c "! UPDATES_DIR='$R/site' TAP_DIR='$R/tap' BUILD=1 CHANNEL=canary Scripts/promote.sh >/dev/null 2>&1"
check "promote of a build never published is refused" bash -c "! UPDATES_DIR='$R/site' TAP_DIR='$R/tap' BUILD=99 CHANNEL=beta Scripts/promote.sh >/dev/null 2>&1"
check "feed: schema 1, two entries, newest build first" python3 -c "
import json; f=json.load(open('$R/site/v1/feed.json'))
assert f['schema']==1 and f['product']=='doz' and [e['build'] for e in f['entries']]==[2,1], f
assert {e['version']:e['channel'] for e in f['entries']}=={'$B':'stable','$C':'canary'}"
check "notes page rendered (escaped)" grep -q '<strong>test</strong>' "$R/site/v1/notes/$B.html"
check "CNAME is the feed's host" grep -qx updates.dozersandbox.com "$R/site/CNAME"
check "formulas: doz = $B, doz-beta = $B, doz-canary = $C" bash -c "grep -q 'version \"$B\"' '$R/tap/Formula/doz.rb' && grep -q 'version \"$B\"' '$R/tap/Formula/doz-beta.rb' && grep -q 'version \"$C\"' '$R/tap/Formula/doz-canary.rb'"
check "formulas conflict with each other and run the upgrade check" bash -c "grep -q 'conflicts_with \"doz-beta\"' '$R/tap/Formula/doz.rb' && grep -q 'conflicts_with \"doz\"' '$R/tap/Formula/doz-canary.rb' && grep -q 'upgrade-check' '$R/tap/Formula/doz-beta.rb' && grep -q 'class DozCanary < Formula' '$R/tap/Formula/doz-canary.rb'"
if command -v ruby >/dev/null; then
    check "formulas are valid Ruby" bash -c "for f in '$R'/tap/Formula/*.rb; do ruby -c \"\$f\" >/dev/null || exit 1; done"
fi

# ── the local feed server ────────────────────────────────────────────────────
mkdir -p "$R/www/dl"
cp -R "$R/site/v1" "$R/www/v1"
cp "$R/dist/"*.tar.gz "$R/www/dl/"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$R/www" >"$R/server.log" 2>&1 &
server=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$PORT/v1/feed.json" >/dev/null 2>&1 && break; sleep 0.1; done

export DOZ_TEST_GUARD=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_CODEX_HOME="$R/codex"
export XDG_CONFIG_HOME="$R/xdg" DOZ_STORE="$R/store"
export DOZ_TEST_UPDATE_FEED="http://127.0.0.1:$PORT/v1/feed.json" DOZ_TEST_UPDATE_KEY="$PUB" DOZ_TEST_UPDATE_ALLOW_ADHOC=1
mkdir -p "$R/codex" "$R/xdg"
requests() { grep -c 'GET /v1/feed.json' "$R/server.log" || true; }

out="$("$DOZ" upgrade --check --store "$R/store" 2>&1)" && rc=0 || rc=$?
check "upgrade --check (stable): $B available, exit 10" bash -c "[ $rc = 10 ] && grep -q 'doz $B is available — upgrade: doz upgrade -y' <<<'$out'"
check "  … the notice links the notes" grep -q "notes: https://updates.dozersandbox.com/v1/notes/$B.html" <<<"$out"
n0=$(requests)
err="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls --store "$R/store" 2>&1 >/dev/null)"
check "notify: one line on stderr after a command" grep -q "doz $B is available" <<<"$err"
check "  … within a day: no new request" [ "$(requests)" = "$n0" ]
err="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls --store "$R/store" 2>&1 >/dev/null)"
check "  … the same version is not said again the same day" bash -c "! grep -q 'is available' <<<'$err'"
rm -f "$R/xdg/dozer-sandbox/updates.json"
err="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls --json --store "$R/store" 2>&1 >/dev/null)"
check "never with --json" bash -c "! grep -q 'is available' <<<'$err'"
err="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls -q --store "$R/store" 2>&1 >/dev/null)"
check "never with -q" bash -c "! grep -q 'is available' <<<'$err'"
err="$("$DOZ" ls --store "$R/store" 2>&1 >/dev/null)"
check "never off a terminal" bash -c "! grep -q 'is available' <<<'$err'"
"$DOZ" config set updates.mode off --store "$R/store" >/dev/null
n1=$(requests)
err="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls --store "$R/store" 2>&1 >/dev/null)"
check "mode off: nothing said, nothing asked" bash -c "! grep -q 'is available' <<<'$err' && [ $(requests) = $n1 ]"
"$DOZ" upgrade --check --store "$R/store" >/dev/null 2>&1 && rc=0 || rc=$?
check "mode off: doz upgrade --check still looks (exit 10)" [ "$rc" = 10 ]
"$DOZ" config set updates.mode notify --store "$R/store" >/dev/null
"$DOZ" config set updates.channel canary --store "$R/store" >/dev/null
out="$("$DOZ" upgrade --check --store "$R/store" 2>&1)" || true
check "canary: $C (every build)" grep -q "doz $C is available" <<<"$out"
"$DOZ" config set updates.channel beta --store "$R/store" >/dev/null
out="$("$DOZ" upgrade --check --store "$R/store" 2>&1)" || true
check "beta: $B (beta + stable, not canary)" grep -q "doz $B is available" <<<"$out"
out="$(DOZ_TEST_UPDATE_EXECUTABLE="$R/zzz/libexec/doz/doz" "$DOZ" upgrade --check --store "$R/store" 2>&1)" || true
check "a development build is never updated" grep -q "development build" <<<"$out"

# Never a downgrade: an install newer than everything is "the newest".
mkdir -p "$R/newer/bin" "$R/newer/libexec/doz" && cp -cR "$R/prefix/libexec/doz/." "$R/newer/libexec/doz/" && printf '%s\n' $Z > "$R/newer/libexec/doz/VERSION" && ln -s ../libexec/doz/doz "$R/newer/bin/doz"
out="$("$R/newer/bin/doz" upgrade --check --store "$R/store" 2>&1)" && rc=0 || rc=$?
check "never a downgrade: $Z is the newest (exit 0)" bash -c "[ $rc = 0 ] && grep -q 'is the newest' <<<'$out'"

# A tampered entry: dropped, said ONCE; the other entry still offered.
python3 - "$R/www/v1/feed.json" <<'PY'
import json, sys
p = sys.argv[1]; f = json.load(open(p))
for e in f["entries"]:
    if e["channel"] == "canary": e["sha256"] = "0" * 64
json.dump(f, open(p, "w"), indent=2)
PY
"$DOZ" config set updates.channel canary --store "$R/store" >/dev/null
err="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" upgrade --check --store "$R/store" 2>&1)" || true
check "a tampered entry is ignored (canary falls back to $B)" bash -c "grep -q 'doz $B is available' <<<'$err' && ! grep -q 'doz $C is available' <<<'$err'"
check "  … and said" grep -q "do not verify" <<<"$err"
err2="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls --store "$R/store" 2>&1 >/dev/null)"
check "  … once (not again after the next command)" bash -c "! grep -q 'do not verify' <<<'$err2'"
printf 'not json' > "$R/www/v1/feed.json"
touch -t 202901010000 "$R/www/v1/feed.json"     # a new Last-Modified (the tampered one was written this same second)
err="$("$DOZ" upgrade --check --store "$R/store" 2>&1)" || true
check "a feed that is not a feed is ignored, said" grep -q "the update feed was ignored" <<<"$err"
cp "$R/site/v1/feed.json" "$R/www/v1/feed.json"
touch -t 203001010000 "$R/www/v1/feed.json"     # a new Last-Modified: not a 304

# auto, a tarball install: idle (no host) → download, verify, atomic swap, the previous kept.
"$DOZ" config set updates.mode auto --store "$R/store" >/dev/null
rm -f "$R/xdg/dozer-sandbox/updates.json"
err="$(DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls --store "$R/store" 2>&1 >/dev/null)" || true
check "auto: installed $C (the next command runs it)" grep -q "Updated to $C" <<<"$err"
check "  … libexec/doz is $C" [ "$("$DOZ" --version)" = "$C" ]
check "  … the previous ($A) is kept as libexec/doz.previous" [ "$(cat "$R/prefix/libexec/doz.previous/VERSION")" = "$A" ]
check "  … bin/doz is still the link" [ -L "$R/prefix/bin/doz" ]
out="$("$DOZ" update --store "$R/store" 2>&1)" || true
check "  … then: the newest" grep -q "is the newest on the canary channel" <<<"$out"

# Homebrew through a fake brew: a keg layout pretended with DOZ_TEST_UPDATE_EXECUTABLE; the doz asking is version A
# again (the previous one auto kept — the installed copy is C now).
DOZ="$R/prefix/libexec/doz.previous/doz"
check "the doz asking is $A" [ "$("$DOZ" --version)" = "$A" ]
mkdir -p "$R/Cellar/doz/$A/libexec/doz"
cp -cR "$R/newer/libexec/doz/." "$R/Cellar/doz/$A/libexec/doz/"
printf '%s\n' $A > "$R/Cellar/doz/$A/libexec/doz/VERSION"
# Homebrew's clone of Dozer's tap: a scratch git clone whose origin moves on after the clone — doz update must
# fast-forward it before `brew upgrade` (Homebrew refreshes taps only now and then). The fake brew answers
# --repository with it.
git init -q -b main "$R/brew-tap-origin" && git -C "$R/brew-tap-origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git clone -q "$R/brew-tap-origin" "$R/brew-tap-clone"
cat > "$R/brew" <<SH
#!/bin/bash
if [ "\$1" = --repository ]; then echo "$R/brew-tap-clone"; exit 0; fi
echo "\$*" >> "$R/brew.log"
echo "no-ask=\${HOMEBREW_NO_ASK:-unset}" >> "$R/brew-env.log"
echo "==> fake brew \$*"
SH
chmod +x "$R/brew"
export DOZ_TEST_BREW="$R/brew" DOZ_TEST_UPDATE_EXECUTABLE="$R/Cellar/doz/$A/libexec/doz/doz"
"$DOZ" config unset updates.channel --store "$R/store" >/dev/null
"$DOZ" config set updates.mode notify --store "$R/store" >/dev/null
out="$("$DOZ" upgrade --check --store "$R/store" 2>&1)" || true
check "homebrew: the notice says doz upgrade -y" grep -q "doz $B is available — upgrade: doz upgrade -y " <<<"$out"
git -C "$R/brew-tap-origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
"$DOZ" upgrade --store "$R/store" >/dev/null 2>&1 < /dev/null && rc=0 || rc=$?
check "homebrew: doz upgrade with no terminal and no -y asks nothing and does nothing" bash -c "[ $rc != 0 ] && [ ! -s '$R/brew.log' ]"
"$DOZ" upgrade -y --store "$R/store" >/dev/null 2>&1 || true
check "homebrew: doz upgrade -y runs brew upgrade doz" grep -qx "upgrade doz" "$R/brew.log"
: > "$R/brew.log"
out="$("$DOZ" update --store "$R/store" 2>&1 < /dev/null)" || true
check "homebrew: doz update (the first name) still upgrades, without asking, and says it is doz upgrade now" bash -c "grep -qx 'upgrade doz' '$R/brew.log' && grep -q 'doz update is now doz upgrade' <<<\"\$1\"" _ "$out"
check "  … after fast-forwarding Dozer's tap" [ "$(git -C "$R/brew-tap-clone" rev-parse HEAD)" = "$(git -C "$R/brew-tap-origin" rev-parse HEAD)" ]
check "  … and Homebrew is never left asking [y/n]" bash -c "! grep -qv '^no-ask=1\$' '$R/brew-env.log'"
: > "$R/brew.log"
"$DOZ" upgrade --channel canary --yes --store "$R/store" >/dev/null 2>&1 || true
check "homebrew: --channel canary = uninstall doz, install the tap's doz-canary" bash -c "[ \"\$(cat '$R/brew.log')\" = \$'uninstall doz\ninstall dozer-sandbox/tap/doz-canary' ]"
check "  … the setting follows" grep -q '^channel = "canary"' "$R/xdg/dozer-sandbox/doz.toml"
: > "$R/brew.log"
export DOZ_TEST_UPDATE_EXECUTABLE="$R/Cellar/doz-canary/$Z/libexec/doz/doz"
mkdir -p "$(dirname "$DOZ_TEST_UPDATE_EXECUTABLE")" && cp -cR "$R/newer/libexec/doz/." "$(dirname "$DOZ_TEST_UPDATE_EXECUTABLE")/"
out="$("$R/newer/bin/doz" upgrade --channel stable --yes --store "$R/store" 2>&1)" || true
check "homebrew: a switch that would install an OLDER build is not made" bash -c "[ ! -s '$R/brew.log' ] && grep -q 'never installs an older build' <<<'$out'"
unset DOZ_TEST_UPDATE_EXECUTABLE
export DOZ_TEST_UPDATE_EXECUTABLE="$R/Cellar/doz/$A/libexec/doz/doz"
"$DOZ" config set updates.channel stable --store "$R/store" >/dev/null
"$DOZ" config set updates.mode auto --store "$R/store" >/dev/null
rm -f "$R/xdg/dozer-sandbox/updates.json"; : > "$R/brew.log"
DOZ_TEST_UPDATE_TTY=1 "$DOZ" ls --store "$R/store" >/dev/null 2>&1 || true
check "homebrew auto (idle): brew upgrade doz" grep -qx "upgrade doz" "$R/brew.log"

printf '\ntest-updates: %d passed, %d failed%s\n' "$pass" "$failn" "$([[ -n "${KEEP:-}" ]] && echo " (kept $R)")"
[[ "$failn" == 0 ]]
