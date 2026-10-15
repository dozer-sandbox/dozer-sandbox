#!/bin/sh
# The network profiler (617, owner: "profile all the recipes by running them and recording their network requests and
# then make a determination"). For each agent: a fresh try in a SCRATCH store with the Open network and every HTTPS
# request decrypted and logged (DOZ_TEST_PROFILE_NETWORK=1), its first start, then a short scripted task run
# non-interactively (read a file, edit it, run a command); every request is recorded (host, method, path, whether a
# key or a placeholder rode it) and merged into profiles/AGENT.json by Scripts/agent-profile.py.
#
#   make profile-agents AGENTS="grok gemini"            record (keeps every determination already made)
#   make profile-agents AGENTS="grok" DIFF=1            report new / missing endpoints only — never writes, never allows
#
# Keys are FAKE, always: xAI, Google and Google Stitch go to Scripts/fake-provider.py (the provider seam, its own CA), which answers
# text only (no tool calls); Anthropic and OpenAI get a fake key the real API refuses (401). A real-key run would see
# more — the model's turns and what its tool calls fetch — and is never automated. Never the default store, the Mac's
# logins, the keychain or a real op/aws: the scratch store is $PROFILE_WORK (default /tmp/doz-profile, kept between
# runs so prepared images are reused; a short path — the host's socket must fit in 104 bytes).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
DOZ=${DOZ:-$REPO/.build/debug/doz}
W=${PROFILE_WORK:-/tmp/doz-profile}
OUT=${PROFILE_OUT:-$REPO/profiles}
MODE=record
[ "${1:-}" = "--diff" ] && { MODE=diff; shift; }
[ $# -gt 0 ] || { echo "usage: profile-agents.sh [--diff] AGENT..." >&2; exit 64; }
mkdir -p "$W/xdg/dozer-sandbox" "$W/store" "$W/projects" "$W/codex-home" "$W/fake" "$W/runs"
[ -f "$W/xdg/dozer-sandbox/doz.toml" ] || printf '[store]\npath = "%s/store"\n\n[defaults]\nprojects_dir = "%s/projects"\n' "$W" "$W" > "$W/xdg/dozer-sandbox/doz.toml"
export XDG_CONFIG_HOME="$W/xdg" DO_NOT_TRACK=1 DOZ_TEST_NO_MAC_LOGIN=1 DOZ_TEST_CREDENTIALS=memory DOZ_TEST_GUARD=1
export DOZ_TEST_CODEX_HOME="$W/codex-home" DOZ_TEST_PROFILE_NETWORK=1

# The fake provider (xAI, Google, Google Stitch) with its own CA.
F="$W/fake"
FAKE_XAI_KEY=xai-FAKE-PROFILE-0123456789abcdef FAKE_GOOGLE_KEY=AIzaFAKEPROFILE-0123456789abcdef \
  FAKE_STITCH_KEY=AQ.FAKEPROFILE-0123456789abcdefghij \
  sh "$REPO/Scripts/fake-provider-up.sh" "$F" >/dev/null || exit 1
export DOZ_TEST_PROVIDER_UPSTREAM="127.0.0.1:$(cat "$F/port")" DOZ_TEST_PROVIDER_CA="$F/ca.pem"

doz() { "$DOZ" "$@"; }
# A host started by someone else's environment would not log every request: start this store's host afresh.
doz host stop >/dev/null 2>&1
printf 'xai-FAKE-PROFILE-0123456789abcdef\n' | doz account add xai --provider xai --force >/dev/null 2>&1
printf 'AIzaFAKEPROFILE-0123456789abcdef\n' | doz account add google --provider google --force >/dev/null 2>&1
printf 'AQ.FAKEPROFILE-0123456789abcdefghij\n' | doz account add google-stitch --provider google-stitch --no-verify --force >/dev/null 2>&1
printf 'sk-ant-api03-FAKEPROFILE-0123456789abcdefghijklmnopqrstuvwxyz\n' | doz account add anthropic --api-key --no-verify --force >/dev/null 2>&1
printf 'sk-proj-FAKEPROFILE-0123456789abcdefghijklmnopqrstuvwxyz\n' | doz account add openai --openai-key --no-verify --force >/dev/null 2>&1
doz account default anthropic >/dev/null 2>&1
doz account default openai >/dev/null 2>&1

TASK="Read notes.txt, add a line that says done to it, then run ls -la and tell me what you see."
trial() { doz ls --json | /usr/bin/python3 -c 'import json,sys; r=[x["name"] for x in json.load(sys.stdin) if x.get("trial")]; print(r[0] if r else "")'; }
rc=0
for a in "$@"; do
  case "$a" in
    claude-code) bin=claude; task="claude -p \"\$T\"" ;;
    pi) bin=pi; task="pi -p \"\$T\"" ;;
    codex) bin=codex; task="codex exec --skip-git-repo-check \"\$T\"" ;;
    gemini) bin=gemini; task="gemini -p \"\$T\"" ;;
    grok) bin=grok; task="grok -p \"\$T\"" ;;
    antigravity) bin=agy; task="agy -p \"\$T\"" ;;
    copilot) bin=copilot; task="copilot -p \"\$T\"" ;;
    opencode) bin=opencode; task="opencode run \"\$T\"" ;;
    qwen-code) bin=qwen; task="qwen -p \"\$T\"" ;;
    goose) bin=goose; task="goose run --no-session -t \"\$T\"" ;;
    kilo) bin=kilo; task="kilo run --auto \"\$T\"" ;;
    mistral-vibe) bin=vibe; task="vibe --trust --auto-approve -p \"\$T\"" ;;
    droid) bin=droid; task="droid exec --auto high -m custom:grok-build-0.1 \"\$T\"" ;;
    dirac) bin=dirac; task="dirac --yolo \"\$T\"" ;;
    kimi-code) bin=kimi; task="kimi -p \"\$T\"" ;;
    every-code) bin=coder; task="coder exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \"\$T\"" ;;
    cline) bin=cline; task="cline -P xai -m grok-build-0.1 \"\$T\"" ;;
    openhands) bin=openhands; task="openhands --override-with-envs --headless -t \"\$T\"" ;;
    codebuddy) bin=codebuddy; task="codebuddy --model grok-build -p --dangerously-skip-permissions \"\$T\"" ;;
    letta-code) bin=letta; task="letta --backend local -m xai/grok-4.3 --new-agent -p \"\$T\"" ;;
    docker-agent) bin=docker-agent; task="docker-agent run coder --model xai/grok-build-0.1 --exec --yolo \"\$T\"" ;;
    nanocoder) bin=nanocoder; task="nanocoder run \"\$T\" --trust-directory --plain" ;;
    mini-swe-agent) bin=mini; task="mini -m xai/grok-build-0.1 -t \"\$T\" --yolo --cost-limit 0 --exit-immediately" ;;
    open-interpreter) bin=interpreter; task="interpreter exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \"\$T\"" ;;
    crush) bin=crush; task="crush run -q -m xai/grok-build-0.1 \"\$T\"" ;;
    mimo-code) bin=mimo; task="mimo run -m xai/grok-build-0.1 --dangerously-skip-permissions \"\$T\"" ;;
    codewhale) bin=codewhale; task="codewhale exec --auto \"\$T\"" ;;
    maki) bin=maki; task="maki -p -m xai/grok-build-0.1 --yolo \"\$T\"" ;;
    omp) bin=omp; task="omp -p --model xai/grok-build-0.1 \"\$T\"" ;;
    tau) bin=tau; task="tau -p --provider xai -m grok-build-0.1 \"\$T\"" ;;
    stitch) bin=stitch; task="stitch find projects --limit 1 --json" ;;
    # 617 (other AI tools): a tool that answers and exits gets the task as its prompt (no tools of its own to run).
    fabric) bin=fabric; task="cat notes.txt | fabric \"\$T\"" ;;
    llm) bin=llm; task="llm -m grok-4-1-fast \"\$T\"" ;;
    shell-gpt) bin=sgpt; task="sgpt \"\$T\"" ;;
    zeroclaw) bin=zeroclaw; task="zeroclaw agent -a main -m \"\$T\"" ;;
    aichat) bin=aichat; task="aichat \"\$T\"" ;;
    tgpt) bin=tgpt; task="tgpt -q \"\$T\"" ;;
    smolagents) bin=smolagent; task="smolagent \"\$T\" --model-type OpenAIModel --model-id grok-4-1-fast --api-base https://api.x.ai/v1" ;;
    adk) bin=adk; task="mkdir -p hello && echo 'from . import agent' > hello/__init__.py && printf 'from google.adk.agents import Agent\\nroot_agent = Agent(name=\"hello\", model=\"gemini-2.5-flash\", instruction=\"Answer briefly.\")\\n' > hello/agent.py && printf '%s\\nexit\\n' \"\$T\" | adk run hello" ;;
    promptfoo) bin=promptfoo; task="printf '%s' \"\$T\" > /tmp/pf-prompt.txt && printf 'prompts: [\"file:///tmp/pf-prompt.txt\"]\\nproviders: [\"xai:grok-4-1-fast\"]\\n' > /tmp/pf.yaml && promptfoo eval -c /tmp/pf.yaml --no-cache" ;;
    clai) bin=clai; task="clai -m openai:grok-4-1-fast --no-stream \"\$T\"" ;;
    nanobot) bin=nanobot; task="nanobot agent -m \"\$T\"" ;;
    gptme) bin=gptme; task="gptme --non-interactive \"\$T\"" ;;
    openclaw) bin=openclaw; task="openclaw agent exec \"\$T\" --auth-env-only --model google/gemini-2.5-flash --timeout 80" ;;
    *) echo "profile-agents: no scripted task for $a — add one here" >&2; rc=2; continue ;;
  esac
  # The release it runs is the one Dozer installs: a recipe agent's pin (exact), a built-in one's latest. The profile
  # is of that release, and a sandbox that reports another (an updater that ran, a wrong install) fails the run.
  read -r setting want vcmd <<EOF2
