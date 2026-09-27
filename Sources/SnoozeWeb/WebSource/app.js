// snooze ui — phase 1: a read-only dashboard.
//
// Rules this file keeps (590.01-DESIGN.md):
//   · Every value from the server is rendered with textContent — never parsed as HTML. Much of it comes
//     from inside a sandbox (hostnames in the net log, session commands, image notes) and a sandbox
//     is untrusted.
//   · The link's capability is read from the fragment ONCE, removed from the address bar and history
//     before anything else, and sent only in the bootstrap's Authorization header.
//   · The CSRF token lives in this page's memory only (never storage, a cookie or a URL).
'use strict';

const state = {
  csrf: null,
  expiresAt: null,
  view: 'overview',
  param: null,
  overview: null,
  activity: [],
  es: null,
  renewTimer: null,
  deniedOnly: false,
  signedOut: false,
};

// ── tiny DOM helpers (text only) ────────────────────────────────────────────
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'on') for (const [ev, fn] of Object.entries(v)) el.addEventListener(ev, fn);
      else el.setAttribute(k, v === true ? '' : String(v));
    }
  }
  for (const kid of kids.flat()) {
    if (kid === undefined || kid === null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
const $ = (id) => document.getElementById(id);

// ── formatting ──────────────────────────────────────────────────────────────
function bytes(n) {
  if (n === undefined || n === null) return '—';
  if (n < 1024) return n + ' B';
  const u = ['KiB', 'MiB', 'GiB', 'TiB'];
  let v = n / 1024, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (v >= 10 ? v.toFixed(0) : v.toFixed(1)) + ' ' + u[i];
}
function mib(m) { return m ? bytes(m * 1048576) : '—'; }
function ms(v) {
  if (v === undefined || v === null) return '—';
  if (v < 1) return v.toFixed(2) + ' ms';
  if (v < 1000) return Math.round(v) + ' ms';
  return (v / 1000).toFixed(v < 10000 ? 2 : 1) + ' s';
}
function when(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  const s = (Date.now() - d.getTime()) / 1000;
  const abs = Math.abs(s);
  let rel;
  if (abs < 45) rel = 'just now';
  else if (abs < 3600) rel = Math.round(abs / 60) + ' min';
  else if (abs < 86400) rel = Math.round(abs / 3600) + ' h';
  else rel = Math.round(abs / 86400) + ' d';
  if (rel !== 'just now') rel = s >= 0 ? rel + ' ago' : 'in ' + rel;
  return rel;
}
function clock(iso) { return iso ? new Date(iso).toLocaleTimeString() : '—'; }
function full(iso) { return iso ? new Date(iso).toLocaleString() : '—'; }
function phasePill(phase, label, busy) {
  return h('span', { class: 'pill ph-' + phase }, (label || phase) + (busy ? ' …' : ''));
}
function statusPill(s) { return h('span', { class: 'pill st-' + s }, s); }

// ── HTTP ────────────────────────────────────────────────────────────────────
class HttpError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
async function api(path, opts = {}) {
  const init = { method: opts.method || 'GET', credentials: 'same-origin', cache: 'no-store', headers: {} };
  if (init.method !== 'GET') init.headers['X-Snooze-CSRF'] = state.csrf || '';
  if (opts.bearer) init.headers['Authorization'] = 'Bearer ' + opts.bearer;
  const r = await fetch('/api/v1/' + path, init);
  if (r.status === 204) return null;
  let body = null;
  try { body = await r.json(); } catch (_) { /* not JSON */ }
  if (!r.ok) {
    const e = body && body.error ? body.error : { code: 'http-' + r.status, message: 'HTTP ' + r.status };
    if (r.status === 401) signedOut(e.message);
    throw new HttpError(r.status, e.code, e.message);
  }
  return body;
}

// ── session ─────────────────────────────────────────────────────────────────
async function bootstrap() {
  const m = /^#cap=([A-Za-z0-9_-]{16,256})$/.exec(location.hash);
  if (m) {
    // The capability leaves the address bar and the history entry before anything else happens.
    history.replaceState(null, '', location.pathname + '#/overview');
    try {
      adopt(await api('session', { method: 'POST', bearer: m[1] }));
      return true;
    } catch (e) {
      signedOut(e.message);
      return false;
    }
  }
  try {
    adopt(await api('session'));
    return true;
  } catch (e) {
    if (!state.signedOut) signedOut(e.message);
    return false;
  }
}
function adopt(info) {
  state.csrf = info.csrf;
  state.expiresAt = new Date(info.expiresAt);
  $('store-path').textContent = info.store;
  document.title = 'snooze — ' + info.store.split('/').pop();
  $('sign-out').hidden = false;
  scheduleRenew();
}
function scheduleRenew() {
  clearTimeout(state.renewTimer);
  const half = Math.max(30000, (state.expiresAt.getTime() - Date.now()) / 2);
  state.renewTimer = setTimeout(async () => {
    try { adopt(await api('session/renew', { method: 'POST' })); } catch (_) { /* signedOut() handles 401 */ }
  }, half);
}
function signedOut(message) {
  if (state.signedOut) return;
  state.signedOut = true;
  state.csrf = null;
  clearTimeout(state.renewTimer);
  if (state.es) { state.es.close(); state.es = null; }
  setLive('bad', 'signed out');
  $('sign-out').hidden = true;
  const view = $('view');
  view.replaceChildren(h('div', { class: 'signed-out' },
    h('h1', null, 'Sign in with a new link'),
    h('p', { class: 'sub' }, message || 'This page is not signed in.'),
    h('p', null, 'In a terminal on this Mac, run ', h('code', null, 'snooze ui link'),
      ' — it opens a fresh one-use link. (If the UI is not running: ', h('code', null, 'snooze ui'), '.)'),
    h('p', { class: 'muted' }, 'Links work once and expire after a few minutes. Nothing on this page can sign you in by itself.')));
}
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('You signed out.');
});

