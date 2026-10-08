# Dozer Sandbox — the `doz` command and the DozerKit Swift package (macOS on Apple silicon only).
#
# `swift build && swift test` at the root is the whole story for a consumer. These targets add
# what is easy to get wrong by hand: the build-system pin, the ENTITLED VM integration run, the
# committed guest binaries, the release, and the update feed. `make help` lists them.

NCPU := $(shell sysctl -n hw.logicalcpu 2>/dev/null || nproc)
JOBS ?= 8

# Xcode 27's SwiftPM defaults to the `swiftbuild` engine; probe rather than hardcode, so this is a
# no-op on a toolchain that already defaults to `native` (same probe as every workspace repo).
SWIFT_BUILD_SYSTEM := $(shell h=$$(swift build --help 2>/dev/null); \
	echo "$$h" | grep -q -- '--build-system' \
	  && echo "$$h" | grep -qE 'default: *swiftbuild' \
	  && echo "$$h" | grep -qE '^[[:space:]]*native' \
	  && echo '--build-system native')

# ── VM integration (needs com.apple.security.virtualization) ─────────────────
# The test host is an executable (not an XCTest bundle) because only a signed executable can
# carry the entitlement. VMTEST_STORE is a SCRATCH store — never an app's storage root.
VMTEST_BIN     := .build/debug/doz-vmtest
VMTEST_STORE  ?= $(or $(TMPDIR),/tmp/)doz-vmtest-store
VMTEST_ARGS   ?= all
# The watchdog: a hang (a VM op that never completes) fails the run instead of wedging it.
VMTEST_TIMEOUT ?= 420
# The pinned kernel's cache. Empty: under the store. CI sets a persistent directory under the
# runner's home so the ~600 MB release archive is fetched once per host, not once per run.
KERNEL_CACHE  ?=
export DOZ_KERNEL_CACHE := $(KERNEL_CACHE)

DECKHOLD_OUT := Guest/deckhold/out/deckhold
DECKHOLD_RES := Sources/DozerKit/Resources/deckhold

DOZNET_OUT := Guest/doznet/out/doznet
DOZNET_RES := Sources/DozerKit/Resources/doznet

DOZVIEW_OUT := Guest/dozview/out/dozview
DOZVIEW_RES := Sources/DozerKit/Resources/dozview

# ── The doz CLI (585) ──────────────────────────────────────────────────────
# `make cli` builds the debug binary and signs it with the virtualization entitlement (an unsigned
# doz runs every command but cannot boot a VM). `make install-cli PREFIX=~/.local` builds
# release and installs <PREFIX>/libexec/doz/{doz, the resource bundle} with <PREFIX>/bin/doz
# a symlink (the guest binaries are found beside the resolved executable).
CLI_BIN        := .build/debug/doz
PREFIX        ?= $(HOME)/.local
# The CLI's VM integration suite drives the REAL signed binary from separate processes, in a
# SCRATCH store (never ~/Library/Application Support/dozer-sandbox).
CLITEST_STORE ?= $(or $(TMPDIR),/tmp/)doz-clitest-store
# 588: the Claude-credentials suite's scratch store (the claude-code image is cloned from the vmtest store).
CLAUDETEST_STORE ?= $(or $(TMPDIR),/tmp/)doz-claudetest-store
# 593: templates and duplicates on pi (images seeded from the vmtest store when there).
TEMPLATES_STORE ?= $(or $(TMPDIR),/tmp/)doz-templates-store

# ── Documentation site (589) ──────────────────────────────────────────────────
# Built directly with `xcrun docc` — no swift-docc-plugin dependency: Scripts/audit.sh's dependency
# allowlist (step 3) checks every `.package(url:)` in Package.swift, and the plugin needs one for a
# build-time-only tool on a package whose whole point is a short, audited dependency list.
# `swift package dump-symbol-graph` is a first-class SwiftPM subcommand, so this needs nothing the
# plugin would add.
DOCC_CATALOG      := Sources/DozerKit/DozerKit.docc
DOCC_SYMBOLS_ALL  := .build/out/symbolgraph
DOCC_SYMBOLS_LIB  := .build/docc-symbolgraph-lib
DOCC_OUT         ?= .docc-build
DOCC_BASE_PATH   ?= /DozerKit/
DOCC_PREVIEW_PORT ?= 8000

