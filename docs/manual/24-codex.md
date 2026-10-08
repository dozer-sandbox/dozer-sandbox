# Codex

OpenAI's **Codex** runs in a Dozer sandbox the way Claude Code does: ready to work, without approval
prompts (the VM and its network are the boundary), told where it runs, and with its credential kept on
your Mac — it never enters the sandbox. It can use **this Mac's own Codex login** (`mac` — nothing to
add: your ChatGPT plan, through Codex's own sign-in) or an **OpenAI API key**.

> **Public releases** include those two. Dozer's *own* ChatGPT sign-in (`doz account add NAME --chatgpt`,
> described further down) is only in builds from source: a public release says so and keeps an account an
> earlier build made, unused — use `mac` or a key instead.

## Quick start

If Codex is already signed in on this Mac (`codex login`, or the Codex app), there is nothing to add:

```sh
doz new --image codex                 # uses this Mac's Codex login (the account mac) — the default while it is signed in
```

Otherwise, sign in to Codex on this Mac (`codex login` — Dozer then reads that login, read-only), or use a key:

```sh
doz account add openai --openai-key   # it asks for the key, not echoed
doz account default openai            # Codex sandboxes that follow the default use it
doz new --image codex                 # a Codex sandbox, attached — Codex is running
```

In the dashboard: **New sandbox**, choose **Codex** as the agent (on any base). The account chooser
offers only OpenAI accounts; an OpenAI key can be typed in the masked field.

## The image

- `codex` is Node.js · Codex; any other base is `<base>-codex` (`python-codex`, `go-codex`,
  `alpine-codex`, or your Dockerfile's): `doz create my-app --agent codex --base python`.
- Codex is installed from its official linux-arm64 build (a single static program, the same on Debian
  and Alpine), checked against the integrity the npm registry publishes. `images.codex_version` is
  `latest` (resolved when the image is prepared) or an exact version like `0.160.1`.
- Codex's own state (its sessions, history and settings) is `~/.codex`, on the state disk: it survives
  shutdown and reset.

## How it starts

`codex` in a sandbox is Dozer's launcher, which:

- runs Codex with **approvals and Codex's own Linux sandbox off**
  (`--dangerously-bypass-approvals-and-sandbox`): the VM, the network permissions and the absent
  credentials are the boundary. Set `codex.permissions` to `ask` (or run
  `doz run NAME -e DOZ_CODEX_PERMISSIONS=ask -- codex`) to keep Codex's own approvals; `codex` run as
  root always keeps them;
- marks the working folder trusted in `~/.codex/config.toml` (only when that folder has no entry
  there — your own choice is kept), so there is no trust screen;
- turns off Codex's update check (the image decides its version);
- gives Codex the sandbox's **facts** as its developer instructions, and the **`dozer` skill** in
  `~/.agents/skills/dozer/SKILL.md` ([Agents and accounts](09-agents-and-accounts.md)). Your
  `AGENTS.md` files are never touched.

`codex exec`, `codex resume` and `codex fork` get the same; `codex login`, `codex mcp` and the other
subcommands run as they are.

## This Mac's Codex login (`mac`)

The least setup: a Codex sandbox uses the login of the Codex already signed in on this Mac, as Claude
Code sandboxes use the Mac's Claude login.

- **Dozer only reads it.** From `$CODEX_HOME/auth.json` (else `~/.codex/auth.json`) it takes the
  **access token** and the few account details Codex reads (plan, email, account id). It never uses or
  keeps the refresh token and never writes anything there: your Mac's Codex stays the one that renews
  the login. Nothing is copied into the sandbox — it gets placeholders, and the proxy puts the token in
  on the way to `chatgpt.com`.
- **It is the default** for Codex sandboxes while this Mac's Codex is signed in (`doz account ls` shows
  `mac` · `codex-mac` with its plan, email and expiry). Choose another per sandbox
  (`doz account use NAME ACCOUNT`) or for all (`doz account default NAME`); `doz account default mac --codex`
  makes it the default explicitly.
- **It must stay fresh.** Access tokens last about an hour; your Mac's Codex renews one when it is within
  5 minutes of expiry, whenever it runs — the Codex app's background server checks every few minutes, so
  while the app (or any `codex` session) runs, sandboxes stay signed in. A renewal reaches open sandboxes
  at their next request. With nothing running it expires, and Codex in a sandbox says: "your Mac's Codex
  login has expired — run codex on the Mac, or turn on the keep-alive". Never another account.
- **Keep-alive** (off by default): `doz config set codex.keep_alive true`. When the token is about to
  expire and a sandbox used it in the last 15 minutes, Dozer runs this Mac's own `codex doctor` once —
  no model call — which renews the login the way Codex itself does.
