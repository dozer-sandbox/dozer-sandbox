# Other AI tools

Beside the coding agents, Dozer runs AI tools that are not coding agents: command-line tools that answer a prompt,
prompt toolkits, agent frameworks. Each is tried like an agent (`doz try TOOL`) and uses an **API key** of a provider
or a **gateway** Dozer offers. The key stays on your Mac; the sandbox only gets a placeholder, which Dozer's proxy swaps
for the key on the way out, and only to that provider's or gateway's own API.

```sh
doz try fabric                                  # Fabric, on its default (a Google AI key)
doz try shell-gpt --provider openai             # ShellGPT on an OpenAI key
doz try gptme --gateway openrouter --model anthropic/claude-sonnet-4.6
doz try aichat --dry-run                        # the plan: its model, and every provider and gateway it can use
doz try stitch                                  # Google Stitch's command line, on a Stitch API key
doz search gemini                               # what Dozer runs with a Google key
```

## Providers and gateways

Most tools here can talk to more than one: **Anthropic**, **OpenAI**, **xAI**, **Google AI** (the Gemini API), and the
gateways **OpenRouter** and **Vercel AI Gateway** (one key, many models — their model names are `creator/name`). Which
ones depends on the tool: each section below lists them, its default first. Choose one with `--provider` (or
`--gateway`) on `doz try`, `doz new`, `doz create` and `doz up`, or in the Quick try's setup (“Where TOOL gets its model”, then the model picker) and New Sandbox, or in doz_project.yaml (`model_source:`, `model:`);
`--model` picks the model (the default is the provider's or gateway's: `grok-4-1-fast`, `gpt-5.4-mini`,
`gemini-2.5-flash`, `claude-sonnet-4-6`, `openai/gpt-5.4-mini` …).

- **The key is a key of that provider or gateway**: `doz account add NAME --provider openrouter` (or
  `vercel-ai-gateway`, `xai`, `google`), `--api-key` for Anthropic, `--openai-key` for OpenAI — never a Claude
  subscription or a ChatGPT sign-in. The sandbox's account decides which one it talks to; `doz account use NAME ACCOUNT`
  switches it (from its next session).
- **Dozer sets the tool's own settings** for the choice (a base URL, a model, its provider switch) at every session and
  `doz exec` — a value you set yourself wins — and nothing is baked into the image, so one image serves every choice.
- **The key only ever goes to that provider's or gateway's own hosts.** The tool may reach the others' (so you can
  switch), but a placeholder sent to any other host is refused.
- The default models were chosen from the providers' published names; a model a provider has renamed or retired is
  refused by the provider itself — choose another with `--model`.

### Which models: `doz models`

```sh
doz models --gateway openrouter               # OpenRouter's models: id, context, price in and out per million tokens, tools
doz models --gateway vercel-ai-gateway sonnet # Vercel AI Gateway's, narrowed to those matching "sonnet"
doz models --gateway openrouter --refresh     # read the list again now
doz models --provider xai                     # a provider: the model Dozer checked
```

- **A gateway publishes its list**, and Dozer reads it on this Mac — never from a sandbox — at most once a day, keeping
  the last one (offline, the last list stays; `--refresh` reads it now and starts Dozer's background process when it
  is not running). `--json` gives it as data.
- **A provider lists its models only with a key**, so `doz models` shows the model Dozer checked for it; any other id
  that provider names may still be given with `--model`.
- **A `--model` a gateway does not list is used as given**, with a note on the closest ids it does list:
  `note: openai/gpt-5.4-mni is not in OpenRouter's model list — did you mean openai/gpt-5.4-mini, …? (used as given)`.
  Lists change every week, so it is never refused for that.

A tool that answers and exits opens a **shell** as its session, with the tool on the PATH. Type its commands there.

## OpenClaw

A self-hosted personal agent with shell and file tools. Its own docs recommend running it isolated: in a sandbox its
tools act on the sandbox, not your Mac.

- **Installed** from the npm registry, integrity-checked, on Node 24, which Dozer installs for it (Debian-based bases
  only). The image is large (about 1.3 GB).
