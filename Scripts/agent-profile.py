#!/usr/bin/env python3
# The network profile of an agent (617): turn a profiling run's connection log (`doz net log NAME --json`, every HTTPS
# request decrypted by DOZ_TEST_PROFILE_NETWORK=1) into the endpoints it called, and merge them into the committed
# profile (profiles/AGENT.json). Python 3.9+ stdlib only. Run by Scripts/profile-agents.sh.
#
#   record: write the profile — every endpoint seen, keeping each determination already made; a NEW endpoint gets
#           "determination": null (FirstRunTests/ProfileTests fail until a person decides it — nothing is ever allowed
#           by this script); an endpoint not seen this time is kept and marked "seen": false.
#   diff:   write nothing; print new and missing endpoints; exit 1 when an endpoint is new.
#
# An endpoint is (host, method, path pattern). A path's ids (long hex, version-like or long mixed tokens) become {id}
# so a plugin's commit or an SDK key does not make a new endpoint each run. The query string is never recorded.
import argparse, datetime, json, re, sys

DETERMINATIONS = ("allow", "allow-path", "off-by-setting", "refuse")

# How every profile is made (Scripts/profile-agents.sh) — what a new profile says until a person says otherwise.
HOW = "a fresh try with the Open network, every HTTPS request decrypted and logged; its first start, then a scripted task (read a file, edit it, run a command) run non-interactively with FAKE keys — xAI and Google through a fake provider that answers text only, Anthropic and OpenAI refused by the real API (401). A real-key run would see more: the model's turns and what its tool calls fetch."

def pattern(path):
    if not path:
        return None
    out = []
    for seg in path.split("?")[0].split("/"):
        seg = re.sub(r"(?<![\w.])v?\d+\.\d+\.\d+", "{version}", seg)
        seg = re.sub(r"^[\w.-]+:(\w+)$", r"{model}:\1", seg)       # the Gemini API's models/<model>:<method>
        m = re.fullmatch(r"([0-9a-fA-F]{16,}|[\w-]{20,})(\.[a-z]{2,5})?", seg)
        if m and "{" not in seg and (re.fullmatch(r"[0-9a-fA-F]{16,}", m.group(1)) or (re.search(r"\d", m.group(1)) and re.search(r"[A-Za-z]", m.group(1)))):
            out.append("{id}" + (m.group(2) or ""))
        else:
            out.append(seg)
    return "/".join(out) or "/"

def credential(c):
    if not c:
        return "none"
    if c.startswith("swapped "):
        return "placeholder swapped for " + c[len("swapped "):]
    if c.startswith("injected "):
        return "key added for " + c[len("injected "):]
    return c.split(":")[0]

def endpoints(records, task_start):
    decrypted_hosts = {r["host"] for r in records if r.get("kind") == "http"}
    seen = {}
    for r in records:
        kind = r.get("kind")
        if kind == "dns":
            continue
        host = r["host"].lower()
        if kind == "http":
            key = (host, r.get("method") or "GET", pattern(r.get("path")))
        elif host in decrypted_hosts:
            continue        # its requests are listed one by one
        else:
            key = (host, "CONNECT", None)
        t = r.get("time")
        when = "start"
        if t is not None and task_start is not None:
            ts = t if isinstance(t, (int, float)) else datetime.datetime.fromisoformat(str(t).replace("Z", "+00:00")).timestamp()
            if ts >= task_start:
                when = "task"
        e = seen.setdefault(key, {"host": key[0], "method": key[1], "path": key[2], "count": 0, "when": set(), "credential": set(),
                                  "verdict": set()})
        e["count"] += 1
        e["when"].add(when)
        e["credential"].add(credential(r.get("credential")))
        e["verdict"].add(r.get("verdict"))
    out = []
    for e in seen.values():
        e["when"] = "start+task" if len(e["when"]) == 2 else next(iter(e["when"]))
        e["credential"] = sorted(e["credential"])
        e["refusedWhenProfiled"] = "denied" in e["verdict"]
        del e["verdict"]
        out.append(e)
    return out

