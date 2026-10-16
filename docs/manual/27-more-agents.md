# More agents: Antigravity CLI, Grok Build, OpenCode, GitHub Copilot CLI, Qwen Code, Goose, Kilo Code CLI, Mistral Vibe, Factory Droid, Dirac, Kimi Code, Cline CLI, OpenHands CLI, Letta Code, Docker Agent, Nanocoder, mini-swe-agent, Open Interpreter, Crush, MiMo Code, CodeWhale, Maki, oh-my-pi, Tau, Gemini CLI

Beside Claude Code, pi and Codex, Dozer runs agents from other makers. Each uses an **API key** — most of them of the
provider or gateway you choose (`--provider` / `--gateway`, or the Quick try's “Where it gets its model”; `--model` picks the
model; see [Other AI tools](28-ai-tools.md#providers-and-gateways)). The key stays on your Mac and the sandbox only ever
gets a placeholder, which Dozer's proxy swaps for the key on the way out — and only to that provider's or gateway's
own API.

```sh
doz try antigravity      # Google's agent (alias: agy)
doz try grok             # xAI's agent
doz try opencode         # OpenCode, the open-source agent, on xAI or another provider or gateway
doz try copilot          # GitHub Copilot CLI with your own key (no Copilot plan)
doz try qwen-code        # Qwen Code (alias qwen), on xAI or another provider or gateway
doz try goose            # Goose, on xAI or another provider or gateway
doz try kilo             # Kilo Code CLI (alias kilocode), on xAI or another provider or gateway
doz try mistral-vibe     # Mistral Vibe (alias vibe), on xAI or another provider or gateway
doz try droid            # Factory Droid (alias factory), no Factory account, any provider or gateway
doz try dirac            # Dirac, a Cline-derived agent, on xAI or another provider or gateway
doz try kimi-code        # Kimi Code (alias kimi), on xAI or another provider or gateway
doz try cline            # Cline CLI, on xAI or another provider or gateway, no Cline account
doz try openhands        # OpenHands CLI, on xAI or another provider or gateway
doz try letta-code       # Letta Code (alias letta), local backend, on xAI or another provider or gateway
doz try docker-agent     # Docker Agent (alias cagent), its built-in coding agent, on xAI or another provider or gateway
doz try nanocoder        # Nanocoder, on xAI or another provider or gateway
doz try mini-swe-agent   # mini-swe-agent (alias mini), on xAI or another provider or gateway
doz try open-interpreter # Open Interpreter (alias interpreter), on xAI or another provider or gateway
doz try crush            # Crush (Charmbracelet), on xAI or another provider or gateway
doz try mimo-code        # MiMo Code (Xiaomi, alias mimo), on xAI or another provider or gateway
doz try codewhale        # CodeWhale (formerly DeepSeek TUI), on xAI or another provider or gateway
doz try maki             # Maki, on xAI or another provider or gateway
doz try omp              # oh-my-pi (a pi derivative), on xAI or another provider or gateway
doz try tau              # Tau (Hugging Face's Python port of pi), on xAI or another provider or gateway
doz try gemini           # Google's earlier agent (superseded by Antigravity CLI)
doz search google        # what Dozer runs with a Google key, each with its latest release
```

The first `doz try` of each asks for the key (a paste, or where you keep it: 1Password, AWS, a command — see
[Keys from 1Password, AWS or a command](09-agents-and-accounts.md#keys-from-1password-aws-or-a-command)), prepares the
agent's image once (a minute or so) and starts it. A try is Locked: the agent reaches its model and, below, the few
hosts its maker's program calls when it starts — nothing else. [Trying agents](26-try-and-search.md) has the rest.

## Antigravity CLI (Google)

Google's terminal agent and **the one to use with a Google key** (`doz try antigravity`, or `agy`).

- **Installed** from Google's own release for linux-arm64, checked against the SHA-512 Google publishes with it.
  Debian-based bases only for now (not Alpine). It is closed source; Dozer installs it from Google, it does not
  redistribute it.
- **Key:** a Gemini API key (`doz account add google --provider google`; get one at https://aistudio.google.com/apikey).
  Dozer never offers the Google sign-in: it keeps its token in a keyring inside the machine.
- **Set up for you:** approval prompts off (`antigravity.permissions = ask` keeps them), its updater off, its
  telemetry setting off.
- **Its first start is yours:** it asks you to pick a colour scheme, then to accept Google's **Terms of Service &
  Data Use** — data sharing is ticked by default and you can untick it. Dozer never accepts those terms for you;
  `doz try antigravity` says so first, and so does the first step of its Guide.
- **May reach:** the Gemini API (its model); Google's feature switches for it (`antigravity-unleash.goog`) when it
  starts; its usage log to `play.googleapis.com`, every few seconds. Its own telemetry setting does not stop that log,
  and Dozer allows it rather than blocking it.

## Grok Build (xAI)

xAI's own agent (`doz try grok`), on an **xAI API key** only: it checks its key with xAI's API when it starts and
will not run without an xAI key or sign-in, so another provider's or gateway's key cannot stand in.

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian, Node and Alpine bases.
- **Key:** an xAI API key (`doz account add xai --provider xai`).
- **Set up for you:** approval prompts off, its auto-updater off, its telemetry and feedback off; copying to your
  Mac's clipboard works (Dozer tells it the terminal takes OSC 52).
- **May reach:** xAI's API (the paths Grok Build uses, and its key-less start-up check of `api.x.ai/`), and its release
  notes on `x.ai` when it starts.
- **Kept out, whatever you choose:** xAI's sign-in hosts (Dozer never offers the sign-in).

## OpenCode (open source)

An open-source terminal agent that works with many model providers (`doz try opencode`). Dozer offers it on the
key of the provider or gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway**; on xAI the model is `xai/grok-build-0.1`.

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine yet).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **No key at all (OpenCode 2):** OpenCode Zen's free models — `doz try opencode --provider opencode-zen`, or
  **OpenCode Zen** in the try setup (marked "no key needed"). No account is used and nothing of yours is added to
  its requests. The model list shows each free model with its data terms as OpenCode's docs state them (some keep
  nothing, some are used to improve the model) — the free models OpenCode's docs list that this release of OpenCode can
  use without a key; `doz models --provider opencode-zen` lists them, and `--model`
  chooses one (default `big-pickle`). Only OpenCode's model requests to `opencode.ai` are allowed — not its Console or
  its sign-in. A key you add with OpenCode's own `/connect` is stored inside the sandbox; a key added in Dozer stays on
  your Mac.
- **Set up for you:** its auto-update, session sharing, language-server downloads and the online model list off; the
  model set in `~/.config/opencode/opencode.json` (written only when it is not there yet). Its plugin kit is not
  downloaded into `~/.config/opencode` when it first starts (it is only for plugins you write; `cd ~/.config/opencode
  && npm install @opencode-ai/plugin` adds it). OpenCode asks no approval questions by default.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch), and, for
  OpenCode 2, OpenCode Zen's model requests on `opencode.ai` (`/zen/v1/chat/completions`, `/zen/v1/responses`).
- **Use:** `opencode` (its TUI), or `opencode run "…"` for one answer.

## GitHub Copilot CLI (GitHub)

GitHub's terminal agent, run in its own **bring-your-own-key** mode (`doz try copilot`): it talks to your model with
your key and never signs in to GitHub, so no Copilot plan is needed. Dozer points it at the provider or
gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `grok-code-fast-1`).

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine yet).
  It is GitHub's software under its own licence; Dozer installs it from npm, it does not redistribute it.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** approval prompts off (`--allow-all`; `copilot.permissions = ask` keeps them), its offline mode
  (no GitHub sign-in, no calls to GitHub) and its auto-update off.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).

