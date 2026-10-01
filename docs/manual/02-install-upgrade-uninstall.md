# Installing, upgrading and uninstalling

`doz` is one command-line program. It comes with everything it needs inside it: the small Linux
programs each sandbox uses, the web dashboard, and the permission macOS requires to run virtual
machines. You install it with Homebrew.

## Concepts

- **The `doz` program** is what you install. It is signed with Apple's virtualization entitlement;
  without that, macOS refuses to boot virtual machines. A copy you build yourself without signing can
  run every command except the ones that boot a VM, and `doz doctor` says so.
- **The store** is where your sandboxes, images and restore points live:
  `~/Library/Application Support/dozer-sandbox` unless you choose another (see
  [Settings reference](15-settings-reference.md), `store.path`). Upgrading `doz` never touches it.
- **The settings** live in `~/.config/dozer-sandbox/doz.toml`, beside your agent prompt template
  (`agent-prompt.md`). Upgrading never touches them either.
- **The host** is a background `doz` process that runs your sandboxes. A running host keeps using the
  version of `doz` it started as, which is why upgrading has one extra step (below).

## Install

You need a Mac with Apple silicon and macOS 26 or later.

```sh
brew tap johnoscott/dozer git@github.com:johnoscott/homebrew-dozer-prelaunch.git
brew trust johnoscott/dozer
export HOMEBREW_GITHUB_API_TOKEN=$(gh auth token)
brew install doz
doz --version
```

1. **Tap.** While Dozer is in private preview its Homebrew tap is a private GitHub repository, cloned
   over SSH, so your GitHub account needs access to it.
2. **Trust.** `brew trust` is needed once: recent Homebrew only loads formulas from a tap you trust.
3. **Token.** The release download goes through GitHub's API, which needs a token for a private
   repository. `gh auth token` prints yours (run `gh auth login` first if you don't use the GitHub
   CLI). Homebrew uses it for that download and does not store it; put the `export` line in your
   shell profile if you'd rather not type it each time.
4. **Install.** A prebuilt `doz` is installed in seconds; no compiler is needed. It ends with a hint:
   run `doz onboard` ([Setting up](03-setting-up.md)).

After the public release, steps 1 and 3 go away: `brew install johnoscott/dozer/doz` (plus the
one-time `brew trust`).

## Upgrade

```sh
brew update && brew upgrade doz
doz host stop
```

- `brew update` fetches the tap's new formula; `brew upgrade doz` installs the new version beside the
  old one, then removes the old one.
- **A running host keeps its old version.** After an upgrade, Homebrew runs `doz host upgrade-check`,
  which says when a host of the previous version is still running. You can run it yourself at any time;
  it never starts or stops anything.
- **`doz host stop`** hibernates every running sandbox and stops the old host. The next command starts
  a host of the new version, and each sandbox wakes on it when you use it — with its programs and
  sessions where they were:

```sh
doz wake my-app        # or doz up, doz attach, or just use the dashboard
```

Until you do, every command that talks to the old host says so, once, on stderr (never in its output,
and not with `-q`):

```
note: the doz host is 0.12.0-rc.9 (this doz is 0.12.0-rc.10) — `doz host stop` switches to 0.12.0-rc.10; sandboxes hibernate and wake
```

(If the host is the *newer* one — you ran an older `doz` — the note says to upgrade this `doz`.)

If you skip `doz host stop`, nothing breaks right away: your sandboxes keep running. But the old
host can no longer boot anything once Homebrew has removed its files, so a start, a wake or a new
sandbox is refused with a message that tells you to run `doz host stop`. Once nothing runs and
nobody is attached, the old host exits by itself.

### Your images after an upgrade

A new version of Dozer may prepare its images differently (it may add a tool, for example). Your
existing images are **never rebuilt without you**: Dozer says an image is out of date — in
`doz image ls`, `doz doctor`, when you create a sandbox, and on the dashboard's Images page — and
you rebuild it when it suits you. See [Images and bases](08-images-and-bases.md#out-of-date-images).

### A sandbox that slept through an upgrade

A sandbox asleep or hibernated when you upgraded wakes on the new version with everything where it
was. Each snapshot remembers the exact virtual machine it was taken in, and the wake rebuilds that
machine, including the Linux kernel it slept under. If a new version ever can't rebuild the same
machine, the wake is refused rather than risk the snapshot, and says so.

## In the dashboard

The dashboard watches the host. If a host of another version takes over, a banner says so; if the
host is **older** than the dashboard, the banner offers **Restart host**: it asks first, hibernates
the running sandboxes and starts the newer host (they wake when you use them). If `doz ui` itself is
the older one, the banner asks you to restart `doz ui`. See [The dashboard](06-the-dashboard.md).

## Uninstall

```sh
doz uninstall
brew uninstall doz
```

`doz uninstall` lists exactly what it will delete and asks once:

- **the store**: every sandbox, image, kernel and restore point, and the host's log and metrics;
- **the settings folder**: `doz.toml` and `agent-prompt.md`.

Keep either with `--keep-store` or `--keep-config`; `--yes` skips the question (without a terminal
and without `--yes` it refuses). A running host is stopped first; a running `doz ui` must be stopped
by you (Ctrl-C in its terminal). For a Homebrew install, the `doz` program itself is Homebrew's to
remove: `doz uninstall` says so and ends with the `brew uninstall doz` command.

It **never** touches:

- your project folders;
- your keychain. Remove accounts you added first if you want their keychain items gone:
  `doz account rm NAME` (it deletes the item `doz account add` made). `doz uninstall` names any left;
- Claude Code's own files and login.

## Build from source (contributors)

The source is in the DozerKit repository. `make install-cli` builds and signs `doz` into
`~/.local/bin`; `make cli` builds a signed development copy. Don't have a Homebrew `doz` and a
source-built one on your `PATH` at the same time. See the repository's README.

## Settings

| key | default | what it does |
|---|---|---|
| `store.path` | `~/Library/Application Support/dozer-sandbox` | Where the store lives (`--store`, `$DOZ_STORE`). |
| `host.idle_timeout_minutes` | `5` | Minutes with nothing running before the host exits (`0` = never). |

## Troubleshooting

| symptom | what to do |
|---|---|
| `brew install doz` says the repository is private or not found | Export the token (`export HOMEBREW_GITHUB_API_TOKEN=$(gh auth token)`) and check your GitHub account can see the tap. |
| Homebrew refuses to load the tap's formula | `brew trust johnoscott/dozer`, once. |
| `doz: command not found` | `brew list doz`, then open a new terminal window. |
| "this host's program … is gone — an upgrade removed it" | `doz host stop`, then run your command again. |
| "cannot boot a VM" or a message about the entitlement | `doz doctor`. Reinstall: `brew reinstall doz`. |
| Start over from nothing | `doz uninstall`, `brew uninstall doz`, then `brew install doz` and `doz onboard`. |
