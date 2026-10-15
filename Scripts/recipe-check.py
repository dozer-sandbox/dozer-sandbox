#!/usr/bin/python3
# `make recipe-check` (617): every recipe run for real, in a SCRATCH store, through the test seams only — never a real
# key, the Mac's logins, the keychain, the default store or a real op/aws. Per recipe (the data comes from the recipe
# itself, Recipes/compiled/ID.json — nothing here is per agent):
#   1. build   its image (`doz image bake`, skipped when this store already holds it for this build and release);
#              the bake checks the release's integrity and runs the recipe's `verify`
#   2. try     a fresh try (`doz try ID -d -q`), its provider's FAKE key held in the host's memory; the model's hosts go
#              to Scripts/fake-provider.py (TLS, a throwaway CA — DOZ_TEST_PROVIDER_* / DOZ_TEST_OPENAI_*)
#   3. verify  each `verify` command again, in the try, its output against `expect`
#   4. smoke   the recipe's `check`: argv as the agent (through its launcher); the output holds `expect`, the exit status
#              is `exit`; the stand-in saw the fake key (swapped in by the proxy) while the guest holds a placeholder
#   5. keys    no fake key anywhere in the guest; the leak guard: the placeholder sent to another provider's host is
#              refused and never reaches it
#   6. status  `status: osc7501` only: an interactive turn in the default session — deckhold must hold at least
#              idle, working and done (sampled with `deckhold ls` in the guest)
#   0. screen  (right after the try, before anything else runs in it) every recipe whose default session is the agent
#              (not `session: shell`): its default session opened on a pty, nothing typed, left to settle (~15 s), its
#              screen read back (`deckhold dump`) — no setup wizard, onboarding, sign-in, consent or trust question
#              (SETUP_SCREEN, less the lines the recipe's check.screen.allow excuses), each check.screen.expect found,
#              no check.screen.refuse. A headless check turn never sees such a screen; a person's first try does.
# Exit 0 when every recipe passed, 1 otherwise (2: usage). The report (JSON) has, per recipe, pass/fail, the version,
# each step's duration, the states seen and the failures; --summary FILE appends a markdown table.
#
# Usage: recipe-check.py [--store DIR] [--report FILE] [--summary FILE] [--doz BIN] [--versions pin|latest]
#                        [--selections all|default|SOURCE…] ID…|all
#   --store     the scratch root (default /tmp/doz-recipe-check; keep it short — the host's socket path must fit in 104
#               bytes). Prepared images are kept there between runs; sandboxes never are.
#   --versions  pin (default): each recipe agent at its pinned release; the built-in three (Claude Code, pi, Codex)
#               at `latest` — their pins are frozen fallbacks (RecipePinTests) and Dozer installs latest for them.
#               latest: every agent at its latest release.
#   --only      screen: only the try and its first-screen check (a quick survey of every agent's first screen).
#   --selections a recipe with models@1 (it can be tried with several providers and gateways): steps 2–5 run once PER
#               model source it is offered — each in a fresh try with that source's FAKE key (`doz try ID --provider|
#               --gateway SOURCE`), `${{ dozer.model }}` and `${{ dozer.base_url }}` in its check argv = that source's, the request seen on
#               that source's host with that key, and the leak guard to another provider AND another gateway. all
#               (default; also $RECIPE_SELECTIONS), default (its default source only), or a list. The build is once.
import argparse, datetime, glob, json, os, pty, re, select, shlex, shutil, signal, struct, subprocess, sys, termios, threading, time, fcntl

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPILED = os.path.join(REPO, "Sources/DozerKit/Recipes/compiled")
# The fake keys (never real ones) and how each provider's account is added.
KEYS = {
    "xai": "xai-FAKE-RECIPECHECK-0123456789abcdef",
    "google": "AIzaFAKERECIPECHECK-0123456789abcdef",
    "anthropic": "sk-ant-api03-FAKERECIPECHECK-0123456789abcdefghijklmnopqrstuvwxyz",
    "openai": "sk-proj-FAKERECIPECHECK-0123456789abcdefghijklmnopqrstuvwxyz",
    "openrouter": "sk-or-v1-FAKERECIPECHECK-0123456789abcdef0123456789abcdef",
    "vercel-ai-gateway": "vck_FAKERECIPECHECK0123456789abcdefghijklmnop",
    "google-stitch": "AQ.FAKERECIPECHECK-0123456789abcdefghijklmnop",
}
ACCOUNT_ARGS = {
    "xai": ["--provider", "xai"],
    "google": ["--provider", "google"],
    "anthropic": ["--api-key", "--no-verify"],
    "openai": ["--openai-key", "--no-verify"],
    "openrouter": ["--provider", "openrouter"],
    "vercel-ai-gateway": ["--provider", "vercel-ai-gateway", "--no-verify"],
    "google-stitch": ["--provider", "google-stitch", "--no-verify"],
}
# A source's host and how a key rides on it — for the leak guard (a placeholder sent where it does not belong).
LEAK_TARGET = {
    "xai": ("api.x.ai", "Authorization: Bearer %s", "/v1/models"),
    "google": ("generativelanguage.googleapis.com", "x-goog-api-key: %s", "/v1beta/models"),
    "openai": ("api.openai.com", "Authorization: Bearer %s", "/v1/models"),
    "anthropic": ("api.anthropic.com", "x-api-key: %s", "/v1/models"),
    "openrouter": ("openrouter.ai", "Authorization: Bearer %s", "/api/v1/models"),
    "vercel-ai-gateway": ("ai-gateway.vercel.sh", "Authorization: Bearer %s", "/v1/models"),
    "google-stitch": ("stitch.googleapis.com", "x-goog-api-key: %s", "/mcp"),
}
GATEWAYS = ("openrouter", "vercel-ai-gateway")
STATES_NEEDED = ("idle", "working", "done")
# What a ready agent's first screen never asks (case-insensitive; a line a recipe's check.screen.allow matches is excused).
SETUP_SCREEN = [
    (r"\bwelcome\b", "a welcome screen"),
    (r"let'?s get (?:you )?(?:set up|started)|\bsetup\b|set ?up wizard|\bget started\b", "set-up"),
    (r"let'?s configure|\bconfigure (?:your|a|an) |configuration (?:wizard|setup)", "configuration"),
    (r"\bsign[ -]?in\b|\blog[ -]?in\b", "a sign-in"),
    (r"would you like|how would you like|do you want to (?:share|send|allow|enable|help|opt)", "a question"),
    (r"usage data|anonymous (?:usage|data|statistics)|telemetry|analytics|improve (?:the )?product", "a usage-data consent"),
    (r"\btrust\b.{0,30}\b(?:folder|directory|workspace|files|project)|do you trust", "a trust question"),
    (r"(?:select|choose|pick) (?:a |your )?(?:theme|colou?r scheme|style)", "a theme choice"),
    (r"\bonboarding\b", "onboarding"),
    (r"(?:enter|paste|provide) (?:your |an? )?(?:own )?(?:\w+ )?api[ _-]?key", "a key request"),
    (r"terms of (?:service|use)|privacy (?:policy|notice)", "terms"),
]


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


