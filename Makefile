# SnoozeContainerKit — sovereign package (feature 578; workspace template, derived from
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
VMTEST_BIN     := .build/debug/snooze-vmtest
VMTEST_STORE  ?= $(or $(TMPDIR),/tmp/)snooze-vmtest-store
VMTEST_ARGS   ?= all
# The watchdog: a hang (a VM op that never completes) fails the run instead of wedging it.
VMTEST_TIMEOUT ?= 420
# The pinned kernel's cache. Empty: under the store. CI sets a persistent directory under the
# runner's home so the ~600 MB release archive is fetched once per host, not once per run.
KERNEL_CACHE  ?=
export SNOOZE_KERNEL_CACHE := $(KERNEL_CACHE)

DECKHOLD_OUT := Guest/deckhold/out/deckhold
DECKHOLD_RES := Sources/SnoozeContainerKit/Resources/deckhold

SNOOZENET_OUT := Guest/snoozenet/out/snoozenet
SNOOZENET_RES := Sources/SnoozeContainerKit/Resources/snoozenet

# ── The snooze CLI (585) ──────────────────────────────────────────────────────
# `make cli` builds the debug binary and signs it with the virtualization entitlement (an unsigned
# snooze runs every command but cannot boot a VM). `make install-cli PREFIX=~/.local` builds
# release and installs <PREFIX>/libexec/snooze/{snooze, the resource bundle} with <PREFIX>/bin/snooze
# a symlink (the guest binaries are found beside the resolved executable).
CLI_BIN        := .build/debug/snooze
PREFIX        ?= $(HOME)/.local
# The CLI's VM integration suite drives the REAL signed binary from separate processes, in a
# SCRATCH store (never ~/Library/Application Support/SnoozeContainerKit).
CLITEST_STORE ?= $(or $(TMPDIR),/tmp/)snooze-clitest-store
# 588: the Claude-credentials suite's scratch store (the claude-code image is cloned from the vmtest store).
CLAUDETEST_STORE ?= $(or $(TMPDIR),/tmp/)snooze-claudetest-store

# ── Documentation site (589) ──────────────────────────────────────────────────
# Built directly with `xcrun docc` — no swift-docc-plugin dependency: Scripts/audit.sh's dependency
# allowlist (step 3) checks every `.package(url:)` in Package.swift, and the plugin needs one for a
# build-time-only tool on a package whose whole point is a short, audited dependency list.
# `swift package dump-symbol-graph` is a first-class SwiftPM subcommand, so this needs nothing the
# plugin would add. See changes/589-i139-SNOOZE-DOCS-SITE/589.01-PLAN.md (workspace repo).
DOCC_CATALOG      := Sources/SnoozeContainerKit/SnoozeContainerKit.docc
DOCC_SYMBOLS_ALL  := .build/out/symbolgraph
DOCC_SYMBOLS_LIB  := .build/docc-symbolgraph-lib
DOCC_OUT         ?= .docc-build
DOCC_BASE_PATH   ?= /SnoozeContainerKit/
DOCC_PREVIEW_PORT ?= 8000

.PHONY: help build test audit web-assets web-assets-check test-vm test-vm-agents test-vm-network test-vm-hardening test-vm-lineage v040-host vmtest-host kernel deckhold deckhold-verify snoozenet snoozenet-verify cli install-cli test-cli test-vm-claude docs docs-preview docs-drift-check

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 22

build: ## Build every product (and the VM test host)
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS)

test: web-assets-check ## Unit tests — no VM, no entitlement (never --parallel); first, the web assets' drift check
	swift test $(SWIFT_BUILD_SYSTEM) -j $(JOBS)

# 590: `snooze ui`'s front end. WebSource/ is what people edit; Resources/Web is generated from it
# (content-hashed, digest manifest) and COMMITTED. The check fails when they differ — run by `make
# test` and Scripts/audit.sh (CI runs both), so a stale bundle cannot ship.
web-assets: ## Regenerate Sources/SnoozeWeb/Resources/Web from WebSource/ (commit the result)
	swift Scripts/build-web-assets.swift

web-assets-check: ## Fail when the committed web assets are not exactly what WebSource/ builds
	swift Scripts/build-web-assets.swift --check

audit: ## Neutrality audit: import allowlist, one remote dependency, no host brand
	@Scripts/audit.sh

vmtest-host: ## Build the VM test host and ad-hoc sign it with the virtualization entitlement
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) --product snooze-vmtest
	codesign --force --sign - --entitlements Scripts/vmtest.entitlements $(VMTEST_BIN)

test-vm-agents: vmtest-host ## 579 agent images: bake claude-code + pi (cold: minutes, network), full agent suite
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) agents --store "$(VMTEST_STORE)"