.PHONY: help build test test-safety test-updates doz-update-keys publish promote audit audit-resolved web-assets web-assets-check test-cli-onboarding test-cli-terminal test-cli-hoststop test-cli-agentsudo test-cli-points test-cli-timezone test-cli-sessions test-cli-images test-cli-bases test-cli-permissions test-cli-clipboard test-cli-browser test-cli-openfiles test-cli-github test-cli-codex test-cli-access test-cli-tools tools-fixture test-cli-quickadd test-cli-projectwizard test-cli-tmux pullbench test-vm test-vm-agents test-vm-network test-vm-hardening test-vm-lineage prev-cli test-vm-upgrade vmtest-host kernel deckhold deckhold-snapshot-check deckhold-verify doznet doznet-verify dozview dozview-verify test-vm-ignore test-vm-cwd cli install-cli test-cli test-vm-claude test-vm-templates docs docs-preview docs-drift-check release bump bump-minor

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 22

build: ## Build every product (and the VM test host)
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS)

# ── Test safety BY DEFAULT ───────────────────────────────────────────────────
# Every test target runs with the seams that keep it off this Mac's real Dozer: no look at the Mac's Claude
# login, accounts' secrets in the host's memory (never the login keychain), a scratch Codex home, and a
# scratch settings file (XDG_CONFIG_HOME) whose store.path and defaults.projects_dir point at scratch
# folders — so a test that forgets --store cannot reach the default store, and a new sandbox's workspace is
# never made under ~/Developer. DOZ_TEST_GUARD=1 arms the guard in the code (`TestSafety`): a test host that
# would still resolve the default store, the real ~/.codex or the keychain's Claude Code item STOPS.
# These are forced (a stray value in the environment does not weaken them). The ONE way out is explicit:
# `make test-vm-claude DOZ_TEST_REAL_MAC=1` (e.g. to add this Mac's own Claude login, read-only).
TEST_SCRATCH ?= $(or $(TMPDIR),/tmp/)doz-test
TEST_XDG     ?= $(TEST_SCRATCH)-xdg
TEST_TARGETS := test test-vm test-vm-% test-cli test-cli-% test-updates kernel pullbench prev-cli
ifneq ($(DOZ_TEST_REAL_MAC),1)
$(TEST_TARGETS): export DOZ_TEST_GUARD := 1
$(TEST_TARGETS): export DOZ_TEST_NO_MAC_LOGIN := 1
$(TEST_TARGETS): export DOZ_TEST_CREDENTIALS := memory
$(TEST_TARGETS): export DOZ_TEST_CODEX_HOME := $(TEST_SCRATCH)-codex-home
$(TEST_TARGETS): export XDG_CONFIG_HOME := $(TEST_XDG)
endif

# The scratch settings file every test target starts from (written once; a test that changes it keeps its own).
test-safety:
	@if [ "$(DOZ_TEST_REAL_MAC)" = 1 ]; then echo "note: DOZ_TEST_REAL_MAC=1 — the test-safety defaults are OFF for this run"; exit 0; fi; \
	mkdir -p "$(TEST_SCRATCH)-codex-home" "$(TEST_XDG)/dozer-sandbox" "$(TEST_SCRATCH)-store" "$(TEST_SCRATCH)-projects"; \
	f="$(TEST_XDG)/dozer-sandbox/doz.toml"; \
	grep -qE '^path = "/' "$$f" 2>/dev/null && grep -qE '^projects_dir = "/' "$$f" 2>/dev/null || \
	  printf '[store]\npath = "%s"\n\n[defaults]\nprojects_dir = "%s"\n' "$(TEST_SCRATCH)-store" "$(TEST_SCRATCH)-projects" > "$$f"

test: test-safety web-assets-check ## Unit tests — no VM, no entitlement (never --parallel); first, the web assets' drift check
	swift test $(SWIFT_BUILD_SYSTEM) -j $(JOBS)

# 590: `doz ui`'s front end. WebSource/ is what people edit; Resources/Web is generated from it
# (content-hashed, digest manifest) and COMMITTED. The check fails when they differ — run by `make
# test` and Scripts/audit.sh (CI runs both), so a stale bundle cannot ship.
web-assets: ## Regenerate Sources/DozerWeb/Resources/Web from WebSource/ (commit the result)
	swift Scripts/build-web-assets.swift

web-assets-check: ## Fail when the committed web assets are not exactly what WebSource/ builds
	swift Scripts/build-web-assets.swift --check

audit: ## Neutrality audit: import allowlist, one remote dependency, no host brand
	@Scripts/audit.sh

vmtest-host: test-safety ## Build the VM test host and ad-hoc sign it with the virtualization entitlement
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) --product doz-vmtest
	codesign --force --sign - --entitlements Scripts/vmtest.entitlements $(VMTEST_BIN)

test-vm-agents: vmtest-host ## 579 agent images: bake claude-code + pi (cold: minutes, network), full agent suite
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) agents --store "$(VMTEST_STORE)"