class Recipe:
    def __init__(self, path):
        self.product = os.path.basename(path)[:-5]
        d = json.load(open(path))
        self.doc_id = d["id"]
        caps = d["capabilities"]
        cfg = lambda t: next((c["config"] for c in caps if c["type"] == t), None)
        self.pin = d["args"]["version"]["default"]
        inst = cfg("com.dozersandbox/install@1")
        self.builtin = bool(inst.get("builtin"))
        launch = cfg("com.dozersandbox/launch@1")
        self.check = launch.get("check")
        self.verify = launch.get("verify", [])
        self.status = launch.get("status", "none")
        self.version_setting = (launch.get("settings") or {}).get("version") or "images.%s_version" % self.product.replace("-", "_")
        cred = cfg("com.docker.sandbox/credential@1") or {}
        self.provider = cred.get("service")
        self.key_env = (cred.get("apiKey") or {}).get("name")
        self.volumes = [c["config"]["path"] for c in caps if c["type"] == "com.docker.sandbox/volume@1"]
        # 617 (models@1): the model sources it can be tried with (the plan says which: `doz try ID --dry-run --json`).
        self.models = cfg("com.dozersandbox/models@1")
        # 617.11: its guide (the steps after the first are run too).
        self.guide = cfg("com.dozersandbox/guide@1")
        # 617 (RP-1): its web ports, and the command that serves them when the session's program does not.
        self.ports = cfg("com.dozersandbox/ports@1")
        # 617: `shell` — the default session is a login shell (a tool that answers and exits): no first screen of its own.
        self.session = launch.get("session")
        self.screen = (self.check or {}).get("screen") or {}


def http_status(host, port, path):
    """The status line of a plain HTTP/1.0 GET (or why there is none)."""
    import socket
    try:
        with socket.create_connection((host, port), timeout=10) as s:
            s.settimeout(15)
            s.sendall(("GET %s HTTP/1.0\r\nHost: %s:%d\r\n\r\n" % (path, host, port)).encode())
            data = s.recv(256)
        return data.split(b"\r\n", 1)[0].decode("latin-1") if data else "an empty answer"
    except OSError as e:
        return "no connection (%s)" % e