- **Key:** Google AI (default), Anthropic, OpenAI, xAI or OpenRouter — OpenClaw's own providers, which read the key's
  usual variable. Its models are `provider/model` (`google/gemini-2.5-flash` by default); Dozer puts the chosen one in
  `DOZ_MODEL`.
- **Use:** one headless turn — `openclaw agent exec "a task" --auth-env-only --model "$DOZ_MODEL"`. Its auto-update is
  off (`OPENCLAW_NO_AUTO_UPDATE`).
- **May reach:** those providers' APIs (the key goes to the chosen one only).
- **Later:** its Gateway (the TUI, the Control UI on port 18789, chat channels such as Telegram or Slack) is a
  background service with a web page, which Dozer does not run or forward yet. You can start it by hand in a second
  session (`openclaw gateway`), but nothing keeps it running and the Control UI is not reachable from the Mac.

## nanobot

A small personal agent in the terminal (an OpenClaw-style assistant its authors keep auditable).

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Key:** xAI (default), OpenAI, Google AI, OpenRouter or Vercel AI Gateway. nanobot is set up with its custom
  OpenAI-compatible provider whose base URL, key and model come from `DOZ_MODEL_BASE_URL`, `DOZ_MODEL_API_KEY` and
  `DOZ_MODEL`, which Dozer sets for the choice (`~/.nanobot/config.json`, keys written only when not there yet).
- **Use:** `nanobot` opens its terminal UI (the session); one headless turn is `nanobot agent -m "a task"`.
- **May reach:** those providers' and gateways' APIs, and OpenAI's public tokenizer file (`openaipublic.blob.core.windows.net/encodings/…`), which
  the token counter it uses downloads at the first turn.
- **Later:** its gateway (chat channels) and web UI need a background service and a forwarded port.

## gptme

A terminal agent with shell, Python and file tools.

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Key:** xAI (default), Anthropic, OpenAI, Google AI, OpenRouter, or Vercel AI Gateway (through its OpenAI-compatible
  `local` provider). Dozer sets `MODEL` to `provider/model` for the choice (or `--model`).
- **Set up for you:** its confirmation prompts off (`--no-confirm`; `gptme.permissions = ask` keeps them).
- **Use:** `gptme` (the session); one headless run is `gptme --non-interactive "a task"`.
- **May reach:** those providers' and gateways' APIs, and OpenAI's public tokenizer file (as nanobot).
- **Later:** its browser tool needs Chromium in the image; `gptme-server`'s web UI needs a forwarded port.

## llm

Simon Willison's command-line tool for prompting models (and logging every prompt to SQLite).

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases), with the
  `llm-grok` plugin, which talks to xAI.
- **Key:** xAI (default, through `llm-grok`) or OpenAI (its own models). Dozer sets `LLM_MODEL` to the chosen model.
- **Use:** the session is a shell. `llm "a question"` (or `-m MODEL`).
- **May reach:** xAI's and OpenAI's APIs. Other providers need plugins, which are not in the image.
- **Later:** `llm install` (more plugins) needs PyPI at run time, which no permission offers yet.

## ShellGPT

A command-line assistant (`sgpt`) that answers questions and turns requests into shell commands (`sgpt --shell`).

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Key:** xAI (default), OpenAI, Google AI (its OpenAI-compatible endpoint), OpenRouter or Vercel AI Gateway. ShellGPT
  speaks OpenAI's API; Dozer points it at the choice (`API_BASE_URL`, `DEFAULT_MODEL`) and puts the key's placeholder
  under `OPENAI_API_KEY` too — it still works only on the chosen API.
- **Use:** the session is a shell. `sgpt "a question"`, `sgpt --shell "find large files"`.
- **May reach:** those providers' and gateways' APIs.

## ZeroClaw

A personal-agent runtime in one Rust program, with shell, file and web tools.

- **Installed** from the project's linux-arm64 release on GitHub, checked against the SHA-512 Dozer recorded (Debian-based
  bases).
