// snooze ui — phase 2: the dashboard, and actions.
//
// Rules this file keeps (590.01-DESIGN.md):
//   · Every value from the server is rendered with textContent — never parsed as HTML. Much of it comes
//     from inside a sandbox (hostnames in the net log, session commands, image notes) and a sandbox
//     is untrusted.
//   · The link's capability is read from the fragment ONCE, removed from the address bar and history
//     before anything else, and sent only in the bootstrap's Authorization header.
//   · The CSRF token lives in this page's memory only (never storage, a cookie or a URL).
//   · Every action is one typed request (POST /api/v1/actions, {action, …}); a destructive one carries
//     `confirm`, filled only from a name the person typed. No secret is ever typed here (owner ruling
//     D3): adding a key or an account is a CLI command the page shows.
//   · Forms live in <dialog>s outside the view, so a live refresh never wipes what is being typed.
'use strict';

const state = {
  csrf: null,
  expiresAt: null,
  view: 'overview',
  param: null,
  overview: null,
  activity: [],
  ops: new Map(),
  es: null,
  renewTimer: null,
  deniedOnly: false,
  signedOut: false,
  metricsFilter: { image: '', days: '', steps: false },
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
  if (opts.json !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.json);
  }
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

// ── actions ─────────────────────────────────────────────────────────────────
// One typed action → one host operation. Answers at once; progress arrives as SSE `op` events.
async function act(body) {
  // No repeat of what is already under way (the server refuses it too — 409).
  const label = body.action + (body.sandbox ? ' ' + body.sandbox : '');
  if ([...state.ops.values()].some((o) => o.state === 'running' && o.label === label && o.action === body.action)) {
    toast(label + ' is already under way', false);
    return null;
  }
  try {
    const op = await api('actions', { method: 'POST', json: body });
    trackOp(op);
    return op;
  } catch (e) {
    toast(e.message || String(e), true);
    return null;
  }
}
function trackOp(op) {
  const before = state.ops.get(op.id);
  state.ops.set(op.id, op);
  if (state.ops.size > 60) state.ops.delete(state.ops.keys().next().value);
  renderOps();
  paintRowOps();
  // A new operation: re-render, so its sandbox's buttons are disabled while it runs.
  if (!before && op.state === 'running') refresh(false);
  if (op.state !== 'running' && (!before || before.state === 'running')) {
    if (op.state === 'failed') toast(op.label + ': ' + op.text, true);
    // The sandbox this page shows is gone: back to the list (route() refreshes) instead of a 404.
    if (op.state === 'done' && op.action === 'rm' && state.view === 'sandbox' && state.param === op.sandbox) { location.hash = '#/overview'; return; }
    refresh(false);
  }
}
function toast(text, bad) {
  const t = h('div', { class: 'toast' + (bad ? ' bad' : ''), role: 'status' }, text);
  $('toasts').append(t);
  setTimeout(() => t.remove(), bad ? 9000 : 4000);
}
function renderOps() {
  // Running ones, and what finished in the last 10 minutes (the newest six).
  const list = [...state.ops.values()].filter((o) => o.state === 'running' || Date.now() - new Date(o.startedAt).getTime() < 600000).slice(-6).reverse();
  const box = $('ops');
  if (!list.length) { box.hidden = true; return; }
  box.hidden = false;
  box.replaceChildren(h('div', { class: 'ops-title' }, 'Operations'),
    ...list.map((o) => h('div', { class: 'op op-' + o.state },
      h('span', { class: 'op-state' }, o.state === 'running' ? '…' : o.state === 'done' ? '✓' : '✕'),
      h('span', { class: 'op-label' }, o.label),
      h('span', { class: 'op-text' }, o.text + (o.milliseconds ? ' · ' + ms(o.milliseconds) : '')))));
}
/// The newest operation of each sandbox, shown under its name in the list (live, without a refetch).
/// A running operation counts its seconds, so a two-minute first start (pull, flatten, bake) is
/// visibly alive; the text is the host's latest step.
function paintRowOps() {
  for (const el of document.querySelectorAll('[data-op-for]')) {
    const name = el.dataset.opFor;
    const ops = [...state.ops.values()].filter((o) => o.sandbox === name);
    const o = ops[ops.length - 1];
    const fresh = o && (o.state === 'running' || Date.now() - new Date(o.startedAt).getTime() < 60000);
    const secs = o ? Math.max(0, Math.round((Date.now() - new Date(o.startedAt).getTime()) / 1000)) : 0;
    const text = !fresh ? '' : o.state === 'running' ? '… ' + o.action + ' · ' + secs + ' s — ' + o.text : (o.state === 'done' ? '✓ ' : '✕ ') + o.text;
    el.textContent = text;
    el.className = (el.dataset.banner ? 'op-banner' : 'row-op') + (fresh ? ' op-' + o.state : '') + (fresh ? '' : ' empty-op');
  }
}
function opRunningFor(name) { return [...state.ops.values()].some((o) => o.sandbox === name && o.state === 'running'); }