test-vm-network: vmtest-host ## 580 proxied network: no NIC, policy, DNS, UDP, credentials, CA, bake preset, sleep → wake (network, claude-code image)
	perl -e 'alarm shift; exec @ARGV' 1800 $(VMTEST_BIN) network --store "$(VMTEST_STORE)"

test-vm-hardening: vmtest-host ## 583 regression tests: discard → cold boot (e2fsck), 200 hibernate cycles with flat threads/fds/footprint, 16 concurrent wakes (HARDENING=discard|leak|concurrent for one)
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) hardening $(HARDENING) --store "$(VMTEST_STORE)"

# 587's item 10 (a sandbox hibernated by the v0.4.0 test host, built from the tag, woken here) was
# retired by 592: the rename kept no backward compatibility (owner ruling), so an older release's
# store is not expected to wake. The journal-less e2fsck path it also covered is `lineage nojournal`.
test-vm-lineage: vmtest-host ## 587 image lineage: warm-base bakes, journal, discard, sync, accounting, reclaim, rederive, children (LINEAGE=part)
	perl -e 'alarm shift; exec @ARGV' 3600 $(VMTEST_BIN) lineage $(LINEAGE) --store "$(VMTEST_STORE)"

# 591: an update never costs a sleeping sandbox its sessions. The PREVIOUS release's `doz` sleeps
# sandboxes in a scratch store, and this build must wake them with their sessions. Also: a running
# host's program overwritten in place (the 591 incident), and an idle host replaced by an update.
# PREV_TAG is the latest release tag this branch descends from that IS a DozerKit release (its tree
# has Sources/doz); it is built once from the tag (git archive, no checkout touched) into PREV_DIR.
# 592: there is none yet — v0.9.0 and older are the pre-rename product, and by owner ruling their stores are NOT
# expected to wake under doz. Then the "previous" build is a COPY of this one (a reinstall of the same
# version): the sessions-survive-an-update wake, the in-place overwrite incident and the replaced-host
# idle exit all still run; only the cross-version part waits for the first DozerKit tag (v0.10.0).
PREV_TAG      ?= $(shell for t in $$(git tag --list 'v[0-9]*' --sort=-v:refname --merged HEAD 2>/dev/null); do \
                   git cat-file -e "$$t:Sources/doz" 2>/dev/null && { echo "$$t"; break; }; done)
ifneq ($(PREV_TAG),)
PREV_DIR      ?= $(or $(TMPDIR),/tmp/)doz-$(PREV_TAG)-cli
PREV_BIN      := $(PREV_DIR)/.build/debug/doz
else
PREV_DIR      ?= $(or $(TMPDIR),/tmp/)doz-self-prev-cli
PREV_BIN      := $(PREV_DIR)/doz
endif
UPGRADE_STORE ?= $(or $(TMPDIR),/tmp/)doz-upgrade-store

prev-cli: cli ## Build + sign the previous DozerKit release's doz from its tag (once, into PREV_DIR) — or copy this build when there is none
	@if [ -z "$(PREV_TAG)" ]; then \
	  echo "prev-cli: no DozerKit release below HEAD yet (v0.9.0 and older are the pre-rename product — not compatible, owner ruling 592); the previous build is a copy of this one"; \
	  mkdir -p "$(PREV_DIR)" && cp "$(CLI_BIN)" "$(PREV_DIR)/.doz.new" && mv -f "$(PREV_DIR)/.doz.new" "$(PREV_BIN)" && \
	  cp -R .build/debug/DozerKit_DozerKit.bundle .build/debug/DozerKit_DozerWeb.bundle "$(PREV_DIR)/" ; \
	elif [ ! -x "$(PREV_BIN)" ]; then \
	  rm -rf "$(PREV_DIR)" && mkdir -p "$(PREV_DIR)" && git archive $(PREV_TAG) | tar -x -C "$(PREV_DIR)" && \
	  (cd "$(PREV_DIR)" && swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) --product doz) ; fi
	codesign --force --sign - --entitlements Scripts/doz.entitlements $(PREV_BIN)

test-vm-upgrade: cli vmtest-host prev-cli ## 591 upgrade: the previous DozerKit release (or a copy of this build) sleeps lab + pi sandboxes (sessions, markers), this build wakes them; the running host's program overwritten in place; an idle host replaced by an update
	perl -e 'alarm shift; exec @ARGV' 3600 $(VMTEST_BIN) upgrade --old $(PREV_BIN) --doz $(CLI_BIN) --store "$(UPGRADE_STORE)" --entitlements Scripts/doz.entitlements

kernel: vmtest-host ## Fetch + verify the pinned Linux kernel into the cache (KERNEL_CACHE=dir; no VM)
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) kernel --store "$(VMTEST_STORE)"

