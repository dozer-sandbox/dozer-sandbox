<!-- placeholder: SnoozeContainerKit library name (== directory basename == last URL component, must match) ·
     {{name}} lowercase slug · {{ONE_LINE_DESCRIPTION}} · {{PRODUCTS}} table of products this package
     exposes · {{DEP_NAME}}/{{DEP_PIN}} optional single upstream sovereign-library dependency, delete
     the "Dependencies" section if this library has none · deck-factory path to the workspace root -->

# CLAUDE.md

Guidance for Claude Code when working in this repo.

**Process lives one level up.** `/feature`, `/plan`, `/ship`, `/fleet`, the `changes/` ledger,
`ROADMAP.md`, `BACKLOG.md`, and `CHANGELOG.md` are workspace-level and run from `deck-factory`,
not from here. This file holds only the code rules specific to `SnoozeContainerKit`.

## This is a sovereign library — release discipline is different from an app

`SnoozeContainerKit` ships by **semver tag**, not by app version bumps. `swift build && swift test` at the
root is the whole story for a consumer; this Makefile only adds the two things easy to get wrong by
hand — the prelaunch mirror in remote mode, and (if applicable) the Linux container this package
must keep compiling in.

- **A library never depends on an app**, and never depends the other direction on anything under
  `repo/app/*`. The only dependencies this package may declare are other sovereign libraries under
  `repo/lib/*`, by the same `lib()` local/pin resolution an app uses.
- **A library never claims a fleet instance token.** A worktree of this library
  (`.claude/worktrees/slot-<token>/SnoozeContainerKit`) reuses the SAME token an app slot already claimed —
  it exists only so that app's build can override to it, never to run this package standalone
  under a fleet instance.
- **This package's own directory basename and the last path component of its remote URL must both
  be `SnoozeContainerKit`.** SwiftPM derives package identity from them; get it wrong and every
  `.product(name: …, package: "SnoozeContainerKit")` reference in every consumer breaks. Never expose this
  package at two paths (a compatibility symlink produces a duplicate-module clang segfault).
- **A library's slot worktree is one level deeper than an app's**: it ends in the library's own
  name — `.claude/worktrees/slot-<token>/SnoozeContainerKit`, not `.../slot-<token>`. The ancestor-walk depth
  used to find the workspace root is **3/7** here (3 from a primary checkout, 7 from a slot
  worktree), vs an app's 3/6, precisely because of that extra path component.

## Dependencies

{{PRODUCTS}}

If this package has an upstream sovereign-library dependency (delete this subsection if it has
none): `Package.swift` resolves `{{DEP_NAME}}` (pinned at `{{DEP_PIN}}`) through the same `lib()`
helper a consuming app uses — a sibling checkout at `<workspace>/repo/lib/{{DEP_NAME}}` when one is
present, the pinned tag otherwise. The committed `Package.resolved` is the **local-mode** file (no
entry for a path dependency); after any `DECK_LOCAL_PACKAGES=0` run, `git checkout Package.resolved`.

## Neutrality is checked, not asserted

`Scripts/audit.sh` runs on every `make audit` and in CI. Extend its denylist rather than relaxing
it when a new import is genuinely needed — the checks it runs exist because each one caught a real
regression upstream:

- No denylisted (platform-UI / app-only, e.g. SwiftUI/AppKit/host-framework) import anywhere under
  `Sources/` — this package is meant to be usable from an app, a CLI, or (where applicable) a Linux
  server process alike.
- No app-brand literal (a bundle id, a product name) survives in this package. Storage location,
  brand strings, and product identity are the HOST's decision, declared once and bootstrapped in —
  never hardcoded here.
- Any platform-conditional import sits behind its `#if canImport(...)` seam in both directions, so
  neither the macOS nor the Linux build breaks silently.

## Verifying changes

```bash
make build   # swift build, mirror flag applied only when it is needed
make test    # swift test
make audit   # Scripts/audit.sh — neutrality + de-branding (+ Linux import seams, if applicable)
make linux   # compile-check in the pinned Linux container, if this package is Foundation-only
```

## Contributing

Features arrive here by **graduation** from a private playground repo — see `docs/GRADUATION.md`
in the workspace. Issues and fixes are welcome directly; see `CONTRIBUTING.md`.
