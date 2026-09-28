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
  // (Not for a removal: the page it would refetch is about to be gone.)
  if (!before && op.state === 'running' && op.action !== 'rm') refresh(false);
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
    // While something runs, the OLDEST running operation (a start that others wait behind) — its
    // steps are the news; otherwise the newest outcome.
    const running = ops.filter((o) => o.state === 'running');
    const o = running.length ? running[0] : ops[ops.length - 1];
    const fresh = o && (o.state === 'running' || Date.now() - new Date(o.startedAt).getTime() < 60000);
    const secs = o ? Math.max(0, Math.round((Date.now() - new Date(o.startedAt).getTime()) / 1000)) : 0;
    const more = running.length > 1 ? ' · then ' + running.slice(1).map((x) => x.action).join(', ') : '';
    const text = !fresh ? '' : o.state === 'running' ? '… ' + o.action + ' · ' + secs + ' s — ' + o.text + more : (o.state === 'done' ? '✓ ' : '✕ ') + o.text;
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
  // 591: the server closes this session's terminals; the page forgets them.
  for (const t of [...terminals.values()]) closeTerminal(t.id);
  $('terminals').hidden = true;
  $('view').hidden = false;
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
  // 591: the terminals live in their own section, never re-rendered by refresh() (a live update
  // must not steal a terminal's focus or reparent its canvas).
  const onTerminals = state.view === 'terminals';
  $('terminals').hidden = !onTerminals;
  $('view').hidden = onTerminals;
  $('main').classList.toggle('main-terms', onTerminals);
  if (onTerminals) { renderTerminals(); return; }
  refresh(true);
}
window.addEventListener('hashchange', () => { if (!state.signedOut) route(); });

let refreshing = false, again = false;
async function refresh(scrollTop) {
  if (state.signedOut) return;
  if (state.view === 'terminals') { renderTerminals(); return; }
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
  else if (verb === 'start') startWithBootView(name);
  else act({ action: verb, sandbox: name });
}
/// 591 — Start shows the boot: a terminal pane streams the host's steps and the kernel's console,
/// then becomes the image's own session (the UI process does the switch; the boot stays in the scrollback).
async function startWithBootView(name) {
  const op = await act({ action: 'start', sandbox: name });
  if (op) openTerminal(name, null, 'interactive');
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
    h('td', null, s.ended ? null : h('div', { class: 'actions' },
      btn('Open', () => openTerminal(name, s.name, 'interactive'), { small: true, title: 'A terminal on this session, here in the browser' }),
      btn('Watch', () => openTerminal(name, s.name, 'watch'), { small: true, title: 'Watch only: nothing you type reaches the session, and it never resizes it' }),
      gated(btn('Open in Terminal', terminal(s.name), { small: true }))))));
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
      ((b) => { if (i.busy || i.phase === 'booting' || opRunningFor(name)) { b.disabled = true; b.title = 'Wait until it is running'; } return b; })(
        btn('Open here', () => (i.phase === 'off' || i.phase === 'failed' ? startWithBootView(name) : openDefaultTerminal(name)),
          { primary: true, title: 'A terminal in this browser on the ' + d.defaultSession + ' session (a shut-down sandbox starts, and you watch it boot)' })),
      gated(btn('Open in Terminal', terminal(null), { title: 'Terminal.app attaches to the ' + d.defaultSession + ' session (waking the sandbox if it sleeps)' }))),
      h('div', { class: 'empty' }, 'Attaches to the ' + d.defaultSession + ' session; Ctrl-] detaches, the session keeps running. Open here keeps it in the Terminals view; Open in Terminal uses your default terminal app.')),
    h('div', { class: 'head' }, h('h2', null, 'Sessions'), h('div', { class: 'actions' },
      gated(btn('New shell', () => newShellTerminal(name).catch((e) => toast(e.message || String(e), true)),
        { small: true, title: 'A new shell session (shell-2, shell-3, …) in a browser terminal' })),
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

// ── terminals (591) ─────────────────────────────────────────────────────────
// Browser terminals on the host's attach relay (591.01-DESIGN.md). Rules this section keeps:
//   · the engine (vendored ghostty-web 0.4.0, pinned by digest) runs ONLY in a sandboxed, opaque-origin
//     iframe per terminal (/terminal-frame, frame.js — owner ruling T2): it has no cookie, no API, no
//     CSRF token and can connect to nothing; this page owns the WebSocket and talks to the frame over a
//     narrow, checked postMessage protocol. One frame = one WASM instance (upstream #141);
//   · links are never opened (the frame drops Cmd/Ctrl clicks, and its sandbox has no popups);
//   · a paste is made safe HERE (Ghostty 1.3.0's encode: unsafe control characters become spaces),
//     confirmed when unsafe or large and refused over 1 MiB (CVE-2026-26982, upstream #193);
//   · the ticket lives only in connectTerminal's memory for the moment it takes to open the socket;
//   · guest text (a title, the ended line) is shown with textContent only;
//   · what wakes a sandbox is decided by the UI process (the 541 rule), never here: every key and
//     every report is sent, and the server says what it did.
const terminals = new Map();
const termUI = { built: false, split: false, selected: [null, null], focusedPane: 0, nextId: 1, lastSandbox: null, dropped: 0 };
const PASTE_CONFIRM_BYTES = 64 * 1024;
const PASTE_MAX_BYTES = 1024 * 1024;
const INPUT_CHUNK = 16 * 1024;
const utf8 = new TextEncoder();

// This page never opens windows.
window.open = function refuseToOpen() { return null; };

function wasmURL() {
  const m = document.querySelector('meta[name="snooze-ghostty-wasm"]');
  return m ? m.getAttribute('content') : null;
}
function quietly(fn, fallback) { try { return fn(); } catch (_) { return fallback; } }
/// The engine's WebAssembly, fetched once from this origin; each frame gets its own copy to compile.
let engineWasm = null;
function engineBytes() {
  if (!engineWasm) engineWasm = fetch(wasmURL(), { credentials: 'omit' }).then((r) => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); });
  return engineWasm;
}
function toFrame(t, msg, transfer) {
  if (t.frame && t.frame.contentWindow) t.frame.contentWindow.postMessage(msg, '*', transfer || []);
}