test-vm-ignore: vmtest-host ## 599g workspace rules: .dozignore lock/hide + .dozreadonly through the guest view across boot, pause, sleep, hibernate and a three-process restore; live reload, case folding, a killed daemon, no rule file = no daemon, a rule file appearing, the cost
	perl -e 'alarm shift; exec @ARGV' 1800 $(VMTEST_BIN) ignore --store "$(VMTEST_STORE)"

test-vm-cwd: vmtest-host ## BUG cwd-after-wake: a program whose cwd is in /workspace keeps it across sleep, hibernate and a restore into a new process (the raw share as the control); the passthrough view's cost
	perl -e 'alarm shift; exec @ARGV' 1200 $(VMTEST_BIN) cwd-wake --store "$(VMTEST_STORE)"

test-vm: vmtest-host ## VM integration suite (entitled host, watchdog, scratch store; VMTEST_ARGS=lifecycle|crash)
	perl -e 'alarm shift; exec @ARGV' $(VMTEST_TIMEOUT) $(VMTEST_BIN) $(VMTEST_ARGS) --store "$(VMTEST_STORE)"

cli: ## Build the doz CLI and sign it with the virtualization entitlement (.build/debug/doz)
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) --product doz
	codesign --force --sign - --entitlements Scripts/doz.entitlements $(CLI_BIN)
	@# 602: stamp the repo's VERSION beside the binary, exactly as a release carries it
	@# (`ReleaseStamp` reads `VERSION` beside the resolved executable) — otherwise this build reports
	@# `DozerCommand.builtVersion`, which no feature remembers to bump (0.11.0 at 0.23.0).
	cp VERSION "$(dir $(CLI_BIN))VERSION"

install-cli: ## Build doz (release), sign it, install into PREFIX (default ~/.local): bin/doz → libexec/doz/
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) -c release --product doz
	codesign --force --sign - --entitlements Scripts/doz.entitlements .build/release/doz
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/libexec/doz"
	rm -rf "$(PREFIX)/libexec/doz/DozerKit_DozerKit.bundle" "$(PREFIX)/libexec/doz/DozerKit_DozerWeb.bundle"
	cp -R .build/release/DozerKit_DozerKit.bundle "$(PREFIX)/libexec/doz/"
	cp -R .build/release/DozerKit_DozerWeb.bundle "$(PREFIX)/libexec/doz/"
	cp VERSION "$(PREFIX)/libexec/doz/VERSION"   # 602: the stamp `doz --version` reads (see `cli`)
	@# NEVER overwrite the executable in place: a running `doz host` executes that very file, and
	@# rewriting it invalidates the running process's code signature — the Virtualization framework
	@# then refuses every VM it asks for ("Internal Virtualization error", 591). Copy + sign under a
	@# temporary name and RENAME over the old one: a running host keeps its original file (inode).
	cp .build/release/doz "$(PREFIX)/libexec/doz/.doz.new"
	codesign --force --sign - --entitlements Scripts/doz.entitlements "$(PREFIX)/libexec/doz/.doz.new"
	mv -f "$(PREFIX)/libexec/doz/.doz.new" "$(PREFIX)/libexec/doz/doz"
	ln -sf "$(PREFIX)/libexec/doz/doz" "$(PREFIX)/bin/doz"
	@echo "installed $(PREFIX)/bin/doz — run: doz doctor"
	@"$(PREFIX)/libexec/doz/doz" host status 2>/dev/null | grep -q '^host .* running' \
	  && echo "note: a doz host is running the PREVIOUS build (it keeps working); \`doz host stop\` switches to this one — sandboxes hibernate and wake on it" || true

# ── The release (598) ────────────────────────────────────────────────────────
# `make release VERSION=X.Y.Z` builds release, packs the install layout above as
# dist/doz-X.Y.Z-macos-arm64.tar.gz (+ .sha256) — what the GitHub Release carries and Homebrew
# installs — signed with a Developer ID and notarised when Makefile.config says how (see
# Makefile.config.example), ad hoc otherwise. DRY_RUN=1 prints every command and runs none.
-include Makefile.config
SIGN_IDENTITY  ?=
NOTARY_PROFILE ?=
# 611: a real release is the PUBLIC flavor (no sound kernel, no Dozer-own ChatGPT sign-in); PUBLIC=0 for a private rc.
PUBLIC         ?= 1
DIST           ?= dist

