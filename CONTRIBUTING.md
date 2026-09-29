# Contributing to DozerKit

Features arrive here already proven: this package was productised from a probe (576's sleep POC)
with its harness app, SandboxLab, built alongside it — so a change usually lands fully formed,
exercised by `make test-vm` and by a human in SandboxLab first. This repo is the destination, not
the workshop. Please do not open a PR for a large new feature; it would likely land beside a version of
itself already being built upstream.

**Issues and fixes are welcome directly.** A bug report, a minimal reproduction, a targeted fix, or
a documentation correction: open it here, and it is handled here.

Before opening a PR:

```bash
make build     # swift build
make test      # unit tests (no VM)
make audit     # Scripts/audit.sh — this package must stay neutral and de-branded
make test-vm   # the VM integration suite (entitled test host; see CLAUDE.md)
```

`make audit` failing is not a style nitpick — it is the check that keeps this package usable from
more than one host app. If your change needs a new import, prefer extending
`Scripts/import-denylist.txt`'s companion allowlist reasoning over silencing the audit.