class Harness:
    def __init__(self, args):
        self.root = os.path.abspath(args.store)
        self.args = args
        self.base_urls = {}          # (recipe, source) → the base URL of its selection (the plan's)
        self.store = os.path.join(self.root, "store")
        self.fake = os.path.join(self.root, "fake")
        self.bin = os.path.join(self.root, "bin")
        for d in ("xdg/dozer-sandbox", "store", "projects", "codex-home", "fake"):
            os.makedirs(os.path.join(self.root, d), exist_ok=True)
        with open(os.path.join(self.root, "xdg/dozer-sandbox/doz.toml"), "w") as f:
            f.write('[store]\npath = "%s"\n\n[defaults]\nprojects_dir = "%s/projects"\n' % (self.store, self.root))
        self.env = dict(os.environ)
        for k in list(self.env):
            if k.startswith("DOZ_") and k not in ("DOZ_KERNEL_CACHE", "DOZ_KERNEL"):
                del self.env[k]
        self.env.update({
            "XDG_CONFIG_HOME": os.path.join(self.root, "xdg"), "DO_NOT_TRACK": "1", "DOZ_TEST_GUARD": "1",
            "DOZ_TEST_NO_MAC_LOGIN": "1", "DOZ_TEST_CREDENTIALS": "memory",
            "DOZ_TEST_CODEX_HOME": os.path.join(self.root, "codex-home"), "DOZ_TEST_BASE_REGISTRY": "pinned",
            "DOZ_PROGRESS": "plain", "NO_COLOR": "1",
        })
        if not self.env.get("DOZ_KERNEL_CACHE"):
            self.env.pop("DOZ_KERNEL_CACHE", None)

    # ── doz ────────────────────────────────────────────────────────────────────
    def doz(self, *a, stdin=None, timeout=600):
        argv = [os.path.join(self.bin, "doz")] + list(a)
        if "--" in argv:
            i = argv.index("--")
            argv[i:i] = ["--store", self.store]
        else:
            argv += ["--store", self.store]
        try:
            p = subprocess.run(argv, input=stdin, capture_output=True, text=True, errors="replace", env=self.env, timeout=timeout)
            return p.returncode, p.stdout + p.stderr
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"") + (e.stderr or b"")
            return 124, (out.decode(errors="replace") if isinstance(out, bytes) else str(out)) + "\n(timed out after %ds)" % timeout

    def install_binary(self):
        """A COPY of the build (never run a long VM job from the file `make cli` rewrites): the old host stopped first."""
        if os.path.exists(os.path.join(self.bin, "doz")):
            self.doz("host", "stop", timeout=300)
        src = os.path.abspath(self.args.doz)
        new = self.bin + ".new"
        shutil.rmtree(new, ignore_errors=True)
        os.makedirs(new)
        shutil.copy2(src, os.path.join(new, "doz"))
        d = os.path.dirname(src)
        for b in glob.glob(os.path.join(d, "*.bundle")):
            shutil.copytree(b, os.path.join(new, os.path.basename(b)), symlinks=True)
        if os.path.exists(os.path.join(d, "VERSION")):
            shutil.copy2(os.path.join(d, "VERSION"), os.path.join(new, "VERSION"))
        shutil.rmtree(self.bin, ignore_errors=True)
        os.rename(new, self.bin)

    def start_fake(self):
        pidf = os.path.join(self.fake, "pid")
        if os.path.exists(pidf):
            try:
                os.kill(int(open(pidf).read()), signal.SIGTERM)
            except (ValueError, OSError):
                pass
            os.remove(pidf)
        fenv = dict(os.environ, FAKE_XAI_KEY=KEYS["xai"], FAKE_GOOGLE_KEY=KEYS["google"], FAKE_ANTHROPIC_KEY=KEYS["anthropic"],
                    FAKE_OPENAI_KEY=KEYS["openai"], FAKE_OPENROUTER_KEY=KEYS["openrouter"], FAKE_VERCEL_KEY=KEYS["vercel-ai-gateway"],
                    FAKE_STITCH_KEY=KEYS["google-stitch"])
        p = subprocess.run(["/bin/sh", os.path.join(REPO, "Scripts/fake-provider-up.sh"), self.fake], capture_output=True, text=True, env=fenv)
        if p.returncode != 0:
            raise SystemExit("recipe-check: the fake provider did not start: " + p.stderr)
        port = p.stdout.strip()
        ca = os.path.join(self.fake, "ca.pem")
        self.env.update({"DOZ_TEST_PROVIDER_UPSTREAM": "127.0.0.1:" + port, "DOZ_TEST_PROVIDER_CA": ca,
                         "DOZ_TEST_PROVIDER_HOSTS": "api.anthropic.com",
                         "DOZ_TEST_OPENAI_UPSTREAM": "127.0.0.1:" + port, "DOZ_TEST_OPENAI_CA": ca})

    def stop_fake(self):
        try:
            os.kill(int(open(os.path.join(self.fake, "pid")).read()), signal.SIGTERM)
        except (ValueError, OSError):
            pass

    def requests(self):
        try:
            return [json.loads(l) for l in open(os.path.join(self.fake, "requests.log")) if l.strip()]
        except OSError:
            return []

    def sandboxes(self):
        code, out = self.doz("ls", "--json", timeout=120)
        try:
            return json.loads(out[out.index("["):]) if code == 0 else []
        except ValueError:
            return []

    def prepare_store(self, providers):
        # A host started under another environment would not use this run's fake: start afresh.
        self.doz("host", "stop", timeout=300)
        for s in self.sandboxes():
            self.doz("rm", s["name"], "--yes", timeout=300)
        for p in sorted(providers):
            if p not in KEYS:
                continue
            self.doz("account", "add", "rc-" + p, *ACCOUNT_ARGS[p], "--force", stdin=KEYS[p] + "\n", timeout=120)
            self.doz("account", "default", "rc-" + p, timeout=60)

    # ── one recipe ─────────────────────────────────────────────────────────────
    def selections(self, r):
        """617 (models@1): the model sources to check — every one the recipe is offered (`--selections all`, the
        default), only its default (`default`), or those named that it is offered. Without models@1: its provider."""
        if not r.models:
            return [(r.provider, None)]
        code, out = self.doz("try", r.product, "--dry-run", "--json", timeout=120)
        try:
            plan = json.loads(out[out.index("{"):])
            offered = [(o["id"], o["defaultModel"]) for o in (plan.get("model") or {}).get("offered") or []]
            for o in (plan.get("model") or {}).get("offered") or []:
                self.base_urls[(r.product, o["id"])] = o.get("baseURL") or ""
        except (ValueError, KeyError):
            offered = []
        if not offered:
            return [(r.models.get("default") or r.provider, None)]
        want = self.args.selections
        if want == "default":
            return offered[:1]
        if want == "all":
            return offered
        names = [w for w in want.replace(",", " ").split() if w]
        return [o for o in offered if o[0] in names]

    def run(self, r):
        """Build once, then each selection (a model source) in a fresh try of its own. One result per selection."""
        results = []
        res = self.new_result(r, r.provider)
        fail = res["failures"].append
        t_all = time.time()
        if not r.check:
            fail("the recipe has no check block")
            return [self.finish(res, t_all)]
        sels = self.selections(r)
        if not sels:
            fail("no selection to check (--selections %s; the recipe offers: %s)" % (self.args.selections, r.models))
            return [self.finish(res, t_all)]
        missing = [s for s, _ in sels if s not in KEYS]
        if missing:
            fail("no stand-in for %s (Scripts/fake-provider.py fakes %s)" % (", ".join(missing), ", ".join(sorted(KEYS))))
            return [self.finish(res, t_all)]
        want = "latest" if (self.args.versions == "latest" or r.builtin) else r.pin
        code, out = self.doz("config", "set", r.version_setting, want, timeout=60)
        if code != 0:
            fail("config set %s %s: %s" % (r.version_setting, want, out.strip()[-300:]))
            return [self.finish(res, t_all)]
        if want == "latest":
            res["notes"].append("at its latest release (%s)" % ("a built-in agent: its pin is a frozen fallback" if r.builtin else "--versions latest"))

        # 1. build (once for every selection: one image serves every model source)
        def build():
            row = self.image_row(r.product)
            if row and row.get("current") and row.get("status") == "up to date" and (want == "latest" or row.get("version") == want.split("+")[0] or row.get("version") == want):
                res["notes"].append("image already prepared for this build (%s)" % row.get("version"))
                return True
            code, out = self.doz("image", "bake", r.product, "--yes", "-q", timeout=2400)
            if code != 0:
                fail("build: doz image bake %s exited %d: %s" % (r.product, code, out.strip()[-600:]))
                return False
            return True
        t = time.time()
        built = build()
        res["durations"]["build"] = round(time.time() - t, 1)
        if not built:
            return [self.finish(res, t_all)]
        row = self.image_row(r.product) or {}
        version = row.get("version") or want
        if want != "latest" and version.split("+")[0] != want.split("+")[0]:
            fail("build: the image holds %s, not the pin %s" % (version, want))
        for i, (source, model) in enumerate(sels):
            s = res if i == 0 else self.new_result(r, source)
            s["provider"] = source
            s["selection"] = source if r.models else None
            s["model"] = model
            s["version"] = version
            if i > 0:
                s["notes"].append("the image of the first selection")
            print("recipe-check: %s · %s …" % (r.product, source), flush=True) if r.models else None
            self.run_selection(r, s, source, model, first=(i == 0))
            results.append(self.finish(s, t_all if i == 0 else s.pop("_t")))
        return results

    def new_result(self, r, provider):
        return {"id": r.product, "recipe": r.doc_id, "provider": provider, "selection": None, "model": None,
                "status_protocol": r.status, "version": None, "pass": False, "durations": {}, "status_states": [],
                "failures": [], "notes": [], "_t": time.time()}

    def run_selection(self, r, res, source, model, first):
        fail = res["failures"].append

        def step(name, fn):
            t = time.time()
            try:
                return fn()
            finally:
                res["durations"][name] = round(time.time() - t, 1)

        # 2. a fresh try (with this model source: its account is the rc-SOURCE key)
        def make_try():
            before = {s["name"] for s in self.sandboxes()}
            extra = []
            if r.models:
                extra = ["--gateway" if source in GATEWAYS else "--provider", source, "--account", "rc-" + source]
            code, out = self.doz("try", r.product, *extra, "-d", "-q", timeout=1500)
            names = [s["name"] for s in self.sandboxes() if s.get("trial") and s["name"] not in before]
            if code != 0 or not names:
                fail("try: doz try %s %s -d exited %d: %s" % (r.product, " ".join(extra), code, out.strip()[-600:]))
                return None
            return names[0]
        name = step("try", make_try)
        if not name:
            return
        res["sandbox"] = name
        try:
            self.checks(r, name, res, step, source, model, first)
        finally:
            self.doz("rm", name, "--yes", timeout=300)
            folder = os.path.join(self.root, "projects", name)
            if os.path.isdir(folder) and not os.listdir(folder):
                os.rmdir(folder)

    def image_row(self, name):
        code, out = self.doz("image", "ls", "--json", timeout=120)
        try:
            rows = json.loads(out[out.index("["):])
        except ValueError:
            return None
        return next((x for x in rows if x.get("name") == name), None)

    def checks(self, r, name, res, step, source, model, first):
        fail = res["failures"].append
        version = (res["version"] or "").split("+")[0]

        # 0. the first screen — before anything else runs in the try (a turn may write the very files a wizard looks for)
        if r.session != "shell" and first:
            step("screen", lambda: self.first_screen(r, name, res))
        if self.args.only == "screen":
            return

        # 3. verify (again after the smoke turn: an agent that updated itself while it ran is caught) — first selection only
        def verify(after=""):
            for v in r.verify:
                code, out = self.doz("exec", name, "--", *v["argv"], timeout=180)
                exp = (v.get("expect") or "").replace("${{ kit.args.version }}", version)
                if code != 0 or (exp and exp not in out):
                    fail("verify%s: %s → exit %d, %r (expected %r)" % (after, " ".join(v["argv"]), code, out.strip()[-200:], exp))
        if first:
            step("verify", verify)

        # 4. smoke — the check turn; `${{ dozer.model }}` is this selection's model
        def smoke():
            c = r.check
            base = self.base_urls.get((r.product, source), "")
            argv = [a.replace("${{ dozer.model }}", model or "").replace("${{ dozer.base_url }}", base) for a in c["argv"]]
            n0 = len(self.requests())
            code, out = self.doz("exec", name, "--", *argv, timeout=int(c.get("timeout") or 240) + 30)
            res["smoke_output"] = out.strip()[-400:]
            if c["expect"] not in out:
                fail("smoke: %s did not print %r (exit %d): %s" % (" ".join(argv), c["expect"], code, out.strip()[-400:]))
            if code != int(c.get("exit") or 0):
                fail("smoke: %s exited %d, expected %d" % (" ".join(argv), code, int(c.get("exit") or 0)))
            seen = self.requests()[n0:]
            if not any(KEYS[source] in json.dumps(q.get("auth") or {}) for q in seen):
                fail("smoke: the stand-in never saw the %s key swapped in by the proxy (%d requests: %s)" % (
                    source, len(seen), ", ".join(sorted({(q.get("host") or "") + (q.get("path") or "") for q in seen}))[:300]))
            hosts = {(q.get("host") or "").split(":")[0] for q in seen}
            if r.models and LEAK_TARGET[source][0] not in hosts:
                fail("smoke: no request reached %s (the chosen source) — it went to %s" % (LEAK_TARGET[source][0], ", ".join(sorted(hosts)) or "nothing"))
        step("smoke", smoke)

        # 4b. the guide (617.11): its first step IS the check turn (the loader holds them equal); every later step with a
        # command that is not an edit runs as a person would type it, in a shell — exit 0 — the first selection only.
        def guide():
            steps = (r.guide or {}).get("steps") or []
            check_step = next((i for i, s in enumerate(steps) if s.get("command")), None)
            for i, s in enumerate(steps):
                cmd = s.get("command")
                if i == check_step or not cmd or s.get("edit"):
                    continue
                code, out = self.doz("exec", name, "--", "sh", "-c", cmd, timeout=int(r.check.get("timeout") or 240) + 30)
                res.setdefault("guide_steps", []).append({"step": i + 1, "exit": code})
                if code != 0:
                    fail("guide step %d: %s exited %d: %s" % (i + 1, cmd, code, out.strip()[-300:]))
        if first and r.guide:
            step("guide", guide)
        if first:
            verify(" after the turn")

        # 5. keys: a placeholder in the guest, no key, the leak guard (to another provider AND another gateway)
        def keys():
            dirs = " ".join("'%s'" % v for v in r.volumes)
            code, out = self.doz("exec", name, "--", "sh", "-c",
                                 "env; for d in %s; do find \"$d\" -maxdepth 2 -type f -size -64k -exec cat {} + 2>/dev/null; done; true" % dirs,
                                 timeout=120)
            m = re.search(r"doz_cred_[A-Za-z0-9_-]+", out)
            if not m:
                fail("keys: no doz placeholder in the guest (%s or its state folders)" % r.key_env)
            pats = " ".join("-e '%s'" % k for k in KEYS.values())
            code, out = self.doz("exec", name, "--user", "root", "--", "sh", "-c",
                                 "grep -rlsF %s /proc/[0-9]*/environ /home /root /run /tmp /etc 2>/dev/null | head -3; echo scanned" % pats,
                                 timeout=300)
            if out.strip() != "scanned":
                fail("keys: a key is in the guest: %s" % out.strip()[:200])
            if not m:
                return
            targets = [next(p for p in ("xai", "google") if p != source)]
            if r.models:
                targets.append(next(g for g in GATEWAYS if g != source))
            for other in targets:
                host, header, path = LEAK_TARGET[other]
                self.doz("net", "allow", name, "site:" + host, "--yes", timeout=120)
                n0 = len(self.requests())
                code, out = self.doz("exec", name, "--", "sh", "-c",
                                     "curl -s -m 20 -o /dev/null -w '%%{http_code}' -H '%s' https://%s%s" % (header % m.group(0), host, path),
                                     timeout=120)
                leaked = [q for q in self.requests()[n0:] if "doz_cred_" in json.dumps(q.get("auth") or {})
                          or any(k in json.dumps(q.get("auth") or {}) for k in KEYS.values())]
                got = out.strip()[-3:]
                if got not in ("400", "401", "403") or leaked:
                    fail("keys: the placeholder sent to %s was not refused by the proxy (HTTP %s, %d reached the stand-in)" % (host, got, len(leaked)))
        step("keys", keys)

        # 6. status (OSC 7501) — the default selection only (the protocol is the agent's, not the source's)
        if r.status == "osc7501" and first:
            step("status", lambda: self.status(r, name, res))

        # 7. web ports (RP-1): each declared http port answers through a real forward on this Mac's 127.0.0.1 — the
        # default selection only (the port is the program's, not the source's)
        if r.ports and first:
            step("ports", lambda: self.web_ports(r, name, res))

    def web_ports(self, r, name, res):
        fail = res["failures"].append
        serve = r.ports.get("serve")
        if serve:
            # In the background, detached from the exec, its output kept for a failure's message.
            cmd = " ".join(shlex.quote(a) for a in serve)
            self.doz("exec", name, "--", "sh", "-c", "setsid nohup %s > /tmp/doz-serve.log 2>&1 < /dev/null & sleep 1" % cmd, timeout=60)
        code, out = self.doz("ports", name, "--json", timeout=60)
        try:
            rows = {p["port"]: p for p in json.loads(out)["ports"]}
        except (ValueError, KeyError):
            fail("ports: doz ports %s --json: %s" % (name, out.strip()[-200:]))
            return
        got = []
        for p in r.ports["ports"]:
            if (p.get("protocol") or "http") != "http":
                continue
            row = rows.get(p["port"])
            if not row or row.get("state") != "listening" or not row.get("mac_port"):
                fail("ports: %s (port %d) is not listening on this Mac: %s" % (p["title"], p["port"], json.dumps(row)[:200]))
                continue
            if not row["mac_port"] or not str(row.get("url", "")).startswith("http://127.0.0.1:"):
                fail("ports: %s is not on this Mac's loopback: %s" % (p["title"], row.get("url")))
                continue
            path = p.get("check") or p.get("path") or "/"
            line, deadline = "", time.time() + 90
            while time.time() < deadline:
                line = http_status("127.0.0.1", row["mac_port"], path)
                if line.startswith("HTTP/"):
                    break
                time.sleep(2)
            if not line.startswith("HTTP/"):
                tail = self.doz("exec", name, "--", "sh", "-c", "tail -5 /tmp/doz-serve.log 2>/dev/null; true", timeout=30)[1] if serve else ""
                fail("ports: GET 127.0.0.1:%d%s (%s, the sandbox's %d) got no HTTP answer: %s %s" % (row["mac_port"], path, p["title"], p["port"], line, tail.strip()[-200:]))
            else:
                got.append("%d→%d %s" % (p["port"], row["mac_port"], line))
        res["ports"] = got


    def session_name(self, name):
        code, out = self.doz("sessions", name, "--json", timeout=60)
        try:
            rows = json.loads(out[out.index("["):])
        except ValueError:
            return None
        live = [x for x in rows if not x.get("saved")]
        return (live or rows or [{}])[0].get("name")

    @staticmethod
    def end_attach(pid, fd):
        """The attach client gone, whatever it was doing: TERM, then KILL after 5 s — never a wait that hangs the run."""
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        end = time.time() + 5
        while time.time() < end:
            try:
                if os.waitpid(pid, os.WNOHANG)[0]:
                    break
            except OSError:
                break
            try:                              # drain, so a client blocked writing to its terminal can exit
                if select.select([fd], [], [], 0.1)[0]:
                    os.read(fd, 65536)
            except OSError:
                pass
        else:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except OSError:
                pass
        try:
            os.close(fd)
        except OSError:
            pass

    def first_screen(self, r, name, res):
        """The default session as a person first sees it: attached on a 120×40 pty, nothing typed, left to settle, then
        its screen (deckhold's text dump; the pty's bytes made plain when the session is gone)."""
        fail = res["failures"].append
        wait = int(r.screen.get("wait") or 15)
        pid, fd = pty.fork()
        if pid == 0:
            argv = [os.path.join(self.bin, "doz"), "attach", name, "--store", self.store]
            os.execve(argv[0], argv, self.env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        raw, end = bytearray(), time.time() + wait
        while time.time() < end:
            r_, _, _ = select.select([fd], [], [], 0.25)
            if r_:
                try:
                    b = os.read(fd, 65536)
                except OSError:
                    break
                if not b:
                    break
                raw.extend(b)
                if b"\x1b[6n" in b:          # a cursor-position query a terminal answers (deckhold forwards it)
                    try:
                        os.write(fd, b"\x1b[1;1R")
                    except OSError:
                        pass
        # check.screen.keys: a choice nothing skips that is not the person's decision, typed to reach the screen checked.
        for k in r.screen.get("keys") or []:
            try:
                os.write(fd, {"enter": b"\r", "esc": b"\x1b", "up": b"\x1b[A", "down": b"\x1b[B", "tab": b"\t", "space": b" "}[k])
            except (OSError, KeyError):
                pass
            end = time.time() + 4
            while time.time() < end:
                if select.select([fd], [], [], 0.25)[0]:
                    try:
                        if not os.read(fd, 65536):
                            break
                    except OSError:
                        break
        session = self.session_name(name)
        text = ""
        if session:
            code, out = self.doz("exec", name, "--user", "root", "--", "/usr/local/bin/deckhold", "dump", "-s", session, timeout=60)
            if code == 0:
                text = out
        if not text.strip():
            text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", " ", re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", raw.decode(errors="replace")))
            text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
            res["notes"].append("screen: read from the attach's bytes (no live session to dump: %s)" % (session or "none"))
        for k in (b"\x1d", b"\x1d"):
            try:
                os.write(fd, k)
            except OSError:
                pass
            time.sleep(0.15)
        self.end_attach(pid, fd)
        lines = [l.rstrip() for l in text.splitlines()]
        while lines and not lines[-1]:
            lines.pop()
        res["first_screen"] = "\n".join(lines)[-4000:]
        allow = [re.compile(a, re.I) for a in r.screen.get("allow") or []]
        found = []
        for pat, what in SETUP_SCREEN:
            for l in lines:
                if re.search(pat, l, re.I) and not any(a.search(l) for a in allow):
                    found.append("%s: %r" % (what, l.strip()[:120]))
        for pat in r.screen.get("refuse") or []:
            for l in lines:
                if re.search(pat, l, re.I):
                    found.append("refused %r: %r" % (pat, l.strip()[:120]))
        if found:
            fail("screen: the first screen is not the agent ready to work — " + "; ".join(dict.fromkeys(found))[:900])
        for pat in r.screen.get("expect") or []:
            if not re.search(pat, "\n".join(lines), re.I | re.M):
                fail("screen: the first screen does not show %r" % pat)
        if not any(l.strip() for l in lines):
            fail("screen: the first screen is empty")

    def status(self, r, name, res):
        states, stop = [], threading.Event()

        def poll():
            while not stop.is_set():
                code, out = self.doz("exec", name, "--user", "root", "--", "/usr/local/bin/deckhold", "ls", timeout=30)
                for m in re.finditer(r"status=state=([a-z]+)", out):
                    if not states or states[-1] != m.group(1):
                        states.append(m.group(1))
                stop.wait(0.5)
        t = threading.Thread(target=poll, daemon=True)
        t.start()
        pid, fd = pty.fork()
        if pid == 0:
            argv = [os.path.join(self.bin, "doz"), "attach", name, "--store", self.store]
            os.execve(argv[0], argv, self.env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        screen = bytearray()

        def read_for(seconds, until=None):
            end = time.time() + seconds
            while time.time() < end:
                r_, _, _ = select.select([fd], [], [], 0.25)
                if r_:
                    try:
                        b = os.read(fd, 65536)
                    except OSError:
                        return False
                    if not b:
                        return False
                    screen.extend(b)
                    if until and until.encode() in screen[-200000:]:
                        return True
                if until is None and states:
                    return True
            return False
        def send(b):
            try:
                os.write(fd, b)
                return True
            except OSError:              # the attach ended (the program exited, or the session could not open)
                return False
        read_for(60)                     # until the first status (or a minute)
        read_for(3, until="\x00")        # let it settle
        mark = len(screen)
        if not send(b"say ok DOZ_SLOW"):
            res["notes"].append("status: the attach ended before the turn — " + screen[-300:].decode(errors="replace"))
        time.sleep(1)
        send(b"\r")
        end = time.time() + int(r.check.get("timeout") or 240)
        got = False
        while time.time() < end and not got:
            read_for(1)
            got = r.check["expect"].encode() in screen[mark:] and "done" in states
        read_for(5, until="\x00")
        send(b"\x1d")
        time.sleep(0.1)
        send(b"\x1d")
        read_for(5, until="\x00")
        self.end_attach(pid, fd)
        stop.set()
        t.join(timeout=40)
        res["status_states"] = states
        missing = [s for s in STATES_NEEDED if s not in states]
        if missing:
            res["failures"].append("status: deckhold never held %s (seen: %s)" % (", ".join(missing), " → ".join(states) or "nothing"))

    def finish(self, res, t_all):
        res.pop("_t", None)
        res["durations"]["total"] = round(time.time() - t_all, 1)
        res["pass"] = not res["failures"]
        return res


def summary_markdown(report):
    lines = ["### Recipes — %s" % ("all passed" if report["pass"] else "FAILED"), "",
             "| Recipe | Result | Version | Build | Smoke | Status states | Total | Failures |", "|---|---|---|---|---|---|---|---|"]
    for r in report["recipes"]:
        d = r["durations"]
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["id"] + (" · " + r["selection"] if r.get("selection") else ""), "pass" if r["pass"] else "**FAIL**", r.get("version") or "", "%ss" % d.get("build", "–"), "%ss" % d.get("smoke", "–"),
            " → ".join(r["status_states"]) or ("–" if r["status_protocol"] != "osc7501" else "none"), "%ss" % d.get("total", "–"),
            "<br>".join(x.replace("|", "\\|")[:300] for x in r["failures"]) or ""))
    return "\n".join(lines) + "\n"