// ── the frame protocol, page side: only our frames (by window), only an opaque origin, only these
// messages with typed, capped fields. Anything else is dropped and counted.
const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;
function validFrameMessage(m) {
  if (!m || typeof m !== 'object' || Array.isArray(m) || typeof m.t !== 'string') return false;
  const n = Object.keys(m).length;
  switch (m.t) {
    case 'ready': case 'failed': return n === 1;
    case 'opened': case 'resize': return n === 3 && isInt(m.cols, 1, 1000) && isInt(m.rows, 1, 500);
    case 'data': return n === 2 && typeof m.s === 'string' && m.s.length <= 65536;
    case 'title': return n === 2 && typeof m.s === 'string' && m.s.length <= 200;
    case 'paste': return n === 3 && typeof m.text === 'string' && m.text.length <= PASTE_MAX_BYTES && typeof m.bracketed === 'boolean';
    case 'paste-too-big': return n === 2 && isInt(m.bytes, 0, Number.MAX_SAFE_INTEGER);
    default: return false;
  }
}
window.addEventListener('message', (ev) => {
  const t = [...terminals.values()].find((x) => x.frame && x.frame.contentWindow === ev.source);
  if (!t || ev.origin !== 'null' || !validFrameMessage(ev.data)) { termUI.dropped++; return; }
  const m = ev.data;
  switch (m.t) {
    case 'ready': if (t.onReady) { t.onReady(); t.onReady = null; } break;
    case 'opened': t.cols = m.cols; t.rows = m.rows; if (t.onOpened) { t.onOpened(); t.onOpened = null; } break;
    case 'failed': if (t.onFailed) { t.onFailed(new Error('the terminal engine did not load')); t.onFailed = null; } break;
    case 'data': sendInput(t, m.s); break;
    case 'resize':
      t.cols = m.cols; t.rows = m.rows;
      if (t.mode === 'interactive') sendJSON(t, { t: 'resize', cols: m.cols, rows: m.rows });
      break;
    case 'title': t.title = m.s.slice(0, 120); paintTabs(); break;
    case 'paste': safePaste(t, m.text, m.bracketed); break;
    case 'paste-too-big': toast('That paste is too big — a terminal takes at most 1 MiB at once', true); break;
  }
});