// ── dialogs (forms live outside the view) ───────────────────────────────────
// fields: [{name, label, type: text|number|select|textarea|checkbox, options, value, placeholder, help, required}]
function dialog(title, intro, fields, submitLabel, onSubmit, opts = {}) {
  const d = h('dialog', { class: 'dlg' });
  const form = h('form', { method: 'dialog' });
  const inputs = {};
  const rows = fields.map((f) => {
    let input;
    if (f.type === 'select') {
      input = h('select', { name: f.name }, f.options.map((o) => {
        const [v, l] = Array.isArray(o) ? o : [o, o];
        const opt = h('option', { value: v }, l);
        if (String(v) === String(f.value ?? '')) opt.selected = true;
        return opt;
      }));
    } else if (f.type === 'textarea') {
      input = h('textarea', { name: f.name, rows: 3, placeholder: f.placeholder || null, spellcheck: 'false' });
      input.value = f.value || '';
    } else if (f.type === 'checkbox') {
      input = h('input', { type: 'checkbox', name: f.name });
      input.checked = !!f.value;
    } else {
      input = h('input', { type: f.type || 'text', name: f.name, placeholder: f.placeholder || null, autocomplete: 'off', spellcheck: 'false',
                           min: f.min ?? null, max: f.max ?? null, required: f.required || null });
      input.value = f.value ?? '';
    }
    inputs[f.name] = input;
    return h('label', { class: 'field' + (f.type === 'checkbox' ? ' check' : '') },
      h('span', null, f.label), input, f.help ? h('small', null, f.help) : null);
  });
  const extra = h('div', { class: 'dlg-extra' });
  const submit = h('button', { type: 'submit', class: 'btn primary' + (opts.danger ? ' danger' : '') }, submitLabel);
  const cancel = h('button', { type: 'button', class: 'btn', on: { click: () => d.close() } }, 'Cancel');
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  form.append(h('h2', null, title), intro ? h('p', { class: 'sub' }, intro) : null, ...rows, extra, error,
    h('div', { class: 'dlg-buttons' }, cancel, submit));
  if (opts.confirmName) {
    submit.disabled = true;
    const typed = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'type the name to confirm' });
    typed.addEventListener('input', () => { submit.disabled = typed.value !== opts.confirmName; });
    inputs.__confirm = typed;
    form.insertBefore(h('label', { class: 'field' }, h('span', null, 'Type ', h('code', null, opts.confirmName), ' to confirm'), typed), extra);
  }
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    error.textContent = '';
    const values = {};
    for (const [k, input] of Object.entries(inputs)) values[k] = input.type === 'checkbox' ? input.checked : input.value.trim();
    submit.disabled = true;
    try {
      const keep = await onSubmit(values, { extra, error, submit });
      if (keep !== 'keep-open') d.close();
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      if (!opts.confirmName || (inputs.__confirm && inputs.__confirm.value === opts.confirmName)) submit.disabled = false;
    }
  });
  d.addEventListener('close', () => d.remove());
  d.append(form);
  document.body.append(d);
  d.showModal();
  const first = form.querySelector('input,select,textarea');
  if (first) first.focus();
  return d;
}
/// A destructive action: the person types the name; the request carries it as `confirm`.
function confirmAction(title, text, name, body) {
  dialog(title, text, [], title, async () => {
    const op = await actOrThrow({ ...body, confirm: name });
    return op;
  }, { danger: true, confirmName: name });
}
async function actOrThrow(body) {
  const op = await api('actions', { method: 'POST', json: body });
  trackOp(op);
  return op;
}
function lines(s) { return s.split(/[\n,]+/).map((x) => x.trim()).filter(Boolean); }
/// A command line → argv (spaces split; '…' and "…" group; \ escapes in "…"). No shell runs it.
function splitArgs(s) {
  const out = [];
  let cur = '', q = null, any = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === q) q = null;
      else if (c === '\\' && q === '"' && i + 1 < s.length) cur += s[++i];
      else cur += c;
    } else if (c === '\'' || c === '"') { q = c; any = true; }
    else if (/\s/.test(c)) { if (cur || any) out.push(cur); cur = ''; any = false; }
    else if (c === '\\' && i + 1 < s.length) cur += s[++i];
    else cur += c;
  }
  if (q) throw new Error('an unclosed quote');
  if (cur || any) out.push(cur);
  return out;
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
  const sp = $('store-path');
  sp.textContent = info.store;
  sp.title = info.store;
  $('version').textContent = 'snooze ' + info.version;
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
  for (const d of document.querySelectorAll('dialog')) d.close();
  setLive('bad', 'signed out');
  $('sign-out').hidden = true;
  $('ops').hidden = true;
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
  es.addEventListener('hello', async () => {
    setLive('on', 'live');
    try { for (const o of await api('operations')) state.ops.set(o.id, o); renderOps(); } catch (_) { /* */ }
    refresh(true);
  });
  es.addEventListener('changed', () => refresh(false));
  es.addEventListener('op', (ev) => { try { trackOp(JSON.parse(ev.data)); } catch (_) { /* */ } });
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
      paintRowOps();
      if (scrollTop) $('main').scrollTop = 0;
    }
  } catch (e) {
    if (!state.signedOut) {
      if (e.status === 404 && state.view === 'sandbox') { location.hash = '#/overview'; return; }
      $('view').replaceChildren(h('div', { class: 'notice bad' }, e.message || String(e)));
    }
  } finally {
    refreshing = false;
    if (again) { again = false; refresh(false); }
  }
}