## Qwen Code (Alibaba Qwen)

Alibaba Qwen's open-source agent, a Gemini CLI fork (`doz try qwen-code`, or `qwen`). Its free Qwen sign-in ended in
April 2026; Dozer runs it in its **OpenAI-compatible mode**, pointed at the provider or gateway you choose: **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (`--provider` / `--gateway`, or the Quick try's “Where it gets its model”; `--model` picks the model).
On xAI the model is `grok-code-fast-1`.

- **Installed** from the npm registry, integrity-checked; it needs Node 22 (the Node and Debian bases; not Alpine).
- **Key:** an API key of that provider or gateway; the sandbox gets a placeholder in its own variable and in
  `OPENAI_API_KEY`. Dozer sets `OPENAI_BASE_URL` and `OPENAI_MODEL` for the choice at each session.
- **Set up for you:** approval prompts off (`--approval-mode=yolo`; `qwen-code.permissions = ask` keeps them), its
  auto-update and usage statistics off, and its download of the public model catalogue (models.dev) off — it uses the
  catalogue it ships with.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).

## Goose (Agentic AI Foundation)

The open-source agent from Block, now an Agentic AI Foundation project (`doz try goose`), on the key of the
provider or gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (its own providers; on xAI the model is `grok-code-fast-1`).