test-vm-network: vmtest-host ## 580 proxied network: no NIC, policy, DNS, UDP, credentials, CA, bake preset, sleep → wake (network, claude-code image)
	perl -e 'alarm shift; exec @ARGV' 1800 $(VMTEST_BIN) network --store "$(VMTEST_STORE)"

test-vm-hardening: vmtest-host ## 583 regression tests: discard → cold boot (e2fsck), 200 Deep Sleep cycles with flat threads/fds/footprint, 16 concurrent wakes (HARDENING=discard|leak|concurrent for one)
	perl -e 'alarm shift; exec @ARGV' 2400 $(VMTEST_BIN) hardening $(HARDENING) --store "$(VMTEST_STORE)"

# 587: item 10 needs a sandbox deep-slept by the LAST release. Its test host is built from the tag
# (git archive, no checkout touched) into V040_DIR, once; its own `crash-save` leaves vmtest-crash
# deep asleep in the store, and this build's `lineage compat-*` wakes / discards it.
V040_TAG ?= v0.4.0
V040_DIR ?= $(or $(TMPDIR),/tmp/)snooze-$(V040_TAG)-src
V040_BIN := $(V040_DIR)/.build/debug/snooze-vmtest

v040-host: ## Build + sign the $(V040_TAG) test host from the tag (once, into V040_DIR)
	@if [ ! -x "$(V040_BIN)" ]; then \
	  rm -rf "$(V040_DIR)" && mkdir -p "$(V040_DIR)" && git archive $(V040_TAG) | tar -x -C "$(V040_DIR)" && \
	  (cd "$(V040_DIR)" && swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) --product snooze-vmtest) ; fi
	codesign --force --sign - --entitlements Scripts/vmtest.entitlements $(V040_BIN)

test-vm-lineage: vmtest-host v040-host ## 587 image lineage: warm-base bakes, journal, discard, sync, accounting, reclaim, rederive (LINEAGE=part), then v0.4.0 compat
	perl -e 'alarm shift; exec @ARGV' 3600 $(VMTEST_BIN) lineage $(LINEAGE) --store "$(VMTEST_STORE)"
	@if [ -z "$(LINEAGE)" ]; then \
	  perl -e 'alarm shift; exec @ARGV' 600 $(VMTEST_BIN) lineage compat-clean --store "$(VMTEST_STORE)" && \
	  perl -e 'alarm shift; exec @ARGV' 600 $(V040_BIN) crash-save --store "$(VMTEST_STORE)" && \
	  perl -e 'alarm shift; exec @ARGV' 600 $(VMTEST_BIN) lineage compat-wake --store "$(VMTEST_STORE)" && \
	  perl -e 'alarm shift; exec @ARGV' 600 $(VMTEST_BIN) lineage compat-clean --store "$(VMTEST_STORE)" && \
	  perl -e 'alarm shift; exec @ARGV' 600 $(V040_BIN) crash-save --store "$(VMTEST_STORE)" && \
	  perl -e 'alarm shift; exec @ARGV' 600 $(VMTEST_BIN) lineage compat-discard --store "$(VMTEST_STORE)" ; fi

kernel: vmtest-host ## Fetch + verify the pinned Linux kernel into the cache (KERNEL_CACHE=dir; no VM)
	perl -e 'alarm shift; exec @ARGV' 900 $(VMTEST_BIN) kernel --store "$(VMTEST_STORE)"

test-vm: vmtest-host ## VM integration suite (entitled host, watchdog, scratch store; VMTEST_ARGS=lifecycle|crash)
	perl -e 'alarm shift; exec @ARGV' $(VMTEST_TIMEOUT) $(VMTEST_BIN) $(VMTEST_ARGS) --store "$(VMTEST_STORE)"

cli: ## Build the snooze CLI and sign it with the virtualization entitlement (.build/debug/snooze)
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) --product snooze
	codesign --force --sign - --entitlements Scripts/snooze.entitlements $(CLI_BIN)

install-cli: ## Build snooze (release), sign it, install into PREFIX (default ~/.local): bin/snooze → libexec/snooze/
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS) -c release --product snooze
	codesign --force --sign - --entitlements Scripts/snooze.entitlements .build/release/snooze
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/libexec/snooze"
	rm -rf "$(PREFIX)/libexec/snooze/SnoozeContainerKit_SnoozeContainerKit.bundle" "$(PREFIX)/libexec/snooze/SnoozeContainerKit_SnoozeWeb.bundle"
	cp -R .build/release/SnoozeContainerKit_SnoozeContainerKit.bundle "$(PREFIX)/libexec/snooze/"
	cp -R .build/release/SnoozeContainerKit_SnoozeWeb.bundle "$(PREFIX)/libexec/snooze/"
	@# NEVER overwrite the executable in place: a running `snooze host` executes that very file, and
	@# rewriting it invalidates the running process's code signature — the Virtualization framework
	@# then refuses every VM it asks for ("Internal Virtualization error", 591). Copy + sign under a
	@# temporary name and RENAME over the old one: a running host keeps its original file (inode).
	cp .build/release/snooze "$(PREFIX)/libexec/snooze/.snooze.new"
	codesign --force --sign - --entitlements Scripts/snooze.entitlements "$(PREFIX)/libexec/snooze/.snooze.new"
	mv -f "$(PREFIX)/libexec/snooze/.snooze.new" "$(PREFIX)/libexec/snooze/snooze"
	ln -sf "$(PREFIX)/libexec/snooze/snooze" "$(PREFIX)/bin/snooze"
	@echo "installed $(PREFIX)/bin/snooze — run: snooze doctor"
	@"$(PREFIX)/libexec/snooze/snooze" host status 2>/dev/null | grep -q '^host .* running' \
	  && echo "note: a snooze host is running the PREVIOUS build (it keeps working); \`snooze host stop\` switches to this one — sandboxes deep-sleep and wake on it" || true