release: ## 598/611: build (PUBLIC=1 by default; PUBLIC=0 a private rc) + sign (+ notarise when configured) + pack dist/doz-VERSION-macos-arm64.tar.gz and its SHA-256 (VERSION=X.Y.Z; DRY_RUN=1 prints the plan)
	@VERSION="$(VERSION)" OUT="$(DIST)" JOBS="$(JOBS)" SWIFT_BUILD_SYSTEM="$(SWIFT_BUILD_SYSTEM)" \
	  SIGN_IDENTITY="$(SIGN_IDENTITY)" NOTARY_PROFILE="$(NOTARY_PROFILE)" HARDENED="$(HARDENED)" \
	  PUBLIC="$(PUBLIC)" TEST_BUILD="$(TEST_BUILD)" SOUND_KERNEL="$(SOUND_KERNEL)" NO_SOUND_KERNEL="$(NO_SOUND_KERNEL)" \
	  DRY_RUN="$(DRY_RUN)" SKIP_BUILD="$(SKIP_BUILD)" Scripts/release.sh

# ── Updates: the signed feed and the Homebrew channels (611) ─────────────────
# The feed is https://updates.dozersandbox.com/v1/feed.json (Distribution in Sources/DozerHost/Updates.swift — the
# ONE place the feed, tap and repository names live). UPDATES_DIR / TAP_DIR are local checkouts of the Pages repo
# and the tap (Makefile.config); they default to scratch folders until those repositories exist. Nothing is pushed
# unless PUSH=1, and the GitHub release is printed, never created.
UPDATES_DIR ?= $(or $(TMPDIR),/tmp/)doz-updates-site
TAP_DIR     ?= $(or $(TMPDIR),/tmp/)doz-homebrew-tap
CHANNEL     ?= canary

doz-update-keys: ## 611: ONCE, by the owner — make Dozer's update-signing key in the login keychain (asks first) and print its public key to commit
	@swift Scripts/update-key.swift generate

publish: ## 611: put dist/doz-VERSION's tarball on the feed + the channel formulas (VERSION=, NOTES=notes.md, CHANNEL=canary|beta|stable; DRY_RUN=1; PUSH=1)
	@VERSION="$(VERSION)" NOTES="$(NOTES)" CHANNEL="$(CHANNEL)" DIST="$(DIST)" UPDATES_DIR="$(UPDATES_DIR)" TAP_DIR="$(TAP_DIR)" \
	  DRY_RUN="$(DRY_RUN)" PUSH="$(PUSH)" Scripts/publish.sh

promote: ## 611: move a published build to a wider channel — never rebuilds (BUILD=N or VERSION=X.Y.Z, CHANNEL=beta|stable; PUSH=1)
	@BUILD="$(BUILD)" VERSION="$(VERSION)" CHANNEL="$(CHANNEL)" UPDATES_DIR="$(UPDATES_DIR)" TAP_DIR="$(TAP_DIR)" PUSH="$(PUSH)" Scripts/promote.sh

test-updates: cli ## 611: the update pipeline end to end with a TEST key (no network): release-shaped tarballs → publish → promote → a local feed server → doz update --check/notify/auto (tarball swap, a fake brew, channels, a downgrade refused, a tampered entry)
	@Scripts/test-updates.sh "$(CLI_BIN)"

test-cli: cli vmtest-host ## 585 CLI suite: the signed doz from separate processes (up/exec/run/attach, lifecycle, points, two sandboxes, kill -9 host, idle exit); 594: onboarding, init/up, the agent prompt, uninstall (stores /tmp/dzo-PID-*)
	perl -e 'alarm shift; exec @ARGV' 10800 $(VMTEST_BIN) cli --doz $(CLI_BIN) --store "$(CLITEST_STORE)"

test-cli-onboarding: cli vmtest-host ## 594: only test-cli's onboarding part (onboard, a joining start, detach/cancel, init/up, the agent prompt in pi + claude-code, uninstall)
	perl -e 'alarm shift; exec @ARGV' 3000 $(VMTEST_BIN) cli-onboarding --doz $(CLI_BIN)

test-cli-terminal: cli vmtest-host ## 594 W13: only test-cli's terminal part — on a pty, a detach / a session's end / SIGHUP put the outer terminal's modes and termios back
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-terminal --doz $(CLI_BIN)

test-cli-hoststop: cli vmtest-host ## 594 W22: only test-cli's host-stop part — each sandbox's line (plain off a terminal, animated on a pty), --json, nothing running, a host killed mid-stop
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-hoststop --doz $(CLI_BIN)

test-cli-agentsudo: cli vmtest-host ## 594 W23: only test-cli's agent-sudo part — sudo apt-get install in a fresh claude-code sandbox, --no-agent-sudo, the setting at the next boot, root reaches no more (prepares claude-code; network)
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) cli-agentsudo --doz $(CLI_BIN)