- **Installed** from its GitHub release (the static linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** it runs without asking (`GOOSE_MODE=auto`, its default), its keyring off (it would keep secrets in
  the sandbox), its telemetry off.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `goose` (a session), or `goose run -t "…"` for one task.

## Kilo Code CLI (Kilo Code)

Kilo Code's terminal agent, an OpenCode derivative (`doz try kilo`), on the key of the provider or
gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `xai/grok-build-0.1`).

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine yet).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its auto-update, sharing and online model list off; its usage telemetry off
  (`experimental.openTelemetry: false` — Kilo sends it by default); its Kilo Gateway provider off, so it does not call
  Kilo's servers. In its TUI, Kilo asks before running commands (its own default); `kilo run --auto` does not.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).

## Mistral Vibe (Mistral AI)

Mistral AI's terminal agent (`doz try mistral-vibe`, or `vibe`). Vibe takes any OpenAI-compatible or Anthropic
provider, and Dozer names the one you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (`--provider` / `--gateway`, or the Quick try's “Where it gets its model”; `--model` picks the model). On xAI the model is `grok-build-0.1`. Mistral's own
models need a Mistral key, which Dozer does not hold yet.

- **Installed** from PyPI with every dependency hash-pinned, into its own Python (Debian base; not Alpine).
- **Key:** an API key of that provider or gateway (a placeholder in the sandbox). Vibe's Mistral key and sign-in
  (`vibe --setup`) are not offered.
- **Set up for you:** its telemetry, update checks and auto-update off (`VIBE_ENABLE_*`); the provider and model are
  set for the choice the same way at each session (`VIBE_PROVIDERS`, `VIBE_MODELS`, `VIBE_ACTIVE_MODEL`), not in its
  settings file.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `vibe` (a session), or `vibe --trust --auto-approve -p "…"` for one task.

## Factory Droid (Factory)

Factory's terminal agent (`doz try droid`) in its **airgap mode**, on the key of the provider or gateway you
choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** — no Factory account, and none of Factory's servers. Droid takes it as a custom model, which
Dozer sets in its settings at every run (on xAI, `grok-build-0.1`).

- **Installed** from Factory's download server (its linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Debian and Node bases (not Alpine: Factory publishes a glibc build only).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** airgap mode (`FACTORY_AIRGAP_ENABLED=1`): without it Droid calls Factory's API (sessions, usage,
  feature flags) and its telemetry even with your own model; with it, only the model. Its first start in a folder asks
  whether to trust it.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `droid` (a session; with approvals off, `--auto high`), or `droid exec -m "custom:$DOZ_MODEL" "…"` for
  one task.

## Dirac (dirac-run)

A Cline-derived terminal agent aimed at lower API cost (`doz try dirac`), on the key of the provider or gateway
you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `grok-build-0.1`).

- **Installed** from the npm registry, integrity-checked. Node 22 on the Node and Debian bases (not Alpine: Dirac needs
  Node 22.13 to 24).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its telemetry off (`telemetrySetting: disabled` — Dirac sends events to dirac.run by default)
  and its self-update off (`DIRAC_NO_AUTO_UPDATE=1`).
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `dirac` (a session; with approvals off, `--auto-approve-all`), or `dirac --yolo "…"` for one task.

## Kimi Code (Moonshot AI)