/// Open the image's own session (starting it when needed — an explicit request), then attach.
async function openDefaultTerminal(name) {
  const op = await act({ action: 'open-session', sandbox: name });
  if (!op) return;
  const done = await waitForOp(op);
  if (done && done.state === 'done') openTerminal(name, null, 'interactive');
}
async function waitForOp(op, seconds = 300) {
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) {
    const o = state.ops.get(op.id);
    if (o && o.state !== 'running') return o;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}

async function openTerminal(sandbox, session, mode, pane) {
  const t = { id: termUI.nextId++, sandbox, session, mode, pane: termUI.split ? (pane ?? termUI.focusedPane) : 0,
              ws: null, frame: null, cols: 80, rows: 24, state: null, ended: false, endText: '', errorText: '', disconnected: '',
              closed: false, title: '', pinger: null, coverAction: null, onReady: null, onOpened: null, onFailed: null };
  t.els = terminalElements(t);
  terminals.set(t.id, t);
  termUI.selected[t.pane] = t.id;
  paintCover(t);
  if (location.hash !== '#/terminals') location.hash = '#/terminals';
  else renderTerminals();
  // The body must be laid out before the engine measures it.
  await new Promise((r) => setTimeout(r, 0));
  renderTerminals();
  try {
    const wasm = await engineBytes();
    if (t.closed) return;
    const opened = new Promise((resolve, reject) => { t.onOpened = resolve; t.onFailed = reject; });
    t.onReady = () => toFrame(t, { t: 'init', wasm: wasm.slice(0), mode });
    // The engine's frame: an opaque origin (allow-scripts only — no same-origin, no popups, no forms).
    t.frame = h('iframe', { class: 'term-frame', src: '/terminal-frame', sandbox: 'allow-scripts', allow: 'clipboard-write',
                            referrerpolicy: 'no-referrer', name: 'term-' + t.id, title: 'Terminal: ' + sandbox + ' · ' + (session || 'default') });
    t.els.host.append(t.frame);
    await opened;
  } catch (e) {
    t.errorText = 'the terminal engine did not load (' + (e.message || e) + ')';
    paintCover(t);
    return;
  }
  if (t.closed) return;
  connectTerminal(t);
  focusTerm(t);
}

async function connectTerminal(t) {
  const body = { mode: t.mode };
  if (t.session) body.session = t.session;
  if (t.mode === 'interactive') {
    body.cols = Math.max(2, Math.min(1000, t.cols));
    body.rows = Math.max(1, Math.min(500, t.rows));
  }
  let ticket;
  try {
    ticket = (await api('sandboxes/' + t.sandbox + '/terminal-ticket', { method: 'POST', json: body })).ticket;
  } catch (e) {
    t.errorText = e.message || String(e);
    paintCover(t);
    paintTabs();
    return;
  }
  if (t.closed) return;
  // The ticket rides in the subprotocol list, never in the URL; it works once, within 30 s.
  const ws = new WebSocket('ws://' + location.host + '/api/v1/sandboxes/' + t.sandbox + '/terminal-socket',
                           ['snooze-terminal.v1', 'snooze-ticket.' + ticket]);
  ticket = null;
  ws.binaryType = 'arraybuffer';
  t.ws = ws;
  t.opened = false;
  ws.addEventListener('open', () => {
    t.opened = true;
    t.pinger = setInterval(() => sendJSON(t, { t: 'ping' }), 25000);
  });
  ws.addEventListener('message', (ev) => onTerminalMessage(t, ev));
  ws.addEventListener('close', (ev) => onTerminalClose(t, ws, ev));
}