test-cli-points: cli vmtest-host ## 594 W25–W27: restore point names never cut + lookup by name/id/prefix, check before asking (W26), exec/run start an off sandbox
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-points --doz $(CLI_BIN)

test-cli-sessions: cli vmtest-host ## 608: a program in /workspace keeps its folder across hibernate and a host restart; doz sessions restart|end (SIGHUP ignored → TERM, tmux, a missing session, never a wake, a racing open, the record), workspace.view off and on
	perl -e 'alarm shift; exec @ARGV' 1500 $(VMTEST_BIN) cli-sessions --doz $(CLI_BIN)

test-cli-timezone: cli vmtest-host ## 594 W10: the sandbox follows the Mac's (stubbed) time zone at boot and every wake, or sandbox.timezone
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-timezone --doz $(CLI_BIN)

test-cli-images: cli vmtest-host ## 594 W28–W30: an older doz's pi image said (image ls, doctor, create, ls), never rebuilt by itself (a newer release neither); --rebuild; reset; own hostname; /usr/games (network)
	perl -e 'alarm shift; exec @ARGV' 3000 $(VMTEST_BIN) cli-images --doz $(CLI_BIN)

BASES_PARTS ?= cli,dockerfile,real,matrix
test-cli-bases: cli vmtest-host ## 596: base × agent images — doz base ls, --agent/--base/--dockerfile, doz_project.yaml; Dockerfiles through a FAKE container (install recorded, services, build/import/bake, unchanged = no bake, rebuild available, reset); the REAL container build (needs Apple's services — SKIPs otherwise; BASES_START_BUILDER=1 starts them through doz); the matrix Node/Python/Go/Debian/Alpine × Claude Code/none + pi on Python (network, ~1 h). BASES_PARTS=… picks
	BASES_PARTS="$(BASES_PARTS)" perl -e 'alarm shift; exec @ARGV' 7200 $(VMTEST_BIN) cli-bases --doz $(CLI_BIN)

test-cli-permissions: cli vmtest-host ## 597: agent permissions — doz net permissions / NAME / allow / deny, create --allow, Claude Code's own hosts reached under Standard, a refusal → a suggestion, live changes, the web warns, the facts in plain words, stored by name, defaults.permissions (prepares claude-code; network)
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) cli-permissions --doz $(CLI_BIN)

test-cli-clipboard: cli vmtest-host ## 599 (594.B1): OSC 52 → the Mac clipboard (a file, DOZ_TEST_PASTEBOARD) with a notice each time; a read never answered; 1 MiB + rate limits; sandbox.clipboard off (per sandbox, for all)
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-clipboard --doz $(CLI_BIN)

test-cli-browser: cli vmtest-host ## 599 (594.B2): xdg-open/$BROWSER → the Mac's browser (a file, DOZ_TEST_OPEN_URL), a fake OAuth sign-in's localhost callback forwarded into the sandbox; refusals, rate, sandbox.browser_bridge off
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-browser --doz $(CLI_BIN)

test-cli-openfiles: cli vmtest-host ## 599b: xdg-open/open/doz-open FILE in a shared-workspace sandbox → the Mac file in its default app or a listed one (a file, DOZ_TEST_OPEN_URL — never a real app); every refusal (outside, .., links out, non-documents, Mach-O as .txt, unlisted app, off, isolated), rate, URLs as before
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-openfiles --doz $(CLI_BIN)

test-cli-github: cli vmtest-host ## 599d: GitHub as the user through SEAMS only — a fake GitHub (git http-backend over TLS, its own CA; the proxy's upstream seam), a fake gh, a throwaway ssh-agent: clone, the swap (Basic + token), read-only refusals (push, API, GraphQL mutation), no token in the guest, push, identity, key source, off revokes, SSH agent on/off (prepares claude-code)
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) cli-github --doz $(CLI_BIN)

test-cli-codex: cli vmtest-host ## 599i: Codex through SEAMS only — a fake OpenAI over TLS (its own CA; the proxy's, the sign-in's and the refresh's upstream), the browser seam: Dozer's own ChatGPT sign-in, the real Codex in a VM answered via chatgpt.com with the placeholder swapped, a renewal on the Mac, the guest's renewal answered by the proxy, no token in the guest, no silent fallback, an API key, Alpine (prepares codex + alpine-codex; network: Docker Hub + npm; CODEX_KEEP=1 keeps the store)
	perl -e 'alarm shift; exec @ARGV' 5400 $(VMTEST_BIN) cli-codex --doz $(CLI_BIN)