// ── live updates ────────────────────────────────────────────────────────────
function setLive(kind, text) {
  const el = $('live');
  el.className = 'live' + (kind ? ' ' + kind : '');
  $('live-text').textContent = text;
}
function connect() {
  if (state.signedOut) return;
  const es = new EventSource('/api/v1/stream');
  state.es = es;
  es.addEventListener('hello', () => { setLive('on', 'live'); refresh(true); });
  es.addEventListener('changed', () => refresh(false));
  es.addEventListener('activity', (ev) => {
    try {
      const a = JSON.parse(ev.data);
      state.activity.push(a);
      if (state.activity.length > 500) state.activity.shift();
      if (state.view === 'activity') renderActivity();
    } catch (_) { /* ignore a malformed line */ }
  });
  es.addEventListener('resync', () => { es.close(); setTimeout(connect, 250); });
  es.addEventListener('end', async (ev) => {
    es.close();
    let reason = '';
    try { reason = JSON.parse(ev.data).reason; } catch (_) { /* */ }
    if (reason === 'session-ended') { signedOut('The session ended.'); return; }
    if (reason === 'shutdown') { setLive('bad', 'the UI stopped'); notice('The snooze ui process stopped. Start it again with snooze ui.', true); return; }
    setTimeout(connect, 500);
  });
  es.onerror = () => {
    if (state.signedOut) return;
    setLive('bad', 'reconnecting…');
    if (es.readyState === EventSource.CLOSED) {
      // The server refused the stream (401/503): find out whether we are still signed in.
      setTimeout(async () => { try { await api('session'); connect(); } catch (_) { /* signedOut() */ } }, 3000);
    }
  };
}
function notice(text, bad) {
  const n = $('notice');
  if (!text) { n.hidden = true; return; }
  n.hidden = false;
  n.className = 'notice' + (bad ? ' bad' : '');
  n.textContent = text;
}

// ── routing ─────────────────────────────────────────────────────────────────
function route() {
  const m = /^#\/([a-z]+)(?:\/([a-z0-9-]{1,40}))?$/.exec(location.hash);
  state.view = m ? m[1] : 'overview';
  state.param = m && m[2] ? m[2] : null;
  if (state.view === 'sandbox' && !state.param) state.view = 'overview';
  for (const a of document.querySelectorAll('#nav a')) {
    a.classList.toggle('active', a.dataset.view === state.view || (state.view === 'sandbox' && a.dataset.view === 'overview'));
  }
  refresh(true);
}
window.addEventListener('hashchange', () => { if (!state.signedOut) route(); });