Moonshot AI's terminal agent, the successor to kimi-cli (`doz try kimi-code`, or `kimi`). Kimi Code takes its model
from the environment (`KIMI_MODEL_*`), and Dozer names the provider or gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (`--provider` / `--gateway`, or the Quick try's “Where it gets its model”; `--model` picks the model). On xAI the
model is `grok-build-0.1`. Kimi's own models need a Kimi account or a Moonshot key, which Dozer does not hold yet.

- **Installed** from the npm registry, integrity-checked. Node 22 on the Node and Debian bases (not Alpine: it needs
  Node 22.19 or later).
- **Key:** an API key of that provider or gateway (a placeholder in the sandbox, in its own variable and in
  `KIMI_MODEL_API_KEY`), read on each request and never written into `~/.kimi-code/config.toml`.
- **Set up for you:** its telemetry and self-update off (`KIMI_DISABLE_TELEMETRY`, `KIMI_CODE_NO_AUTO_UPDATE`). At each
  start it asks Moonshot for its public client settings; Dozer keeps that request out quietly, and Kimi Code does
  without them. Its first start in a folder asks whether to trust it.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `kimi` (a session; with approvals off, `--auto`), or `kimi -p "…"` for one task.

## Cline CLI (Cline)

Cline's terminal agent (`doz try cline`), on the key of the provider or gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** — no Cline account.
Dozer puts the provider and model on its command line (`cline -P xai -m grok-build-0.1` on xAI).

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its telemetry and self-update off (`telemetryOptOut`, `autoUpdateEnabled: false`,
  `CLINE_NO_AUTO_UPDATE`), and its ClinePass notice. When it starts it asks for feature flags (its PostHog host), its
  recommended models (api.cline.bot) and the models.dev catalogue; Dozer keeps those requests out quietly, and Cline
  does without them. Cline approves its own tool calls by default (its
  `--auto-approve` is on unless you pass `--auto-approve false`).
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `cline` (a session), or `cline "…"` for one task.

## OpenHands CLI (OpenHands)

OpenHands' terminal agent (`doz try openhands`). Its LLM settings come from the environment (`--override-with-envs`,
in Dozer's command), set for the provider or gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (`--provider` / `--gateway`, or the Quick try's “Where it gets its model”; `--model` picks the model). On xAI the model is `grok-build-0.1`.
Nothing is written to its settings.

- **Installed** from its GitHub release (the linux-arm64 build), checked against the SHA-512 Dozer recorded. Debian and
  Node bases (not Alpine: OpenHands publishes a glibc build only).
- **Key:** an API key of that provider or gateway (`LLM_API_KEY` and its own variable, the same placeholder in the
  sandbox). OpenHands Cloud's sign-in is not offered.
- **Set up for you:** its model price list read locally (`LITELLM_LOCAL_MODEL_COST_MAP`, not fetched from GitHub) and
  its banner off.
- **May reach:** the API of the provider or gateway it was given (any of those it can use), and two reads no setting
  turns off: its public skills (a git clone of
  github.com/OpenHands/extensions at each start) and its latest release on PyPI (a notice only; Dozer installs the
  pinned release).
- **Use:** `openhands` (a session; with approvals off, `--always-approve`), or
  `openhands --override-with-envs --headless -t "…"` for one task.

## Letta Code (Letta)

Letta's memory-first coding agent (`doz try letta-code`, or `letta`) on its **local backend** — no Letta account, its
agents and memory kept in the sandbox (`~/.letta`) — on the key of the provider or gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `xai/grok-4.3`; `grok-build-0.1` is
not in its catalogue).

- **Installed** from the npm registry, integrity-checked. Node 22 on the Node and Debian bases (not Alpine: it needs
  Node 22.19 or later).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its telemetry and self-update off (`LETTA_CODE_TELEM=0`, `DISABLE_AUTOUPDATER`). When its TUI
  starts it may ask Letta Cloud for its health and an account balance; Dozer keeps those requests out quietly, and it
  does without them. Letta asks before running commands (its own default).
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `letta` (a session), or `letta --backend local --new-agent -p "…"` for one task.

## Docker Agent (Docker)

Docker's YAML-defined agent runner, formerly cagent (`doz try docker-agent`), as a program in the sandbox — Docker
Desktop is not used. A session runs its built-in coding agent (`docker-agent run coder`) on the key of the provider or
gateway you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `xai/grok-build-0.1`); your own agent files run the same way (`docker-agent run ./agent.yaml`).

- **Installed** from its GitHub release (the static linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its telemetry, self-update, tour and setup wizard off. At each run it reads the public models.dev
  catalogue; Dozer keeps that request out quietly, and it does without it.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `docker-agent` (a session; with approvals off, `--yolo`), or
  `docker-agent run coder --exec "…"` for one task.

## Nanocoder (Nano Collective)

A local-first terminal agent (`doz try nanocoder`), with a provider at the base URL of the one you choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `grok-build-0.1`).

