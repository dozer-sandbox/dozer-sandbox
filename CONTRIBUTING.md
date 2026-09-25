<!-- placeholder: SnoozeContainerKit -->

# Contributing to SnoozeContainerKit

Features arrive here via **graduation** from the private playground: they are designed, built, and
lived with in a consuming app first, and land here already proven. That is why the commit history
may look shallow and why a change can appear fully formed — this repo is the destination, not the
workshop. Please do not open a PR for a large new feature; it would likely land beside a version of
itself already being built upstream.

**Issues and fixes are welcome directly.** A bug report, a minimal reproduction, a targeted fix, or
a documentation correction: open it here, and it is handled here.

Before opening a PR:

```bash
make build   # swift build
make test    # swift test
make audit   # Scripts/audit.sh — this package must stay neutral and de-branded
```

`make audit` failing is not a style nitpick — it is the check that keeps this package usable from
more than one host app. If your change needs a new import, prefer extending
`Scripts/import-denylist.txt`'s companion allowlist reasoning over silencing the audit.