- **Key:** xAI (default), OpenAI, Google AI, OpenRouter or Vercel AI Gateway. ZeroClaw is set up
  (`~/.zeroclaw/config.toml`, keys written only when not there yet) with one OpenAI-shaped provider and one agent,
  `main`, at full autonomy — the sandbox is the boundary. Dozer points the provider at the choice (its uri, model and the
  key's placeholder) through ZeroClaw's own environment overrides.
- **Use:** the session is `zeroclaw agent -a main`; one headless turn is `zeroclaw agent -a main -m "a task"`.
- **May reach:** those providers' and gateways' APIs.
- **Later:** its gateway, web dashboard and chat channels need a background service and a forwarded port.

## AIChat

An all-in-one LLM command line: a chat REPL, a shell assistant (`-e`), roles, sessions.

- **Installed** from the project's static linux-arm64 release on GitHub, checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** xAI (default), Anthropic, OpenAI, Google AI or OpenRouter — its built-in clients, with no config file
  (`AICHAT_PROVIDER`, `AICHAT_MODEL`: `xai:grok-4-1-fast` by default, or `-m`).
- **Use:** the session is its REPL; one question is `aichat "a question"`, a shell command `aichat -e "list big files"`.
- **May reach:** those providers' APIs.
- **Its playground:** run `aichat --serve` in a session; the sandbox's **Open AIChat web** button (or
  `doz open NAME`) opens it in your Mac's browser — see [Web ports](29-web-ports.md).

## tgpt

A small terminal chat client.

- **Installed** from the project's static linux-arm64 release on GitHub, checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Providers:** **Google AI** (the default — its Gemini provider, `AI_PROVIDER=gemini`), **OpenAI**, **xAI**,
  **OpenRouter** and **Vercel AI Gateway** (its OpenAI provider at the chosen source's chat endpoint, `OPENAI_URL`,
  `OPENAI_MODEL`).
- **Key:** an API key of that provider or gateway (a placeholder in the sandbox). On Google AI, Dozer's proxy sends the
  key as Google's `x-goog-api-key` header — checked against a stand-in provider, not yet against Google itself.
- **Use:** the session is its interactive mode (`tgpt -i`); one question is `tgpt -q "a question"`.
- **May reach:** the API of the provider or gateway it was given. Its key-less "free" providers are other companies' services, which Dozer does not allow
  by default.

## smolagents

Hugging Face's library for agents that write and run Python, with its `smolagent` command. Its own README says its
built-in Python executor is not a security boundary and recommends a sandbox — this is one.

- **Installed** from PyPI (with its toolkit and OpenAI extras) with every dependency pinned by its hash, on Dozer's own
  Python (Debian-based bases).
