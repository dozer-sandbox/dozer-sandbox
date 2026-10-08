# Contributing to Dozer Sandbox

**How this project is built.** Dozer is developed in a private workspace alongside other projects, and
features arrive here already proven — designed, built and exercised there (by the VM suites and by a person
at the screen), then released from this repository. So please do not open a pull request for a large new
feature: it would likely land beside a version of itself already being built. Do open an issue to ask for
one — that is how it gets onto the list.

**Issues and fixes are welcome directly.** A bug report, a minimal reproduction, a targeted fix, or a
documentation correction: open it here, and it is handled here.

Before opening a pull request:

```bash
make build     # swift build (Xcode 27 or later, macOS 26 on Apple silicon)
make test      # unit tests — no VM, no entitlement
make audit     # Scripts/audit.sh — imports, dependencies, the guest binaries' provenance, the web UI's rules
make docs-drift-check   # the CLI reference and the user manual against the real `doz --help`
make test-vm   # the VM integration suite (an entitled test host; see CLAUDE.md "Verifying changes")
```

**CI and pull requests from forks.** This project's CI runs on its own Mac runners (a VM needs a real Mac), and those
never run code from a fork: for a pull request from a fork, only a short notice job and the VERSION check run (on a
GitHub-hosted runner). A maintainer runs the build, the tests and the VM suite by pushing your change to a branch of
this repository — so please make sure `make build`, `make test` and `make audit` pass on your Mac first. The workflow
never uses `pull_request_target`, and `make audit` fails if a self-hosted job loses its fork guard.

Every test target runs on scratch folders with the test seams on by default — no test touches your own
Dozer store, settings, keychain, `~/.codex` or `~/.claude` (CLAUDE.md, "Test safety is the default").

`make audit` failing is not a style nitpick: it keeps the dependency list short and exact, the guest
binaries reproducible, and the dashboard's security rules (loopback only, typed routes, no inline script)
enforced. If your change needs a new import or dependency, say why in the pull request rather than
silencing the audit.

[CLAUDE.md](CLAUDE.md) is the engineering guide — the rules each of which cost a bug to learn, where the
code lives, how to verify a change. It is written for people and for coding agents alike.

Security issues: please report them privately (GitHub's "Report a vulnerability" on this repository) rather
than in a public issue.