$(/usr/bin/python3 - "$REPO/Sources/DozerKit/Recipes/compiled/$a.json" "$a" "$bin" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); caps = {c["type"]: c["config"] for c in d["capabilities"]}
launch, inst = caps["com.dozersandbox/launch@1"], caps["com.dozersandbox/install@1"]
key = (launch.get("settings") or {}).get("version") or "images.%s_version" % sys.argv[2].replace("-", "_")
# How it reports its release: a recipe agent's first verify command (smolagents has no --version); built-ins BIN --version.
import shlex
v = (not inst.get("builtin") and (launch.get("verify") or [{}])[0].get("argv")) or [sys.argv[3], "--version"]
print(key, "latest" if inst.get("builtin") else d["args"]["version"]["default"], shlex.join(v))
PY
)
EOF2
  doz config set "$setting" "$want" >/dev/null || { echo "profile-agents: could not set $setting = $want" >&2; rc=1; continue; }
  old=$(trial); [ -n "$old" ] && doz rm "$old" --yes >/dev/null 2>&1
  echo "== $a: a fresh try (Open network, every request logged)"
  doz try "$a" -d -q --rebuild --network open || { rc=1; continue; }
  n=$(trial)
  sleep "${PROFILE_FIRST_START_SECONDS:-25}"
  start=$(/bin/date +%s)
  echo "== $a: the scripted task"
  doz exec "$n" -- sh -c "cd /workspace && printf 'hello\n' > notes.txt && T='$TASK' && timeout ${PROFILE_TASK_SECONDS:-90} $task" > "$W/runs/$a.task.txt" 2>&1
  sleep 5
  pin=${want%%+*}
  out=$(doz exec "$n" -- sh -c "$vcmd" 2>/dev/null)
  version=$(printf '%s\n' "$out" | grep -F -m1 -- "$pin")
  [ -n "$version" ] || version=$(printf '%s\n' "$out" | head -1)
  if [ "$want" != latest ] && [ "${version#*"$pin"}" = "$version" ]; then
    echo "profile-agents: $a reports \"$version\" — not its pin $pin (an updater ran, or another release was installed)" >&2
    rc=1
  fi
  doz net log "$n" --json > "$W/runs/$a.log.json"
  /usr/bin/python3 "$REPO/Scripts/agent-profile.py" "$MODE" --agent "$a" --version "$version" --log "$W/runs/$a.log.json" \
    --task-start "$start" --task-output "$W/runs/$a.task.txt" --profile "$OUT/$a.json" || rc=1
  doz rm "$n" --yes >/dev/null 2>&1
  rm -rf "$W/projects/$n"
done
doz host stop >/dev/null 2>&1
kill "$(cat "$F/pid")" 2>/dev/null
exit $rc