test-cli-projectwizard: cli vmtest-host ## 599f: doz init --yes (every choice a flag) then doz up in the folder makes exactly that sandbox; doz_project.yml; both spellings refused; an interactive doz init on a pseudo-terminal walks the 9 steps, and again replaces the file only after its diff and a yes
	perl -e 'alarm shift; exec @ARGV' 1200 $(VMTEST_BIN) cli-projectwizard --doz $(CLI_BIN)

tools-fixture: ## 599h: download gh's pinned linux-arm64 release ONCE into the vmtest store's fixtures (test-cli-tools serves it from a local server — tests never reach github.com)
	@mkdir -p "$(VMTEST_STORE)/fixtures"
	@f="$(VMTEST_STORE)/fixtures/gh_2.102.0_linux_arm64.tar.gz"; \
	if [ "$$(shasum -a 256 "$$f" 2>/dev/null | cut -d' ' -f1)" = 7862c86c72f43df3a2d93ddde6f473285b4e2af61b494849846827e513ef6484 ]; then echo "ok $$f"; \
	else curl -fsSL --max-time 300 -o "$$f.part" https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_linux_arm64.tar.gz \
	  && [ "$$(shasum -a 256 "$$f.part" | cut -d' ' -f1)" = 7862c86c72f43df3a2d93ddde6f473285b4e2af61b494849846827e513ef6484 ] \
	  && mv "$$f.part" "$$f" && echo "downloaded $$f (sha256 checked)"; fi

test-cli-tools: cli vmtest-host tools-fixture ## 599h: the tools layer in real VMs through SEAMS only (a local download server for gh's tarball, a fake GitHub with its own CA, a fake gh, a throwaway ssh-agent): the first start's progress lines, a bad checksum refused (the boot goes on), --apply, gh auth status / gh repo view through the placeholder, the ssh client + github.com host keys, off/on across a hibernate+wake (quiet), lab + Debian + Alpine bases, no recipe change
	perl -e 'alarm shift; exec @ARGV' 3600 $(VMTEST_BIN) cli-tools --doz $(CLI_BIN)

test-cli-access: cli vmtest-host ## 599e: the Access step through SEAMS only (a fake GitHub API with its own CA, a fake gh, a throwaway ssh-agent; no VM): onboard --yes confirms GitHub (login + scopes) and SSH (N keys) and writes them as the defaults; a refused token and a missing agent are skipped with the reason (exit 0); doz access / access set (a fine-grained key: repositories it sees); no token anywhere
	perl -e 'alarm shift; exec @ARGV' 600 $(VMTEST_BIN) cli-access --doz $(CLI_BIN)

test-cli-quickadd: cli vmtest-host ## 599c: doz new — what it chose, created + started, a command runs, <projects_dir>/<name> is its /workspace; again → -2; --isolated/--name/--json; a taken name; pi without an API-key account; attached on a terminal (lab, a scratch projects folder)
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-quickadd --doz $(CLI_BIN)

test-cli-tmux: cli vmtest-host ## 599 (594.B3): sessions.tmux — a lab shell and Claude Code inside tmux (within deckhold): attach/detach, hibernate/wake, saved screens, a copy and xdg-open through tmux, no tmux in the image (prepares claude-code; network)
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) cli-tmux --doz $(CLI_BIN)

pullbench: vmtest-host ## 594 D12: pull the node base with 3 vs 6 concurrent layer downloads into fresh stores (network; ROUNDS=3)
	$(VMTEST_BIN) pullbench --rounds $(or $(ROUNDS),3)

test-vm-claude: cli vmtest-host ## 588 Claude credentials: the proxy's classifier (allow/strict), a placeholder across a host restart, revoke on shutdown, no token on disk — a FAKE key, nobody's login (DOZ_TEST_CLAUDE_LOGIN=1 adds this Mac's login, read-only)
	perl -e 'alarm shift; exec @ARGV' 1500 $(VMTEST_BIN) claude --doz $(CLI_BIN) --store "$(CLAUDETEST_STORE)"

test-vm-templates: cli vmtest-host ## 593 templates and duplicates on pi: a template holds the root disk only (never the state disk); duplicate's new workspace and fresh (or --copy-state) state disk
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) templates --doz $(CLI_BIN) --store "$(TEMPLATES_STORE)"

deckhold: ## Rebuild the deckhold guest binary, install it as the committed resource, refresh PROVENANCE.md
	Guest/deckhold/build.sh
	cp $(DECKHOLD_OUT) $(DECKHOLD_RES)
	@Scripts/deckhold-provenance.sh

deckhold-snapshot-check: ## 610: deckhold's SNAPSHOT replayed on a fresh emulator equals its own screen, cell by cell, after resizes (fixed cases + a seeded fuzz; on the Mac, the pinned ghostty)
	Guest/deckhold/test/run.sh $(or $(ITERATIONS),20000)