- **Key:** xAI (default), OpenAI, Google AI, OpenRouter or Vercel AI Gateway, through its OpenAI-compatible model:
  `smolagent "a task" --model-type OpenAIModel --model-id "$DOZ_MODEL" --api-base "$OPENAI_BASE_URL"` (Dozer sets both
  for the choice; the key's placeholder is also `OPENAI_API_KEY`).
- **Set up for you:** Hugging Face Hub telemetry off (`HF_HUB_DISABLE_TELEMETRY`).
- **Use:** the session is a shell.
- **May reach:** those providers' and gateways' APIs. Its web-search tools reach the open web only when you allow it.

## Agent Development Kit (Google)

Google's Python framework for building agents (`adk`).

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Key:** a Gemini API key, read by Google's genai SDK (`GOOGLE_GENAI_USE_VERTEXAI=FALSE`: the API key, never Vertex AI).
- **Use:** the session is a shell. Write an agent (a Python package folder whose agent module defines `root_agent`), then
  `adk run FOLDER` talks to it in the terminal.
- **May reach:** the Gemini API.
- **Later:** `adk web` (its dev UI) and `adk api_server` need a forwarded port.

## promptfoo

A command line for evaluating and red-teaming prompts and LLM apps. A red-team run sends attack prompts with your key —
in a sandbox the key stays on the Mac.

- **Installed** from the npm registry, integrity-checked, on Node 22 (Debian-based bases).
- **Key:** xAI (default), OpenAI, Google AI, OpenRouter or Vercel AI Gateway: its `openai` provider is pointed at the
  choice (`OPENAI_BASE_URL`, the key under `OPENAI_API_KEY`) — `providers: ["openai:chat:MODEL"]` in a config, the model
  in `DOZ_MODEL`; on xAI its `xai` provider works too.
- **Set up for you:** its telemetry and update check off (`PROMPTFOO_DISABLE_TELEMETRY`, `PROMPTFOO_DISABLE_UPDATE`).
- **Use:** the session is a shell. `promptfoo eval -c promptfooconfig.yaml`.
- **May reach:** those providers' and gateways' APIs. **Kept out, quietly:** `r.promptfoo.app` — with its telemetry off, promptfoo still sends one
  "telemetry disabled" event each run; no setting stops it, so Dozer refuses it without counting it as a refusal.
- **Later:** `promptfoo view` (its web viewer) needs a forwarded port.

## clai (Pydantic AI)

Pydantic AI's command line for chatting with models.

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Providers:** **xAI** (the default), **Anthropic**, **OpenAI**, **Google AI**, **OpenRouter** and **Vercel AI
  Gateway** — Pydantic AI's OpenAI-compatible model at the chosen source's base URL (`OPENAI_BASE_URL`), or its
  Anthropic model (`ANTHROPIC_BASE_URL`). Dozer puts the model on its command line (`-m openai-chat:MODEL`; on xAI,
  `grok-4-1-fast`), unless you give your own `-m`.
- **Key:** an API key of that provider or gateway (a placeholder in the sandbox, also under `OPENAI_API_KEY` or
  `ANTHROPIC_API_KEY`).
- **Use:** one question is `clai --no-stream "a question"`.
- **May reach:** the API of the provider or gateway it was given.
- **Later:** `clai web` (its chat page) needs a forwarded port.

## Fabric

A prompt toolkit: crowd-sourced "patterns" applied to text you pipe in.

- **Installed** from the project's own linux-arm64 release on GitHub, checked against the SHA-512 Dozer recorded when it
  pinned the release. Debian, Node and Alpine bases.
- **Key:** Google AI (default: `doz account add google --provider google`; get one at https://aistudio.google.com/apikey),
  Anthropic, OpenAI, xAI or OpenRouter — its own vendors. Dozer sets `DEFAULT_VENDOR` and `DEFAULT_MODEL` for the choice
  (over the ones in `~/.config/fabric/.env`, written only when not there yet).
- **Patterns** come with it: its release's some 260 patterns, checksum-verified when the image is prepared, in
  `/opt/fabric/patterns` (`CUSTOM_PATTERNS_DIRECTORY`) — `fabric -l` lists them; `fabric -U` (from GitHub) is not needed.
- **Use:** `echo "some text" | fabric "summarise this"`, `cat notes.txt | fabric -p summarize` — or the sandbox page's Guide.
- **May reach:** those providers' APIs.
- **Its REST API:** run `fabric --serve` in a session; the sandbox's **Open Fabric REST API** button (or `doz open NAME`)
  opens its API reference in your Mac's browser — see [Web ports](29-web-ports.md).

## Google Stitch CLI

Google Labs' command line for Stitch, Google's UI design service: it generates and edits app screens from a prompt (on
Google's side, with Gemini) and prints their ids and links. It is a client of the hosted service — every command is a
call to Stitch.

- **Installed** from the npm registry, integrity-checked, on Node 22 (Debian-based bases).
- **Key:** a **Stitch API key** (it starts `AQ.`), made in Stitch's settings at https://stitch.withgoogle.com —
  `doz account add stitch --provider google-stitch --no-verify`. Not a Gemini or Google Cloud key (`AIza…`), which Stitch
  refuses. Generation uses your Stitch account's quota.
- **Not offered:** its Google sign-in (`stitch login`), which would keep Google tokens in the sandbox. The API key covers
  projects, screens and design systems.
- **Use:** the session is a shell. `stitch find projects --json`;
  `stitch generate screen --new-project "My app" --prompt "A sign-up screen" --device MOBILE`. Every command takes
  `--json` and `--dry-run`.
- **May reach:** Stitch's API only (`stitch.googleapis.com`). It has no update check; its client header's telemetry is off.
- **Preview:** `stitch serve -p PROJECT --port 3000` serves a project's screens; `doz ports add NAME 3000` opens them on
  your Mac — see [Web ports](29-web-ports.md).