function onTerminalMessage(t, ev) {
  if (typeof ev.data !== 'string') {
    toFrame(t, { t: 'write', data: ev.data }, [ev.data]);
    return;
  }
  let m;
  try { m = JSON.parse(ev.data); } catch (_) { return; }
  if (m.t === 'state') {
    t.state = m;
    if (m.session) t.session = m.session;
    // "woke in 0.4 s": one line over the screen, for a few seconds.
    if (typeof m.notice === 'string' && m.notice) {
      const n = t.els.note;
      n.textContent = m.notice.slice(0, 80);
      n.hidden = false;
      t.els.wrap.dataset.notice = n.textContent;
      clearTimeout(t.noticeTimer);
      t.noticeTimer = setTimeout(() => { n.hidden = true; }, 4000);
    }
  } else if (m.t === 'ended') {
    t.ended = true;
    t.endText = m.text || (m.ending === 'exited' ? 'exit ' + m.code : m.ending);
  } else if (m.t === 'error') {
    t.errorText = m.message || m.code;
  }
  paintCover(t);
  paintTabs();
}

function onTerminalClose(t, ws, ev) {
  if (t.ws === ws) t.ws = null;
  clearInterval(t.pinger);
  if (t.closed || t.ended || t.errorText) return;
  if (ev.reason === 'session-ended') return;            // signedOut() follows
  t.disconnected = !t.opened ? 'the terminal socket was refused — open it again'
    : ev.reason === 'shutdown' ? 'the snooze ui process stopped'
    : ev.reason === 'idle' ? 'closed after a long silence'
    : 'the socket closed (' + (ev.reason || ev.code) + ')';
  paintCover(t);
  paintTabs();
}

function sendJSON(t, obj) {
  if (t.ws && t.ws.readyState === WebSocket.OPEN) t.ws.send(JSON.stringify(obj));
}
function sendInput(t, s) {
  if (t.mode !== 'interactive' || !t.ws || t.ws.readyState !== WebSocket.OPEN) return;
  const b = utf8.encode(s);
  for (let i = 0; i < b.length; i += INPUT_CHUNK) t.ws.send(b.subarray(i, i + INPUT_CHUNK));
}

function closeTerminal(id) {
  const t = terminals.get(id);
  if (!t) return;
  t.closed = true;
  clearInterval(t.pinger);
  if (t.ws) { try { t.ws.close(1000, 'closed'); } catch (_) { /* */ } }
  t.els.wrap.remove();                                 // its frame — and its engine instance — go with it
  terminals.delete(id);
  for (const p of [0, 1]) if (termUI.selected[p] === id) termUI.selected[p] = null;
  renderTerminals();
}
function focusTerm(t) {
  if (!t.frame) return;
  quietly(() => t.frame.focus());
  toFrame(t, { t: 'focus' });
}

// ── a terminal's elements: the frame's host, and the cover over it (the guards live in the frame)
function terminalElements(t) {
  const host = h('div', { class: 'term-frame-host' });
  const note = h('div', { class: 'term-notice', role: 'status', hidden: true });
  const spin = h('div', { class: 'tc-spin', 'aria-hidden': 'true' });
  const head = h('div', { class: 'tc-head' });
  const detail = h('div', { class: 'tc-detail' });
  const action = h('button', { type: 'button', class: 'btn small tc-act' });
  action.addEventListener('click', (ev) => { ev.stopPropagation(); coverAction(t); });
  const cover = h('div', { class: 'term-cover', role: 'status', 'aria-live': 'polite' }, h('div', { class: 'tc-box' }, spin, head, detail, action));
  const wrap = h('div', { class: 'term-wrap', 'data-terminal': String(t.id) }, host, cover, note);
  return { wrap, host, cover, spin, head, detail, action, note };
}

