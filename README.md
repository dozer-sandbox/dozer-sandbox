# Dozer Sandbox

**Secure, suspendable Linux sandboxes for AI coding agents on your Mac — your API keys never go inside.**
[dozersandbox.com](https://dozersandbox.com)

Each sandbox is a small Linux virtual machine with your
project folder inside it. It starts in about a third of a second, pauses in a millisecond, and hibernates to
disk to give its memory back — then wakes with every program still running where it was. Run a coding agent
(Claude Code, Codex, pi) with its permission prompts off: the VM is the boundary, the network goes through a
policy you can read, and your keys never enter the sandbox.

```sh
brew trust --tap dozer-sandbox/tap             # once per Mac: Homebrew loads a third-party tap only once trusted
brew install dozer-sandbox/tap/doz             # stable; doz-beta and doz-canary are the other channels
doz ui                                         # opens the dashboard — a new install starts on its setup wizard
```

The dashboard's setup wizard checks this Mac, chooses how your agent signs in, and prepares an image; then
**New sandbox** (or Quick add) makes one. Each sandbox's workspace is a folder on your Mac, shared at
`/workspace` inside it — by default `~/dozer-sandbox-workspaces/<sandbox name>`, made when missing.
Keep them there unless you have a reason not to; Settings › Choose… (or `doz config set
defaults.projects_dir PATH`) moves the default.

Prefer the terminal? The same setup, without the dashboard:

```sh
doz onboard                 # once: checks this Mac, your agent's account, and prepares an image
cd ~/code/my-project
doz up                      # a sandbox for this folder (at /workspace), its agent running, your terminal attached
```

## Requirements

- A Mac with **Apple silicon** and **macOS 26** (Tahoe) or later.
- [Homebrew](https://brew.sh). (Each release is also a tarball on this repository's releases page.)
- For an agent: an account it can use — this Mac's own Claude Code or Codex login (read, never copied),
  an API key, or a Claude setup token. `doz onboard` walks you through it.

Linux sandboxes run on Apple's Virtualization framework through Apple's
[Containerization](https://github.com/apple/containerization) package. `doz` is signed and notarised, and
carries the virtualization entitlement macOS requires to boot a VM.

## What it does

| | |
|---|---|
| start (image prepared) | ~0.3–0.4 s to a running Linux |
| pause / resume | ~1 ms; attached terminals freeze and continue |
| hibernate (sleep to disk) | ~0.35 s; its memory goes back to the Mac |
| wake | ~0.3 s, with its programs, sessions and terminal screens as they were |
| after a crash | sleeping sandboxes are restored with their sessions; nothing is lost silently |

Measured on an M3 (Alpine guest, 512 MiB–1 GiB). Plus: a network that is **proxied** by default (no network
card in the VM; every connection is judged by a policy of permissions you can read and change — `doz net
permissions`), credentials **swapped in by the proxy** (the sandbox only ever sees a placeholder), restore
points and templates (APFS clones), workspace rules (`.dozignore`, `.dozreadonly`), browser sign-ins and
`open`/clipboard bridges back to the Mac, GitHub as you (read-only by default), and a dashboard you can also
serve to your other devices (`doz serve`).

## Updates and channels

doz tells you when a new release is out (at most once a day; one line on your terminal and a banner on the
dashboard) from a feed signed with the project's own key, and never installs anything that does not verify.
`updates.mode` is `notify` (the default), `auto` or `off`. Three release channels, one formula each:

| | |
|---|---|
| `brew install dozer-sandbox/tap/doz` | stable |
| `brew install dozer-sandbox/tap/doz-beta` | beta (and stable) |
| `brew install dozer-sandbox/tap/doz-canary` | every build, first |

`doz upgrade --channel beta` switches; your store, sandboxes and settings stay. See
[Installing, upgrading and uninstalling](docs/manual/02-install-upgrade-uninstall.md).

## Documentation

- **[The user manual](docs/manual/README.md)** — start here: getting started, projects, the lifecycle, the
  dashboard, terminals and sessions, images, agents and accounts, permissions and the network, restore
  points, resources, every setting, the security model, troubleshooting. Each page shows the CLI and the
  dashboard side by side, and is checked against the program on every build.
- [The CLI walkthrough](docs/CLI-WALKTHROUGH.md) (~25 minutes, from nothing installed to uninstalling again),
  the terser [CLI user guide](docs/CLI-USER-GUIDE.md), and the complete
  [CLI reference](Sources/DozerKit/DozerKit.docc/Articles/CLIReference.md).
- [The security model](docs/manual/16-security-model.md) — what the VM, the proxy and the placeholders keep
  from a sandbox, and what they do not.
- [DozerKit](docs/DOZERKIT.md) — the Swift engine underneath, for developers: the lifecycle, lineage,
  memory, the proxied network, the host process, and how to depend on it.

## Building from source

```sh
make build        # swift build (Xcode 27 or later)
make test         # unit tests — no VM
make cli          # .build/debug/doz, signed (ad hoc) with the virtualization entitlement
make install-cli  # a release build into ~/.local (bin/doz → libexec/doz/)
make test-vm      # the VM integration suite (boots real VMs; see CLAUDE.md)
```

An unsigned `doz` runs every command but cannot boot a VM (`doz doctor` says so). A source build is never
updated by doz itself. [CLAUDE.md](CLAUDE.md) is the engineering guide: where the code lives, the rules that
each cost a bug to learn, and how a change is verified.

## Contributing

Issues and fixes are welcome directly; large features arrive from the project's own development — see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT — see [LICENSE](LICENSE). Third-party components, what each release carries and their licences:
[LICENCES.md](LICENCES.md) and [NOTICE](NOTICE). The Linux kernel a sandbox boots (GPL-2.0) is downloaded on
your Mac from its upstream release, verified, and never redistributed by this project.