def keyof(e):
    return (e["host"], e["method"], e.get("path"))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["record", "diff"])
    ap.add_argument("--agent", required=True)
    ap.add_argument("--version", default="")
    ap.add_argument("--log", required=True)
    ap.add_argument("--task-start", type=float)
    ap.add_argument("--task-output")
    ap.add_argument("--profile", required=True)
    a = ap.parse_args()

    with open(a.log) as f:
        raw = json.load(f)
    records = raw if isinstance(raw, list) else raw.get("connections") or raw.get("records") or []
    found = endpoints(records, a.task_start)
    try:
        with open(a.profile) as f:
            old = json.load(f)
    except FileNotFoundError:
        old = {"schema": 1, "agent": a.agent, "endpoints": []}
    known = {keyof(e): e for e in old.get("endpoints", [])}
    now = {keyof(e): e for e in found}
    # A tunnel with no request in it, to a host the profile already lists request by request: the program exited
    # before its request went (promptfoo's telemetry event at the end of a run) — that host is not new.
    decrypted_known = {k[0] for k in known if k[1] != "CONNECT"}
    now = {k: e for k, e in now.items() if not (k[1] == "CONNECT" and k[0] in decrypted_known)}
    # And the other way round: a host the profile knows only as a tunnel (its request never came when profiled — Docker
    # Agent's models.dev) seen request by request now is the same host, already decided as a whole.
    tunnel_known = {k[0] for k in known if k[1] == "CONNECT"}
    now = {k: e for k, e in now.items() if not (k[1] != "CONNECT" and k[0] in tunnel_known and k[0] not in decrypted_known)}
    new =[k for k in now if k not in known]
    missing = [k for k in known if k not in now]

    def show(k):
        return "%s %s%s" % (k[1], k[0], k[2] or "")

    if a.mode == "diff":
        print("== %s %s: %d endpoints seen, %d new, %d not seen this time" % (a.agent, a.version, len(now), len(new), len(missing)))
        for k in new:
            print("  NEW      " + show(k) + "   (credential: " + ", ".join(now[k]["credential"]) + ")")
        for k in missing:
            print("  MISSING  " + show(k))
        return 1 if new else 0

    merged = []
    for k, e in now.items():
        prev = known.get(k, {})
        merged.append({"host": e["host"], "method": e["method"], "path": e["path"], "when": e["when"], "count": e["count"],
                       "credential": e["credential"], "refusedWhenProfiled": e["refusedWhenProfiled"],
                       "determination": prev.get("determination"), "reason": prev.get("reason"),
                       **({"setting": prev["setting"]} if prev.get("setting") else {}), "seen": True})
    for k in missing:
        e = dict(known[k])
        e["seen"] = False
        merged.append(e)
    merged.sort(key=lambda e: (e["host"], e.get("path") or "", e["method"]))
    task_note = None
    if a.task_output:
        try:
            with open(a.task_output, errors="replace") as f:
                tail = [l.strip() for l in f.read().splitlines() if l.strip()][-3:]
            task_note = " / ".join(tail)[:300]
        except FileNotFoundError:
            pass
    prof = {
        "schema": 1,
        "agent": a.agent,
        "version": a.version,
        "profiled": datetime.date.today().isoformat(),
        "how": old.get("how") or HOW,
        "taskEnded": task_note,
        "endpoints": merged,
    }
    with open(a.profile, "w") as f:
        json.dump(prof, f, indent=2, ensure_ascii=False)
        f.write("\n")
    undecided = [e for e in merged if not e.get("determination")]
    print("== %s %s: %d endpoints (%d new, %d not seen this time) -> %s" % (a.agent, a.version, len(merged), len(new), len(missing), a.profile))
    for e in undecided:
        print("  UNDECIDED  %s %s%s" % (e["method"], e["host"], e.get("path") or ""))
    return 0

sys.exit(main())