// ── building blocks ─────────────────────────────────────────────────────────
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
  return h('div', { class: 'meter', title: pct.toFixed(0) + '% of the allocation' }, bar);
}
function btn(label, onClick, opts = {}) {
  return h('button', { type: 'button', class: 'btn' + (opts.danger ? ' danger' : '') + (opts.primary ? ' primary' : '') + (opts.small ? ' small' : ''),
                       title: opts.title || null, on: { click: (ev) => { ev.stopPropagation(); onClick(ev); } } }, label);
}

// The owner's vocabulary (2026-09-25); aliases in the tooltips.
const VERBS = {
  start: ['Start', 'Boot it (cold boot) — or wake / resume it'],
  pause: ['Pause', 'Suspend: guest CPU to 0 in ~1 ms, RAM kept'],
  resume: ['Resume', 'Run again after a pause'],
  sleep: ['Sleep', 'Pause + snapshot to disk: RAM kept, survives a host crash'],
  'deep-sleep': ['Deep sleep', 'Hibernate: snapshot and stop the VM — RAM returned; wake in ~0.3 s'],
  wake: ['Wake', 'Back from sleep or deep sleep, sessions where they were'],
  shutdown: ['Shut down', 'Cold stop, keeping the disk (running programs end)'],
  reset: ['Reset', 'Discard the disk — back to the image'],
  rm: ['Remove', 'Remove the sandbox and everything it has on disk'],
};
const DESTRUCTIVE = {
  shutdown: 'Running programs end; the disk is kept.',
  reset: 'The root disk is discarded — everything installed or written since the image is gone. Restore points are kept.',
  rm: 'The sandbox, its disks, snapshot and restore points are deleted.',
};
function verbsFor(phase) {
  switch (phase) {
    case 'off': return ['start'];
    case 'running': return ['pause', 'sleep', 'deep-sleep', 'shutdown'];
    case 'paused': return ['resume', 'sleep', 'deep-sleep', 'shutdown'];
    case 'asleep': return ['wake', 'deep-sleep', 'shutdown'];
    case 'deepAsleep': return ['wake', 'shutdown'];
    case 'failed': return ['start'];
    default: return [];
  }
}
function lifecycle(verb, name) {
  if (DESTRUCTIVE[verb]) confirmAction(VERBS[verb][0] + ' ' + name, DESTRUCTIVE[verb], name, { action: verb, sandbox: name });
  else act({ action: verb, sandbox: name });
}
function lifecycleButtons(s, all) {
  const busy = s.busy || s.phase === 'booting' || opRunningFor(s.name);
  const verbs = verbsFor(s.phase);
  const extra = all ? ['reset', 'rm'] : [];
  return h('div', { class: 'actions' }, [...verbs, ...extra].map((v) => {
    const b = btn(VERBS[v][0], () => lifecycle(v, s.name), { small: true, title: VERBS[v][1], danger: !!DESTRUCTIVE[v] });
    if (busy) b.disabled = true;
    return b;
  }));
}

function hostCard(host) {
  if (host.running) {
    return card('Host', 'running', 'pid ' + host.pid + ' · ' + (host.version || '') + ' · since ' + when(host.startedAt) +
      (host.idleSeconds ? ' · idle ' + Math.round(host.idleSeconds) + ' s' : ''));
  }
  return card('Host', 'not running', host.recoveryPending.length ? 'recovery pending: ' + host.recoveryPending.join(', ') : 'nothing is running — shown from the store');
}