# What makes every recipe's check stale: the harness, the stand-in, the shared recipe data, the format.
SHARED = ("Scripts/recipe-check.py", "Scripts/fake-provider.py", "Scripts/fake-provider-up.sh", ".github/workflows/recipes.yml",
          "Sources/DozerKit/Recipes/providers.json", "Sources/DozerKit/Recipes/gateways.json", "Sources/DozerKit/Recipes/tags.json",
          "schema/dozer-recipe-2.schema.json")


def changed_recipes(base, known):
    """The recipes a change since BASE touches: `all` when something they share changed, else each recipe whose
    YAML, compiled JSON or network profile changed (a new recipe included; a removed one left out)."""
    p = subprocess.run(["git", "-C", REPO, "diff", "--name-only", base + "...HEAD"], capture_output=True, text=True)
    if p.returncode != 0:
        p = subprocess.run(["git", "-C", REPO, "diff", "--name-only", base, "HEAD"], capture_output=True, text=True)
    if p.returncode != 0:
        return ["all"]
    out = []
    for f in p.stdout.split():
        if f in SHARED:
            return ["all"]
        m = (re.match(r"Sources/DozerKit/Recipes/agents/[^/]+/([^/]+)\.yaml$", f) or re.match(r"Sources/DozerKit/Recipes/compiled/([^/]+)\.json$", f)
             or re.match(r"profiles/([^/]+)\.json$", f))
        if m and m.group(1) in known and m.group(1) not in out:
            out.append(m.group(1))
    return out