// ── paste (Ghostty 1.3.0's `encode`, after xterm): these become a space, in either paste mode —
// NUL, ENQ, EOT, BS, ESC, DEL, and the line-discipline characters (^C ^\ ^U ^Z ^Q ^S ^V ^W ^R ^O ^Y
// ^T); C1 controls too. A newline is sent as CR (what a terminal sends for Return).
const UNSAFE_PASTE = new Set([0x00, 0x03, 0x04, 0x05, 0x08, 0x0f, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x19, 0x1a, 0x1b, 0x1c, 0x7f]);
function encodePaste(raw) {
  let out = '', replaced = 0;
  for (const ch of raw.replace(/\r\n|\n/g, '\r')) {
    const c = ch.codePointAt(0);
    if (UNSAFE_PASTE.has(c) || (c >= 0x80 && c <= 0x9f)) { out += ' '; replaced++; } else out += ch;
  }
  return { text: out, replaced };
}
/// A paste the frame caught (with whether the program turned on bracketed paste): made safe here,
/// asked about when unsafe or large, then handed back to the frame to type.
function safePaste(t, raw, bracketed) {
  if (t.mode !== 'interactive' || !t.frame) return;
  const size = utf8.encode(raw).length;
  if (size > PASTE_MAX_BYTES) { toast('That paste is ' + bytes(size) + ' — a terminal takes at most 1 MiB at once', true); return; }
  const { text, replaced } = encodePaste(raw);
  const reasons = [];
  if (replaced) reasons.push(replaced + ' control character' + (replaced === 1 ? ' was' : 's were') + ' replaced with spaces.');
  if (!bracketed && text.includes('\r')) reasons.push('It has line breaks and the program did not turn on bracketed paste — each line may run as a command.');
  if (size > PASTE_CONFIRM_BYTES) reasons.push('It is large (' + bytes(size) + ').');
  if (!reasons.length) { toFrame(t, { t: 'paste', text }); return; }
  const lines = text.split('\r');
  const d = h('dialog', { class: 'dlg paste-dialog' });
  const ok = h('button', { type: 'button', class: 'btn primary' }, 'Paste');
  const cancel = h('button', { type: 'button', class: 'btn' }, 'Cancel');
  ok.addEventListener('click', () => { d.close(); toFrame(t, { t: 'paste', text }); focusTerm(t); });
  cancel.addEventListener('click', () => { d.close(); focusTerm(t); });
  d.append(h('form', { method: 'dialog' },
    h('h2', null, 'Paste ' + lines.length + ' line' + (lines.length === 1 ? '' : 's') + ' (' + bytes(size) + ') into ' + t.sandbox + '?'),
    ...reasons.map((r) => h('p', { class: 'sub' }, r)),
    h('pre', { class: 'paste-preview' }, lines.slice(0, 5).join('\n').slice(0, 2000) + (lines.length > 5 ? '\n…' : '')),
    h('div', { class: 'dlg-buttons' }, cancel, ok)));
  d.addEventListener('close', () => d.remove());
  document.body.append(d);
  d.showModal();
  ok.focus();
}