- **Installed** from the npm registry, integrity-checked. Node 22 on the Node and Debian bases.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its context size given (`NANOCODER_CONTEXT_LIMIT`). It reads the public models.dev catalogue for
  prices when it needs them; Dozer keeps that request out quietly, and it does without it. Its first start in a
  folder asks whether to trust it.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `nanocoder` (a session; with approvals off, `--mode yolo`), or
  `nanocoder run "…" --trust-directory --plain` for one task.

## mini-swe-agent (SWE-agent team)

A minimal bash-only coding agent from the SWE-agent team (`doz try mini-swe-agent`; its command is `mini`), on an
key of the provider or gateway you choose, through LiteLLM: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `grok-build-0.1`).

- **Installed** from PyPI with every dependency hash-pinned, into its own Python (Debian base; not Alpine).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** LiteLLM's price list read locally (not fetched), and cost tracking that does not stop on a model
  without a price.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `mini` (a session; with approvals off, `--yolo`), or
  `mini -t "…" --yolo --exit-immediately` for one task.

## Open Interpreter

Open Interpreter, rebuilt as a Codex CLI derivative (`doz try open-interpreter`; its command is `interpreter`), on an
key of the provider or gateway you choose: **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** — a Codex-style provider Dozer names on its command line
(`-c model_providers…`, `-m`; on xAI the model is `grok-build-0.1`).

- **Installed** from its GitHub release (the static linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its analytics, plugins, apps and update check off (without them it calls ChatGPT's and GitHub's
  servers).
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch), and one read when its TUI starts: Codex's announcement tips file on GitHub.
- **Use:** `interpreter` (a session; with approvals off, `--dangerously-bypass-approvals-and-sandbox`), or
  `interpreter exec --skip-git-repo-check "…"` for one task.

## Crush (Charmbracelet)

Charmbracelet's terminal agent (`doz try crush`), on the key of the provider or gateway you
choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** — its model and provider set in its settings at every run (on xAI, `grok-build-0.1`). Its licence is FSL-1.1-MIT: each release becomes MIT two years on, and until then it forbids a
competing use — running it in your own sandbox is not one.

- **Installed** from its GitHub release (the static linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its metrics and provider auto-update off (`CRUSH_DISABLE_METRICS`,
  `CRUSH_DISABLE_PROVIDER_AUTO_UPDATE`; without them it calls Charm's catalogue and Hyper hosts).
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch), and GitHub's API for one read: its latest release, asked at each run.
- **Use:** `crush` (a session; with approvals off, `--yolo`), or `crush run -q "…"` for one
  task.

## MiMo Code (Xiaomi)

Xiaomi's terminal agent, an OpenCode derivative (`doz try mimo-code`, or `mimo`), on the key of the provider or gateway you
choose: **Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** (on xAI the model is `xai/grok-build-0.1`). Its code is MIT, with Xiaomi's use restrictions beside it.

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine yet).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its usage analytics off (`MIMOCODE_ENABLE_ANALYSIS=false` — by default it posts to
  tracking.miui.com, which is never allowed), its online model list, auto-update and sharing off.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `mimo` (a session; with approvals off, `--dangerously-skip-permissions`), or
  `mimo run "…"` for one task.

## CodeWhale

A provider-neutral terminal agent, formerly DeepSeek TUI (`doz try codewhale`), on the key of the provider or gateway you choose:
**Anthropic**, **OpenAI**, **xAI** (the default), **Google AI** or **OpenRouter** — its built-in providers (on xAI the model is `grok-build-0.1`; it has no Vercel AI Gateway provider).

- **Installed** from its GitHub release (the static linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **Set up for you:** its usage telemetry and update check off (`CODEWHALE_TELEMETRY=0`, `CODEWHALE_NO_UPDATE_CHECK`),
  its onboarding skipped. Its TUI refreshes the models.dev catalogue when it starts; Dozer keeps that out quietly, and
  it uses the catalogue it has.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch).
- **Use:** `codewhale` (a session; with approvals off, `--approval-policy never`), or `codewhale exec "…"` for one task
  (`--auto` lets it use tools).

