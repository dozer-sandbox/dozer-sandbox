#!/usr/bin/env python3
"""feed — Dozer's update feed and Homebrew formulas, built from per-build fragments (611).

THE SHAPE (Deckosaurus's appcast design, as JSON). The updates site (a GitHub Pages repo behind
https://updates.dozersandbox.com, Cloudflare in front) holds

    v1/items/build-<n>.json   ONE fragment per build: the signed entry + its channel history (the truth)
    v1/feed.json              GENERATED from every fragment, newest build first — never edited by hand
    v1/notes/<version>.html   the release notes page each entry links to
    CNAME                     updates.dozersandbox.com

`/v1/` is the feed's FORMAT version — every doz ever shipped reads `/v1/feed.json` (compiled in); a new format
goes beside it as `/v2/`, never in place. Rendering is DETERMINISTIC (same fragments → byte-identical feed, no
timestamp of its own), which is what makes `make publish` and `make promote` idempotent: a re-run is no diff.

A build is published ONCE (its signature covers version, build, archive name, sha256 and size — Scripts/update-key.swift)
and moves between channels by editing one field of its fragment: PROMOTE, NEVER REBUILD. Channels nest — a stable
build is offered on beta and canary too — and promotion only ever WIDENS (canary → beta → stable): narrowing would hide
a build from the people who have not installed it while leaving it on the machines that have.

The Homebrew formulas (Formula/doz.rb, doz-beta.rb, doz-canary.rb) are a pure function of the fragments as well: each
channel's formula is the newest build that channel is offered.

  feed.py write-item   --items DIR --version V --channel C --archive-url U --size N --sha256 H --signature S
                       --notes-url U --date YYYY-MM-DD        → prints the build number (idempotent)
  feed.py set-channel  --items DIR --build N --channel C --date D   (widen only; idempotent)
  feed.py render       --items DIR --out FILE
  feed.py show         --items DIR --build N --field F
  feed.py build-of     --items DIR --version V             (the build number of a version, or nothing)
  feed.py formulas     --items DIR --tap-dir DIR --template FILE --homepage URL
  feed.py render-notes --markdown FILE --out FILE --title T
  feed.py selftest

Standard library only. Exit 0 on success; non-zero with a message on stderr otherwise.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import tempfile
from pathlib import Path

CHANNELS = ["stable", "beta", "canary"]  # widest first: a build on index i is offered on every channel j >= i
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FIELDS = ["version", "build", "channel", "date", "notes", "archive", "size", "sha256", "signature"]


def die(message: str) -> None:
    print(f"x feed: {message}", file=sys.stderr)
    sys.exit(1)


def semver_key(v: str):
    m = SEMVER.match(v)
    if not m:
        die(f"'{v}' is not a version")
    core = tuple(int(x) for x in m.groups()[:3])
    pre = m.group(4)
    if pre is None:
        return core + ((1,),)
    ids = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return core + ((0,) + ids,)


def width(channel: str) -> int:
    if channel not in CHANNELS:
        die(f"'{channel}' is not one of {'/'.join(CHANNELS)}")
    return CHANNELS.index(channel)


def fragments(items: Path) -> list[dict]:
    out = []
    for p in sorted(items.glob("build-*.json")):
        out.append(json.loads(p.read_text()))
    return out


def fragment_path(items: Path, build: int) -> Path:
    return items / f"build-{build}.json"


def write_json(path: Path, obj) -> None:
    text = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == text:
        return
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as t:
        t.write(text)
    Path(t.name).replace(path)


def cmd_write_item(a) -> None:
    items = Path(a.items)
    width(a.channel)
    semver_key(a.version)
    if not re.fullmatch(r"[0-9a-f]{64}", a.sha256):
        die("--sha256 is 64 lowercase hex")
    if not DATE.match(a.date):
        die("--date is YYYY-MM-DD")
    existing = [f for f in fragments(items) if f["version"] == a.version]
    if existing:
        f = existing[0]
        if f["sha256"] != a.sha256 or f["size"] != a.size:
            die(f"{a.version} is already published as build {f['build']} with other bytes — a published version is "
                "never re-cut: publish a new version")
        # Idempotent: the same bytes again keep the build, its channel and its history.
        print(f["build"])
        return
    build = max([f["build"] for f in fragments(items)] or [0]) + 1
    entry = {"version": a.version, "build": build, "channel": a.channel, "date": a.date, "notes": a.notes_url,
             "archive": a.archive_url, "size": a.size, "sha256": a.sha256, "signature": a.signature,
             "history": [{"channel": a.channel, "date": a.date, "event": "published"}]}
    write_json(fragment_path(items, build), entry)
    print(build)


def cmd_set_channel(a) -> None:
    items = Path(a.items)
    p = fragment_path(items, a.build)
    if not p.exists():
        have = ", ".join(str(f["build"]) + "=" + f["version"] for f in fragments(items)) or "nothing"
        die(f"build {a.build} is not in the feed (published: {have})")
    f = json.loads(p.read_text())
    if width(a.channel) > width(f["channel"]):
        die(f"build {a.build} ({f['version']}) is on {f['channel']}; moving it to {a.channel} would NARROW it — a channel only "
            "widens (publish a newer build instead)")
    if a.channel == f["channel"]:
        return
    f["channel"] = a.channel
    f.setdefault("history", []).append({"channel": a.channel, "date": a.date, "event": "promoted"})
    write_json(p, f)


def feed_of(items: Path) -> dict:
    entries = sorted(fragments(items), key=lambda f: f["build"], reverse=True)
    return {"schema": 1, "product": "doz", "entries": [{k: e[k] for k in FIELDS if k in e} for e in entries]}


def cmd_render(a) -> None:
    write_json(Path(a.out), feed_of(Path(a.items)))


def cmd_show(a) -> None:
    p = fragment_path(Path(a.items), a.build)
    if not p.exists():
        die(f"build {a.build} is not in the feed")
    f = json.loads(p.read_text())
    if a.field == "history":
        for h in f.get("history", []):
            print(f"{h['date']}  {h['event']:<9}  {h['channel']}")
        return
    if a.field not in f:
        die(f"no field {a.field}")
    print(f[a.field])


def cmd_build_of(a) -> None:
    for f in fragments(Path(a.items)):
        if f["version"] == a.version:
            print(f["build"])
            return


def newest_for(channel: str, entries: list[dict]):
    offered = [e for e in entries if width(e["channel"]) <= width(channel)]
    return max(offered, key=lambda e: semver_key(e["version"]), default=None)


def class_name(formula: str) -> str:
    return "".join(part.capitalize() for part in formula.split("-"))


def formula_name(channel: str) -> str:
    return "doz" if channel == "stable" else f"doz-{channel}"


def cmd_formulas(a) -> None:
    entries = fragments(Path(a.items))
    template = Path(a.template).read_text()
    out = Path(a.tap_dir) / "Formula"
    for ch in CHANNELS:
        e = newest_for(ch, entries)
        name = formula_name(ch)
        if e is None:
            continue
        others = [formula_name(c) for c in CHANNELS if c != ch]
        conflicts = "\n".join(f'  conflicts_with "{o}", because: "it installs the same doz command (another release channel)"'
                              for o in others) + "\n"
        line = ("stable releases." if ch == "stable" else
                f"the {ch} channel ({'beta and stable releases' if ch == 'beta' else 'every build first: canary, beta and stable'}).")
        text = (template.replace("{{NAME}}", name).replace("{{CLASS}}", class_name(name))
                .replace("{{CHANNEL_LINE}}", line).replace("{{HOMEPAGE}}", a.homepage)
                .replace("{{URL}}", e["archive"]).replace("{{VERSION}}", e["version"]).replace("{{SHA256}}", e["sha256"])
                .replace("{{CONFLICTS}}", conflicts))
        if "{{" in text:
            die(f"the template left a placeholder in {name}.rb")
        p = out / f"{name}.rb"
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists() or p.read_text() != text:
            p.write_text(text)
        print(f"{name}: {e['version']} (build {e['build']}, {e['channel']})")


# ── release notes: a deliberately minimal, dependency-free markdown subset ──────────────────────────────────────
# Headings, paragraphs, bullets, fenced code, `code`, [links](https://…) and **strong** — everything else is escaped.

def inline(t: str) -> str:
    out, i = [], 0
    while i < len(t):
        if t[i] == "`" and (j := t.find("`", i + 1)) != -1:
            out.append(f"<code>{html.escape(t[i + 1:j])}</code>"); i = j + 1; continue
        if t.startswith("**", i) and (j := t.find("**", i + 2)) != -1:
            out.append(f"<strong>{inline(t[i + 2:j])}</strong>"); i = j + 2; continue
        m = re.match(r"\[([^\]]+)\]\((https://[^)\s]+)\)", t[i:])
        if m:
            out.append(f'<a href="{html.escape(m.group(2), quote=True)}">{inline(m.group(1))}</a>'); i += m.end(); continue
        out.append(html.escape(t[i])); i += 1
    return "".join(out)


def markdown(text: str) -> str:
    out, para, in_list, in_code = [], [], False, False

    def flush():
        nonlocal para, in_list
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>"); para = []
        if in_list:
            out.append("</ul>"); in_list = False

    for raw in text.replace("\r\n", "\n").split("\n"):
        line = raw.rstrip()
        if line.startswith("```"):
            if in_code:
                out.append("</code></pre>"); in_code = False
            else:
                flush(); out.append("<pre><code>"); in_code = True
            continue
        if in_code:
            out.append(html.escape(raw)); continue
        if not line.strip():
            flush(); continue
        if m := re.match(r"^(#{1,6})\s+(.*)$", line):
            flush(); n = len(m.group(1)); out.append(f"<h{n}>{inline(m.group(2))}</h{n}>"); continue
        if m := re.match(r"^\s*[-*]\s+(.*)$", line):
            if para:
                out.append(f"<p>{inline(' '.join(para))}</p>"); para = []
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(m.group(1))}</li>"); continue
        if in_list:
            out.append("</ul>"); in_list = False
        para.append(line.strip())
    if in_code:
        out.append("</code></pre>")
    flush()
    return "\n".join(out)


def cmd_render_notes(a) -> None:
    body = markdown(Path(a.markdown).read_text())
    t = html.escape(a.title)
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t}</title>
<style>:root{{color-scheme:light dark}}body{{font:16px/1.55 -apple-system,system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}}code,pre{{font:14px ui-monospace,Menlo,monospace}}pre{{overflow:auto;padding:.75rem;border-radius:6px;background:color-mix(in srgb,currentColor 8%,transparent)}}</style>
</head><body>
<h1>{t}</h1>
{body}
</body></html>
"""
    p = Path(a.out)
    p.parent.mkdir(parents=True, exist_ok=True)
    if not p.exists() or p.read_text() != page:
        p.write_text(page)