test-cli: cli vmtest-host ## 585 CLI suite: the signed snooze from separate processes (up/exec/run/attach, lifecycle, points, two sandboxes, kill -9 host, idle exit)
	perl -e 'alarm shift; exec @ARGV' 1500 $(VMTEST_BIN) cli --snooze $(CLI_BIN) --store "$(CLITEST_STORE)"

test-vm-claude: cli vmtest-host ## 588 Claude credentials: the proxy's classifier (allow/strict), a placeholder across a host restart, revoke on shutdown, no token on disk — a FAKE key, nobody's login (SNOOZE_TEST_CLAUDE_LOGIN=1 adds this Mac's login, read-only)
	perl -e 'alarm shift; exec @ARGV' 1500 $(VMTEST_BIN) claude --snooze $(CLI_BIN) --store "$(CLAUDETEST_STORE)"

deckhold: ## Rebuild the deckhold guest binary, install it as the committed resource, refresh PROVENANCE.md
	Guest/deckhold/build.sh
	cp $(DECKHOLD_OUT) $(DECKHOLD_RES)
	@Scripts/deckhold-provenance.sh

deckhold-verify: ## Rebuild deckhold from scratch and check the committed bytes match (slow: pinned Zig + ghostty)
	FORCE=1 Guest/deckhold/build.sh
	@cmp $(DECKHOLD_OUT) $(DECKHOLD_RES) && echo "ok deckhold: the committed binary is exactly what the pinned source builds"

snoozenet: ## Rebuild the snoozenet guest binary (580), install it as the committed resource, refresh PROVENANCE.md
	Guest/snoozenet/build.sh
	cp $(SNOOZENET_OUT) $(SNOOZENET_RES)
	@Scripts/snoozenet-provenance.sh

snoozenet-verify: ## Rebuild snoozenet from scratch and check the committed bytes match
	FORCE=1 Guest/snoozenet/build.sh
	@cmp $(SNOOZENET_OUT) $(SNOOZENET_RES) && echo "ok snoozenet: the committed binary is exactly what the pinned source builds"

docs-drift-check: ## 589: the CLI reference's documented command names vs real `snooze --help` (cheap; names only)
	@Scripts/docs-drift-check.sh

docs: docs-drift-check ## 589: build the static docs site (DocC) into DOCC_OUT (default .docc-build); DOCC_BASE_PATH for hosting (default /SnoozeContainerKit/)
	swift package dump-symbol-graph --minimum-access-level public
	@rm -rf "$(DOCC_SYMBOLS_LIB)" && mkdir -p "$(DOCC_SYMBOLS_LIB)"
	cp "$(DOCC_SYMBOLS_ALL)/SnoozeContainerKit.symbols.json" "$(DOCC_SYMBOLS_LIB)/"
	rm -rf "$(DOCC_OUT)"
	xcrun docc convert "$(DOCC_CATALOG)" \
	  --analyze \
	  --fallback-display-name SnoozeContainerKit \
	  --fallback-bundle-identifier org.snoozecontainerkit.docs \
	  --fallback-bundle-version 1.0.0 \
	  --additional-symbol-graph-dir "$(DOCC_SYMBOLS_LIB)" \
	  --output-path "$(DOCC_OUT)" \
	  --transform-for-static-hosting \
	  --hosting-base-path "$(DOCC_BASE_PATH)"
	@echo "ok docs: built $(DOCC_OUT) (hosting base path $(DOCC_BASE_PATH))"

docs-preview: docs ## 589: build, then serve the docs site locally (127.0.0.1:DOCC_PREVIEW_PORT, default 8000)
	@echo "docs-preview: http://127.0.0.1:$(DOCC_PREVIEW_PORT)/documentation/snoozecontainerkit/  (Ctrl-C to stop)"
	python3 -m http.server $(DOCC_PREVIEW_PORT) --bind 127.0.0.1 --directory "$(DOCC_OUT)"