// ── views ───────────────────────────────────────────────────────────────────
async function viewOverview() {
  const o = await api('overview');
  state.overview = o;
  const rows = o.sandboxes.map((s) => h('tr', { class: 'click', on: { click: () => { location.hash = '#/sandbox/' + s.name; } } },
    h('td', null, h('a', { href: '#/sandbox/' + s.name }, s.name), h('div', { class: 'muted' }, s.image), h('div', { 'data-op-for': s.name })),
    h('td', null, phasePill(s.phase, s.phaseLabel, s.busy), s.diedWithHost ? h('div', { class: 'st-warn' }, 'died with its host') : null),
    h('td', { class: 'num' }, h('div', null, s.ramHeldMiB ? mib(s.ramHeldMiB) : '—'), h('div', { class: 'muted' }, 'of ' + mib(s.memoryMiB)), meter(s.ramHeldMiB, s.memoryMiB)),
    h('td', { class: 'num' }, bytes(s.diskBytes)),
    h('td', null, s.network, s.deniedConnections ? h('div', { class: 'st-warn' }, s.deniedConnections + ' denied') : null),
    s.accountApplies
      ? h('td', null, s.account || '—', s.credentialState ? h('div', { class: s.credentialState === 'ok' ? 'st-ok' : 'st-warn' }, s.credentialState) : null,
        s.foreignCredentials ? h('div', { class: 'st-warn' }, s.foreignCredentials + ' own credential(s)') : null)
      : h('td', { class: 'muted', title: 'its network cannot reach an account’s API' }, 'n/a'),
    h('td', null, lifecycleButtons(s, false))));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Sandboxes'), btn('New sandbox', () => createDialog(), { primary: true })),
    h('p', { class: 'sub' }, o.source === 'host' ? 'Live from the host.' : 'No host is running: read from the store (nothing is live). An action starts the host.'),
    h('div', { class: 'cards' },
      hostCard(o.host),
      card('Sandboxes', String(o.totals.sandboxes), o.totals.live + ' with a VM'),
      card('RAM held', mib(o.totals.ramHeldMiB), 'charged to this Mac now'),
      card('Disk', bytes(o.totals.diskBytes), 'allocated, all sandboxes')),
    h('h2', null, 'All sandboxes'),
    // No session column: counting sessions asks every session's holder in the guest, and this list
    // is kept live — sessions are on each sandbox's page (590 bug 3).
    panel(table(['Sandbox', 'Phase', 'RAM held', 'Disk', 'Network', 'Account', ''], rows, [2, 3]),
      'No sandboxes yet — New sandbox, or snooze create NAME --image lab'));
}

async function createDialog() {
  let images = [], accounts = { accounts: [] };
  try { [images, accounts] = await Promise.all([api('images'), api('accounts')]); } catch (_) { /* defaults */ }
  dialog('New sandbox', 'It is created off; Start boots it (the first start of an image bakes it — minutes, needs network).', [
    { name: 'sandbox', label: 'Name', placeholder: 'a-z 0-9 -', required: true },
    { name: 'image', label: 'Image', type: 'select', options: images.length ? images.map((i) => [i.name, i.name + (i.kind === 'custom' ? ' (custom)' : '')]) : ['lab', 'claude-code', 'pi'] },
    { name: 'network', label: 'Network', type: 'select', value: '',
      options: [['', 'default (agent for agent images, bake for lab)'], ['agent', 'agent — proxied, Anthropic + registries'], ['bake', 'bake — proxied, package registries'],
        ['locked', 'locked — proxied, nothing'], ['open', 'open — proxied, everything (logged)'], ['nat', 'nat — a real interface (vmnet)'], ['none', 'none']] },
    { name: 'account', label: 'Account', type: 'select', value: '',
      options: [['', 'the store default'], ['none', 'none'], ...accounts.accounts.map((a) => [a.name, a.name + ' (' + a.kind + ')'])] },
    { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: 'default' },
    { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: 'default (1024, or 2048 for agents)' },
    { name: 'workspace', label: 'Workspace (a folder on this Mac, shared at /workspace)', placeholder: '/Users/you/code/project' },
  ], 'Create', async (v) => {
    const body = { action: 'create', sandbox: v.sandbox, image: v.image };
    if (v.network) body.network = v.network;
    if (v.account) body.account = v.account;
    if (v.cpus) body.cpus = Number(v.cpus);
    if (v.memoryMiB) body.memoryMiB = Number(v.memoryMiB);
    if (v.workspace) body.workspace = v.workspace;
    await actOrThrow(body);
  });
}