let refreshing = false, again = false;
async function refresh(scrollTop) {
  if (state.signedOut) return;
  if (refreshing) { again = true; return; }
  refreshing = true;
  try {
    const views = { overview: viewOverview, sandbox: viewSandbox, images: viewImages, accounts: viewAccounts,
                    metrics: viewMetrics, activity: viewActivity, doctor: viewDoctor };
    const fn = views[state.view] || viewOverview;
    const node = await fn();
    if (node && !state.signedOut) {
      $('view').replaceChildren(node);
      if (scrollTop) $('main').scrollTop = 0;
    }
  } catch (e) {
    if (!state.signedOut) $('view').replaceChildren(h('div', { class: 'notice bad' }, e.message || String(e)));
  } finally {
    refreshing = false;
    if (again) { again = false; refresh(false); }
  }
}

// ── views ───────────────────────────────────────────────────────────────────
function card(k, v, n) { return h('div', { class: 'card' }, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v), n ? h('div', { class: 'n' }, n) : null); }
function table(head, rows, numeric = []) {
  if (!rows.length) return null;
  return h('table', null,
    h('thead', null, h('tr', null, head.map((c, i) => h('th', { class: numeric.includes(i) ? 'num' : null }, c)))),
    h('tbody', null, rows));
}
function panel(content, emptyText) { return h('div', { class: 'panel' }, content || h('div', { class: 'empty' }, emptyText || 'Nothing here.')); }
function meter(part, whole) {
  const pct = whole > 0 ? Math.max(0, Math.min(100, (part / whole) * 100)) : 0;
  const bar = h('span');
  bar.style.width = pct.toFixed(1) + '%';
  return h('div', { class: 'meter', title: pct.toFixed(0) + '%' }, bar);
}

function hostCard(host) {
  if (host.running) {
    return card('Host', 'running', 'pid ' + host.pid + ' · ' + (host.version || '') + ' · since ' + when(host.startedAt) +
      (host.idleSeconds ? ' · idle ' + Math.round(host.idleSeconds) + ' s' : ''));
  }
  return card('Host', 'not running', host.recoveryPending.length ? 'recovery pending: ' + host.recoveryPending.join(', ') : 'nothing is running — shown from the store');
}

async function viewOverview() {
  const o = await api('overview');
  state.overview = o;
  const rows = o.sandboxes.map((s) => h('tr', { class: 'click', on: { click: () => { location.hash = '#/sandbox/' + s.name; } } },
    h('td', null, h('a', { href: '#/sandbox/' + s.name }, s.name), h('div', { class: 'muted' }, s.image)),
    h('td', null, phasePill(s.phase, s.phaseLabel, s.busy), s.diedWithHost ? h('div', { class: 'st-warn' }, 'died with its host') : null),
    h('td', { class: 'num' }, s.ramHeldMiB ? mib(s.ramHeldMiB) : '—', h('div', { class: 'muted' }, 'of ' + mib(s.memoryMiB)), meter(s.ramHeldMiB, s.memoryMiB)),
    h('td', { class: 'num' }, bytes(s.diskBytes)),
    h('td', { class: 'num' }, s.sessions === null || s.sessions === undefined ? '—' : String(s.sessions)),
    h('td', null, s.network, s.deniedConnections ? h('div', { class: 'st-warn' }, s.deniedConnections + ' denied') : null),
    h('td', null, s.account || '—', s.credentialState ? h('div', { class: s.credentialState === 'ok' ? 'st-ok' : 'st-warn' }, s.credentialState) : null,
      s.foreignCredentials ? h('div', { class: 'st-warn' }, s.foreignCredentials + ' own credential(s)') : null)));
  return h('div', null,
    h('h1', null, 'Sandboxes'),
    h('p', { class: 'sub' }, o.source === 'host' ? 'Live from the host.' : 'No host is running: read from the store (nothing is live).'),
    h('div', { class: 'cards' },
      hostCard(o.host),
      card('Sandboxes', String(o.totals.sandboxes), o.totals.live + ' with a VM'),
      card('RAM held', mib(o.totals.ramHeldMiB), 'charged to this Mac now'),
      card('Disk', bytes(o.totals.diskBytes), 'allocated, all sandboxes'),
      card('Sessions', String(o.totals.sessions), 'in running sandboxes')),
    h('h2', null, 'All sandboxes'),
    panel(table(['Sandbox', 'Phase', 'RAM held', 'Disk', 'Sessions', 'Network', 'Account'], rows, [2, 3, 4]),
      'No sandboxes yet — snooze create NAME --image lab'));
}

