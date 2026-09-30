# DozerKit — sovereign package (feature 578; workspace template, derived from
# repo/lib/GhosttyTerminalKit's Makefile: no sibling-library dependency, so no lib() lookup and no
# prelaunch mirror; macOS-only, so no Linux container).
#
# `swift build && swift test` at the root is the whole story for a consumer. These targets add
# what is easy to get wrong by hand: the build-system pin, the ENTITLED VM integration run, and
# the committed deckhold guest binary.

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
# plugin would add. See changes/589-*/589.01-PLAN.md (workspace repo).
DOCC_CATALOG      := Sources/DozerKit/DozerKit.docc
DOCC_SYMBOLS_ALL  := .build/out/symbolgraph
DOCC_SYMBOLS_LIB  := .build/docc-symbolgraph-lib
DOCC_OUT         ?= .docc-build
DOCC_BASE_PATH   ?= /DozerKit/
DOCC_PREVIEW_PORT ?= 8000

.PHONY: help build test audit web-assets web-assets-check test-cli-onboarding test-cli-terminal test-cli-hoststop test-cli-agentsudo test-cli-points test-cli-timezone test-cli-images test-cli-bases pullbench test-vm test-vm-agents test-vm-network test-vm-hardening test-vm-lineage prev-cli test-vm-upgrade vmtest-host kernel deckhold deckhold-verify doznet doznet-verify cli install-cli test-cli test-vm-claude test-vm-templates docs docs-preview docs-drift-check release

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 22

build: ## Build every product (and the VM test host)
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS)

# 591: the settings file (doz.toml under XDG_CONFIG_HOME) of every test run is a scratch one — the
# owner's own ~/.config never shapes a test (the CLI suites set their own, under their scratch store).
TEST_XDG ?= $(or $(TMPDIR),/tmp/)doz-unit-xdg
test test-vm test-vm-agents test-vm-network test-vm-hardening test-vm-lineage test-vm-upgrade test-cli test-vm-claude test-vm-templates kernel: export XDG_CONFIG_HOME := $(TEST_XDG)

test: web-assets-check ## Unit tests — no VM, no entitlement (never --parallel); first, the web assets' drift check
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

vmtest-host: ## Build the VM test host and ad-hoc sign it with the virtualization entitlement
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

test-vm: vmtest-host ## VM integration suite (entitled host, watchdog, scratch store; VMTEST_ARGS=lifecycle|crash)
	perl -e 'alarm shift; exec @ARGV' $(VMTEST_TIMEOUT) $(VMTEST_BIN) $(VMTEST_ARGS) --store "$(VMTEST_STORE)"

cli: ## Build the doz CLI and sign it with the virtualization entitlement (.build/debug/doz)
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) --product doz
	codesign --force --sign - --entitlements Scripts/doz.entitlements $(CLI_BIN)

install-cli: ## Build doz (release), sign it, install into PREFIX (default ~/.local): bin/doz → libexec/doz/
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) -c release --product doz
	codesign --force --sign - --entitlements Scripts/doz.entitlements .build/release/doz
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/libexec/doz"
	rm -rf "$(PREFIX)/libexec/doz/DozerKit_DozerKit.bundle" "$(PREFIX)/libexec/doz/DozerKit_DozerWeb.bundle"
	cp -R .build/release/DozerKit_DozerKit.bundle "$(PREFIX)/libexec/doz/"
	cp -R .build/release/DozerKit_DozerWeb.bundle "$(PREFIX)/libexec/doz/"
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
DIST           ?= dist

release: ## 598: build + sign (+ notarise when configured) + pack dist/doz-VERSION-macos-arm64.tar.gz and its SHA-256 (VERSION=X.Y.Z; DRY_RUN=1 prints the plan)
	@VERSION="$(VERSION)" OUT="$(DIST)" JOBS="$(JOBS)" SWIFT_BUILD_SYSTEM="$(SWIFT_BUILD_SYSTEM)" \
	  SIGN_IDENTITY="$(SIGN_IDENTITY)" NOTARY_PROFILE="$(NOTARY_PROFILE)" HARDENED="$(HARDENED)" \
	  DRY_RUN="$(DRY_RUN)" SKIP_BUILD="$(SKIP_BUILD)" Scripts/release.sh

test-cli: cli vmtest-host ## 585 CLI suite: the signed doz from separate processes (up/exec/run/attach, lifecycle, points, two sandboxes, kill -9 host, idle exit); 594: onboarding, init/up, the agent prompt, uninstall (stores /tmp/dzo-PID-*)
	perl -e 'alarm shift; exec @ARGV' 3600 $(VMTEST_BIN) cli --doz $(CLI_BIN) --store "$(CLITEST_STORE)"

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

test-cli-timezone: cli vmtest-host ## 594 W10: the sandbox follows the Mac's (stubbed) time zone at boot and every wake, or sandbox.timezone
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) cli-timezone --doz $(CLI_BIN)

test-cli-images: cli vmtest-host ## 594 W28–W30: an older doz's pi image said (image ls, doctor, create, ls), never rebuilt by itself (a newer release neither); --rebuild; reset; own hostname; /usr/games (network)
	perl -e 'alarm shift; exec @ARGV' 3000 $(VMTEST_BIN) cli-images --doz $(CLI_BIN)

BASES_PARTS ?= cli,dockerfile,real,matrix
test-cli-bases: cli vmtest-host ## 596: base × agent images — doz base ls, --agent/--base/--dockerfile, doz_project.yaml; Dockerfiles through a FAKE container (install recorded, services, build/import/bake, unchanged = no bake, rebuild available, reset); the REAL container build (needs Apple's services — SKIPs otherwise; BASES_START_BUILDER=1 starts them through doz); the matrix Node/Python/Go/Debian/Alpine × Claude Code/none + pi on Python (network, ~1 h). BASES_PARTS=… picks
	BASES_PARTS="$(BASES_PARTS)" perl -e 'alarm shift; exec @ARGV' 7200 $(VMTEST_BIN) cli-bases --doz $(CLI_BIN)

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

docs-drift-check: ## 589: the CLI reference's documented command names vs real `doz --help` (cheap; names only)
	@Scripts/docs-drift-check.sh

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