def prune(h, days):
    """Remove prepared images (one bake each) made more than DAYS ago: the next check prepares them again."""
    if not os.path.exists(os.path.join(h.bin, "doz")):
        print("recipe-check: nothing to prune (no store at %s)" % h.root)
        return 0
    code, out = h.doz("resources", "--json", timeout=600)
    try:
        tree = json.loads(out[out.index("{"):])
    except ValueError:
        print("recipe-check: could not read the store's resources: " + out[-300:], file=sys.stderr)
        return 1
    old, cutoff = [], time.time() - days * 86400

    def walk(x):
        if isinstance(x, dict):
            i, path = str(x.get("id", "")), x.get("path")
            if i.startswith("image:") and "@" in i and path and x.get("deletable"):
                try:
                    if os.path.getmtime(os.path.join(h.store, path)) < cutoff:
                        old.append(i)
                except OSError:
                    pass
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(tree)
    if not old:
        print("recipe-check: no image older than %d days" % days)
        return 0
    code, out = h.doz("resources", "rm", *old, "--yes", timeout=900)
    print("recipe-check: pruned %s (exit %d)\n%s" % (", ".join(old), code, out.strip()[-600:]))
    h.doz("host", "stop", timeout=300)
    return code


def main():
    ap = argparse.ArgumentParser(description="Run each recipe for real in a scratch store (make recipe-check).")
    ap.add_argument("--store", default=os.environ.get("RECIPE_STORE") or "/tmp/doz-recipe-check")
    ap.add_argument("--report")
    ap.add_argument("--summary")
    ap.add_argument("--doz", default=os.path.join(REPO, ".build/debug/doz"))
    ap.add_argument("--versions", choices=["pin", "latest"], default="pin")
    ap.add_argument("--only", choices=["screen"], help="screen: only the try and its first-screen check")
    ap.add_argument("--selections", default=os.environ.get("RECIPE_SELECTIONS") or "all",
                    help="a models@1 recipe: all (default) | default | a list of sources (\"openai openrouter\")")
    ap.add_argument("--changed", metavar="BASE", help="print the recipes a change since BASE touches (all, or ids, or nothing) and exit")
    ap.add_argument("--prune-days", type=int, metavar="N", help="remove prepared images baked more than N days ago from the store, then exit")
    ap.add_argument("recipes", nargs="*")
    a = ap.parse_args()
    known = sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(COMPILED, "*.json")))
    if a.changed:
        print(" ".join(changed_recipes(a.changed, known)))
        return 0
    if a.prune_days is not None:
        return prune(Harness(a), a.prune_days)
    wanted = [w for x in a.recipes for w in x.replace(",", " ").split()]
    if not wanted:
        ap.error("name the recipes (or all): " + " ".join(known))
    ids = known if wanted == ["all"] else wanted
    unknown = [i for i in ids if i not in known]
    if unknown:
        ap.error("no such recipe: %s (known: %s)" % (", ".join(unknown), " ".join(known)))
    if not os.path.exists(a.doz):
        ap.error("no doz at %s (make cli)" % a.doz)
    recipes = [Recipe(os.path.join(COMPILED, i + ".json")) for i in ids]
    h = Harness(a)
    report_path = a.report or os.path.join(h.root, "report.json")
    report = {"started": now(), "store": h.root, "versions": a.versions, "recipes": []}
    h.install_binary()
    code, out = h.doz("--version", timeout=60)
    report["doz"] = out.strip().splitlines()[-1] if out.strip() else ""
    h.start_fake()
    try:
        # Every source's account (rc-SOURCE, a FAKE key): a selection's try names its own.
        h.prepare_store(set(KEYS) | {r.provider for r in recipes if r.provider})
        for r in recipes:
            print("recipe-check: %s …" % r.product, flush=True)
            for res in h.run(r):
                report["recipes"].append(res)
                print("recipe-check: %s%s %s (%s, %ss)%s" % (r.product, " · " + res["selection"] if res.get("selection") else "",
                                                            "PASS" if res["pass"] else "FAIL", res.get("version"), res["durations"].get("total"),
                                                            "".join("\n  - " + f for f in res["failures"])), flush=True)
            report["pass"] = all(x["pass"] for x in report["recipes"])
            report["finished"] = now()
            with open(report_path, "w") as f:
                json.dump(report, f, indent=2)
    finally:
        h.doz("host", "stop", timeout=300)
        h.stop_fake()
    report["pass"] = all(x["pass"] for x in report["recipes"])
    report["finished"] = now()
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
    if a.summary:
        with open(a.summary, "a") as f:
            f.write(summary_markdown(report))
    print("recipe-check: %d of %d passed — report %s" % (sum(x["pass"] for x in report["recipes"]), len(report["recipes"]), report_path))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