- **Not supported yet:** a Codex that keeps its login in the keyring (`cli_auth_credentials_store =
  "keyring"`) — use `doz account add NAME --chatgpt` instead; and a Mac Codex signed in with an API key
  — add the key as an account (`--openai-key`). `doz doctor` says which.

## Your ChatGPT plan, without the token in the sandbox (builds from source)

`doz account add NAME --chatgpt` signs **Dozer** in to ChatGPT — the same browser sign-in `codex login`
does, on your Mac. It is Dozer's own sign-in, separate from your Mac's: Dozer never reads or changes
your Mac's `~/.codex`. What must last is kept in your login keychain (`doz-chatgpt:NAME`): the refresh token
and the few account details Codex reads. The short-lived access token is kept only in Dozer's memory (a new
Dozer host renews it on first use). `doz account ls` shows the account's plan and email, never a token.

- **In the sandbox**, Codex's `~/.codex/auth.json` holds only **placeholders** (`doz_cred_…`) where the
  tokens go, written at every session start. The id_token's details Codex reads (your plan, account id)
  are there; its signature is not — nothing in the VM can be used anywhere else.
- **On the way out**, Dozer's proxy on your Mac puts the real access token into Codex's requests to
  `chatgpt.com` — only there.
- **Renewal happens on your Mac.** OpenAI's tokens last about an hour; Dozer renews them with the
  refresh token only it holds, and keeps the new one in the keychain. When Codex asks to renew (its
  request to `auth.openai.com`), the proxy answers it itself — the request never leaves your Mac.
- **No silent fallback.** If the sign-in has ended (or you took the account away), Codex's requests
  get Dozer's message saying what to do — `doz account add NAME --chatgpt --force` signs in again —
  never another account or a key.

An OpenAI API key works the same way on `api.openai.com`: the sandbox's `OPENAI_API_KEY` and
`auth.json` hold a placeholder; the proxy puts the key in.

## Permissions

A Codex sandbox has **Talk to OpenAI** (`model:openai`: `chatgpt.com`, `api.openai.com`, and
`ab.chatgpt.com`, Codex's metrics) on in every preset, and it can't be switched off there — Codex
couldn't work. Claude Code and pi sandboxes never get it. `auth.openai.com` itself is not allowed:
only Codex's renewal of Dozer's sign-in is answered there, by the proxy.

```sh
doz net my-app                 # the permissions, "Talk to OpenAI" among them
doz net allow my-app web       # e.g. let Codex browse the web
```

## Accounts

```sh
doz account add chatgpt --chatgpt          # sign in with ChatGPT (opens the browser on this Mac)
doz account add chatgpt --chatgpt --force  # sign in again (after the sign-in ended)
doz account add openai --openai-key        # an OpenAI API key (prompt or stdin)
doz account default chatgpt                # the default OpenAI account (Codex sandboxes that follow it)
doz account use my-app openai              # this sandbox uses the key (open sessions switch on their next request)
doz account verify chatgpt                 # renews the sign-in when it is due, and says how it stands
doz account rm chatgpt                     # also deletes its keychain item
```

The store has two defaults: the Anthropic one (`mac` out of the box) for Claude Code and pi, and the
OpenAI one (none until you choose) for Codex. `doz onboard` asks about Codex's account when you choose
the codex image (or `doz onboard --openai-account chatgpt|openai-key|later`).

## Settings

| key | default | what it does |
|---|---|---|
| `images.codex_version` | `latest` | The Codex version an image is prepared with. |
| `codex.permissions` | `skip` | Codex's own approvals and sandbox in a sandbox: `skip` or `ask`. |
| `codex.keep_alive` | `false` | Renew this Mac's Codex login near expiry (`codex doctor`) while a sandbox uses it. |
| `images.codex.memory_mib` · `images.codex.network` | 2048 · `agent` | A new Codex sandbox's memory and network. |

## Troubleshooting

| symptom | what to do |
|---|---|
| Codex says Dozer's sign-in has ended | `doz account add NAME --chatgpt --force` on your Mac; open sessions recover by themselves. |
| "your Mac's Codex login has expired" | Run `codex` on the Mac (any prompt), or `doz config set codex.keep_alive true`. |
| "Codex needs an OpenAI account" when creating | `doz account add chatgpt --chatgpt` (or `--openai-key`), then `doz account default NAME` or `--account NAME`. |
| The sign-in's port is in use | Another sign-in (`codex login` on your Mac) is waiting — finish or cancel it, then try again. |
| Codex asks for approval for every command | `codex.permissions` is `ask`, or Codex runs as root. |
| Codex can't reach a site | It's the network permissions: `doz net NAME` shows them; ask for the one it needs. |