async function viewSandbox() {
  const name = state.param;
  const [d, net, accounts] = await Promise.all([api('sandboxes/' + name), api('sandboxes/' + name + '/network'), api('accounts').catch(() => ({ accounts: [] }))]);
  const i = d.info;
  const running = i.phase === 'running';
  // Sessions need a VM: running, or one a session request wakes (paused, asleep, deep asleep) — never
  // while off, failed, booting, busy or while another operation on it runs (590 bug 2).
  const sessionsReady = ['running', 'paused', 'asleep', 'deepAsleep'].includes(i.phase) && !i.busy && !opRunningFor(name);
  const whyNot = sessionsReady ? null : i.phase === 'off' || i.phase === 'failed' ? 'Start it first' : 'Wait until it is running';
  const gated = (b) => { if (!sessionsReady) { b.disabled = true; b.title = whyNot; } return b; };
  const fact = (k, v) => h('div', null, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v));
  const copy = btn('Copy', async (ev) => {
    const b = ev.currentTarget;
    try { await navigator.clipboard.writeText(d.attachCommand); b.textContent = 'Copied'; } catch (_) { b.textContent = 'Select and copy'; }
    setTimeout(() => { b.textContent = 'Copy'; }, 1500);
  });
  const terminal = (session) => async () => {
    try {
      const r = await api('sandboxes/' + name + '/terminal', { method: 'POST', json: session ? { session } : {} });
      toast(r.message);
    } catch (e) { toast(e.message, true); }
  };
  const sessions = (d.sessions || []).map((s) => h('tr', null,
    h('td', null, s.name, s.name === d.defaultSession ? h('span', { class: 'tag' }, 'default') : null),
    h('td', null, s.ended ? h('span', { class: 'muted' }, 'ended (exit ' + s.exitCode + ')') : 'running'),
    h('td', { class: 'mono' }, s.command),
    h('td', { class: 'num' }, s.cols ? s.cols + '×' + s.rows : '—'),
    h('td', { class: 'num' }, String(s.clients)),
    h('td', null, s.ended ? null : gated(btn('Open in Terminal', terminal(s.name), { small: true })))));
  const points = d.restorePoints.map((p) => h('tr', null,
    h('td', null, p.name, h('div', { class: 'muted mono' }, p.id)),
    h('td', null, full(p.createdAt), h('div', { class: 'muted' }, when(p.createdAt))),
    h('td', null, p.takenWhile + (p.automatic ? ' (auto)' : ''), p.needsFsck ? h('div', { class: 'st-warn' }, 'e2fsck on next boot') : null),
    h('td', null, p.note || '—'),
    h('td', null, h('div', { class: 'actions' },
      btn('Revert', () => confirmAction('Revert ' + name, 'Revert to “' + p.name + '”: it shuts down (running programs end); the current disk is kept as a restore point first. Start boots it.', name,
        { action: 'point-revert', sandbox: name, point: p.id }), { small: true, danger: true }),
      btn('Fork', () => dialog('Fork ' + p.name, 'A new sandbox whose disks are this point’s (it cold-boots on start).',
        [{ name: 'newName', label: 'New sandbox name', required: true }], 'Fork', async (v) => { await actOrThrow({ action: 'point-fork', sandbox: name, point: p.id, newName: v.newName }); }), { small: true }),
      btn('Save as image', () => dialog('Save ' + p.name + ' as an image', 'Other sandboxes can then be created from it.',
        [{ name: 'image', label: 'Image name', required: true }, { name: 'note', label: 'Note' }], 'Save', async (v) => {
          const b = { action: 'point-save-image', sandbox: name, point: p.id, image: v.image };
          if (v.note) b.note = v.note;
          await actOrThrow(b);
        }), { small: true }),
      btn('Delete', () => confirmAction('Delete ' + p.name, 'Delete the restore point “' + p.name + '” of ' + name + '.', name,
        { action: 'point-rm', sandbox: name, point: p.id }), { small: true, danger: true })))));
  const creds = d.credentials.map((c) => h('tr', null,
    h('td', null, c.binding, h('div', { class: 'muted' }, c.hosts.join(', '))),
    h('td', null, c.set ? 'set' : 'not set'),
    h('td', null, c.source || '—', c.account ? h('div', { class: 'muted' }, 'account ' + c.account) : null),
    h('td', null, c.state || '—', c.expiresAt ? h('div', { class: 'muted' }, 'expires ' + when(c.expiresAt)) : null),
    h('td', null, c.policy || '—'),
    h('td', null, c.set && c.source && !c.source.startsWith('account:')
      ? btn('Remove', () => act({ action: 'key-rm', sandbox: name, binding: c.binding }), { small: true }) : null)));
  const foreign = d.credentials.flatMap((c) => c.foreign).map((f) => h('tr', null,
    h('td', null, f.kind + (f.matches ? ' (= ' + f.matches + ')' : '')),
    h('td', { class: 'mono' }, f.prefix + '…'),
    h('td', { class: 'mono' }, f.fingerprint),
    h('td', null, f.header),
    h('td', { class: 'num' }, String(f.requests)),
    h('td', null, when(f.lastSeen))));
  const proxied = net.proxied;
  return h('div', null,
    h('p', { class: 'sub' }, h('a', { href: '#/overview' }, '← Sandboxes')),
    h('div', { class: 'head' }, h('h1', null, name, ' ', phasePill(i.phase, i.phaseLabel, i.busy)), lifecycleButtons(i, true)),
    h('p', { class: 'sub' }, i.image + ' · created ' + when(i.createdAt)),
    h('div', { 'data-op-for': name, 'data-banner': '1', role: 'status' }),
    h('div', { class: 'cards' },
      card('RAM held', mib(i.ramHeldMiB), 'of ' + mib(i.memoryMiB) + (i.memoryReturnedMiB ? ' · balloon returned ' + mib(i.memoryReturnedMiB) : '')),
      card('Disk', bytes(i.diskBytes), d.snapshotBytes ? 'snapshot ' + bytes(d.snapshotBytes) : (d.hasRootDisk ? 'root disk kept' : 'no root disk yet')),
      card('CPUs', String(d.cpus)),
      card('Sessions', d.sessions ? String(d.sessions.filter((s) => !s.ended).length) : '—', running ? '' : 'listed while it runs')),
    h('h2', null, 'Terminal'),
    h('div', { class: 'panel' }, h('div', { class: 'cmd' }, h('code', null, d.attachCommand), copy,
      gated(btn('Open in Terminal', terminal(null), { primary: true, title: 'Terminal.app attaches to the ' + d.defaultSession + ' session (waking the sandbox if it sleeps)' }))),
      h('div', { class: 'empty' }, 'Attaches to the ' + d.defaultSession + ' session; Ctrl-] detaches, the session keeps running. The first time, macOS asks whether snooze may control Terminal.')),
    h('div', { class: 'head' }, h('h2', null, 'Sessions'), h('div', { class: 'actions' },
      gated(btn('Open the ' + d.defaultSession + ' session', () => act({ action: 'open-session', sandbox: name }), { small: true, title: 'Start the image’s own session if it is not running (wakes a sleeping sandbox)' })),
      gated(btn('Run detached…', () => dialog('Run a command in ' + name, 'A new session running the command — no shell in front (say bash -lc \'…\' for one). It runs inside the sandbox; attach to see it.',
        [{ name: 'session', label: 'Session name', placeholder: 'e.g. worker', required: true },
         { name: 'command', label: 'Command', placeholder: 'sleep 600', required: true }], 'Run', async (v) => {
          const argv = splitArgs(v.command);
          if (!argv.length) throw new Error('the command is empty');
          await actOrThrow({ action: 'open-session', sandbox: name, session: v.session, argv });
        }), { small: true })))),
    panel(table(['Session', 'State', 'Command', 'Size', 'Viewers', ''], sessions, [3, 4]),
      running ? 'No sessions.' : 'Sessions are listed while the sandbox runs.'),
    h('div', { class: 'head' }, h('h2', null, 'Restore points'), h('div', { class: 'actions' },
      btn('Take a restore point…', () => dialog('Take a restore point of ' + name, running ? 'A running sandbox pauses for the clone (milliseconds); its copy gets e2fsck on the first boot from it.' : 'An instant APFS clone of the disks.',
        [{ name: 'point', label: 'Name', placeholder: 'default point-N' }, { name: 'note', label: 'Note' }], 'Take', async (v) => {
          const b = { action: 'point-take', sandbox: name };
          if (v.point) b.point = v.point;
          if (v.note) b.note = v.note;
          await actOrThrow(b);
        }), { small: true }),
      i.phase === 'off' ? btn('Save disk as image…', () => dialog('Save ' + name + '’s disk as an image', 'The stopped sandbox’s current disk becomes a custom image.',
        [{ name: 'image', label: 'Image name', required: true }, { name: 'note', label: 'Note' }], 'Save', async (v) => {
          const b = { action: 'point-save-image', sandbox: name, image: v.image };
          if (v.note) b.note = v.note;
          await actOrThrow(b);
        }), { small: true }) : null)),
    panel(table(['Point', 'Taken', 'While', 'Note', ''], points), 'No restore points.'),
    h('div', { class: 'head' }, h('h2', null, 'Network'), proxied ? btn('Edit policy…', () => policyDialog(name, net.policy), { small: true }) : null),
    networkPanel(net),
    h('div', { class: 'head' }, h('h2', null, 'Keys & account'), h('div', { class: 'actions' },
      proxied ? btn('Key policy…', () => dialog('Key policy of ' + name, 'What the proxy does with a credential the guest brings itself. auto: strict when the account is not the Mac login, allow otherwise.',
        [{ name: 'policy', label: 'Policy', type: 'select', options: ['auto', 'allow', 'strict'], value: 'auto' }], 'Set', async (v) => {
          await actOrThrow({ action: 'key-policy', sandbox: name, policy: v.policy });
        }), { small: true }) : null,
      proxied ? btn('Account…', () => dialog('Account of ' + name, 'Which Anthropic account the proxy uses for it. The guest only ever sees a placeholder.',
        [{ name: 'account', label: 'Account', type: 'select', value: i.account || 'default',
           options: [['default', 'the store default'], ['none', 'none'], ...accounts.accounts.map((a) => [a.name, a.name + ' (' + a.kind + ')'])] }], 'Use', async (v) => {
          await actOrThrow({ action: 'account-use', sandbox: name, account: v.account });
        }), { small: true }) : null)),
    panel(table(['Key', 'Set', 'Source', 'State', 'Policy', ''], creds), 'No keys — the sandbox uses none.'),
    h('p', { class: 'muted' }, 'A key is never typed here: ', h('code', null, 'snooze key set ' + name + ' --anthropic --keychain SERVICE'), ' (or from stdin) in a terminal.'),
    foreign.length ? h('h2', null, 'Credentials the guest brought itself (fingerprints only)') : null,
    foreign.length ? panel(table(['Kind', 'Prefix', 'Fingerprint', 'Header', 'Requests', 'Last seen'], foreign, [4])) : null,
    h('h2', null, 'Configuration'),
    h('div', { class: 'panel' }, h('div', { class: 'facts' },
      fact('Memory', mib(d.memoryMiB)), fact('Root disk', mib(d.rootfsMiB)), fact('State disk', mib(d.stateDiskMiB)),
      fact('Journal', d.journalMiB ? mib(d.journalMiB) : 'none'), fact('Network', d.networkMode + (d.subnet ? ' · ' + d.subnet : '')),
      fact('Account', i.accountApplies ? (i.account || '—') : 'n/a'), fact('Shares', d.shares.length ? d.shares.map((s) => s.hostPath + ' → ' + s.guestPath).join(', ') : 'none'),
      fact('Directory', d.directory))));
}