def cmd_selftest(_a) -> None:
    assert semver_key("0.31.0-rc.2") < semver_key("0.31.0-rc.10") < semver_key("0.31.0") < semver_key("0.31.1")
    assert semver_key("1.0.0-alpha") < semver_key("1.0.0-alpha.1") < semver_key("1.0.0-beta")
    with tempfile.TemporaryDirectory() as d:
        items = Path(d) / "items"
        ns = argparse.Namespace
        common = dict(items=str(items), archive_url="https://x/doz.tgz", size=10, signature="s", notes_url="https://n", date="2026-10-09")
        cap = sys.stdout
        import io
        sys.stdout = io.StringIO()
        cmd_write_item(ns(version="0.31.0", channel="canary", sha256="a" * 64, **common))
        cmd_write_item(ns(version="0.31.0", channel="canary", sha256="a" * 64, **common))  # idempotent
        cmd_write_item(ns(version="0.31.1-rc.1", channel="canary", sha256="b" * 64, **common))
        sys.stdout = cap
        assert len(fragments(items)) == 2
        cmd_set_channel(ns(items=str(items), build=1, channel="stable", date="2026-10-10"))
        cmd_set_channel(ns(items=str(items), build=1, channel="stable", date="2026-10-11"))  # idempotent
        f = json.loads(fragment_path(items, 1).read_text())
        assert f["channel"] == "stable" and len(f["history"]) == 2
        es = fragments(items)
        assert newest_for("stable", es)["version"] == "0.31.0"
        assert newest_for("beta", es)["version"] == "0.31.0"
        assert newest_for("canary", es)["version"] == "0.31.1-rc.1"
        a1 = json.dumps(feed_of(items), sort_keys=True)
        a2 = json.dumps(feed_of(items), sort_keys=True)
        assert a1 == a2 and feed_of(items)["entries"][0]["build"] == 2 and "history" not in feed_of(items)["entries"][0]
        assert "<script>" not in markdown("<script>x</script> [a](javascript:x) **b**")
    print("ok feed.py selftest")