## Maki

A Rust terminal agent with Lua plugins (`doz try maki`), on the key of the provider or gateway you choose:
**Anthropic**, **OpenAI**, **xAI** (the default) or **OpenRouter** — its own providers, the model on its command line (on xAI, `xai/grok-build-0.1`).

- **Installed** from its GitHub release (the static linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch), and GitHub's API for one read: its latest release, asked when its TUI starts. It also
  fetches the models.dev catalogue then; Dozer keeps that out quietly, and it does without it.
- **Use:** `maki` (a session; with approvals off, `--yolo`), or `maki -p "…"` for one task.

## oh-my-pi

A batteries-included derivative of pi (`doz try omp`), on the key of the provider or gateway you choose:
**Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** — its built-in providers, the model on its command line (on xAI, `xai/grok-build-0.1`).

- **Installed** from its GitHub release (the linux-arm64 build), checked against the SHA-512 Dozer recorded. Debian
  and Node bases (not Alpine yet).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch). When it starts it checks for a newer release and asks several model gateways for
  their public model lists (Kilo, Venice, ZenMux, Command Code, Charm Hyper, Alibaba Model Studio, a model
  catalogue); no setting turns that off, so Dozer keeps those requests out quietly, and it does without them.
- **Use:** `omp` (a session), or `omp -p "…"` for one task.

## Tau

Hugging Face's Python port of pi (`doz try tau`), on the key of the provider or gateway you choose:
**Anthropic**, **OpenAI**, **xAI** (the default), **Google AI**, **OpenRouter** or **Vercel AI Gateway** — its own providers, named on its command line (on xAI, `grok-build-0.1`).

- **Installed** from PyPI into its own Python environment: Dozer's Python and exactly the packages Dozer locked, each
  checked against its recorded hash. Debian and Node bases (not Alpine yet).
- **Key:** an API key of that provider or gateway (`doz account add NAME --provider xai` — or `openrouter`, `vercel-ai-gateway`, `google`; `--api-key` for Anthropic, `--openai-key` for OpenAI); the sandbox only gets a placeholder.
- **May reach:** the API of the provider or gateway it was given (any of those it can use, so you can switch). Its update check and its model catalogue refresh are turned off.
- **Use:** `tau` (a session), or `tau -p "…"` for one task.

## Gemini CLI (Google) — superseded

Superseded by Antigravity CLI: Google retired Gemini CLI for personal accounts; it still works with a **paid** Gemini
API key. Dozer keeps it, listed after the current agents; `doz try gemini` says so first.

- **Installed** from the npm registry, integrity-checked. Node, Debian and Alpine (on Alpine its shell tool runs
  without a terminal).
- **Key:** a Gemini API key, as Antigravity CLI. Never the Google sign-in (Google's terms forbid third-party tools from
  using it).
- **Set up for you:** approval prompts off, usage statistics off, auto-update off.

## Coming: CodeBuddy Code, Every Code

Two agents Dozer had recipes for are **coming** again, because their first screen is a sign-in Dozer cannot offer
(`doz search` says why):

- **CodeBuddy Code** (Tencent) asks you to sign in to a CodeBuddy account at its first screen, even with Dozer's model
  set.
- **Every Code** (just-every, a Codex CLI fork) shows a ChatGPT sign-in whenever it has no login file, whatever
  provider is set.

Each comes back when it can start on the model Dozer gives it.

## What each one calls — the network profiles

Dozer keeps a **network profile** of every agent: a fresh try with the network open and every request logged, its
first start and a short task, and for each host and path it called, a decision — allowed (and why), allowed by its
path only, turned off by the agent's own setting, or refused. The recipes are checked against these profiles on every
build, so an agent never meets a refusal on a normal first run, and a new release is profiled again before anything
new is allowed (`make profile-agents` in the source tree; `make agent-currency` says which agents moved).

## Is it current?

`doz search`, `doz try` and the Quick try show each agent's **latest release** as your Mac last saw it — the version,
the day it came out, how long ago, and **active** (a release in the last 3 months), **quiet** (none for 3),
**stale** (none for 6) or **deprecated** by its maker — and its **standing**: current, or superseded by another
agent. See [Is it current?](26-try-and-search.md#is-it-supported-doz-search).