/// Edit the policy in a dialog; Preview shows exactly what the host will do; Apply sends it.
function policyDialog(name, policy) {
  dialog('Network policy of ' + name, 'The change is live (the next connection is judged by it) and kept for the next start. Preview first.', [
    { name: 'preset', label: 'Replace with a preset', type: 'select', value: '', options: [['', '— keep the rules —'], 'agent', 'bake', 'locked', 'open'] },
    { name: 'allow', label: 'Allow hosts', type: 'textarea', placeholder: 'example.com\n*.example.org\nhost:443', help: 'one per line: exact, *.domain, host:port or an IPv4 CIDR' },
    { name: 'deny', label: 'Deny hosts', type: 'textarea', placeholder: 'one per line' },
    { name: 'remove', label: 'Remove every rule for these hosts', type: 'textarea', placeholder: 'one per line' },
  ], 'Preview', async (v, ui) => {
    const edit = {};
    if (v.preset) edit.preset = v.preset;
    for (const k of ['allow', 'deny', 'remove']) if (lines(v[k]).length) edit[k] = lines(v[k]);
    if (!Object.keys(edit).length) throw new Error('nothing to change');
    if (ui.submit.dataset.previewed === JSON.stringify(edit)) {
      await actOrThrow({ action: 'net-policy', sandbox: name, ...edit });
      return;
    }
    const p = await api('sandboxes/' + name + '/network/preview', { method: 'POST', json: edit });
    ui.extra.replaceChildren(h('div', { class: 'diff' },
      h('div', { class: 'muted' }, (p.before.preset ? p.before.preset + ' preset' : 'custom') + ' → ' + (p.after.preset ? p.after.preset + ' preset' : 'custom') +
        ' · anything else: ' + p.after.defaultAction),
      p.changed ? null : h('div', null, 'No change.'),
      ...p.removed.map((r) => h('div', { class: 'del' }, '− ' + r)),
      ...p.added.map((r) => h('div', { class: 'add' }, '+ ' + r)),
      h('details', null, h('summary', null, 'The whole policy after (' + p.after.rules.length + ' rules, in order)'),
        h('ol', null, p.after.rules.map((r) => h('li', { class: r.action === 'allow' ? 'st-ok' : 'st-fail' }, r.label + (r.note ? ' — ' + r.note : '')))))));
    ui.submit.dataset.previewed = JSON.stringify(edit);
    ui.submit.textContent = p.changed ? 'Apply' : 'Apply anyway';
    return 'keep-open';
  });
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
    h('td', { class: 'mono muted' }, r.key ? r.key.slice(0, 16) : ''),
    h('td', null, h('div', { class: 'actions' },
      r.kind === 'builtin' ? btn(r.baked ? 'Re-bake' : 'Bake', () => act({ action: 'image-bake', image: r.name }), { small: true, title: 'Minutes, needs network' }) : null,
      r.baked || r.kind === 'custom' ? btn('Remove', () => confirmAction('Remove image ' + r.name,
        r.kind === 'custom' ? 'The custom image is deleted; sandboxes made from it keep working.' : 'Its baked disk is deleted (it is baked again when next needed); sandboxes cloned from it keep working.',
        r.name, { action: 'image-rm', image: r.name }), { small: true, danger: true }) : null))));
  return h('div', null, h('h1', null, 'Images'),
    h('p', { class: 'sub' }, 'Built-in images and custom images saved from restore points. Progress of a bake shows under Operations.'),
    panel(table(['Image', 'Kind', 'Baked', 'Size', 'Note', 'Key', ''], rows, [3])));
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
    h('td', null, x.usedBy.length ? x.usedBy.join(', ') : '—'),
    h('td', null, h('div', { class: 'actions' },
      x.isDefault ? null : btn('Make default', () => act({ action: 'account-default', account: x.name }), { small: true }),
      x.kind === 'mac' ? null : btn('Verify', () => act({ action: 'account-verify', account: x.name }), { small: true, title: 'One tiny request to the API with it' }),
      x.name === 'mac' ? null : btn('Remove', () => confirmAction('Remove account ' + x.name, 'Its keychain item is deleted' + (x.usedBy.length ? '; sandboxes pinned to it must move first (' + x.usedBy.join(', ') + ')' : '') + '.',
        x.name, { action: 'account-rm', account: x.name }), { small: true, danger: true })))));
  const keep = h('input', { type: 'checkbox', id: 'keepalive' });
  keep.checked = a.keepalive;
  keep.addEventListener('change', () => act({ action: 'account-keepalive', enabled: keep.checked }));
  return h('div', null, h('h1', null, 'Accounts & keys'),
    h('p', { class: 'sub' }, 'Anthropic credentials the host holds for sandboxes. Never a secret: states, keychain item names and fingerprints only.'),
    h('div', { class: 'cards' },
      card('Default account', a.defaultAccount, a.defaultAccount === 'none' ? 'sandboxes that follow it get none' : ''),
      h('div', { class: 'card' }, h('div', { class: 'k' }, 'Keep-alive'), h('label', { class: 'v switch' }, keep, ' ', a.keepalive ? 'on' : 'off'),
        h('div', { class: 'n' }, 'runs the Mac’s own claude -p near expiry while a sandbox uses the login'))),
    h('div', { class: 'head' }, h('h2', null, 'Accounts'), btn('Set the default to none', () => act({ action: 'account-default', account: 'none' }), { small: true })),
    panel(table(['Account', 'Kind', 'Identity', 'State', 'Expires', 'Fingerprint', 'Used by', ''], rows)),
    h('p', { class: 'muted' }, 'Adding an account takes a secret, which is never typed in a browser: ',
      h('code', null, 'claude setup-token'), ' then ', h('code', null, 'snooze account add NAME --setup-token'), ' in a terminal.'));
}