async function viewSandbox() {
  const name = state.param;
  const [d, net] = await Promise.all([api('sandboxes/' + name), api('sandboxes/' + name + '/network')]);
  const i = d.info;
  const fact = (k, v) => h('div', null, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v));
  const copy = h('button', { type: 'button', class: 'btn' }, 'Copy');
  copy.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(d.attachCommand); copy.textContent = 'Copied'; } catch (_) { copy.textContent = 'Select and copy'; }
    setTimeout(() => { copy.textContent = 'Copy'; }, 1500);
  });
  const sessions = (d.sessions || []).map((s) => h('tr', null,
    h('td', null, s.name, s.name === d.defaultSession ? h('span', { class: 'tag' }, 'default') : null),
    h('td', null, s.ended ? h('span', { class: 'muted' }, 'ended (exit ' + s.exitCode + ')') : 'running'),
    h('td', { class: 'mono' }, s.command),
    h('td', { class: 'num' }, s.cols ? s.cols + '×' + s.rows : '—'),
    h('td', { class: 'num' }, String(s.clients)),
    h('td', null, s.screen || '—')));
  const points = d.restorePoints.map((p) => h('tr', null,
    h('td', null, p.name, h('div', { class: 'muted mono' }, p.id)),
    h('td', null, full(p.createdAt), h('div', { class: 'muted' }, when(p.createdAt))),
    h('td', null, p.takenWhile + (p.automatic ? ' (auto)' : ''), p.needsFsck ? h('div', { class: 'st-warn' }, 'e2fsck on next boot') : null),
    h('td', null, p.note || '—')));
  const creds = d.credentials.map((c) => h('tr', null,
    h('td', null, c.binding, h('div', { class: 'muted' }, c.hosts.join(', '))),
    h('td', null, c.set ? 'set' : 'not set'),
    h('td', null, c.source || '—', c.account ? h('div', { class: 'muted' }, 'account ' + c.account) : null),
    h('td', null, c.state || '—', c.expiresAt ? h('div', { class: 'muted' }, 'expires ' + when(c.expiresAt)) : null),
    h('td', null, c.policy || '—')));
  const foreign = d.credentials.flatMap((c) => c.foreign).map((f) => h('tr', null,
    h('td', null, f.kind + (f.matches ? ' (= ' + f.matches + ')' : '')),
    h('td', { class: 'mono' }, f.prefix + '…'),
    h('td', { class: 'mono' }, f.fingerprint),
    h('td', null, f.header),
    h('td', { class: 'num' }, String(f.requests)),
    h('td', null, when(f.lastSeen))));
  return h('div', null,
    h('p', { class: 'sub' }, h('a', { href: '#/overview' }, '← Sandboxes')),
    h('h1', null, name, ' ', phasePill(i.phase, i.phaseLabel, i.busy)),
    h('p', { class: 'sub' }, i.image + ' · created ' + when(i.createdAt)),
    h('div', { class: 'cards' },
      card('RAM held', mib(i.ramHeldMiB), 'of ' + mib(i.memoryMiB) + (i.memoryReturnedMiB ? ' · balloon returned ' + mib(i.memoryReturnedMiB) : '')),
      card('Disk', bytes(i.diskBytes), d.snapshotBytes ? 'snapshot ' + bytes(d.snapshotBytes) : (d.hasRootDisk ? 'root disk kept' : 'no root disk yet')),
      card('CPUs', String(d.cpus)),
      card('Sessions', i.sessions === null || i.sessions === undefined ? '—' : String(i.sessions), i.phase === 'running' ? '' : 'listed while it runs')),
    h('h2', null, 'Terminal'),
    h('div', { class: 'panel' }, h('div', { class: 'cmd' }, h('code', null, d.attachCommand), copy),
      h('div', { class: 'empty' }, 'Run it in a terminal to attach to the ' + d.defaultSession + ' session (Ctrl-] detaches). Opening Terminal.app from here comes with the actions phase.')),
    h('h2', null, 'Sessions'),
    panel(table(['Session', 'State', 'Command', 'Size', 'Viewers', 'Screen'], sessions, [3, 4]),
      i.phase === 'running' ? 'No sessions.' : 'Sessions are listed while the sandbox runs.'),
    h('h2', null, 'Restore points'),
    panel(table(['Point', 'Taken', 'While', 'Note'], points), 'No restore points.'),
    h('h2', null, 'Network'),
    networkPanel(net),
    h('h2', null, 'Keys'),
    panel(table(['Key', 'Set', 'Source', 'State', 'Policy'], creds), 'No keys — the sandbox uses none.'),
    foreign.length ? h('h2', null, 'Credentials the guest brought itself (fingerprints only)') : null,
    foreign.length ? panel(table(['Kind', 'Prefix', 'Fingerprint', 'Header', 'Requests', 'Last seen'], foreign, [4])) : null,
    h('h2', null, 'Configuration'),
    h('div', { class: 'panel' }, h('div', { class: 'facts' },
      fact('Memory', mib(d.memoryMiB)), fact('Root disk', mib(d.rootfsMiB)), fact('State disk', mib(d.stateDiskMiB)),
      fact('Journal', d.journalMiB ? mib(d.journalMiB) : 'none'), fact('Network', d.networkMode + (d.subnet ? ' · ' + d.subnet : '')),
      fact('Account', i.account || '—'), fact('Shares', d.shares.length ? d.shares.map((s) => s.hostPath + ' → ' + s.guestPath).join(', ') : 'none'),
      fact('Directory', d.directory))));
}