deckhold-verify: ## Rebuild deckhold from scratch and check the committed bytes match (slow: pinned Zig + ghostty)
	FORCE=1 Guest/deckhold/build.sh
	@cmp $(DECKHOLD_OUT) $(DECKHOLD_RES) && echo "ok deckhold: the committed binary is exactly what the pinned source builds"

doznet: ## Rebuild the doznet guest binary (580), install it as the committed resource, refresh PROVENANCE.md
	Guest/doznet/build.sh
	cp $(DOZNET_OUT) $(DOZNET_RES)
	@Scripts/doznet-provenance.sh

doznet-verify: ## Rebuild doznet from scratch and check the committed bytes match
	FORCE=1 Guest/doznet/build.sh
	@cmp $(DOZNET_OUT) $(DOZNET_RES) && echo "ok doznet: the committed binary is exactly what the pinned source builds"

dozview: ## Rebuild the dozview guest binary (599g: the workspace rules' view), install it as the committed resource, refresh PROVENANCE.md
	Guest/dozview/build.sh
	cp $(DOZVIEW_OUT) $(DOZVIEW_RES)
	@Scripts/dozview-provenance.sh

dozview-verify: ## Rebuild dozview from scratch and check the committed bytes match
	FORCE=1 Guest/dozview/build.sh
	@cmp $(DOZVIEW_OUT) $(DOZVIEW_RES) && echo "ok dozview: the committed binary is exactly what the pinned source builds"

docs-drift-check: ## 589: the CLI reference's documented command names vs real `doz --help` (cheap; names only); the user manual's commands, flags, settings and links (docs/manual)
	@JOBS=$(JOBS) Scripts/docs-drift-check.sh

docs: docs-drift-check ## 589: build the static docs site (DocC) into DOCC_OUT (default .docc-build); DOCC_BASE_PATH for hosting (default /DozerKit/)
	swift package dump-symbol-graph --minimum-access-level public
	@rm -rf "$(DOCC_SYMBOLS_LIB)" && mkdir -p "$(DOCC_SYMBOLS_LIB)"
	cp "$(DOCC_SYMBOLS_ALL)/DozerKit.symbols.json" "$(DOCC_SYMBOLS_LIB)/"
	rm -rf "$(DOCC_OUT)"
	xcrun docc convert "$(DOCC_CATALOG)" \
	  --analyze \
	  --fallback-display-name DozerKit \
	  --fallback-bundle-identifier org.dozerkit.docs \
	  --fallback-bundle-version 1.0.0 \
	  --additional-symbol-graph-dir "$(DOCC_SYMBOLS_LIB)" \
	  --output-path "$(DOCC_OUT)" \
	  --transform-for-static-hosting \
	  --hosting-base-path "$(DOCC_BASE_PATH)"
	@echo "ok docs: built $(DOCC_OUT) (hosting base path $(DOCC_BASE_PATH))"

docs-preview: docs ## 589: build, then serve the docs site locally (127.0.0.1:DOCC_PREVIEW_PORT, default 8000)
	@echo "docs-preview: http://127.0.0.1:$(DOCC_PREVIEW_PORT)/documentation/dozerkit/  (Ctrl-C to stop)"
	python3 -m http.server $(DOCC_PREVIEW_PORT) --bind 127.0.0.1 --directory "$(DOCC_OUT)"

audit-resolved: ## (app gate) this repo pins no workspace library — the ship's app gate calls it
	@echo "ok audit-resolved: dozer-sandbox pins no workspace library"

# ── Version (602) ────────────────────────────────────────────────────────────
# The app's VERSION file is what a feature claims (workspace `Scripts/feature-bump` runs `make bump`)
# and what `make cli` / `install-cli` stamp beside the binary; `make release VERSION=X.Y.Z` is given the
# release's version explicitly by the ship.
bump: ## Bump the patch version in VERSION (0.23.0 → 0.23.1)
	@V=$$(cat VERSION); \
	MAJOR=$$(echo $$V | cut -d. -f1); MINOR=$$(echo $$V | cut -d. -f2); PATCH=$$(echo $$V | cut -d. -f3); \
	NEW="$$MAJOR.$$MINOR.$$((PATCH + 1))"; echo "$$NEW" > VERSION; echo "  doz $$V → $$NEW"

bump-minor: ## Bump the minor version in VERSION (0.23.1 → 0.24.0)
	@V=$$(cat VERSION); \
	MAJOR=$$(echo $$V | cut -d. -f1); MINOR=$$(echo $$V | cut -d. -f2); \
	NEW="$$MAJOR.$$((MINOR + 1)).0"; echo "$$NEW" > VERSION; echo "  doz $$V → $$NEW"