// ── the cover (the UI process derives it; this only draws it)
function elapsedText(verb, since) {
  if (!verb || !since) return null;
  const s = Math.floor((Date.now() - new Date(since).getTime()) / 1000);
  if (s < 60) return null;
  const m = Math.floor(s / 60);
  if (m < 60) return verb + ' ' + m + ' min';
  const hr = Math.floor(m / 60);
  if (hr < 24) return verb + ' ' + hr + ' h';
  return verb + ' ' + Math.floor(hr / 24) + ' d';
}
function paintCover(t) {
  const e = t.els;
  let kind = 'none', headline = '', detail = '', action = null, spinner = false;
  if (t.errorText) { kind = 'error'; headline = 'This terminal could not open'; detail = t.errorText; }
  else if (t.ended) { kind = 'ended'; headline = 'The session ended'; detail = t.endText; }
  else if (t.disconnected) { kind = 'disconnected'; headline = 'Disconnected'; detail = t.disconnected; action = 'Reconnect'; }
  else if (!t.state) { kind = 'reattaching'; headline = 'Attaching…'; spinner = true; }
  else {
    const c = t.state.cover;
    kind = c.kind;
    headline = c.headline;
    const el = elapsedText(c.elapsedVerb, c.since);
    detail = [c.detail, el].filter(Boolean).join(' · ');
    action = c.action || null;
    spinner = !!c.spinner;
  }
  e.wrap.dataset.cover = kind;
  e.wrap.dataset.phase = (t.state && t.state.phase) || '';
  e.wrap.dataset.reports = String((t.state && t.state.reportsIgnored) || 0);
  e.wrap.dataset.wakes = String((t.state && t.state.keystrokeWakes) || 0);
  // The boot view draws the boot in the terminal itself: no cover.
  e.cover.hidden = kind === 'none' || kind === 'boot';
  e.head.textContent = headline;
  e.detail.textContent = detail;
  e.detail.hidden = !detail;
  e.spin.hidden = !spinner;
  e.action.hidden = !action;
  e.action.textContent = action || '';
  e.action.title = action === 'Reconnect' ? 'Open the terminal again' : action ? action + ' — so does any key typed in the terminal' : '';
  t.coverAction = action;
}
function coverAction(t) {
  const a = t.coverAction;
  if (a === 'Reconnect') {
    t.disconnected = '';
    t.state = null;
    paintCover(t);
    connectTerminal(t);
  } else if (a) {
    act({ action: { Resume: 'resume', Wake: 'wake', Start: 'start' }[a], sandbox: t.sandbox });
  }
  focusTerm(t);
}

// ── the Terminals view: tabs, and a split
function paintTabs() { if (state.view === 'terminals') renderTerminals(); }
function renderTerminals() {
  const root = $('terminals');
  if (!termUI.built) {
    termUI.splitBtn = btn('Split', () => {
      termUI.split = !termUI.split;
      if (!termUI.split) {
        for (const t of terminals.values()) t.pane = 0;
        termUI.selected[0] = termUI.selected[0] ?? termUI.selected[1];
        termUI.selected[1] = null;
        termUI.focusedPane = 0;
      }
      renderTerminals();
      // A new pane opens a NEW shell (next to the terminal on the left, same sandbox) — never a
      // second view of the same session.
      const left = terminals.get(termUI.selected[0]);
      if (termUI.split && left && ![...terminals.values()].some((t) => t.pane === 1)) {
        termUI.focusedPane = 1;
        newShellTerminal(left.sandbox, 1).catch((e) => toast(e.message || String(e), true));
      }
    }, { title: 'Show two terminals side by side — a new shell opens on the right' });
    termUI.panes = [0, 1].map((i) => {
      const strip = h('div', { class: 'tabs', role: 'tablist' });
      const body = h('div', { class: 'term-body' });
      const empty = h('div', { class: 'empty term-empty' }, 'No terminal here. Open one from a sandbox’s page (Open here, or a session’s Open / Watch), or New terminal….');
      const pane = h('div', { class: 'term-pane', 'data-pane': String(i) }, strip, body);
      body.append(empty);
      pane.addEventListener('focusin', () => { termUI.focusedPane = i; });
      pane.addEventListener('mousedown', () => { termUI.focusedPane = i; });
      return { root: pane, strip, body, empty };
    });
    termUI.grid = h('div', { class: 'term-grid' }, termUI.panes[0].root, termUI.panes[1].root);
    root.replaceChildren(
      h('div', { class: 'head' }, h('h1', null, 'Terminals'),
        h('div', { class: 'actions' }, btn('New terminal…', () => newTerminalDialog(), { primary: true }), termUI.splitBtn)),
      termUI.grid);
    termUI.built = true;
  }
  termUI.grid.classList.toggle('split', termUI.split);
  termUI.splitBtn.textContent = termUI.split ? 'Unsplit' : 'Split';
  termUI.panes[1].root.hidden = !termUI.split;
  termUI.panes.forEach((p, i) => {
    const mine = [...terminals.values()].filter((t) => t.pane === i);
    if (!mine.some((t) => t.id === termUI.selected[i])) termUI.selected[i] = mine.length ? mine[mine.length - 1].id : null;
    p.strip.replaceChildren(...mine.map((t) => tabElement(t, i)));
    p.empty.hidden = mine.length > 0;
    for (const t of mine) {
      if (t.els.wrap.parentNode !== p.body) p.body.append(t.els.wrap);
      t.els.wrap.hidden = t.id !== termUI.selected[i];
    }
  });
}
function tabElement(t, pane) {
  const phase = t.ended || t.errorText || t.disconnected ? 'ended' : (t.state && t.state.phase) || 'unknown';
  // Tabs are numbered (1, 2, …) so a shared session can say which tab it is shared with.
  const order = [...terminals.keys()];
  const num = order.indexOf(t.id) + 1;
  const label = num + ' · ' + t.sandbox + ' · ' + (t.session || '…');
  const twins = t.session && !t.ended ? [...terminals.values()].filter((o) => o.id !== t.id && !o.ended && o.sandbox === t.sandbox && o.session === t.session) : [];
  const shared = twins.length ? h('span', { class: 'tag shared', title: 'Two views of ONE session: what is typed in either shows in both' },
    'shared with tab ' + twins.map((o) => order.indexOf(o.id) + 1).join(', ')) : null;
  const select = h('button', { type: 'button', role: 'tab', class: 'tab' + (t.id === termUI.selected[pane] ? ' active' : ''),
                               title: t.title ? t.title + ' — ' + label : label, 'data-term': String(t.id),
                               on: { click: () => { termUI.selected[pane] = t.id; renderTerminals(); focusTerm(t); } } },
    h('span', { class: 'tab-dot ph-' + phase, 'aria-hidden': 'true' }), label, t.mode === 'watch' ? h('span', { class: 'tag' }, 'watch') : null, shared);
  const move = termUI.split ? h('button', { type: 'button', class: 'tab-x', title: 'Move to the other pane',
    on: { click: () => { t.pane = 1 - t.pane; termUI.selected[t.pane] = t.id; renderTerminals(); focusTerm(t); } } }, '⇄') : null;
  const close = h('button', { type: 'button', class: 'tab-x', title: 'Close this terminal (the session keeps running)', 'aria-label': 'Close ' + label,
    on: { click: () => closeTerminal(t.id) } }, '×');
  return h('div', { class: 'tab-wrap' }, select, move, close);
}