function networkPanel(net) {
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
  return h('div', null,
    h('div', { class: 'panel' }, h('div', { class: 'empty' },
      (net.policy.preset ? net.policy.preset + ' preset' : 'custom policy') + ' · anything else: ' + net.policy.defaultAction)),
    h('div', { class: 'panel' }, table(['#', 'Rule', 'Host', 'Note'], rules, [0]) || h('div', { class: 'empty' }, 'No rules.')),
    h('h2', null, 'Connection log'),
    h('div', { class: 'toolbar' }, h('label', null, toggle, ' denied only'),
      net.logAvailable ? net.logTotal + ' connections since the host started · ' + net.denied + ' denied' + (net.logTotal > net.log.length ? ' · newest ' + net.log.length + ' shown' : '') : (net.note || '')),
    panel(table(['Time', 'Verdict', 'Kind', 'Target', 'Rule', 'Bytes', 'Credential'], log, [5]), net.logAvailable ? 'No connections.' : net.note));
}

async function viewImages() {
  const rows = (await api('images')).map((r) => h('tr', null,
    h('td', null, r.name), h('td', null, r.kind),
    h('td', null, r.baked ? (r.bakedAt ? full(r.bakedAt) : 'yes') : h('span', { class: 'muted' }, 'no — bakes on first start')),
    h('td', { class: 'num' }, r.allocatedBytes ? bytes(r.allocatedBytes) : '—'),
    h('td', null, [r.note, r.fromSandbox ? 'from ' + r.fromSandbox : null].filter(Boolean).join(' · ') || '—'),
    h('td', { class: 'mono muted' }, r.key ? r.key.slice(0, 16) : '')));
  return h('div', null, h('h1', null, 'Images'),
    h('p', { class: 'sub' }, 'Built-in images and custom images saved from restore points.'),
    panel(table(['Image', 'Kind', 'Baked', 'Size', 'Note', 'Key'], rows, [3])));
}

