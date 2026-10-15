#!/usr/bin/env python3
# The agents' currency report (617, owner: "we are going to see this a lot so need to record the latest version and how
# old it is and is it current"). For every recipe: its latest release (npm's registry, or the vendor's own release
# manifest), when it came out and how old that is, freshness (active <= 90 days, quiet > 90, stale > 180; deprecated
# overrides), npm's deprecation message, whether the vendor's GitHub repository is archived, and the lifecycle the recipe
# RECORDS (current / superseded by … / retired). Read-only, unauthenticated requests to registry.npmjs.org, the vendor's
# manifest and api.github.com. Python 3.9+ stdlib only.
#
#   make agent-currency             print the report and write profiles/currency.json
#   Scripts/agent-currency.py --check   print only; exit 1 when something needs a person (see below)
#
# Against the last committed report and the network profiles it says what to do: a NEW latest version → "re-profile
# its network" (make profile-agents AGENTS=…); newly deprecated or archived → "review its lifecycle".
import datetime, glob, json, os, re, sys, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The compiled recipes (Recipes/compiled/*.json — each Recipes/agents/VENDOR/PRODUCT.yaml as JSON, schema 2).
RECIPES = os.path.join(REPO, "Sources/DozerKit/Recipes/compiled")

def flat(doc):
    """The few fields this report reads, from a schema-2 recipe (its capabilities by type)."""
    caps = {c["type"]: c.get("config", {}) for c in doc["capabilities"]}
    return {"id": doc["id"].split("/")[-1], "title": doc["displayName"], "homepage": doc["sourceUrl"],
            "install": caps["com.dozersandbox/install@1"], "pin": doc["args"]["version"]["default"].split("+")[0],
            "lifecycle": caps.get("com.dozersandbox/currency@1", {}).get("lifecycle")}
OUT = os.path.join(REPO, "profiles/currency.json")
TODAY = datetime.date.today()
UA = {"User-Agent": "dozer-sandbox-agent-currency (read-only)"}

def get(url, method="GET", accept="application/json"):
    req = urllib.request.Request(url, method=method, headers=dict(UA, Accept=accept))
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.headers, (r.read() if method == "GET" else b"")

def npm(package):
    _, body = get("https://registry.npmjs.org/" + package.replace("/", "%2F"))
    d = json.loads(body)
    v = d.get("dist-tags", {}).get("latest")
    t = d.get("time", {}).get(v)
    dep = d.get("versions", {}).get(v, {}).get("deprecated")
    repo = d.get("repository", {})
    url = repo.get("url") if isinstance(repo, dict) else repo
    return v, (t or "")[:10] or None, dep, url

def manifest(recipe):
    _, body = get(recipe["install"]["manifest"])
    m = json.loads(body)
    released = None
    try:
        h, _ = get(m["url"], method="HEAD", accept="*/*")
        lm = h.get("Last-Modified")
        if lm:
            released = datetime.datetime.strptime(lm, "%a, %d %b %Y %H:%M:%S %Z").date().isoformat()
    except Exception:
        pass
    return m["version"], released, None, recipe.get("homepage")

def pypi(package):
    # 617: a pypi recipe's package — PyPI's latest release and when its files were uploaded.
    _, body = get("https://pypi.org/pypi/%s/json" % package)
    d = json.loads(body)
    v = d["info"]["version"]
    files = d.get("releases", {}).get(v) or []
    t = min((f.get("upload_time") or "" for f in files), default="")
    urls = d["info"].get("project_urls") or {}
    repo = next((u for u in urls.values() if "github.com" in (u or "")), d["info"].get("home_page"))
    return v, t[:10] or None, "yanked" if any(f.get("yanked") for f in files) else None, repo

def release(recipe):
    # 617: a release-binary recipe's GitHub repository (its url) — the latest release's tag and date.
    m = re.search(r"github\.com/([^/]+)/([^/]+)/releases/", recipe["install"]["url"])
    if not m:
        return None, None, None, recipe.get("homepage")
    _, body = get("https://api.github.com/repos/%s/%s/releases/latest" % (m.group(1), m.group(2)), accept="application/vnd.github+json")
    d = json.loads(body)
    return (d.get("tag_name") or "").lstrip("v") or None, (d.get("published_at") or "")[:10] or None, None, "https://github.com/%s/%s" % (m.group(1), m.group(2))

def github(url):
    m = re.search(r"github\.com[/:]([^/]+)/([^/#?]+?)(?:\.git)?(?:[/#?]|$)", url or "")
    if not m:
        return None
    try:
        _, body = get("https://api.github.com/repos/%s/%s" % (m.group(1), m.group(2)), accept="application/vnd.github+json")
        d = json.loads(body)
        return {"repo": "%s/%s" % (m.group(1), m.group(2)), "archived": bool(d.get("archived")), "pushed": (d.get("pushed_at") or "")[:10] or None}
    except Exception as e:
        return {"repo": "%s/%s" % (m.group(1), m.group(2)), "error": str(e)[:120]}

def freshness(released, deprecated):
    if deprecated:
        return "deprecated"
    if not released:
        return "unknown"
    age = (TODAY - datetime.date.fromisoformat(released)).days
    return "stale" if age > 180 else "quiet" if age > 90 else "active"

BUILTIN_PACKAGES = {"claude-code": "@anthropic-ai/claude-code", "pi": "@earendil-works/pi-coding-agent", "codex": "@openai/codex"}

def main():
    check = "--check" in sys.argv
    try:
        old = {a["agent"]: a for a in json.load(open(OUT))["agents"]}
    except FileNotFoundError:
        old = {}
    rows, todo = [], []
    for f in sorted(glob.glob(os.path.join(RECIPES, "*.json"))):
        r = flat(json.load(open(f)))
        aid = r["id"]
        try:
            if r["install"]["kind"] == "manifest-binary":
                v, released, dep, repo = manifest(r)
            elif r["install"]["kind"] == "pypi":
                v, released, dep, repo = pypi(r["install"]["package"])
            elif r["install"]["kind"] == "release-binary":
                v, released, dep, repo = release(r)
            else:
                v, released, dep, repo = npm(r["install"].get("package") or BUILTIN_PACKAGES[aid])
            err = None
        except Exception as e:
            v, released, dep, repo, err = None, None, None, None, str(e)[:160]
        gh = github(repo or r.get("homepage"))
        life = r.get("lifecycle") or {"status": "current"}
        try:
            profiled = json.load(open(os.path.join(REPO, "profiles", aid + ".json"))).get("version", "")
        except FileNotFoundError:
            profiled = None
        row = {"agent": aid, "title": r["title"], "pin": r["pin"], "latest": v, "released": released,
               "ageDays": (TODAY - datetime.date.fromisoformat(released)).days if released else None,
               "freshness": freshness(released, dep), "deprecated": dep, "github": gh,
               "lifecycle": life, "profiledVersion": profiled, "error": err}
        rows.append(row)
        prev = old.get(aid, {})
        # What needs doing is measured against the recipe, never against the last report: a recipe agent runs at its
        # pin (a newer release means checking it and moving the pin), a built-in one at the latest (its profile must be
        # of what it runs). The profile must always be of the version that runs.
        builtin = bool(r["install"].get("builtin"))
        runs = v if builtin else r["pin"]
        if v and not builtin and v != r["pin"]:
            todo.append("%s: a new release %s; the recipe pins %s — check it, move the pin (download + hash), re-profile: make profile-agents AGENTS=%s" % (aid, v, r["pin"], aid))
        elif runs and profiled is not None and runs not in profiled:
            todo.append("%s: its profile is of %s, it runs %s — re-profile its network: make profile-agents AGENTS=%s" % (aid, profiled, runs, aid))
        if dep and not prev.get("deprecated"):
            todo.append("%s: deprecated by its maker (%s) — review its lifecycle" % (aid, dep))
        if gh and gh.get("archived") and not (prev.get("github") or {}).get("archived"):
            todo.append("%s: its GitHub repository %s is archived — review its lifecycle" % (aid, gh["repo"]))
        if err:
            todo.append("%s: could not be checked (%s)" % (aid, err))
    print("%-12s %-22s %-11s %-9s %-10s %s" % ("AGENT", "LATEST", "RELEASED", "AGE", "FRESHNESS", "STANDING"))
    for r in rows:
        life = r["lifecycle"]
        standing = life["status"] + (" by " + life["by"] if life.get("by") else "") + (" (checked %s)" % life["checked"] if life.get("checked") else "")
        if r["github"] and r["github"].get("archived"):
            standing += " · repo archived"
        print("%-12s %-22s %-11s %-9s %-10s %s" % (r["agent"], (r["latest"] or "?")[:22], r["released"] or "?",
                                                  ("%dd" % r["ageDays"]) if r["ageDays"] is not None else "?", r["freshness"], standing))
    for t in todo:
        print("TODO  " + t)
    if not check:
        with open(OUT, "w") as f:
            json.dump({"schema": 1, "checked": TODAY.isoformat(), "agents": rows}, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print("wrote " + os.path.relpath(OUT, REPO))
    return 1 if (check and todo) else 0

sys.exit(main())