async function newTerminalDialog() {
  let o = state.overview;
  try { o = await api('overview'); state.overview = o; } catch (_) { /* the last one */ }
  const names = o ? o.sandboxes.map((s) => s.name) : [];
  if (!names.length) { toast('No sandboxes yet — create one first', true); return; }
  const first = termUI.lastSandbox && names.includes(termUI.lastSandbox) ? termUI.lastSandbox : names[0];
  // What to open: a NEW shell by default (591 owner feedback: an empty form must never mirror an
  // existing session); attaching to or watching a running session is an explicit choice.
  const d = dialog('New terminal', 'A new shell session by default. To see a session that already runs, pick Attach or Watch.', [
    { name: 'sandbox', label: 'Sandbox', type: 'select', options: names, value: first },
    { name: 'what', label: 'Open', type: 'select', options: [['new', 'New shell'], ['command', 'New session running a command…']] },
    { name: 'session', label: 'Session name (new session only)', placeholder: 'e.g. worker' },
    { name: 'command', label: 'Command (new session only)', placeholder: 'e.g. htop — no shell in front (say bash -lc \'…\' for one)' },
  ], 'Open', async (v) => {
    termUI.lastSandbox = v.sandbox;
    const pane = termUI.split ? termUI.focusedPane : 0;
    if (v.what === 'new') { await newShellTerminal(v.sandbox, pane); return; }
    if (v.what === 'command') {
      const argv = splitArgs(v.command);
      if (!argv.length) throw new Error('the command is empty');
      if (!v.session) throw new Error('a new session needs a name');
      const done = await waitForOp(await actOrThrow({ action: 'open-session', sandbox: v.sandbox, session: v.session, argv }));
      if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
      if (!done.text.startsWith('started')) throw new Error('a session named ' + v.session + ' already runs — pick another name, or Attach to it');
      openTerminal(v.sandbox, v.session, 'interactive', pane);
      return;
    }
    const m = /^(attach|watch):(.+)$/.exec(v.what);
    if (!m) throw new Error('pick what to open');
    openTerminal(v.sandbox, m[2], m[1] === 'watch' ? 'watch' : 'interactive', pane);
  });
  const sandboxSel = d.querySelector('[name="sandbox"]'), whatSel = d.querySelector('[name="what"]');
  const nameField = d.querySelector('[name="session"]').closest('label'), cmdField = d.querySelector('[name="command"]').closest('label');
  const showFields = () => { const c = whatSel.value === 'command'; nameField.hidden = !c; cmdField.hidden = !c; };
  // The running sessions of the chosen sandbox, as explicit Attach / Watch choices.
  const loadSessions = async () => {
    for (const o of [...whatSel.options]) if (o.value.includes(':')) o.remove();
    let rows = [];
    try { rows = await api('sandboxes/' + sandboxSel.value + '/sessions'); } catch (_) { /* not running: none to attach to */ }
    for (const s of rows.filter((r) => !r.ended)) {
      whatSel.append(h('option', { value: 'attach:' + s.name }, 'Attach to ' + s.name + ' (' + s.command + ')'));
      whatSel.append(h('option', { value: 'watch:' + s.name }, 'Watch ' + s.name + ' (read-only)'));
    }
    showFields();
  };
  sandboxSel.addEventListener('change', loadSessions);
  whatSel.addEventListener('change', showFields);
  loadSessions();
}

