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

.PHONY: help build test audit test-vm test-vm-agents test-vm-network test-vm-hardening vmtest-host kernel deckhold deckhold-verify snoozenet snoozenet-verify cli install-cli test-cli

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 22

build: ## Build every product (and the VM test host)
	swift build $(SWIFT_BUILD_SYSTEM) -j $(JOBS)

test: ## Unit tests — no VM, no entitlement (never --parallel)
	swift test $(SWIFT_BUILD_SYSTEM) -j $(JOBS)

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
	rm -rf "$(PREFIX)/libexec/snooze/SnoozeContainerKit_SnoozeContainerKit.bundle"
	cp -R .build/release/SnoozeContainerKit_SnoozeContainerKit.bundle "$(PREFIX)/libexec/snooze/"
	cp .build/release/snooze "$(PREFIX)/libexec/snooze/snooze"
	codesign --force --sign - --entitlements Scripts/snooze.entitlements "$(PREFIX)/libexec/snooze/snooze"
	ln -sf "$(PREFIX)/libexec/snooze/snooze" "$(PREFIX)/bin/snooze"
	@echo "installed $(PREFIX)/bin/snooze — run: snooze doctor"

test-cli: cli vmtest-host ## 585 CLI suite: the signed snooze from separate processes (up/exec/run/attach, lifecycle, points, two sandboxes, kill -9 host, idle exit)
	perl -e 'alarm shift; exec @ARGV' 1500 $(VMTEST_BIN) cli --snooze $(CLI_BIN) --store "$(CLITEST_STORE)"

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
