import DozerHost
import DozerKit
import Foundation

/// 597 — Dozer Agent Permissions end to end, from separate processes of the REAL signed doz
/// (`make test-cli-permissions`; also in `make test-cli`): `doz net permissions`; `doz create --allow`;
/// `doz net NAME` (the checklist); a fresh claude-code sandbox (Standard) reaches Claude Code's own
/// hosts — the API, downloads.claude.ai, the Datadog intake, GitHub, pi.dev — and is refused PyPI and the
/// web; the refusal becomes a suggestion; `doz net allow NAME install:python` applies live (the next
/// connection, no restart); `deny github`; `allow web` warns and asks (--yes); a site; back to
/// Standard; the facts block lists the permissions in plain words; the policy is stored BY NAME; the
/// setting defaults.permissions. A store of its own (`/tmp/dzo-PID-q`); the claude-code image at the
/// pinned version (the registry is not asked); network needed for the reachability checks.
func cliPermissionsSuite(binary: String) async {
    let t = onboardingHarness(binary, "q", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: agent permissions (597)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    let projects = t.store.appendingPathComponent("projects")
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    t.run(["config", "set", "defaults.projects_dir", projects.path])
    check(t.run(["config", "set", "images.claude_code_version", AgentImages.claudeCodePinned.version]).code == 0, "images.claude_code_version = the pin")

    // 1. The catalogue.
    var r = t.run(["net", "permissions"])
    check(r.code == 0 && ["model", "sign-in", "update", "install:python", "github", "error-reports", "web", "downloads.claude.ai",
                          "http-intake.logs.us5.datadoghq.com", "pypi.org", "Talk to its AI model", "Browse the web"].allSatisfy(r.out.contains),
          "doz net permissions: every permission, in words, with its hosts")
    let cat = t.json(["net", "permissions"], [AgentPermission].self) ?? []
    check(cat.map(\.id) == AgentPermissions.all.map(\.id), "--json: the catalogue (\(cat.count))")

    // 2. create --allow, and refusals.
    r = t.run(["create", "qa", "--image", "claude-code", "--isolated", "--account", "none", "--allow", "install:python,site:example.com", "--allow", "-error-reports"])
    check(r.code == 0, "create qa --allow install:python,site:example.com --allow -error-reports (exit \(r.code))")
    var rep = t.json(["net", "show", "qa"], PermissionReport.self)
    let on = Set(rep?.permissions.filter(\.on).map(\.id) ?? [])
    check(on.contains("install:python") && on.contains("install:node") && !on.contains("error-reports") && rep?.sites == ["example.com"] && rep?.preset == nil,
          "net show qa: Python on, the base's Node on, error reports off, example.com a site, Custom (\(on.sorted().joined(separator: ",")))")
    r = t.run(["net", "qa"])
    check(r.code == 0 && r.out.contains("what the agent can do — Custom") && r.out.contains("[x] Install software — Python (PyPI)")
          && r.out.contains("[ ] Send error reports") && r.out.contains("sites you allowed: example.com"), "doz net qa: the checklist (the default subcommand)")
    r = t.run(["create", "qb", "--image", "claude-code", "--isolated", "--account", "none", "--allow", "telepathy"])
    check(r.code != 0 && r.err.contains("no permission telepathy"), "--allow telepathy: refused, named")
    r = t.run(["net", "deny", "qa", "model"])
    check(r.code != 0 && r.err.contains("cannot be switched off"), "net deny model: refused (the agent needs it)")
    let stored = (try? String(contentsOf: DozerStore(root: t.store).configFile("qa"), encoding: .utf8)) ?? ""
    check(stored.contains("install:python") && !stored.contains("pypi.org") && !stored.contains("downloads.claude.ai"),
          "stored BY NAME: the sandbox's file names the permissions, no permission hosts (P5)")
    check(t.run(["rm", "qa", "--yes"], timeout: 120).code == 0, "rm qa")

    // 3. A fresh Standard sandbox, booted.
    r = t.run(["up", "qs", "--image", "claude-code", "--isolated", "--account", "none", "--memory", "1G", "--detach"], timeout: 1800)
    check(r.code == 0, "up qs --image claude-code (Standard; exit \(r.code))")
    rep = t.json(["net", "show", "qs"], PermissionReport.self)
    check(rep?.preset == "agent" && rep?.base == "node", "Standard, base node")
    /// `curl` from the agent: `exit=0` when the TLS connection went through (any HTTP status).
    func reach(_ url: String) -> Bool {
        let r = t.run(["exec", "qs", "--", "sh", "-c", "curl -sS --max-time 20 -o /dev/null \(url) 2>/dev/null; echo exit=$?"], timeout: 60)
        return r.out.contains("exit=0")
    }
    for (url, why) in [("https://api.anthropic.com/", "Talk to its AI model"), ("https://downloads.claude.ai/", "Update itself (Claude Code's updates)"),
                       ("https://http-intake.logs.us5.datadoghq.com/", "Send error reports (Datadog intake)"), ("https://github.com/", "Use GitHub"),
                       ("https://pi.dev/", "Update itself (pi)")] {
        check(reach(url), "Standard reaches \(url) — \(why)")
    }
    check(!reach("https://pypi.org/simple/"), "Standard on the node base: PyPI refused")
    check(!reach("https://example.com/"), "Standard: the web refused")
    check(!reach("https://claude.ai/"), "Standard: sign-in hosts refused (Dozer's proxy supplies the credential)")
    rep = t.json(["net", "show", "qs"], PermissionReport.self)
    let py = rep?.suggestions.first { $0.grant == "install:python" }
    check(py != nil && py?.hosts.contains("pypi.org") == true, "the refusal is a suggestion: install:python (pypi.org, \(py?.count ?? 0) time(s))")
    check(rep?.suggestions.contains { $0.grant == "site:example.com" } == true, "an unknown host: site:example.com")
    r = t.run(["net", "qs"])
    check(r.out.contains("the agent tried to install Python packages (PyPI)") && r.out.contains("doz net allow qs install:python"), "doz net qs: says it plainly, with the command")
    r = t.run(["inspect", "qs", "--prompt"])
    check(r.out.contains("You may talk to your AI model, update yourself") && r.out.contains("use GitHub") && r.out.contains("You may not sign in to Claude")
          && r.out.contains("browse the web (any site)") && r.out.contains("doz net allow qs"), "the facts block lists the permissions in plain words (P7)")

    // 4. Live changes.
    r = t.run(["net", "allow", "qs", "install:python"])
    check(r.code == 0 && r.out.contains("[x] Install software — Python (PyPI)"), "net allow qs install:python: the checklist back")
    check(reach("https://pypi.org/simple/"), "PyPI reached at once — live, no restart")
    check(t.json(["net", "show", "qs"], PermissionReport.self)?.suggestions.contains { $0.grant == "install:python" } == false, "its suggestion is gone")
    check(t.run(["inspect", "qs", "--prompt"]).out.contains("install Python packages (PyPI)"), "the facts follow the change")
    r = t.run(["net", "deny", "qs", "github"])
    check(r.code == 0 && !reach("https://github.com/"), "net deny qs github: refused at once")
    r = t.run(["net", "allow", "qs", "web"])
    check(r.code != 0 && r.err.contains("could send your code anywhere"), "net allow web: warns and asks (no terminal, no --yes: not changed)")
    check(!reach("https://example.com/"), "…the web still refused")
    r = t.run(["net", "allow", "qs", "web", "--yes"])
    check(r.code == 0 && reach("https://example.com/"), "net allow qs web --yes: any site")
    check(t.run(["net", "deny", "qs", "web"]).code == 0 && !reach("https://example.com/"), "net deny qs web")
    r = t.run(["net", "allow", "qs", "site:example.com"])
    check(r.code == 0 && reach("https://example.com/") && !reach("https://example.org/"), "net allow qs site:example.com: that site only")
    r = t.run(["net", "allow", "qs", "standard"])
    rep = t.json(["net", "show", "qs"], PermissionReport.self)
    check(r.code == 0 && rep?.preset == "agent" && rep?.sites.isEmpty == true && reach("https://github.com/") && !reach("https://pypi.org/simple/"),
          "net allow qs standard: Standard again (GitHub back, PyPI off, the site gone)")
    r = t.run(["net", "policy", "qs"])
    check(r.out.contains("permissions: model, update") && r.out.contains("downloads.claude.ai"), "doz net policy: the raw rules, permissions first named")

    // 5. The setting.
    check(t.run(["config", "set", "defaults.permissions", "locked"]).code == 0, "config set defaults.permissions locked")
    check(t.run(["config", "set", "defaults.permissions", "+telepathy"]).code != 0, "config set defaults.permissions +telepathy: refused")
    r = t.run(["create", "ql", "--image", "claude-code", "--isolated", "--account", "none"])
    rep = t.json(["net", "show", "ql"], PermissionReport.self)
    check(r.code == 0 && rep?.preset == "locked" && rep?.permissions.filter(\.on).map(\.id) == ["model"], "a new sandbox under the setting: Locked (the model only)")
    check(t.run(["config", "set", "defaults.permissions", "standard"]).code == 0, "the setting back to standard")
    t.run(["rm", "ql", "--yes"], timeout: 120)
    t.run(["rm", "qs", "--yes"], timeout: 180)
}
