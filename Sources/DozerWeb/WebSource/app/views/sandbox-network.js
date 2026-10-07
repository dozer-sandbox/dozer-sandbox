// views/sandbox-network — A sandbox's Network tab: its permissions (597) and its policy.
import { upcall } from '../core/hooks.js';
import { h } from '../dom/h.js';
import { icon, withIcon } from '../dom/icons.js';
import { bytes, clock } from '../core/format.js';
import { actOrThrow } from '../core/operations.js';
import { refresh } from '../core/router.js';
import { state } from '../core/state.js';
import { panel, table } from '../components/blocks.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { confirmGitHub, confirmWeb, permissionSwitches, PRESET_LABEL } from '../components/permissions.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const refreshSandbox = upcall('refreshSandbox');

state.permErr = new Map();
function permissionsPanel(name, net) {
  const p = net.permissions;
  if (!p) return null;
  const on = new Set(p.rows.filter((r) => r.on).map((r) => r.id));
  const send = async (body) => {
    try { state.permErr.delete(name); await actOrThrow({ action: 'net-policy', sandbox: name, ...body }); }
    catch (e) { state.permErr.set(name, e.message || String(e)); refreshSandbox(); }
  };
  const change = (id, v) => {
    if (id === 'web' && v) return confirmWeb(() => send({ grant: ['web'] }));
    if ((id === 'github:as-you' || id === 'github:push') && v) return confirmGitHub(id, () => send({ grant: [id] }));
    send(v ? { grant: [id] } : { revoke: [id] });
  };
  const presetBtn = (id) => {
    const b = h('button', { type: 'button', class: 'seg' + (p.preset === id ? ' active' : ''), 'data-perm-preset': id, 'aria-pressed': p.preset === id ? 'true' : 'false' },
      withIcon(id === 'locked' ? 'shield' : id === 'open' ? 'eye' : 'check', PRESET_LABEL[id]));
    b.addEventListener('click', () => { if (id === 'open') confirmWeb(() => send({ preset: 'open' })); else send({ preset: id }); });
    return b;
  };
  const suggestions = p.suggestions.map((s) => callout('warn', { compact: true, cls: 'perm-suggest', icon: 'shield', attrs: { 'data-suggest': s.grant },
    body: ['The agent tried to ', h('strong', null, s.permission ? s.what : 'reach ' + s.what),
      h('div', { class: 'muted' }, s.hosts.join(', ') + ' · ' + s.count + ' time' + (s.count === 1 ? '' : 's'))],
    actions: [btn(s.permission ? 'Allow' : 'Allow this site', () => (s.permission === 'web' ? confirmWeb(() => send({ grant: [s.grant] })) : send({ grant: [s.grant] })),
      { small: true, icon: 'check' })] }));
  const sites = p.sites.map((host) => h('span', { class: 'tag perm-site', 'data-site': host }, host, ' ',
    h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Deny ' + host, 'aria-label': 'Deny ' + host, on: { click: () => send({ revoke: ['site:' + host] }) } }, icon('x'))));
  const siteInput = h('input', { type: 'text', placeholder: 'api.example.com', 'aria-label': 'A site to allow', 'data-site-input': '', spellcheck: 'false' });
  return h('div', { class: 'panel perm-panel', 'data-perm-panel': name },
    h('div', { class: 'perm-head' }, h('strong', null, 'What the agent can do'),
      h('div', { class: 'segmented', role: 'group', 'aria-label': 'Preset' }, presetBtn('locked'), presetBtn('agent'), presetBtn('open')),
      p.preset ? null : h('span', { class: 'tag', 'data-perm-custom': '' }, 'Custom'),
      p.inferred ? h('span', { class: 'muted' }, ' an older policy, shown as permissions (stored as names at its first change)') : null),
    state.permErr.has(name) ? callout('bad', { compact: true, body: state.permErr.get(name), attrs: { 'data-perm-error': '' },
      dismiss: () => { state.permErr.delete(name); refreshSandbox(); } }) : null,
    suggestions.length ? h('div', { class: 'perm-suggestions' }, suggestions) : null,
    permissionSwitches(p.rows, on, change),
    h('div', { class: 'perm-sites' }, h('span', null, 'Other sites: '), sites.length ? sites : h('span', { class: 'muted' }, 'none'), ' ', siteInput,
      btn('Allow site', () => { const v = siteInput.value.trim().toLowerCase(); if (v) send({ grant: ['site:' + v] }); }, { small: true, icon: 'plus' })));
}

export function networkPanel(net) {
  if (!net.proxied) return panel(null, net.note || 'Not proxied.');
  const rules = net.policy.rules.map((r, n) => h('tr', null, h('td', { class: 'num' }, String(n + 1)),
    h('td', null, h('span', { class: r.action === 'allow' ? 'st-ok' : 'st-fail' }, r.action)), h('td', { class: 'mono' }, r.label), h('td', null, r.note || '')));
  const log = net.log.filter((c) => !state.deniedOnly || c.verdict === 'denied').slice().reverse().map((c) => h('tr', null,
    h('td', null, clock(c.time)),
    h('td', null, h('span', { class: c.verdict === 'allowed' ? 'st-ok' : 'st-fail' }, c.verdict)),
    h('td', null, c.kind),
    h('td', { class: 'mono' }, c.host + (c.port ? ':' + c.port : ''), c.method ? h('div', { class: 'muted' }, c.method + ' ' + (c.path || '')) : null),
    h('td', null, c.rule),
    h('td', { class: 'num' }, '↑' + bytes(c.bytesUp) + ' ↓' + bytes(c.bytesDown)),
    h('td', null, c.credential || '')));
  const toggle = h('input', { type: 'checkbox', id: 'denied-only' });
  toggle.checked = state.deniedOnly;
  toggle.addEventListener('change', () => { state.deniedOnly = toggle.checked; refresh(false); });
  const policyParts = [
    h('div', { class: 'panel' }, h('div', { class: 'empty' },
      (net.policy.preset ? (PRESET_LABEL[net.policy.preset] || net.policy.preset) + ' preset' : 'custom policy') + ' · anything else: ' + net.policy.defaultAction)),
    h('div', { class: 'panel' }, table(['#', 'Rule', 'Host', 'Note'], rules, [0]) || h('div', { class: 'empty' }, 'No rules.'))];
  return h('div', null,
    // 597: the permissions first; the rules (every host they amount to) under details.
    net.permissions ? permissionsPanel(net.name, net) : null,
    net.permissions ? h('details', { class: 'net-rules', 'data-net-rules': '' }, h('summary', null, 'Details: the rules and hosts'), policyParts) : policyParts,
    h('h2', null, 'Connection log'),
    h('div', { class: 'toolbar' }, h('label', null, toggle, ' denied only'),
      net.logAvailable ? net.logTotal + ' connections since the host started · ' + net.denied + ' denied' + (net.logTotal > net.log.length ? ' · newest ' + net.log.length + ' shown' : '') : (net.note || '')),
    panel(table(['Time', 'Verdict', 'Kind', 'Target', 'Rule', 'Bytes', 'Credential'], log, [5]), net.logAvailable ? 'No connections.' : net.note));
}