/// A NEW shell session in `sandbox` — `shell-2`, `shell-3`, … (the next name not taken), running a
/// login shell — opened with the ordinary open-session action (one HostOp; its idempotency unchanged:
/// a name that turns out to be taken answers "already running", and the next name is tried).
async function newShellTerminal(sandbox, pane) {
  let rows = [], detail = null;
  try { [detail, rows] = await Promise.all([api('sandboxes/' + sandbox), api('sandboxes/' + sandbox + '/sessions')]); } catch (_) { /* asleep: listed after the wake */ }
  const argv = loginShell(detail, rows);
  const taken = new Set(rows.map((r) => r.name));
  for (let n = 2, tries = 0; tries < 20; n++) {
    const name = 'shell-' + n;
    if (taken.has(name)) continue;
    tries++;
    const op = await actOrThrow({ action: 'open-session', sandbox, session: name, argv });
    const done = await waitForOp(op);
    if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
    if (done.text.startsWith('started')) { openTerminal(sandbox, name, 'interactive', pane); return; }
    taken.add(name);                                   // it already ran (a sandbox that was asleep): the next one
  }
  throw new Error('no free shell-N name');
}
/// `bash -l` where the image has bash (the built-in images, and custom images made from them; or
/// any running session that is bash), else `sh -l`.
function loginShell(detail, rows) {
  const image = detail && detail.info ? detail.info.image : '';
  const hasBash = ['lab', 'claude-code', 'pi'].includes(image) || rows.some((r) => /(^|\/)bash(\s|$)/.test(r.command));
  return hasBash ? ['bash', '-l'] : ['sh', '-l'];
}

// ── start ───────────────────────────────────────────────────────────────────
(async () => {
  if (await bootstrap()) {
    if (!/^#\/[a-z]/.test(location.hash)) history.replaceState(null, '', location.pathname + '#/overview');
    route();
    connect();
    setInterval(() => { if ([...state.ops.values()].some((o) => o.state === 'running')) paintRowOps(); }, 1000);
    setInterval(paintRowOps, 15000);
    setInterval(() => { for (const t of terminals.values()) paintCover(t); }, 30000);   // "asleep 7 min"
  }
})();