def main() -> None:
    p = argparse.ArgumentParser(prog="feed.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write-item")
    for k in ["items", "version", "channel", "archive-url", "sha256", "signature", "notes-url", "date"]:
        w.add_argument("--" + k, required=True)
    w.add_argument("--size", type=int, required=True)
    s = sub.add_parser("set-channel")
    s.add_argument("--items", required=True); s.add_argument("--build", type=int, required=True)
    s.add_argument("--channel", required=True); s.add_argument("--date", required=True)
    r = sub.add_parser("render"); r.add_argument("--items", required=True); r.add_argument("--out", required=True)
    sh = sub.add_parser("show"); sh.add_argument("--items", required=True); sh.add_argument("--build", type=int, required=True); sh.add_argument("--field", required=True)
    b = sub.add_parser("build-of"); b.add_argument("--items", required=True); b.add_argument("--version", required=True)
    f = sub.add_parser("formulas")
    for k in ["items", "tap-dir", "template", "homepage"]:
        f.add_argument("--" + k, required=True)
    n = sub.add_parser("render-notes")
    for k in ["markdown", "out", "title"]:
        n.add_argument("--" + k, required=True)
    sub.add_parser("selftest")
    a = p.parse_args()
    {"write-item": cmd_write_item, "set-channel": cmd_set_channel, "render": cmd_render, "show": cmd_show,
     "build-of": cmd_build_of, "formulas": cmd_formulas, "render-notes": cmd_render_notes, "selftest": cmd_selftest}[a.cmd](a)


if __name__ == "__main__":
    main()
