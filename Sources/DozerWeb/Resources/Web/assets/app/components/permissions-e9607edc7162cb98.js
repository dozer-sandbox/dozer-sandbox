// components/permissions — What the agent can do (597): the permission switches and their confirmations.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { agentKey } from '../core/agents-66154a04b9c4696c.js';
import { dialog } from './dialog-627b79752657f161.js';

// ── 597: what the agent can do ────────────────────────────────────────────
// Owner ruling (2026-09-30, P1–P7): a proxied sandbox's network as plain-language permissions, each a
// switch; hosts only under details. Presets Locked / Standard / Open; a changed switch is "Custom".
// Install software has a sub-switch per ecosystem (preset from the sandbox's base). Stored BY NAME:
// the hosts behind a permission come from the running doz.
export const PRESET_LABEL = { locked: 'Locked', agent: 'Standard', open: 'Open' };
/// The switches: `rows` (id, title, summary, locked, warning, group, hosts), `on` (a Set), `change(id, on)`.
/// 599i: an agent's own model permission — "Talk to OpenAI" is Codex's: shown (on, always) only in a Codex
/// sandbox's form, and never a switch another agent's form offers. The host adds it whatever a form sends.
const AGENT_MODEL = { codex: 'model:openai' };
export const isAgentModel = (id) => Object.values(AGENT_MODEL).includes(id);
export function permissionSwitches(rows, on, change, opts = {}) {
  const own = AGENT_MODEL[agentKey(opts.agent || '', AGENT_MODEL)];
  rows = rows.filter((r) => !isAgentModel(r.id) || r.id === own || on.has(r.id)).map((r) => (r.id === own ? { ...r, locked: true } : r));
  const sw = (r, indent) => {
    const box = h('input', { type: 'checkbox', role: 'switch', 'data-permission': r.id, 'aria-label': r.title });
    box.checked = on.has(r.id) || r.locked;
    box.disabled = !!r.locked || !!opts.disabled;
    box.addEventListener('change', () => { const v = box.checked; box.checked = !v; change(r.id, v); });
    return h('div', { class: 'perm' + (indent ? ' perm-sub' : '') + (box.checked ? ' perm-on' : ''), 'data-perm-row': r.id },
      h('label', { class: 'perm-main' }, box, h('span', { class: 'perm-title' }, r.title, r.locked ? h('span', { class: 'muted' }, ' — always') : null)),
      h('div', { class: 'perm-summary muted' }, r.summary, r.warning ? h('span', { class: 'perm-warn' }, ' ' + r.warning) : null),
      // 599e: no "hosts" expander for a permission without hosts of its own (Push to GitHub: a gate on "Use GitHub as you").
      opts.hosts === false || !(r.hosts && r.hosts.length) ? null : h('details', { class: 'perm-hosts' }, h('summary', null, 'hosts'), h('div', { class: 'mono muted' }, r.hosts.join(', '))));
  };
  // The user's GitHub login: "Use GitHub as you", with "Push to GitHub" under it, after "Use GitHub".
  const top = rows.filter((r) => r.group !== 'install' && r.group !== 'github'), inst = rows.filter((r) => r.group === 'install');
  const gh = rows.filter((r) => r.group === 'github');
  const anyInstall = inst.some((r) => on.has(r.id));
  const master = h('input', { type: 'checkbox', role: 'switch', 'data-permission': 'install', 'aria-label': 'Install software' });
  master.checked = anyInstall;
  master.disabled = !!opts.disabled;
  master.addEventListener('change', () => { const v = master.checked; master.checked = !v; change('install', v); });
  const installBlock = h('div', { class: 'perm perm-group' + (anyInstall ? ' perm-on' : ''), 'data-perm-row': 'install' },
    h('label', { class: 'perm-main' }, master, h('span', { class: 'perm-title' }, 'Install software')),
    h('div', { class: 'perm-summary muted' }, 'Install packages for your project — per ecosystem:'),
    inst.map((r) => sw(r, true)));
  const out = [];
  for (const r of top) {
    out.push(sw(r, false));
    if (r.id === 'update') out.push(installBlock);
    if (r.id === 'github') gh.forEach((g, i) => out.push(sw(g, i > 0)));
  }
  return h('div', { class: 'perm-list', 'data-permissions': '' }, out);
}
/// "Browse the web" (and Open) warn first.
export function confirmWeb(then) {
  dialog('Let the agent browse the web?', 'The agent could send your code anywhere — use with care. Every connection is still proxied and logged, and you can switch it off again.',
    [], 'Allow the web', async () => { await then(); }, { danger: true });
}
/// The user's GitHub login: said plainly before it is switched on.
export function confirmGitHub(id, then) {
  const push = id === 'github:push';
  dialog(push ? 'Let the agent push to GitHub as you?' : 'Sign the agent in to GitHub as you?',
    push ? 'The agent can push commits and change things on GitHub as you (pull requests, issues, comments) — within what your token may do. Every such request is in the network log; switch it off at any time.'
      : 'git and gh in this sandbox use your GitHub login (your Mac\'s gh login, or a token you gave it) — read-only: the agent can read everything your login can. The token never enters the sandbox; switching this off revokes it at once.',
    [], push ? 'Allow pushing' : 'Use my GitHub login', async () => { await then(); }, { danger: push, icon: 'check' });
}
