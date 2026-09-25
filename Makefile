# placeholder legend: SnoozeContainerKit this library's name · {{DEP_NAME}} an optional single upstream
# sovereign-library dependency (delete the DEP_NAME block entirely, and set SWIFT_PKG_FLAGS := ,
# if this package has no such dependency) · {{LINUX_TARGETS}} space-separated `--target` list for
# the Foundation-only subset this package compiles on Linux (delete the linux/smoke targets
# entirely if this package is macOS-only, e.g. it links AppKit/Metal — see GhosttyTerminalKit for
# that shape) · {{DOCKER_IMAGE}} e.g. {{name}}/linux
#
# SnoozeContainerKit — sovereign package (workspace template; derived from repo/lib/DeckKit's real Makefile).
#
# `swift build && swift test` at the root is the whole story; these targets add the two things
# that are easy to get wrong by hand: the prelaunch mirror in remote mode, and (if applicable) the
# Linux container this package must keep compiling in.

NCPU := $(shell sysctl -n hw.logicalcpu 2>/dev/null || nproc)

# The {{DEP_NAME}} sibling this package resolves as a path dependency, or EMPTY
# when Package.swift will fall back to the pin. Same rule an app's manifest
# applies: a slot worktree considers ONLY its own token's library worktree. A
# LIBRARY slot worktree carries no `.instance-token`, so the slot name is the
# PARENT path component (`.../worktrees/slot-<token>/SnoozeContainerKit`) — exactly what
# `lib()` reads.
DECK_SLOT_DIR := $(if $(findstring /.claude/worktrees/,$(CURDIR)),$(notdir $(patsubst %/,%,$(dir $(CURDIR)))))
# A LIBRARY slot worktree is SEVEN levels deep, not six: it ends in the
# library's own name, one deeper than an app's. This mirrors the same fix in
# every consuming app's Package.swift / Makefile.
WORKSPACE_ROOT ?= $(abspath $(CURDIR)/../../..$(if $(DECK_SLOT_DIR),/../../../..))
{{DEP_NAME}}_LOCAL := $(shell \
	slot="$(WORKSPACE_ROOT)/repo/lib/{{DEP_NAME}}/.claude/worktrees/$(DECK_SLOT_DIR)/{{DEP_NAME}}"; \
	prim="$(WORKSPACE_ROOT)/repo/lib/{{DEP_NAME}}"; \
	if [ -n "$(DECK_SLOT_DIR)" ]; then \
	  [ -f "$$slot/Package.swift" ] && echo "$$slot"; \
	else \
	  [ -f "$$prim/Package.swift" ] && echo "$$prim"; \
	fi; true)

# A SwiftPM mirror rewrites package IDENTITY, so it must be supplied ONLY when
# the manifest falls back to the pin — never when a path dependency is in play.
MIRROR_FLAG := --config-path Scripts/swiftpm-remote-config

DECK_LOCAL_PACKAGES ?=
ifeq ($(DECK_LOCAL_PACKAGES),0)
SWIFT_PKG_FLAGS := --scratch-path .build-remote $(MIRROR_FLAG)
else
SWIFT_PKG_FLAGS := $(if $({{DEP_NAME}}_LOCAL),,$(MIRROR_FLAG))
endif

.PHONY: help build test audit linux smoke

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 22

build: ## Build every product
	swift build $(SWIFT_PKG_FLAGS) -j $(NCPU)

test: ## Run the package test suite
	swift test $(SWIFT_PKG_FLAGS) -j $(NCPU)

audit: ## App-neutrality + de-branding (+ Linux-seam, if applicable) audit
	@Scripts/audit.sh

# ── Linux (Foundation-only packages only) — delete this section if this
# package links AppKit/SwiftUI/Metal and has no Linux-buildable subset. ──────

linux: ## Compile-check the Foundation-only targets in the pinned Linux container
	@docker image inspect {{DOCKER_IMAGE}} >/dev/null 2>&1 || \
		docker build -t {{DOCKER_IMAGE}} -f Scripts/linux.Dockerfile Scripts
	docker run --rm -v "$(WORKSPACE_ROOT)":/ws -w /ws/repo/lib/SnoozeContainerKit \
		-v {{name}}-linux:/linux-build \
		{{DOCKER_IMAGE}} \
		swift build {{LINUX_TARGETS}} --scratch-path /linux-build/scratch

smoke: ## Run the Linux runtime smoke (builds if needed) in the container
	@docker image inspect {{DOCKER_IMAGE}} >/dev/null 2>&1 || \
		docker build -t {{DOCKER_IMAGE}} -f Scripts/linux.Dockerfile Scripts
	docker run --rm -v "$(WORKSPACE_ROOT)":/ws -w /ws/repo/lib/SnoozeContainerKit \
		-v {{name}}-linux:/linux-build \
		{{DOCKER_IMAGE}} \
		swift run --scratch-path /linux-build/scratch {{name}}-smoke