async function viewMetrics() {
  const f = state.metricsFilter;
  const qs = new URLSearchParams();
  if (f.image) qs.set('image', f.image);
  if (f.days) qs.set('days', f.days);
  qs.set('steps', f.steps ? '1' : '0');
  const [m, images] = await Promise.all([api('metrics?' + qs), api('images').catch(() => [])]);
  const imageSel = h('select', { 'aria-label': 'image' }, [['', 'all images'], ...images.map((i) => [i.kind === 'custom' ? 'custom:' + i.name : i.name, i.name])].map(([v, l]) => {
    const o = h('option', { value: v }, l);
    if (v === f.image) o.selected = true;
    return o;
  }));
  const daysSel = h('select', { 'aria-label': 'since' }, [['', 'all time'], ['1', 'last day'], ['7', 'last 7 days'], ['30', 'last 30 days']].map(([v, l]) => {
    const o = h('option', { value: v }, l);
    if (v === f.days) o.selected = true;
    return o;
  }));
  const steps = h('input', { type: 'checkbox' });
  steps.checked = f.steps;
  for (const el of [imageSel, daysSel, steps]) {
    el.addEventListener('change', () => { state.metricsFilter = { image: imageSel.value, days: daysSel.value, steps: steps.checked }; refresh(false); });
  }
  const csv = h('a', { class: 'btn small', href: '/api/v1/metrics.csv?' + qs, download: 'snooze-metrics.csv' }, 'Download CSV');
  const toolbar = h('div', { class: 'toolbar' }, imageSel, daysSel, h('label', null, steps, ' steps inside actions'), csv);
  if (!m.available) return h('div', null, h('h1', null, 'Metrics'), toolbar, panel(null, 'No metrics yet — the host records every action it times.'));
  const max = Math.max(1, ...m.summary.map((r) => r.p90Ms || r.medianMs || 0));
  const rows = m.summary.map((r) => {
    const bar = h('span');
    bar.style.width = (((r.medianMs || 0) / max) * 100).toFixed(1) + '%';
    return h('tr', null, h('td', null, r.action, r.kind === 'step' ? h('span', { class: 'tag' }, 'step') : null), h('td', { class: 'num' }, String(r.count)),
      h('td', { class: 'num' }, ms(r.medianMs)), h('td', { class: 'num' }, ms(r.p90Ms)),
      h('td', { class: 'num' }, ms(r.minMs)), h('td', { class: 'num' }, ms(r.maxMs)),
      h('td', { class: 'num' }, r.failed ? h('span', { class: 'st-fail' }, String(r.failed)) : ''),
      h('td', { class: 'bar' }, h('div', { class: 'hbar', title: 'median, relative to the slowest p90' }, bar)));
  });
  return h('div', null, h('h1', null, 'Metrics'),
    h('p', { class: 'sub' }, 'Lifecycle timings the host recorded.'),
    toolbar,
    h('div', { class: 'cards' }, card('Host runs', String(m.runs)), card('Rows', String(m.rows)), card('Sessions', String(m.sessions)), card('Network minutes', String(m.networkMinutes))),
    h('h2', null, 'Per action'),
    panel(h('div', { class: 'bars' }, table(['Action', 'Count', 'Median', 'P90', 'Min', 'Max', 'Failed', ''], rows, [1, 2, 3, 4, 5, 6])), 'Nothing recorded for this filter.'));
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
    setInterval(() => { if ([...state.ops.values()].some((o) => o.state === 'running')) paintRowOps(); }, 1000);
    setInterval(paintRowOps, 15000);
  }
})();