async function viewAccounts() {
  const a = await api('accounts');
  const rows = a.accounts.map((x) => h('tr', null,
    h('td', null, x.name, x.isDefault ? h('span', { class: 'tag' }, 'default') : null),
    h('td', null, x.kind, x.plan ? h('div', { class: 'muted' }, x.plan) : null),
    h('td', null, x.identity || '—'),
    h('td', null, h('span', { class: x.state === 'ok' ? 'st-ok' : 'st-warn' }, x.state), x.verification ? h('div', { class: 'muted' }, x.verification) : null),
    h('td', null, x.expiresAt ? full(x.expiresAt) : '—', x.expiresAt ? h('div', { class: 'muted' }, when(x.expiresAt)) : null),
    h('td', { class: 'mono' }, x.fingerprint || '—', x.keychainService ? h('div', { class: 'muted' }, 'keychain: ' + x.keychainService) : null),
    h('td', null, x.usedBy.length ? x.usedBy.join(', ') : '—')));
  return h('div', null, h('h1', null, 'Accounts & keys'),
    h('p', { class: 'sub' }, 'Anthropic credentials the host holds for sandboxes. Never a secret: states, keychain item names and fingerprints only.'),
    h('div', { class: 'cards' }, card('Default account', a.defaultAccount), card('Keep-alive', a.keepalive ? 'on' : 'off', 'runs the Mac’s own claude -p near expiry')),
    h('h2', null, 'Accounts'),
    panel(table(['Account', 'Kind', 'Identity', 'State', 'Expires', 'Fingerprint', 'Used by'], rows)),
    h('p', { class: 'muted' }, 'Per-sandbox keys and the credentials a guest brought itself are on each sandbox’s page.'));
}

async function viewMetrics() {
  const m = await api('metrics');
  if (!m.available) return h('div', null, h('h1', null, 'Metrics'), panel(null, 'No metrics yet — the host records every action it times.'));
  const max = Math.max(1, ...m.summary.map((r) => r.p90Ms || r.medianMs || 0));
  const rows = m.summary.map((r) => {
    const bar = h('span');
    bar.style.width = (((r.medianMs || 0) / max) * 100).toFixed(1) + '%';
    return h('tr', null, h('td', null, r.action), h('td', { class: 'num' }, String(r.count)),
      h('td', { class: 'num' }, ms(r.medianMs)), h('td', { class: 'num' }, ms(r.p90Ms)),
      h('td', { class: 'num' }, ms(r.minMs)), h('td', { class: 'num' }, ms(r.maxMs)),
      h('td', { class: 'num' }, r.failed ? h('span', { class: 'st-fail' }, String(r.failed)) : ''),
      h('td', { class: 'bar' }, h('div', { class: 'hbar', title: 'median, relative to the slowest p90' }, bar)));
  });
  return h('div', null, h('h1', null, 'Metrics'),
    h('p', { class: 'sub' }, 'Lifecycle timings the host recorded (all time, all images; steps inside actions left out).'),
    h('div', { class: 'cards' }, card('Host runs', String(m.runs)), card('Rows', String(m.rows)), card('Sessions', String(m.sessions)), card('Network minutes', String(m.networkMinutes))),
    h('h2', null, 'Per action'),
    panel(h('div', { class: 'bars' }, table(['Action', 'Count', 'Median', 'P90', 'Min', 'Max', 'Failed', ''], rows, [1, 2, 3, 4, 5, 6]))));
}

async function viewActivity() {
  const recent = await api('events');
  const seen = new Set(state.activity.map((a) => a.seq));
  for (const a of recent) if (!seen.has(a.seq)) state.activity.push(a);
  state.activity.sort((x, y) => x.seq - y.seq);
  return activityNode();
}
function activityNode() {
  const items = state.activity.slice().reverse().map((a) => h('li', null,
    h('span', { class: 't' }, clock(a.time)), h('span', { class: 'who muted' }, a.sandbox || a.kind),
    h('span', { class: 'text' }, a.text)));
  return h('div', null, h('h1', null, 'Activity'),
    h('p', { class: 'sub' }, 'What the host does — phases, timed steps, notes — while a sandbox is live and this page is open.'),
    panel(items.length ? h('ul', { class: 'feed' }, items) : null, 'Nothing yet. Start or wake a sandbox and it shows here.'));
}
function renderActivity() { $('view').replaceChildren(activityNode()); }

async function viewDoctor() {
  const checks = await api('doctor');
  const rows = checks.map((c) => h('tr', null, h('td', null, statusPill(c.status)), h('td', null, c.check), h('td', null, c.detail)));
  return h('div', null, h('h1', null, 'Doctor'),
    h('p', { class: 'sub' }, 'snooze doctor: this Mac, the store, the host and the Claude login (re-checked at most every 30 s).'),
    panel(table(['', 'Check', 'Detail'], rows)));
}

// ── start ───────────────────────────────────────────────────────────────────
(async () => {
  if (await bootstrap()) {
    if (!/^#\/[a-z]/.test(location.hash)) history.replaceState(null, '', location.pathname + '#/overview');
    route();
    connect();
  }
})();
