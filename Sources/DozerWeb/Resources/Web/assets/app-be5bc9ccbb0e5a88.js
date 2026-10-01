// doz ui — phase 2: the dashboard, and actions.
//
// Rules this file keeps (590.01-DESIGN.md):
//   · Every value from the server is rendered with textContent — never parsed as HTML. Much of it comes
//     from inside a sandbox (hostnames in the net log, session commands, image notes) and a sandbox
//     is untrusted.
//   · The link's capability is read from the fragment ONCE, removed from the address bar and history
//     before anything else, and sent only in the bootstrap's Authorization header.
//   · The CSRF token lives in this page's memory only (never storage, a cookie or a URL).
//   · Every action is one typed request (POST /api/v1/actions, {action, …}); a destructive one carries
//     `confirm`, filled only from a name the person typed. No action ever carries a secret (590's D3).
//     594 (owner ruling): an ACCOUNT's key or token may be typed in a masked field (accountForm) — one
//     POST /api/v1/accounts body, while ui.allow_secret_entry; a sandbox's own key likewise (keyEntry,
//     POST /api/v1/sandboxes/NAME/key).
//   · Forms live in <dialog>s outside the view, so a live refresh never wipes what is being typed.
'use strict';

const state = {
  csrf: null,
  expiresAt: null,
  view: 'overview',
  param: null,
  session: null,           // 593: #/sandbox/NAME/SESSION
  sbx: null,               // 593: the shown sandbox's {name, d, net, accounts}
  opsSeenAt: Date.now(),   // 593: a failure that ended after this is unacknowledged (the Operations badge)
  opsFilter: '',
  imagesMode: 'table',     // 593: Images › Table | Lineage
  overview: null,
  activity: [],
  ops: new Map(),
  es: null,
  renewTimer: null,
  deniedOnly: false,
  signedOut: false,
  metricsFilter: { image: '', days: '', steps: false },
  settings: null,          // 591: {report, byKey} from GET /api/v1/settings
  preps: [],               // 594: the host's image preparations (SSE `preparations`, GET /api/v1/preparations)
  wiz: null,               // 594: the onboarding wizard's state (#/onboarding)
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

// ── icons (593): Lucide (lucide-static, ISC — vendored and pinned; one generated sprite, a same-origin
// asset). An icon is <svg class="icon"><use href="SPRITE#name"></svg>, made with createElementNS; its
// colour is the button's (stroke: currentColor, in app.css) and it is hidden from assistive tech —
// every button keeps its text (or its aria-label). One map says which icon a label gets.
const SVG_NS = 'http://www.w3.org/2000/svg';
const SPRITE = (() => { const m = document.querySelector('meta[name="doz-icons"]'); return m ? m.getAttribute('content') : ''; })();
const ICON_FALLBACK = 'circle-dot';
/// 593 (owner): Sleep and Hibernate are told apart by a second glyph — Sleep keeps the machine in
/// memory (a CPU), Hibernate frees it and keeps the state on disk (a cylinder — storage). Used
/// wherever those states show.
const ICON_SLEEP = 'moon+cpu', ICON_HIBERNATE = 'moon+cylinder';
/// A phase (or a cover's kind) → its glyph, where it has one.
const PHASE_GLYPH = { paused: 'pause', asleep: ICON_SLEEP, hibernated: ICON_HIBERNATE, off: 'power', shutDown: 'power' };
/// An operation's action → its glyph (the lifecycle verbs; the rest have none).
const OP_GLYPH = { start: 'play', pause: 'pause', resume: 'play', sleep: ICON_SLEEP, hibernate: ICON_HIBERNATE, wake: 'sun',
                   shutdown: 'power', reset: 'rotate-ccw', rm: 'trash-2', duplicate: 'copy', 'template-create': 'layout-template' };
/// `name`, or a pair `a+b`: a glyph drawn as two icons side by side (both hidden, one tight group).
function icon(name) {
  if (name.includes('+')) {
    const g = h('span', { class: 'icon-pair', 'aria-hidden': 'true', 'data-icon': name });
    for (const n of name.split('+')) g.append(icon(n));
    return g;
  }
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('class', 'icon');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.setAttribute('data-icon', name);
  const use = document.createElementNS(SVG_NS, 'use');
  use.setAttribute('href', SPRITE + '#' + name);
  svg.append(use);
  return svg;
}
/// A label's icon: the exact label, else its first word; the fallback is a visible "missing" (the probe fails on it).
const ICON_EXACT = {
  'open in terminal': 'square-terminal', 'set the default to none': 'ban', 'make default': 'star', 'save as template…': 'layout-template',
  'save template': 'layout-template', 'hide details': 'panel-right', 'details': 'panel-right', 'take a restore point…': 'camera', 'take': 'camera',
  'key policy…': 'key-round', 'account…': 'user-round', 'edit policy…': 'shield', 'terminal…': 'terminal', 'new shell': 'plus',
  'new sandbox': 'plus', 'run detached…': 'play', 'default': 'rotate-ccw', 'apply anyway': 'check', 'download csv': 'download',
  'shut down': 'power', 'sign out': 'log-out', 'unsplit': 'columns-2',
  // 594: the onboarding wizard.
  'get started': 'rocket', 'run onboarding again': 'rocket', 'check again': 'refresh-cw', 'next': 'arrow-right', 'back': 'arrow-left',
  'continue in the background': 'layers', 'skip': 'skip-forward', 'open sandboxes': 'box', 'prepare and continue': 'flame',
  'cancel preparation': 'x', 'create sandbox': 'plus', 'try again': 'refresh-cw', 'continue': 'arrow-right',
};
const ICON_WORD = {
  start: 'play', pause: 'pause', resume: 'play', sleep: ICON_SLEEP, hibernate: ICON_HIBERNATE, wake: 'sun', reset: 'rotate-ccw', remove: 'trash-2', delete: 'trash-2',
  open: 'terminal', split: 'columns-2', duplicate: 'copy', revert: 'history', fork: 'git-fork', copy: 'clipboard', copied: 'check',
  select: 'clipboard', refresh: 'refresh-cw', create: 'plus', bake: 'flame', 're-bake': 'flame', verify: 'badge-check', watch: 'eye',
  set: 'check', use: 'check', run: 'play', save: 'layout-template', preview: 'eye', apply: 'check', cancel: 'x', paste: 'clipboard-paste',
  reconnect: 'refresh-cw', table: 'table', lineage: 'list-tree', shut: 'power', attach: 'link', close: 'x',
};
function iconFor(label) {
  const l = String(label).trim().toLowerCase();
  return ICON_EXACT[l] || ICON_WORD[l.split(/\s+/)[0].replace(/[…:.,]+$/, '')] || ICON_FALLBACK;
}
/// A button's label with its icon in front (the label stays text).
function withIcon(name, label) { return [icon(name), h('span', { class: 'btn-label' }, label)]; }
/// Put (or replace) the icon of an existing button, keeping its text.
function setButton(b, label, name) { b.replaceChildren(...withIcon(name || iconFor(label), label)); }

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
  if (init.method !== 'GET') init.headers['X-Doz-CSRF'] = state.csrf || '';
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
  beginTransition(body.sandbox, body.action);
  try {
    const op = await api('actions', { method: 'POST', json: body });
    trackOp(op);
    return op;
  } catch (e) {
    endTransition(body.sandbox, body.action);
    toast(e.message || String(e), true);
    return null;
  }
}

// ── transitions (593 follow-up — owner: "when i clicked on the button to start the sandbox, it briefly
// flashed a button that it was "Shut Down" before the boot sequence"). The moment a lifecycle action is
// asked for, its sandbox is IN that transition on this page: the phase pill says so ("Booting…", with a
// spinner), every lifecycle button stays where it was but disabled — the set shown when it was clicked,
// never another phase's — and the boot view's cover says it is starting. It ends when the operation
// ends (or is refused); only then does the control bar show the new phase's buttons.
const TRANSITION_LABEL = { start: 'Booting…', wake: 'Waking…', resume: 'Resuming…', pause: 'Pausing…', sleep: 'Going to sleep…',
                           hibernate: 'Hibernating…', shutdown: 'Shutting down…', reset: 'Resetting…', rm: 'Removing…' };
state.transitions = new Map();
state.trGen = 0;
function beginTransition(name, action) {
  if (!name || !TRANSITION_LABEL[action]) return;
  const have = state.transitions.get(name);
  if (have && have.action === action) return;
  state.trGen++;
  state.transitions.set(name, { action, verbs: verbsFor(sandboxPhase(name)) });
  paintTransition(name);
}
/// `repaint`: the action failed or was refused — show what is true again at once. After a success the
/// refresh that follows repaints from the NEW state (repainting now would show the phase it just left).
function endTransition(name, action, repaint = true) {
  const t = name && state.transitions.get(name);
  if (!t || (action && t.action !== action)) return;
  state.trGen++;
  state.transitions.delete(name);
  for (const x of terminals.values()) {
    if (x.sandbox !== name) continue;
    if (x.bootIntent) { x.bootIntent = false; if (repaint) paintCover(x); } else if (x.saved && repaint) paintCover(x);
  }
}
/// This page's transition of the sandbox, or — an operation it did not start here (a reload, another
/// tab's) — the running lifecycle operation it knows of (then the buttons follow the phase).
function transitionOf(name) {
  const t = state.transitions.get(name);
  if (t) return t;
  const o = [...state.ops.values()].find((x) => x.sandbox === name && x.state === 'running' && TRANSITION_LABEL[x.action]);
  return o ? { action: o.action, verbs: null } : null;
}
function transitionPill(t, name) {
  return h('span', { class: 'pill ph-busy', 'data-pill-for': name, 'data-transition': t.action },
    h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), ' ' + TRANSITION_LABEL[t.action]);
}
/// Put a sandbox into its transition where it is shown NOW — in place, no re-render: its pills say so
/// and its lifecycle buttons are disabled (nothing is swapped).
function paintTransition(name) {
  const t = state.transitions.get(name);
  if (!t) return;
  for (const el of document.querySelectorAll('[data-lifecycle-for]')) {
    if (el.dataset.lifecycleFor !== name) continue;
    for (const b of el.querySelectorAll('button')) { b.disabled = true; b.title = TRANSITION_LABEL[t.action]; }
  }
  for (const el of document.querySelectorAll('[data-pill-for]')) if (el.dataset.pillFor === name) el.replaceWith(transitionPill(t, name));
  for (const x of terminals.values()) if (x.sandbox === name && x.saved) paintCover(x);
  if (state.view === 'sandbox' && state.param === name) paintTermEmpty();
}
function trackOp(op) {
  const before = state.ops.get(op.id);
  // 595: a fast operation's end (SSE) can arrive before the POST's own "running" answer — never
  // let the older news overwrite the end (it left the page thinking it still ran).
  if (before && before.state !== 'running' && op.state === 'running') return;
  state.ops.set(op.id, op);
  if (state.ops.size > 60) state.ops.delete(state.ops.keys().next().value);
  renderOps();
  paintRowOps();
  // A new operation: re-render, so its sandbox's buttons are disabled while it runs.
  // (Not for a removal: the page it would refetch is about to be gone.)
  if (!before && op.state === 'running' && op.action !== 'rm') refresh(false);
  if (op.state !== 'running' && (!before || before.state === 'running')) {
    endTransition(op.sandbox, op.action, op.state === 'failed');
    if (op.state === 'failed') toast(op.label + ': ' + op.text, true);
    refreshNav();
    // 595: an operation's end may have changed the disks — measure again (the nav's total too).
    remeasure();
    scheduleResTotal();
    // The sandbox this page shows is gone: back to the list (route() refreshes) instead of a 404.
    if (op.state === 'done' && op.action === 'rm' && state.view === 'sandbox' && state.param === op.sandbox) { location.hash = '#/overview'; return; }
    refresh(false);
  }
}
function toast(text, bad) {
  const t = h('div', { class: 'toast' + (bad ? ' bad' : ''), role: 'status' }, text);
  $('toasts').append(t);
  setTimeout(() => t.remove(), bad ? 9000 : 4000);
  return t;
}
// 599 (594.B1/B2): what a session bridge did — "hello copied 42 chars", "hello opened https://… in your
// browser". Shown every time (a copy is the one thing an agent can hand the person unasked); two views of
// one session (a pane and a tile) are told the same thing once. A refusal is shown as a failure.
const recentBridgeNotices = new Map();
function bridgeNotice(kind, text) {
  const k = String(kind).slice(0, 32), s = String(text).slice(0, 400), now = Date.now();
  for (const [key, at] of recentBridgeNotices) if (now - at > 2000) recentBridgeNotices.delete(key);
  if (recentBridgeNotices.has(k + '\n' + s)) return;
  recentBridgeNotices.set(k + '\n' + s, now);
  const t = toast(s, /-(refused|off)$/.test(k));
  t.classList.add('bridge');
  t.dataset.bridge = k;
}
// 593 (owner): Operations is its own page, not a block on top of every page. What the nav shows: the
// running count (with a spinner) and a red dot while a failure is unacknowledged — one that ended
// after the Operations page was last shown (or this page loaded). In-context progress stays: the
// overview row and the sandbox's control bar (`data-op-for`).
function opEnded(o) { return new Date(o.startedAt).getTime() + (o.milliseconds || 0); }
function prepRunning(p) { return p.state === 'running' || p.state === 'cancelling'; }
function renderOps() {
  const running = [...state.ops.values()].filter((o) => o.state === 'running').length + state.preps.filter(prepRunning).length;
  const badge = $('ops-badge');
  badge.hidden = running === 0;
  badge.replaceChildren(h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), String(running));
  badge.title = running + ' running';
  if (state.view === 'operations') state.opsSeenAt = Date.now();
  const unseen = [...state.ops.values()].some((o) => o.state === 'failed' && opEnded(o) > state.opsSeenAt);
  $('ops-alert').hidden = !unseen;
  if (state.view === 'operations') renderOperations();
}
function acknowledgeOps() {
  state.opsSeenAt = Date.now();
  $('ops-alert').hidden = true;
}
function viewOperations() {
  acknowledgeOps();
  const box = h('div');
  state.opsBox = box;
  renderOperations();
  return box;
}
function renderOperations() {
  const box = state.opsBox;
  if (!box) return;
  const all = [...state.ops.values()].reverse();
  const names = [...new Set(all.map((o) => o.sandbox).filter(Boolean))].sort();
  const filter = h('select', { 'aria-label': 'Filter by sandbox' }, h('option', { value: '' }, 'every sandbox'), names.map((n) => {
    const o = h('option', { value: n }, n);
    if (n === state.opsFilter) o.selected = true;
    return o;
  }));
  filter.addEventListener('change', () => { state.opsFilter = filter.value; renderOperations(); });
  const list = all.filter((o) => !state.opsFilter || o.sandbox === state.opsFilter);
  const rows = list.map((o) => {
    const secs = o.state === 'running' ? Math.max(0, Math.round((Date.now() - new Date(o.startedAt).getTime()) / 1000)) + ' s' : (o.milliseconds ? ms(o.milliseconds) : '—');
    return h('tr', { class: 'op-row op-' + o.state, 'data-op': o.id },
      h('td', null, o.state === 'running' ? h('span', { class: 'mini-spin', title: 'running' }) : h('span', { class: 'op-state', title: o.state }, o.state === 'done' ? '✓' : '✕')),
      h('td', { class: 'op-action' }, OP_GLYPH[o.action] ? icon(OP_GLYPH[o.action]) : null, o.action), h('td', null, o.sandbox ? h('a', { href: '#/sandbox/' + o.sandbox }, o.sandbox) : '—'),
      h('td', null, clock(o.startedAt)), h('td', { class: 'num' }, secs),
      // 594 W22: an operation of several parts (Restart host) lists each finished one.
      h('td', { class: 'op-text' }, o.text, o.lines && o.lines.length ? h('ul', { class: 'op-lines' }, o.lines.map((l) => h('li', null, l))) : null));
  });
  // (replaceChildren writes a null as the text "null" — h() skips it, replaceChildren does not.)
  box.replaceChildren(h('h1', null, 'Operations'),
    ...(state.preps.length ? [preparationsSection()] : []),
    h('p', { class: 'sub' }, 'What this UI asked the host to do, newest first: live progress while it runs, then its result. A failure also raises a message.'),
    h('div', { class: 'toolbar' }, filter, list.length + ' of ' + all.length),
    panel(table(['', 'Action', 'Sandbox', 'Started', 'Took', 'Progress / result'], rows, [4]), 'Nothing yet — actions you take show here.'));
}
/// 594: the host's image preparations — whoever asked (doz onboard, the wizard, a start): they run in
/// the host, not in this page, so they show here even when started from a terminal.
function prepProgressText(p) {
  if (p.error) return p.error;
  if (!prepRunning(p)) return p.state === 'done' ? 'ready' : p.state;
  if (p.transferLine) return p.transferLine;
  if (p.step) return p.step + ' · ' + Math.round(p.stepSeconds || 0) + ' s';
  return p.lines.length ? p.lines[p.lines.length - 1] : 'starting…';
}
function preparationsSection() {
  // A row per preparation and, beneath it, the same card as the wizard's (the running ones in full).
  // (prep-row, not op-row: a preparation is the host's, not one of this page's operations — the
  // operations table's filter and its "newest first" are the UI's own actions only.)
  const rows = state.preps.flatMap((p) => [h('tr', { class: 'prep-row op-' + (prepRunning(p) ? 'running' : p.state === 'done' ? 'done' : 'failed'), 'data-prep': p.image },
    h('td', null, prepRunning(p) ? h('span', { class: 'mini-spin', title: p.state }) : h('span', { class: 'op-state', title: p.state }, p.state === 'done' ? '✓' : '✕')),
    h('td', { class: 'op-action' }, icon('flame'), 'prepare ' + p.image),
    h('td', null, p.requestedBy.join(', ')),
    h('td', null, clock(p.startedAt)), h('td', { class: 'num' }, Math.round(p.seconds) + ' s'),
    h('td', { class: 'op-text' }, prepProgressText(p)),
    h('td', null, prepRunning(p) && p.state !== 'cancelling'
      ? btn('Cancel preparation', () => act({ action: 'prepare-cancel', images: [p.image] }), { small: true, danger: true }) : null)),
    h('tr', { class: 'prep-detail-row', 'data-prep-detail': p.image }, h('td', { colspan: '7' }, prepCard(p, { open: false })))]);
  return h('div', { class: 'ops-preps' }, h('h2', null, 'Image preparations (in the host)'),
    h('p', { class: 'sub' }, 'The kernel, the base image and the bake of a built-in image — asked for by doz onboard, the onboarding wizard, doz image bake or a first start. One per image at a time; whoever asks next joins it.'),
    panel(table(['', 'Image', 'Asked by', 'Started', 'Took', 'Progress', ''], rows, [4])));
}
async function loadPreparations() {
  try { state.preps = await api('preparations'); } catch (_) { /* the last list */ }
  renderOps();
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
  const customs = {};
  const rows = fields.map((f) => {
    // 594: a composite field (the workspace chooser) brings its own element and its value.
    if (f.type === 'custom') { customs[f.name] = f.get; return f.el; }
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
  const submit = h('button', { type: 'submit', class: 'btn primary' + (opts.danger ? ' danger' : '') }, withIcon(opts.icon || iconFor(submitLabel), submitLabel));
  const cancel = h('button', { type: 'button', class: 'btn', on: { click: () => d.close() } }, withIcon('x', 'Cancel'));
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
      for (const [k, get] of Object.entries(customs)) values[k] = get();
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
  return Object.assign(d, { inputs });
}

// ── 594: the workspace of a new sandbox ─────────────────────────────────────
// Owner (2026-09-29): "an easier way to pick a workspace folder … a default location
// ~/Developer/dozer-sandbox-projects/[SANDBOX-NAME] and … a better default name like claude-sandbox";
// "present the no workspace toggle better … call it Isolated"; "i dont want the user to have to create
// the path first". Shared folder (default) | Isolated. The name follows the image until it is typed
// in; the folder follows the name until it is typed in (or chosen). The host says what a path would
// do (POST workspace/check — it makes nothing): "will be created", "exists", or why not. Choose…
// opens the MAC's folder picker (POST workspace/choose — one at a time; the answer is a path).
const ISOLATED_NOTE = 'Nothing on your Mac is shared. /workspace exists only inside the sandbox.';
function workspaceChooser({ nameInput = null, image = () => null, name = null, initialPath = '', initialIsolated = false }) {
  let mode = initialIsolated ? 'isolated' : 'shared', nameEdited = false, pathEdited = !!initialPath, seq = 0, lastError = null, timer = null;
  // 596 (B6): a folder the page chose (a Dockerfile's) — replaced by the next one, never over a typed or picked folder.
  let autoPath = null;
  const path = h('input', { type: 'text', name: 'workspace', 'data-ws-path': '', placeholder: '~/Developer/dozer-sandbox-projects/NAME',
                            autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Workspace folder' });
  path.value = initialPath;
  const note = h('small', { class: 'ws-note', 'data-ws-note': '', 'aria-live': 'polite' });
  const choose = h('button', { type: 'button', class: 'btn small', 'data-ws-choose': '', title: 'Opens the Mac’s folder picker (New Folder allowed)' },
    withIcon('folder', 'Choose…'));
  const segs = {};
  const seg = (m, label, icon) => (segs[m] = h('button', { type: 'button', class: 'seg', 'data-ws-seg': m, on: { click: () => setMode(m) } }, withIcon(icon, label)));
  const control = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Workspace' }, seg('shared', 'Shared folder', 'folder'), seg('isolated', 'Isolated', 'shield'));
  const shared = h('div', { class: 'ws-shared' }, h('div', { class: 'ws-row' }, path, choose), note);
  const isolatedNote = h('small', { class: 'ws-isolated-note', 'data-ws-isolated': '' }, ISOLATED_NOTE);
  const el = h('div', { class: 'field ws-field', 'data-ws-mode': mode },
    h('span', null, 'Workspace'), control, shared, isolatedNote);
  function setMode(m) {
    mode = m;
    el.dataset.wsMode = m;
    for (const [k, b] of Object.entries(segs)) { b.classList.toggle('active', k === m); b.setAttribute('aria-pressed', k === m ? 'true' : 'false'); }
    shared.hidden = m !== 'shared';
    isolatedNote.hidden = m !== 'isolated';
  }
  function say(r) {
    lastError = r.error || null;
    note.classList.toggle('error', !!r.error);
    note.dataset.wsState = r.error ? 'error' : r.willCreate ? 'create' : r.exists ? 'exists' : '';
    note.textContent = r.error ? r.error : r.willCreate ? 'Will be created (with any missing folders above it) when the sandbox is.'
      : r.exists ? 'Exists — shared live at /workspace.' : '';
  }
  async function check(what = {}) {
    const my = ++seq;
    const body = {};
    const img = image();
    if (img) body.image = img;
    const n = name ? name() : nameInput ? nameInput.value.trim() : '';
    if (nameEdited && n) body.name = n;
    if (what.path !== undefined) body.path = what.path;
    let r;
    try { r = await api('workspace/check', { method: 'POST', json: body }); } catch (e) { if (my === seq) say({ error: e.message || String(e) }); return; }
    if (my !== seq) return;
    if (nameInput && !nameEdited) nameInput.value = r.suggestedName;
    if (!pathEdited) {
      path.value = r.defaultPath;
      if (what.path === undefined) return check({ path: path.value });
    } else if (what.path === undefined && autoPath && path.value.trim() === autoPath) {
      // 596: a name/image check superseded the chosen Dockerfile folder's own check — say that folder's state.
      return check({ path: autoPath });
    }
    if (what.path !== undefined) say(r);
  }
  const later = (f) => { clearTimeout(timer); timer = setTimeout(f, 250); };
  if (nameInput) nameInput.addEventListener('input', () => { nameEdited = true; if (!pathEdited) later(() => check()); });
  path.addEventListener('input', () => { pathEdited = true; autoPath = null; later(() => check({ path: path.value.trim() })); });
  choose.addEventListener('click', async () => {
    choose.disabled = true;
    try {
      const r = await api('workspace/choose', { method: 'POST', json: path.value.trim() ? { start: path.value.trim() } : {} });
      if (r && r.path) { path.value = r.path; pathEdited = true; autoPath = null; await check({ path: r.path }); }
    } catch (e) { toast(e.message || String(e), true); } finally { choose.disabled = false; }
  });
  setMode(mode);
  if (pathEdited) check({ path: path.value.trim() }); else check();
  return {
    el,
    /// The image changed: a name not typed in follows it (and the folder, the name).
    imageChanged() { if (!nameEdited || !pathEdited) check(); },
    /// 596 (B6): a Dockerfile was chosen — its folder becomes the workspace unless the person set one.
    suggest(p) {
      if (!p || (pathEdited && path.value.trim() !== autoPath)) return false;
      autoPath = p;
      pathEdited = true;
      path.value = p;
      check({ path: p });
      return true;
    },
    get path() { return path.value.trim(); },
    /// {isolated: true} or {workspace} — or an Error with why not.
    get() {
      if (mode === 'isolated') return { isolated: true };
      const p = path.value.trim();
      if (!p) throw new Error('Give the folder to share at /workspace (Choose…), or pick Isolated.');
      if (lastError) throw new Error('Workspace: ' + lastError);
      return { workspace: p };
    },
  };
}
// ── 596: the image of a new sandbox — Agent × Base ────────────────────────────
// Owner (2026-09-30): "more options in New Sandbox ui page for the base image … recommended base images
// … Dockerfile (requires `container build` which should be installed on-demand) … [COMING SOON] Deck
// Stack Recipes". Two choices (B1): the AGENT (Claude Code · pi · none) and the BASE — Recommended (a
// card per catalogue base), Dockerfile (Choose Dockerfile… is the Mac's own file picker; its folder
// becomes the workspace unless one was set; built with Apple's container build, OUTSIDE Dozer's network
// policy — said on the card), DeckStack recipe (disabled, coming soon) — or a Template (a saved disk).
// The image a pair makes is named as the host names it: claude-code / pi / lab keep their names.
const AGENTS = [['claude-code', 'Claude Code'], ['pi', 'pi'], ['none', 'none']];
/// B9, the same words as the server's (`Dockerfiles.outsidePolicyNote`).
const DOCKERFILE_POLICY_NOTE = 'Dockerfile builds run in Apple’s builder (container build), OUTSIDE Dozer’s network policy: its RUN steps reach the internet directly, without Dozer’s proxy or allow list. The sandbox made from the image is under the policy as usual.';
function imageNameOf(base, agent) {
  if (base === 'node' && agent === 'claude-code') return 'claude-code';
  if (base === 'node' && agent === 'pi') return 'pi';
  if (base === 'alpine' && agent === 'none') return 'lab';
  return agent === 'none' ? base : base + '-' + agent;
}
function parseImageName(name, baseIDs) {
  if (name === 'claude-code') return { base: 'node', agent: 'claude-code' };
  if (name === 'pi') return { base: 'node', agent: 'pi' };
  if (name === 'lab') return { base: 'alpine', agent: 'none' };
  for (const a of ['claude-code', 'pi']) if (name.endsWith('-' + a) && baseIDs.includes(name.slice(0, -a.length - 1))) return { base: name.slice(0, -a.length - 1), agent: a };
  return baseIDs.includes(name) ? { base: name, agent: 'none' } : null;
}
function imagePicker({ images = [], bases = null, value = 'claude-code', dockerfile = '', onChange = () => {}, onDockerfile = () => {} }) {
  const catalogue = bases ? bases.bases : [];
  const ids = catalogue.map((b) => b.id);
  const templates = images.filter((i) => i.kind === 'custom');
  const parsed = parseImageName(value, ids);
  let agent = parsed ? parsed.agent : 'claude-code', base = parsed ? parsed.base : 'node';
  let kind = dockerfile ? 'dockerfile' : parsed || !templates.some((t) => t.name === value) ? 'recommended' : 'template';
  let template = templates.some((t) => t.name === value) ? value : (templates[0] ? templates[0].name : '');
  let builder = bases ? bases.builder : { state: 'missing', note: '', startNote: '', installNote: '' };
  let notNow = false;
  const changed = () => { paint(); onChange(); };
  // Agent.
  const agentSegs = {};
  const agentCtl = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Agent', 'data-agent-choice': '' },
    AGENTS.map(([a, label]) => (agentSegs[a] = h('button', { type: 'button', class: 'seg', 'data-agent': a, on: { click: () => { agent = a; changed(); } } },
      withIcon(a === 'none' ? 'terminal' : 'rocket', label)))));
  // Base kind.
  const kindSegs = {};
  const kindSeg = (k, label, ic, extra = {}) => (kindSegs[k] = h('button', { type: 'button', class: 'seg', 'data-base-kind': k, ...extra,
    on: { click: () => { if (!extra.disabled) { kind = k; changed(); } } } }, withIcon(ic, label)));
  const kindCtl = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Base' },
    kindSeg('recommended', 'Recommended', 'star'), kindSeg('dockerfile', 'Dockerfile', 'box'),
    kindSeg('deckstack', 'DeckStack recipe', 'layers', { disabled: true, 'aria-disabled': 'true', title: 'Coming soon' }),
    templates.length ? kindSeg('template', 'Template', 'layout-template') : null);
  // Recommended: a card per base.
  const cards = {};
  const grid = h('div', { class: 'base-grid', role: 'radiogroup', 'aria-label': 'Recommended bases', 'data-base-grid': '' },
    catalogue.map((b) => (cards[b.id] = h('button', { type: 'button', class: 'base-card', role: 'radio', 'data-base': b.id,
      on: { click: () => { base = b.id; changed(); } } },
      h('span', { class: 'base-title' }, b.title),
      h('span', { class: 'base-use' }, b.useCase),
      h('code', { class: 'base-ref' }, b.reference),
      h('span', { class: 'base-meta', 'data-base-meta': '' }, '↓ ' + bytes(b.downloadBytes) + ' · first prepare ~' + Math.max(1, Math.round(b.prepareSeconds / 60)) + ' min'),
      h('span', { class: 'base-prepared', 'data-base-prepared': '' }),
      b.updateAvailable ? h('span', { class: 'tag ver-available' }, 'update available') : null))));
  // Dockerfile.
  const dfPath = h('input', { type: 'text', name: 'dockerfile', 'data-dockerfile-path': '', placeholder: '~/code/app/Dockerfile', autocomplete: 'off',
                              spellcheck: 'false', 'aria-label': 'Dockerfile' });
  dfPath.value = dockerfile;
  const dfChoose = h('button', { type: 'button', class: 'btn small', 'data-dockerfile-choose': '', title: 'Opens the Mac’s file picker' },
    withIcon('folder', 'Choose Dockerfile…'));
  const policyNote = h('div', { class: 'df-policy', role: 'note', 'data-dockerfile-policy': '' }, icon('shield'), ' ', bases ? bases.outsidePolicy : '');
  const builderBox = h('div', { class: 'df-builder', 'data-builder': '' });
  const dfPanel = h('div', { class: 'df-panel' },
    h('div', { class: 'ws-row' }, dfPath, dfChoose),
    h('small', { class: 'muted' }, 'Dozer builds it with Apple’s container build, then adds the developer baseline and the agent — your Dockerfile need not install Claude Code. Its folder is the build context, and the workspace unless you set one.'),
    policyNote, builderBox);
  const dfTell = () => { onDockerfile(dfPath.value.trim() ? dfPath.value.trim().replace(/\/[^/]*$/, '') || '/' : ''); };
  dfPath.addEventListener('input', () => { onChange(); });
  dfPath.addEventListener('change', dfTell);
  dfChoose.addEventListener('click', async () => {
    dfChoose.disabled = true;
    try {
      const r = await api('dockerfile/choose', { method: 'POST', json: dfPath.value.trim() ? { start: dfPath.value.trim() } : {} });
      if (r && r.path) { dfPath.value = r.path; onDockerfile(r.folder); onChange(); }
    } catch (e) { toast(e.message || String(e), true); } finally { dfChoose.disabled = false; }
  });
  async function refreshBuilder() {
    try { const b = await api('bases'); builder = b.builder; } catch (_) { /* keep */ }
    paint(); onChange();
  }
  function paintBuilder() {
    const s = builder.state;
    const kids = [h('p', { class: 'df-state', 'data-builder-state': s }, icon(s === 'ready' ? 'check' : 'box'), ' ', builder.note)];
    if (notNow && s !== 'ready') {
      kids.push(h('p', { class: 'muted', 'data-builder-notnow': '' }, 'Dockerfile images are unavailable until Apple’s container tool is ' + (s === 'stopped' ? 'running' : 'installed') + ' — or choose a recommended base.'),
        btn('Set it up now…', () => { notNow = false; paint(); onChange(); }, { small: true, icon: 'settings' }));
    } else if (s === 'stopped') {
      kids.push(h('p', { class: 'muted' }, builder.startNote),
        h('div', { class: 'actions' },
          btn('Start its services', async () => { try { await actOrThrow({ action: 'builder-start' }); await waitOps(); } catch (e) { toast(e.message || String(e), true); } refreshBuilder(); },
            { small: true, primary: true, icon: 'play' }),
          btn('Not now', () => { notNow = true; paint(); onChange(); }, { small: true, icon: 'x' })));
    } else if (s !== 'ready') {
      kids.push(h('p', { class: 'muted' }, builder.installNote),
        h('div', { class: 'actions' },
          btn('Install Apple’s container tool…', async () => { try { await actOrThrow({ action: 'builder-install' }); } catch (e) { toast(e.message || String(e), true); } setTimeout(refreshBuilder, 1500); },
            { small: true, primary: true, icon: 'download' }),
          btn('Not now', () => { notNow = true; paint(); onChange(); }, { small: true, icon: 'x' })));
    }
    builderBox.replaceChildren(...kids);
  }
  // DeckStack (B11) and templates.
  const deckPanel = h('div', { class: 'base-card soon', 'aria-disabled': 'true', 'data-deckstack': '' },
    h('span', { class: 'base-title' }, 'DeckStack recipes'), h('span', { class: 'base-use' }, bases ? bases.deckstack : 'Coming soon.'));
  const tplSelect = h('select', { name: 'template', 'aria-label': 'Template' }, templates.map((t) => h('option', { value: t.name }, t.name + (t.fromSandbox ? ' (from ' + t.fromSandbox + ')' : ''))));
  tplSelect.value = template;
  tplSelect.addEventListener('change', () => { template = tplSelect.value; onChange(); });
  const tplPanel = h('div', { class: 'tpl-panel' }, tplSelect, h('small', { class: 'muted' }, 'A template is a saved root disk: its base and agent are the ones it was saved from.'));
  const summary = h('small', { class: 'muted image-summary', 'data-image-summary': '' });
  // The image by its name, too (hidden): what a script or an older page names — setting it moves the choices.
  const names = [...new Set(['claude-code', 'pi', 'lab', ...catalogue.flatMap((b) => AGENTS.map(([a]) => imageNameOf(b.id, a))), ...templates.map((t) => t.name)])];
  const byName = h('select', { name: 'image', hidden: true, 'aria-hidden': 'true', tabindex: '-1' }, names.map((n) => h('option', { value: n }, n)));
  byName.addEventListener('change', () => {
    const p = parseImageName(byName.value, ids.length ? ids : ['node', 'alpine']);
    if (p) { agent = p.agent; base = p.base; kind = 'recommended'; } else if (templates.some((t) => t.name === byName.value)) { kind = 'template'; template = byName.value; tplSelect.value = template; }
    changed();
  });
  function paint() {
    for (const [a, b] of Object.entries(agentSegs)) { b.classList.toggle('active', a === agent); b.setAttribute('aria-pressed', a === agent ? 'true' : 'false'); b.disabled = kind === 'template'; }
    for (const [k, b] of Object.entries(kindSegs)) { b.classList.toggle('active', k === kind); b.setAttribute('aria-pressed', k === kind ? 'true' : 'false'); }
    for (const [id, c] of Object.entries(cards)) {
      c.classList.toggle('active', id === base);
      c.setAttribute('aria-checked', id === base ? 'true' : 'false');
      const b = catalogue.find((x) => x.id === id);
      c.querySelector('[data-base-prepared]').textContent = b && b.prepared.includes(agent) ? 'prepared' : '';
    }
    grid.hidden = kind !== 'recommended';
    dfPanel.hidden = kind !== 'dockerfile';
    deckPanel.hidden = kind !== 'deckstack';
    tplPanel.hidden = kind !== 'template';
    paintBuilder();
    const b = catalogue.find((x) => x.id === base);
    const now = kind === 'template' ? template : kind === 'dockerfile' ? null : imageNameOf(base, agent);
    if (now && [...byName.options].some((o) => o.value === now)) byName.value = now;
    summary.textContent = kind === 'template' ? 'Template ' + template
      : kind === 'dockerfile' ? 'Your Dockerfile · ' + (AGENTS.find((x) => x[0] === agent) || [0, agent])[1]
      : (b ? b.title : base) + ' · ' + (AGENTS.find((x) => x[0] === agent) || [0, agent])[1] + ' — image ' + imageNameOf(base, agent);
  }
  paint();
  const el = h('div', { class: 'field image-picker' },
    h('span', null, 'Agent'), agentCtl,
    h('span', null, 'Base'), kindCtl, grid, dfPanel, deckPanel, tplPanel, summary, byName);
  return {
    el,
    /// The image name the host is sent (a Dockerfile's: the agent's carrier — the host names it by its file).
    image() { return kind === 'template' ? template : kind === 'dockerfile' ? (agent === 'none' ? 'lab' : agent) : imageNameOf(base, agent); },
    /// The agent a sandbox of it runs (for the account's choice).
    agent() {
      if (kind === 'template') { const t = templates.find((x) => x.name === template); return t ? AGENT_NAMES[t.agent] ? t.agent : (parseImageName(t.agent || '', ids) || {}).agent : null; }
      return agent === 'none' ? null : agent;
    },
    dockerfile() { return kind === 'dockerfile' ? dfPath.value.trim() : null; },
    /// 597: the catalogue base (a Dockerfile's: '', a template's: null) — its permissions' Standard.
    base() { return kind === 'recommended' ? base : kind === 'dockerfile' ? '' : null; },
    /// Why Create cannot go ahead now (null: it can).
    blocked() {
      if (kind === 'deckstack') return 'DeckStack recipes are coming soon.';
      if (kind === 'template' && !template) return 'No template to start from.';
      if (kind !== 'dockerfile') return null;
      if (!dfPath.value.trim()) return 'Choose the Dockerfile (Choose Dockerfile…), or type its path.';
      if (notNow && builder.state !== 'ready') return 'Dockerfile images are unavailable until Apple’s container tool is ' + (builder.state === 'stopped' ? 'running.' : 'installed.');
      return null;
    },
  };
}
/// What a new sandbox's suggested name follows: the image, or for a Dockerfile "dockerfile-claude" (→ dockerfile-claude-sandbox).
function pickerNameHint(picker) {
  if (picker.dockerfile() === null) return picker.image();
  const a = picker.agent();
  return 'dockerfile' + (a === 'claude-code' ? '-claude' : a ? '-' + a : '');
}
/// Wait (briefly) for the operations this page started to end.
async function waitOps(max = 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < max && [...state.ops.values()].some((o) => o.state === 'running' && o.action && o.action.startsWith('builder-'))) {
    await new Promise((r) => setTimeout(r, 400));
  }
}

/// A destructive action: the person types the name; the request carries it as `confirm`.
function confirmAction(title, text, name, body) {
  dialog(title, text, [], title, async () => {
    const op = await actOrThrow({ ...body, confirm: name });
    return op;
  }, { danger: true, confirmName: name });
}
async function actOrThrow(body) {
  beginTransition(body.sandbox, body.action);
  let op;
  try { op = await api('actions', { method: 'POST', json: body }); } catch (e) { endTransition(body.sandbox, body.action); throw e; }
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
  $('version').textContent = 'doz ' + info.version;
  document.title = 'Dozer — ' + info.store.split('/').pop();
  $('sign-out').hidden = false;
  scheduleRenew();
}
// ── settings (591) ──────────────────────────────────────────────────────────
// doz.toml, as the UI process reads it (GET /api/v1/settings, every value with its default, source and
// description). A change is one typed, CSRF-checked POST {key, value} or {key, reset: true}; the
// server checks the key against its closed schema and the value against the key's type and range,
// writes the file, and answers the new report — the page re-reads it, so a ui.* setting applies at once.
function setting(key, fallback) {
  const r = state.settings && state.settings.byKey[key];
  return r ? r.value : fallback;
}
function adoptSettings(report) {
  state.settings = { report, byKey: Object.fromEntries(report.settings.map((r) => [r.key, r])) };
  const theme = setting('ui.theme', 'auto');
  if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
  else delete document.documentElement.dataset.theme;
  const split = setting('ui.split_default', 'shell');
  termUI.splitKind = SPLIT_KINDS[split] ? split : 'shell';
  paintSplitButton();
}
async function loadSettings() {
  try { adoptSettings(await api('settings')); } catch (_) { /* the defaults, until the next read */ }
}
async function saveSetting(key, value) { adoptSettings(await api('settings', { method: 'POST', json: { key, value } })); }
async function resetSetting(key) { adoptSettings(await api('settings', { method: 'POST', json: { key, reset: true } })); }

const SETTING_SECTIONS = {
  ui: 'This UI', host: 'The host', store: 'The store', claude: 'Claude Code', defaults: 'New sandboxes', agent: 'The agent', sandbox: 'Inside every sandbox',
  'images.lab': 'New lab sandboxes', 'images.claude-code': 'New claude-code sandboxes', 'images.pi': 'New pi sandboxes', kernel: 'The kernel',
};
function shownValue(v) { return typeof v === 'string' ? (v === '' ? '""  (automatic)' : v) : String(v); }
async function viewSettings() {
  adoptSettings(await api('settings'));
  const rep = state.settings.report;
  const sections = [];
  for (const r of rep.settings) {
    let s = sections.find((x) => x.name === r.section);
    if (!s) sections.push(s = { name: r.section, rows: [] });
    s.rows.push(r);
  }
  const warnings = rep.warnings.filter((w) => !rep.error || !w.startsWith(rep.error));
  return h('div', null, h('h1', null, 'Settings'),
    h('p', { class: 'sub' }, 'Written to ', h('code', null, rep.path || 'no file (neither XDG_CONFIG_HOME nor HOME is set)'),
      rep.exists ? '' : ' — not written yet: the first change writes it, with every setting listed at its default',
      '. A command-line flag wins, then the environment, then this file, then the default; ', h('code', null, 'doz config show'), ' prints the same.'),
    rep.error ? h('div', { class: 'notice bad' }, rep.error + ' — nothing in it applies, and the UI will not overwrite it. Fix it (or remove it) first.') : null,
    warnings.length ? h('div', { class: 'notice' }, h('ul', { class: 'plain' }, warnings.map((w) => h('li', null, w)))) : null,
    sections.flatMap((sec) => [
      h('h2', null, SETTING_SECTIONS[sec.name] || sec.name, ' ', h('code', { class: 'muted' }, '[' + sec.name + ']')),
      h('div', { class: 'panel settings' }, sec.rows.map(settingRow)),
    ]),
    h('h2', null, 'Not settable, by design'),
    panel(h('ul', { class: 'plain' }, rep.notSettable.map((n) => h('li', null, n)))));
}
function settingRow(r) {
  const source = h('span', { class: 'pill src src-' + r.source, title: r.source === 'file' ? 'set in the file' : r.source === 'default' ? 'not set: the default' : (r.note || '') },
    r.source === 'env' ? 'env ' + r.environment : r.source);
  const reset = r.editable && r.source === 'file'
    ? btn('Default', () => changeSetting(r.key, null), { small: true, title: 'Comment it out in the file: the default (' + shownValue(r.defaultValue) + ') applies' }) : null;
  return h('div', { class: 'setting', 'data-key': r.key },
    h('div', { class: 'setting-main' },
      h('div', { class: 'setting-name' }, h('code', null, r.name), ' ', source),
      h('div', null, r.description),
      h('div', { class: 'muted setting-meta' }, 'default ', h('code', null, shownValue(r.defaultValue)), ' · ', r.appliesNote,
        r.note ? h('div', null, r.note) : null)),
    h('div', { class: 'setting-control' }, settingControl(r), reset));
}
function settingControl(r) {
  if (!r.editable) return h('code', { class: 'setting-value', title: r.note || '' }, shownValue(r.value));
  let input;
  if (r.type === 'bool') {
    input = h('input', { type: 'checkbox', 'aria-label': r.key });
    input.checked = r.value === true;
    input.addEventListener('change', () => changeSetting(r.key, input.checked));
  } else if (r.type === 'choice') {
    input = h('select', { 'aria-label': r.key }, r.choices.map((c) => {
      const o = h('option', { value: c }, c);
      if (c === r.value) o.selected = true;
      return o;
    }));
    input.addEventListener('change', () => changeSetting(r.key, input.value));
  } else if (r.type === 'permissions') {
    // 597 (P4): the default permissions of new sandboxes — the same switches (on a base with no
    // language of its own; a base's ecosystem joins Standard for it), saved as words on Standard.
    input = h('div', { class: 'perm-setting', 'data-perm-setting': '' }, h('span', { class: 'muted' }, '…'));
    api('bases').then((b) => {
      const std = new Set(b.standard[''] || []);
      let on = new Set(b.defaults[''] || []);
      const all = b.permissions.map((x) => x.id);
      const words = () => {
        const same = (a, c) => a.size === c.size && [...a].every((x) => c.has(x));
        if (same(on, std)) return 'standard';
        if (same(on, new Set(['model']))) return 'locked';
        if (same(on, new Set(all))) return 'open';
        return [...all.filter((x) => on.has(x) && !std.has(x)).map((x) => '+' + x), ...all.filter((x) => !on.has(x) && std.has(x)).map((x) => '-' + x)].join(',');
      };
      const paint = () => input.replaceChildren(h('code', { 'data-perm-words': '' }, words()),
        permissionSwitches(b.permissions, on, (id, v) => {
          const apply = () => {
            const inst = b.permissions.filter((x) => x.group === 'install').map((x) => x.id);
            for (const x of id === 'install' ? inst : [id]) { if (v) on.add(x); else on.delete(x); }
            changeSetting(r.key, words());
          };
          if (id === 'web' && v) confirmWeb(async () => apply()); else apply();
        }, { hosts: false }));
      paint();
    }).catch(() => input.replaceChildren(h('code', null, String(r.value))));
  } else if (r.type === 'int') {
    input = h('input', { type: 'number', min: String(r.min), max: String(r.max), step: '1', 'aria-label': r.key });
    input.value = String(r.value);
    input.addEventListener('change', () => {
      const n = Number(input.value);
      if (!isInt(n, r.min, r.max)) { toast(r.key + ' is a whole number, ' + r.min + '–' + r.max, true); input.value = String(r.value); return; }
      changeSetting(r.key, n);
    });
  } else {
    input = h('input', { type: 'text', spellcheck: 'false', autocomplete: 'off', 'aria-label': r.key, placeholder: '"" = automatic' });
    input.value = String(r.value);
    input.addEventListener('change', () => changeSetting(r.key, input.value.trim()));
  }
  return input;
}
async function changeSetting(key, value) {
  try {
    if (value === null) await resetSetting(key); else await saveSetting(key, value);
    toast(key + (value === null ? ' is the default again' : ' saved'), false);
  } catch (e) {
    toast(e.message || String(e), true);
  }
  refresh(false);
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
  // 591: the server closes this session's terminals; the page forgets them.
  gridLeave();
  for (const t of [...terminals.values()]) closeTerminal(t.id);
  $('sbx').hidden = true;
  $('grid').hidden = true;
  $('view').hidden = false;
  const view = $('view');
  view.replaceChildren(h('div', { class: 'signed-out' },
    h('h1', null, 'Sign in with a new link'),
    h('p', { class: 'sub' }, message || 'This page is not signed in.'),
    h('p', null, 'In a terminal on this Mac, run ', h('code', null, 'doz ui link'),
      ' — it opens a fresh one-use link. (If the UI is not running: ', h('code', null, 'doz ui'), '.)'),
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
// ── 594 W18: the host and the doz ui server, watched ─────────────────────────
// The footer holds two facts: this page's link to the `doz ui` server (#live) and the host's state and
// build (#host-live). A banner says each transition once: the host stopped (hibernated), died (its
// sandboxes shut down), came back as another build; doz ui stopped (the page retries on its own).
function banner(key, kind, parts, actions = []) {
  const box = $('banners');
  const el = h('div', { class: 'banner' + (kind ? ' ' + kind : ''), 'data-banner': key, role: kind === 'bad' ? 'alert' : 'status' },
    h('div', { class: 'b-text' }, parts),
    h('div', { class: 'b-acts' }, ...actions,
      h('button', { type: 'button', class: 'b-x', title: 'Dismiss', 'aria-label': 'Dismiss', on: { click: () => el.remove() } }, '×')));
  const old = box.querySelector('[data-banner="' + key + '"]');
  if (old) old.replaceWith(el); else box.append(el);
  return el;
}
function dropBanner(key) {
  const el = $('banners').querySelector('[data-banner="' + key + '"]');
  if (el) el.remove();
}
function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }
function sandboxLinks(names) {
  return names.map((n) => h('a', { href: '#/sandbox/' + n, 'data-sandbox-link': n }, n));
}
/// The host's fact in the footer: from the last overview, or — while doz ui is away — what the page last
/// knew, said as such.
function renderHostFoot() {
  const el = $('host-live');
  if (!el) return;
  const host = state.overview && state.overview.host;
  let kind = '', text = '—';
  if (host) {
    const died = state.hostChange && state.hostChange.state === 'died' && !host.running;
    if (host.running) { kind = 'on'; text = 'running · doz ' + (host.version || '?'); }
    else if (died) { kind = 'bad'; text = 'died'; }
    else { kind = 'warn'; text = 'stopped'; }
  }
  if (state.uiDown) { text = host ? 'last seen ' + text : 'unknown'; kind += ' stale'; }
  el.className = 'live' + (kind ? ' ' + kind : '');
  el.dataset.host = host ? (host.running ? 'running' : (state.hostChange && state.hostChange.state === 'died' ? 'died' : 'stopped')) : '';
  $('host-text').textContent = text;
  // One note, once per pair of builds: this UI and the host it talks to differ. 594 W20: the server
  // compares them and advises the OLDER side (a host older than this UI: stop it — Restart host).
  const note = host && host.running && host.versionNote;
  if (note && !state.uiDown) {
    const pair = host.uiVersion + '|' + host.version;
    let seen = state.versionNoted === pair;
    try { seen = seen || localStorage.getItem('doz.versionNoted') === pair; } catch (_) { /* no storage: once per page */ }
    if (!seen) {
      state.versionNoted = pair;
      try { localStorage.setItem('doz.versionNoted', pair); } catch (_) { /* */ }
      banner('version', 'warn', [note.text], note.older === 'host' ? [restartHostButton(host)] : []);
    }
  } else if (host && host.running && !host.versionNote) {
    dropBanner('version');
  }
}
/// 594 W20: an OLDER host — stop it (its sandboxes hibernate, and wake when used) and start this UI's
/// build. The server refuses it unless the host is older.
function restartHostButton(host) {
  return btn('Restart host', () => {
    // What runs NOW (the banner may be older than the last overview).
    host = (state.overview && state.overview.host) || host;
    const live = host.liveSandboxes || [];
    dialog('Restart the host?',
      'The host (doz ' + host.version + ') stops and doz ' + host.uiVersion + ' starts in its place. ' +
      (live.length ? 'Its running sandboxes (' + live.join(', ') + ') hibernate first — sessions kept — and wake when you use them.'
                   : 'No sandbox is running.'),
      [], 'Restart host', async () => { await actOrThrow({ action: 'host-restart' }); dropBanner('version'); }, { icon: 'rotate-ccw' });
  }, { small: true, primary: true, icon: 'rotate-ccw', title: 'Stop the older host and start doz ' + host.uiVersion });
}
function startHostButton() {
  return btn('Start host', async (ev) => {
    ev.currentTarget.disabled = true;
    await act({ action: 'host-start' });
  }, { small: true, primary: true, icon: 'play', title: 'Starts the store’s host the normal way (detached, as the CLI does)' });
}
/// SSE `host`: one transition of the host.
function hostChanged(c) {
  state.hostChange = c;
  const n = c.sandboxes.length;
  if (c.state === 'running') {
    dropBanner('host-stopped');
    if (c.previousVersion) {
      banner('host-build', '', ['The host is now ', h('code', null, 'doz ' + c.version), ' (was ', h('code', null, c.previousVersion), ').']);
    }
  } else if (c.state === 'stopped') {
    const why = c.reason ? ' (' + c.reason + ')' : '';
    banner('host-stopped', 'warn', n
      ? ['The doz host stopped' + why + ' — your sandboxes were hibernated: ', ...sandboxLinks(c.sandboxes),
         h('span', { class: 'muted' }, ' Waking one starts a host again, as the CLI does.')]
      : ['The doz host stopped' + why + '. Nothing was running. ', h('span', { class: 'muted' }, 'Any action starts a host again, as the CLI does.')],
      [startHostButton()]);
  } else {
    banner('host-died', 'bad', n
      ? ['The doz host died — ' + plural(n, 'sandbox was', 'sandboxes were') + ' running; ' + (n === 1 ? 'it is' : 'they are') +
         ' shut down (restart ' + (n === 1 ? 'it' : 'them') + '): ', ...sandboxLinks(c.sandboxes)]
      : ['The doz host died (killed or crashed). No sandbox was running.'],
      state.overview && state.overview.host.running ? [] : [startHostButton()]);
  }
  // Every page's phases follow at once (the grid and the sandbox pages too).
  refreshNav();
  liveRefresh();
}
/// What a live change re-renders: not Settings (a half-typed value), Operations (its own events) or the
/// onboarding wizard (its own), nor a page whose masked key field is being filled in.
function liveRefresh() {
  const typing = [...document.querySelectorAll('[data-secret]')].some((e) => e.value);
  if (state.view !== 'settings' && state.view !== 'operations' && state.view !== 'onboarding' && !typing) refresh(false);
}
/// The doz ui server went away (it said so, or the stream broke): keep what the page shows, say so, and
/// retry — the next doz ui listens on the same port when it can and keeps its pages' sessions (594 W19:
/// `<store>/ui.sessions`), so the page finds it by itself, still signed in. When the session did not carry
/// over (another port, `--new-link`, expired) the page asks for a new link.
///
/// 594 W21 (owner: "show an overlay over the entire web ui when its disconnected because navigating
/// anywhere or attempting to restart sandboxes wont work anyway"): after ~1.5 s of failed reconnects —
/// never on a momentary blip — the page is PAUSED: everything but the banner strip is `inert` and dimmed
/// under an overlay (role alertdialog, focus moved into it). The banner strip stays in front of it and
/// live (owner: "i still like the info banners at the top"): the banner says WHAT happened (doz ui
/// stopped); the overlay says the page is paused and reconnecting, what to do, and holds the one Try now.
/// The HOST stopping is never this: the page still works then (a banner; Start host).
const UI_OVERLAY_AFTER_MS = 1500;
function uiLost(said) {
  if (state.signedOut) return;
  if (state.es) { state.es.close(); state.es = null; }
  state.uiDown = true;
  state.uiSaid = state.uiSaid || said;
  setLive('bad', said ? 'stopped — retrying' : 'reconnecting…');
  renderHostFoot();
  if (!state.uiDownSince) {
    state.uiDownSince = Date.now();
    state.lastConnected = state.uiDownSince;   // connected until this moment
  }
  if (state.uiRetry) return;
  state.uiRetry = setTimeout(uiRetryTick, said ? 400 : 250);
}
function hostLastKnown() {
  const host = state.overview && state.overview.host;
  if (!host) return 'The page never heard from the host.';
  if (host.running) {
    const n = host.liveSandboxes.length;
    return 'The host was running (doz ' + (host.version || '?') + (n ? ', ' + plural(n, 'sandbox', 'sandboxes') + ' live' : '') +
      ') as far as this page knows — doz ui stopping does not stop it.';
  }
  return 'The host was not running when this page last heard.';
}
async function uiRetryTick() {
  clearTimeout(state.uiRetry);
  state.uiRetry = null;
  if (state.signedOut) return;
  let r = null;
  try { r = await fetch('/api/v1/session', { credentials: 'same-origin', cache: 'no-store' }); } catch (_) { /* not listening */ }
  if (state.signedOut || !state.uiDown) return;
  if (r && r.ok) {
    // doz ui is back and this page is still signed in (594 W19: a restarted doz ui keeps its pages'
    // sessions on the same port) — or the stream only broke: carry on, silently.
    try { adopt(await r.json()); } catch (_) { /* the session stands; its details next time */ }
    uiBack();
    connect();
    return;
  }
  if (r && r.status === 401) {
    // doz ui is back, but this page's session did not carry over (a new link was made, the port
    // changed, or the session expired): say so — never hang on "reconnecting".
    const msg = 'doz ui restarted, and this page’s sign-in did not carry over (a new link was made, or it listens on another port). Open the new link: run doz ui link.';
    if (state.uiOverlay) uiOverlaySignedOut();
    else uiBack();
    signedOut(msg);
    return;
  }
  // Still away.
  if (Date.now() - state.uiDownSince >= UI_OVERLAY_AFTER_MS) showUiOverlay(); else updateUiOverlay();
  state.uiRetry = setTimeout(uiRetryTick, state.uiOverlay ? 1000 : 400);
}
/// Everything but the banner strip: the sidebar and main's other children (an inert ancestor would
/// take the banners with it).
function pausedParts() {
  return [document.querySelector('.side'), ...[...$('main').children].filter((e) => e.id !== 'banners')];
}
function showUiOverlay() {
  if (state.uiOverlay) { updateUiOverlay(); return; }
  state.uiOverlay = true;
  banner('ui-stopped', 'bad', [(state.uiSaid ? 'The doz ui process stopped' : 'This page lost its doz ui server') +
    ' (last connected ' + clock(state.lastConnected) + ').']);
  for (const el of pausedParts()) el.inert = true;
  document.body.classList.add('ui-paused');
  const o = $('ui-overlay');
  buildUiOverlay();
  $('ui-ov-host').textContent = hostLastKnown();
  o.setAttribute('role', 'alertdialog');
  o.setAttribute('aria-modal', 'true');
  o.setAttribute('aria-labelledby', 'ui-ov-title');
  o.setAttribute('aria-describedby', 'ui-ov-desc');
  o.hidden = false;
  updateUiOverlay();
  $('ui-try-now').focus();
}
/// Built while doz ui still answers (on `hello`): the button's icon is a `<use>` of the served sprite,
/// which a page that has lost its server can no longer fetch.
function buildUiOverlay() {
  const o = $('ui-overlay');
  if (o.querySelector('#ui-try-now')) return;
  const tryNow = h('button', { type: 'button', class: 'btn primary', id: 'ui-try-now', on: { click: () => { updateUiOverlay('trying…'); uiRetryTick(); } } },
    withIcon('refresh-cw', 'Try now'));
  o.replaceChildren(h('div', { class: 'ui-ov-card' },
    h('div', { class: 'ui-ov-head' }, h('span', { class: 'ui-ov-spin', 'aria-hidden': 'true' }),
      h('h2', { id: 'ui-ov-title' }, 'Paused — reconnecting to doz ui…')),
    h('div', { id: 'ui-ov-desc' },
      h('p', null, 'Nothing on this page works until it reconnects. Run ', h('code', null, 'doz ui'),
        ' in a terminal — this page reconnects by itself (same port), still signed in.'),
      h('p', { class: 'muted', id: 'ui-ov-when' }),
      h('p', { class: 'muted', id: 'ui-ov-host' })),
    h('div', { class: 'ui-ov-acts' }, tryNow)));
}
function updateUiOverlay(status) {
  const w = $('ui-ov-when');
  if (!w) return;
  const ago = state.lastConnected ? Math.round((Date.now() - state.lastConnected) / 1000) : null;
  w.textContent = 'Last connected ' + clock(state.lastConnected) + (ago != null ? ' (' + ago + ' s ago)' : '') + '. ' + (status || 'Retrying every second.');
}
/// The server came back with this page signed out (`--new-link`, another port): the overlay says so.
function uiOverlaySignedOut() {
  const o = $('ui-overlay');
  o.querySelector('.ui-ov-spin')?.remove();
  $('ui-ov-title').textContent = 'This page was signed out';
  $('ui-ov-desc').replaceChildren(
    h('p', null, 'doz ui is back, but this page’s sign-in did not carry over (a new link was made, or it listens on another port).'),
    h('p', null, 'Run ', h('code', null, 'doz ui link'), ' in a terminal — it opens a fresh one-use link.'));
  o.querySelector('.ui-ov-acts')?.remove();
  banner('ui-stopped', 'bad', ['doz ui restarted with a new link — this page is signed out.']);
  o.focus();
}
/// Reconnected: the overlay goes by itself; the page refreshes (on `hello`).
function uiBack() {
  state.uiDown = false;
  state.uiDownSince = null;
  state.uiSaid = false;
  clearTimeout(state.uiRetry);
  state.uiRetry = null;
  dropBanner('ui-stopped');
  if (!state.uiOverlay) return;
  state.uiOverlay = false;
  for (const el of pausedParts()) el.inert = false;
  document.body.classList.remove('ui-paused');
  $('ui-overlay').hidden = true;
  $('main').focus();
}

function connect() {
  if (state.signedOut) return;
  const es = new EventSource('/api/v1/stream');
  state.es = es;
  es.addEventListener('hello', async () => {
    setLive('on', 'live');
    uiBack();
    buildUiOverlay();
    try { for (const o of await api('operations')) state.ops.set(o.id, o); renderOps(); } catch (_) { /* */ }
    loadPreparations();
    refreshNav();
    refresh(true);
  });
  // The Settings page is not about the store's live state: re-rendering it would drop a half-typed
  // value; nor is Operations (its own events keep it current), nor the onboarding wizard (its own).
  es.addEventListener('changed', () => {
    refreshNav();
    liveRefresh();
  });
  // 594 W19: a line from doz ui itself ("doz ui restarted — 0.12.0-rc.4").
  es.addEventListener('notice', (ev) => { try { toast(JSON.parse(ev.data).text, false); } catch (_) { /* */ } });
  es.addEventListener('host', (ev) => { try { hostChanged(JSON.parse(ev.data)); } catch (_) { /* ignore a malformed line */ } });
  // 594: the host's image preparations, while any runs (and once when the last ends).
  es.addEventListener('preparations', (ev) => {
    try { state.preps = JSON.parse(ev.data); } catch (_) { return; }
    renderOps();
    if (state.view === 'onboarding') renderWizard();
  });
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
    if (reason === 'shutdown') { uiLost(true); return; }
    // 594 W19: `doz ui --new-link` / `doz ui link --rotate` ended every session.
    if (reason === 'rotated') { signedOut('A new link was made for this UI (doz ui --new-link, or doz ui link --rotate): every page signed out. Open the new link — or run doz ui link.'); return; }
    setTimeout(connect, 500);
  });
  // A broken stream (doz ui killed, the Mac asleep): the page's own retry, never the browser's
  // (which would hammer a new doz ui with a session it does not know).
  es.onerror = () => {
    if (state.signedOut || state.es !== es) return;
    uiLost(false);
  };
}
function notice(text, bad) {
  const n = $('notice');
  if (!text) { n.hidden = true; return; }
  n.hidden = false;
  n.className = 'notice' + (bad ? ' bad' : '');
  n.textContent = text;
}

// ── the nav: a child per sandbox (593) ──────────────────────────────────────
// From the overview (`ls` without session counts — never the guest's session holders), re-read on
// the stream's hello, on `changed`, and when an operation ends. Text only.
let navTimer = null;
function refreshNav() {
  clearTimeout(navTimer);
  navTimer = setTimeout(async () => {
    try { state.overview = await api('overview'); renderNavSandboxes(); } catch (_) { /* the last list */ }
  }, 300);
}
function renderNavSandboxes() {
  // 594 (owner: "add a link to Onboarding in the left nav"): a dot until this store is onboarded.
  if (state.overview) $('onb-dot').hidden = state.overview.onboarded !== false;
  renderHostFoot();
  const list = state.overview ? state.overview.sandboxes.slice().sort((a, b) => a.name.localeCompare(b.name)) : [];
  $('nav-sandboxes').replaceChildren(...list.map((s) => h('a', {
    href: '#/sandbox/' + s.name, class: 'nav-child' + (state.view === 'sandbox' && state.param === s.name ? ' active' : ''),
    role: 'listitem', 'data-sandbox': s.name, title: s.name + ' — ' + s.phaseLabel },
    h('span', { class: 'ph-dot ph-' + s.phase, 'aria-hidden': 'true' }), h('span', { class: 'nav-name' }, s.name))));
}
function paintNav() {
  for (const a of document.querySelectorAll('#nav > a')) {
    a.classList.toggle('active', a.dataset.view === state.view || (state.view === 'sandbox' && a.dataset.view === 'overview'));
  }
  renderNavSandboxes();
}

// ── routing ─────────────────────────────────────────────────────────────────
// #/VIEW, #/sandbox/NAME and #/sandbox/NAME/SESSION (a session addressed: its tab opened or selected).
function route() {
  const m = /^#\/([a-z]+)(?:\/([a-z0-9-]{1,40})(?:\/([A-Za-z0-9_-][A-Za-z0-9._-]{0,63}))?)?$/.exec(location.hash);
  if (m && m[1] === 'terminals') { location.replace('#/sessions'); return; }      // 591's name for the grid's place
  state.view = m ? m[1] : 'overview';
  state.param = m && m[2] ? m[2] : null;
  state.session = m && m[3] ? m[3] : null;
  if (state.view === 'sandbox' && !state.param) state.view = 'overview';
  paintNav();
  // 591: the terminals live in their own section, never re-rendered by refresh() (a live update
  // must not steal a terminal's focus or reparent its canvas). 593: that section is the sandbox
  // page's terminal area; the grid is a section of its own too.
  const onSbx = state.view === 'sandbox', onGrid = state.view === 'sessions';
  $('sbx').hidden = !onSbx;
  $('grid').hidden = !onGrid;
  $('view').hidden = onSbx || onGrid;
  $('main').classList.toggle('main-terms', onSbx);
  if (!onGrid) gridLeave();
  if (state.view !== 'operations') state.opsBox = null;
  if (state.view === 'operations') { acknowledgeOps(); loadPreparations(); }
  if (state.view !== 'onboarding') wizardStopPolling();
  if (state.view === 'images' || state.view === 'resources') remeasure();   // 595: measured on arrival, Refresh, an op's end
  if (onSbx) { showSandbox(); return; }
  if (onGrid) { gridEnter(); return; }
  refresh(true);
}
window.addEventListener('hashchange', () => { if (!state.signedOut) route(); });

let refreshing = false, again = false;
async function refresh(scrollTop) {
  if (state.signedOut) return;
  if (state.view === 'sandbox') { refreshSandbox(); return; }
  if (state.view === 'sessions') { gridRefresh(false); return; }
  if (refreshing) { again = true; return; }
  refreshing = true;
  try {
    const views = { overview: viewOverview, images: viewImages, resources: viewResources, operations: viewOperations, accounts: viewAccounts,
                    metrics: viewMetrics, activity: viewActivity, doctor: viewDoctor, settings: viewSettings, onboarding: viewOnboarding };
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
/// A button: its icon (opts.icon, else the label's — `iconFor`) and its text label.
function btn(label, onClick, opts = {}) {
  return h('button', { type: 'button', class: 'btn' + (opts.danger ? ' danger' : '') + (opts.primary ? ' primary' : '') + (opts.small ? ' small' : ''),
                       title: opts.title || null, on: { click: (ev) => { ev.stopPropagation(); onClick(ev); } } },
    withIcon(opts.icon || iconFor(label), label));
}

// The owner's vocabulary (2026-09-25); aliases in the tooltips.
const VERBS = {
  start: ['Start', 'Boot it (cold boot) — or wake / resume it'],
  pause: ['Pause', 'Suspend: guest CPU to 0 in ~1 ms, RAM kept'],
  resume: ['Resume', 'Run again after a pause'],
  sleep: ['Sleep', 'Pause + snapshot to disk: RAM kept, survives a host crash'],
  hibernate: ['Hibernate', 'Snapshot and stop the VM — RAM returned; wake in ~0.3 s'],
  wake: ['Wake', 'Back from sleep or hibernation, sessions where they were'],
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
    case 'running': return ['pause', 'sleep', 'hibernate', 'shutdown'];
    case 'paused': return ['resume', 'sleep', 'hibernate', 'shutdown'];
    case 'asleep': return ['wake', 'hibernate', 'shutdown'];
    case 'hibernated': return ['wake', 'shutdown'];
    case 'failed': return ['start'];
    default: return [];
  }
}
/// Shut Down keeps the disk, so it asks with a plain confirmation (and can stop asking); Reset and
/// Remove destroy data and keep the typed name. "Don't ask again" is the setting ui.confirm_shutdown
/// (doz.toml — every browser, and the Settings page turns it back on).
function confirmShutdown(name) {
  const body = { action: 'shutdown', sandbox: name };
  if (!setting('ui.confirm_shutdown', true)) { act(body); return; }
  dialog('Shut down ' + name + '?', DESTRUCTIVE.shutdown + ' Start cold-boots the same disk.', [
    { name: 'dontAsk', label: 'Don’t ask again', type: 'checkbox', help: 'Sets ui.confirm_shutdown = false in the settings (Settings turns it back on).' },
  ], 'Shut down', async (v) => {
    if (v.dontAsk) await saveSetting('ui.confirm_shutdown', false).catch((e) => toast('The setting was not saved: ' + (e.message || e), true));
    return await actOrThrow(body);
  }, { danger: true });
}
function lifecycle(verb, name) {
  if (verb === 'shutdown') confirmShutdown(name);
  else if (DESTRUCTIVE[verb]) confirmAction(VERBS[verb][0] + ' ' + name, DESTRUCTIVE[verb], name, { action: verb, sandbox: name });
  else if (verb === 'start' && bootViewOnStart()) startWithBootView(name);
  else act({ action: verb, sandbox: name });
}
/// The settings' ui.boot_view_on_start (and a boot view needs browser terminals).
function bootViewOnStart() { return setting('ui.boot_view_on_start', true) && setting('ui.terminals', true); }
/// 591 — Start shows the boot: a terminal pane streams the host's steps and the kernel's console,
/// then becomes the image's own session (the UI process does the switch; the boot stays in the scrollback).
async function startWithBootView(name) {
  // The terminal first: once the UI process shows it waiting on the shut-down sandbox, it is following
  // the host's events — then the start, so not one step is missed (a warm start takes half a second).
  // The transition starts at the click (the bar says "Booting…" at once), and the boot view's cover says
  // it is starting from its first paint — never "Sandbox shut down" while the start is being sent.
  beginTransition(name, 'start');
  const before = new Set(terminals.keys());
  openTerminal(name, null, 'interactive', undefined, { bootIntent: true });
  const t = [...terminals.values()].find((x) => !before.has(x.id));
  const end = Date.now() + 15000;
  while (t && Date.now() < end && !t.closed && !t.errorText && !(t.state && ['shutDown', 'failed', 'boot'].includes(t.state.cover.kind))) {
    await new Promise((r) => setTimeout(r, 100));
  }
  await act({ action: 'start', sandbox: name });
}
function lifecycleButtons(s, all) {
  const tr = transitionOf(s.name);
  const busy = s.busy || s.phase === 'booting' || opRunningFor(s.name) || !!tr;
  // In a transition this page started, the buttons it showed when asked — disabled, never swapped.
  const verbs = tr && tr.verbs ? tr.verbs : verbsFor(s.phase);
  const extra = all ? ['reset', 'rm'] : [];
  return h('div', { class: 'actions', 'data-lifecycle-for': s.name }, [...verbs, ...extra].map((v) => {
    const b = btn(VERBS[v][0], () => lifecycle(v, s.name), { small: true, title: tr ? TRANSITION_LABEL[tr.action] : VERBS[v][1], danger: !!DESTRUCTIVE[v] });
    if (busy) b.disabled = true;
    return b;
  }));
}
/// The phase pill — or, in a transition, what is under way.
function sandboxPill(s) {
  const tr = transitionOf(s.name);
  if (tr) return transitionPill(tr, s.name);
  const p = phasePill(s.phase, s.phaseLabel, s.busy);
  p.dataset.pillFor = s.name;
  return p;
}

function hostCard(host) {
  if (host.running) {
    return card('Host', 'running', 'pid ' + host.pid + ' · ' + (host.version || '') + ' · since ' + when(host.startedAt) +
      (host.idleSeconds ? ' · idle ' + Math.round(host.idleSeconds) + ' s' : ''));
  }
  // 594 W18: every action starts a host on demand (as the CLI does); this starts one on its own.
  const c = card('Host', 'not running', host.recoveryPending.length ? 'recovery pending: ' + host.recoveryPending.join(', ') : 'nothing is running — shown from the store');
  c.append(h('div', { class: 'n' }, startHostButton()));
  return c;
}

// ── views ───────────────────────────────────────────────────────────────────
async function viewOverview() {
  const o = await api('overview');
  state.overview = o;
  renderNavSandboxes();
  const rows = o.sandboxes.map((s) => h('tr', { class: 'click', on: { click: () => { location.hash = '#/sandbox/' + s.name; } } },
    h('td', null, h('a', { href: '#/sandbox/' + s.name }, s.name), h('div', { class: 'muted' }, s.image),
      s.workspace ? null : h('div', { class: 'muted no-ws', 'data-isolated': '', title: ISOLATED_NOTE }, 'isolated'),
      h('div', { 'data-op-for': s.name })),
    h('td', null, sandboxPill(s), s.diedWithHost ? h('div', { class: 'st-warn' }, 'died with its host') : null),
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
      'No sandboxes yet — New sandbox, or doz create NAME --image lab'));
}

async function createDialog() {
  let images = [], accounts = { accounts: [] }, bases = null;
  try { [images, accounts] = await Promise.all([api('images'), api('accounts')]); } catch (_) { /* defaults */ }
  try { bases = await api('bases'); } catch (_) { /* no catalogue: the picker shows what it can */ }
  const slot = h('div'), acctSlot = h('div'), imgSlot = h('div'), permSlot = h('div');
  let perms = { value: () => null };
  // 594 W28 (owner: "i dont think we should rebuild images without the user agreeing … better to warn"):
  // an out-of-date image is said here, with the choice — use it as it is (the default), or rebuild first.
  const imgNote = h('div', { class: 'img-choice', 'data-image-choice': '', hidden: true });
  let imgChoice = 'current';
  const renderImgNote = (name) => {
    const i = images.find((x) => x.name === name);
    imgChoice = 'current';
    if (!i || !i.baked || !i.standing) { imgNote.hidden = true; imgNote.replaceChildren(); return; }
    const missing = i.olderRecipe && !(i.olderRecipe.length === 1 && i.olderRecipe[0] === 'its recipe changed') ? ' (missing: ' + i.olderRecipe.join(', ') + ')' : '';
    const radio = (value, label, checked) => {
      const r = h('input', { type: 'radio', name: 'img-choice', value });
      r.checked = checked;
      r.addEventListener('change', () => { if (r.checked) imgChoice = value; });
      return h('label', { class: 'check' }, r, ' ', label);
    };
    imgNote.replaceChildren(
      h('p', { class: 'img-choice-note' }, icon('flame'), ' The ' + name + ' image is out of date: ' + i.standing.replace(/ — rebuild when ready: .*$/, '') + '.'),
      radio('current', 'Use the current image' + missing, true),
      radio('rebuild', 'Rebuild it first (~2 min, needs network; existing sandboxes are NOT affected)', false));
    imgNote.hidden = false;
  };
  const dlg = dialog('New sandbox','It is created off; Start boots it (the first start of an image not yet prepared prepares it — minutes, needs network).', [
    { name: 'sandbox', label: 'Name', placeholder: 'a-z 0-9 -', required: true },
    // 596 (B1): Agent × Base.
    { name: 'image', type: 'custom', el: imgSlot, get: () => {
      const why = picker.blocked();
      if (why) throw new Error(why);
      return picker.image();
    } },
    { name: 'dockerfile', type: 'custom', el: h('span', { hidden: true }), get: () => picker.dockerfile() },
    // 597 (P4): what the agent can do — preset from the base (and the Network choice).
    { name: 'permissions', type: 'custom', el: permSlot, get: () => perms.value() },
    { name: 'imageChoice', type: 'custom', el: imgNote, get: () => imgChoice },
    { name: 'network', label: 'Network', type: 'select', value: '',
      options: [['', 'default — the permissions below (Settings)'], ['agent', 'Standard permissions'], ['bake', 'bake — proxied, package registries only'],
        ['locked', 'Locked — its AI model only'], ['open', 'Open — everything, the web included (logged)'], ['nat', 'nat — a real interface (vmnet), not filtered'], ['none', 'none']] },
    // 594: only the accounts the image's agent can use; pi with none: the key right here.
    { name: 'account', type: 'custom', el: acctSlot, get: () => {
      if (!acct.ok()) throw new Error((AGENT_NAMES[agentOf()] || 'This agent') + ' needs an Anthropic API key — add one above.');
      return acct.get();
    } },
    { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: 'default (' + setting('defaults.cpus', 2) + ', Settings)' },
    { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: 'default (per image, Settings)' },
    // 594: Shared folder (the default: <projects_dir>/<name>, made when missing) | Isolated.
    { name: 'ws', type: 'custom', el: slot, get: () => chooser.get() },
  ], 'Create', async (v) => {
    const body = { action: 'create', sandbox: v.sandbox, image: v.image, ...v.ws };
    if (v.dockerfile) body.dockerfile = v.dockerfile;
    if (v.permissions) body.permissions = v.permissions;
    if (v.imageChoice === 'rebuild') body.rebuild = true;
    if (v.network) body.network = v.network;
    if (v.account) body.account = v.account;
    if (v.cpus) body.cpus = Number(v.cpus);
    if (v.memoryMiB) body.memoryMiB = Number(v.memoryMiB);
    await actOrThrow(body);
  });
  let chooser = null, acct = null;
  const submit = dlg.querySelector('button[type="submit"]');
  const why = h('small', { class: 'dlg-why', 'data-create-why': '', 'aria-live': 'polite' });
  submit.parentElement.before(why);
  const gate = () => {
    const w = picker.blocked();
    why.textContent = w || '';
    submit.disabled = !!w || (acct ? !acct.ok() : false);
  };
  const picker = imagePicker({ images, bases, value: setting('defaults.image', 'claude-code'),
    onChange: () => { if (chooser) chooser.imageChanged(); if (acct) acct.agentChanged(); renderImgNote(picker.image()); if (perms.baseChanged) perms.baseChanged(); gate(); },
    onDockerfile: (folder) => { if (chooser) chooser.suggest(folder); } });
  imgSlot.replaceWith(picker.el);
  chooser = workspaceChooser({ nameInput: dlg.inputs.sandbox, image: () => pickerNameHint(picker) });
  slot.replaceWith(chooser.el);
  const netProxied = () => !['nat', 'none'].includes(dlg.inputs.network.value);
  acct = accountChooser({ accounts, agent: () => (netProxied() ? picker.agent() : null), onChange: gate });
  acctSlot.replaceWith(acct.el);
  renderImgNote(picker.image());
  perms = newSandboxPermissions(bases, picker, dlg.inputs.network);
  permSlot.replaceWith(perms.el);
  gate();
  dlg.inputs.network.addEventListener('change', () => { acct.agentChanged(); perms.networkChanged(); });
}

/// 597 (P4): New Sandbox's switches — the default for the base (defaults.permissions), or the Network
/// choice's preset; changed by hand, they stay as set. Hidden for bake / nat / none and a template.
function newSandboxPermissions(bases, picker, network) {
  const el = h('div', { class: 'field perm-field', 'data-new-permissions': '' });
  if (!bases || !bases.permissions) return { el, value: () => null, baseChanged() {}, networkChanged() {} };
  let on = new Set(), touched = false;
  const baseKey = () => { const b = picker.base(); return b === null ? null : b; };
  const presetFor = (net, b) => net === 'locked' ? ['model'] : net === 'open' ? bases.permissions.map((r) => r.id)
    : net === 'agent' ? (bases.standard[b] || bases.standard[''] || []) : (bases.defaults[b] || bases.defaults[''] || []);
  const visible = () => baseKey() !== null && !['bake', 'nat', 'none'].includes(network.value);
  const reset = () => { if (!touched) on = new Set(presetFor(network.value, baseKey() || '')); paint(); };
  const change = (id, v) => {
    const apply = () => {
      touched = true;
      const inst = bases.permissions.filter((r) => r.group === 'install').map((r) => r.id);
      for (const x of id === 'install' ? inst : [id]) { if (v) on.add(x); else on.delete(x); }
      paint();
    };
    if (id === 'web' && v) confirmWeb(async () => apply()); else apply();
  };
  function paint() {
    el.hidden = !visible();
    const std = new Set(bases.standard[baseKey() || ''] || []);
    const same = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
    const label = same(on, std) ? 'Standard' : same(on, new Set(['model'])) ? 'Locked' : same(on, new Set(bases.permissions.map((r) => r.id))) ? 'Open' : 'Custom';
    el.replaceChildren(h('span', null, 'What the agent can do ', h('span', { class: 'tag', 'data-new-perm-preset': label }, label)),
      permissionSwitches(bases.permissions, on, change, { hosts: true }));
  }
  reset();
  return {
    el,
    value: () => (visible() ? [...on] : null),
    baseChanged: reset,
    networkChanged() { touched = false; reset(); },
  };
}

// ── a sandbox's page (593): a control bar, the terminal area, a collapsible details panel ──────
// #sbx is persistent: refreshSandbox() re-renders the bar and the details, never #terminals.
let sbxRefreshing = false, sbxAgain = false;
async function showSandbox() {
  const name = state.param;
  const want = state.session;                  // the addressed session (renderTerminals re-points the URL)
  const first = !state.sbx || state.sbx.name !== name;
  if (first) {
    state.sbx = { name, d: null };
    $('sbx-bar').replaceChildren(h('div', { class: 'sbx-title' }, h('h1', null, name)));
    $('sbx-details').replaceChildren();
    $('main').scrollTop = 0;
  }
  renderTerminals();
  // What arriving does needs the sandbox's detail: it runs once, after whichever refresh loads it first
  // (a refresh already in flight — the stream's hello — may be the one; this one then returns early).
  state.arrival = { name, want };
  await refreshSandbox();
  takeArrival(name);
}
function takeArrival(name) {
  const a = state.arrival;
  if (!a || a.name !== name || !state.sbx || state.sbx.name !== name || !state.sbx.d) return;
  state.arrival = null;
  sandboxArrived(a.name, a.want);
}
async function refreshSandbox() {
  // A re-run queued while the page was a sandbox's may come after it left for another page (593 §9:
  // it asked for sandboxes/null, got a 404 and sent the grid to the overview).
  if (state.view !== 'sandbox' || !state.param) return;
  if (sbxRefreshing) { sbxAgain = true; return; }
  sbxRefreshing = true;
  const name = state.param;
  try {
    const gen = state.trGen;
    const [d, net, accounts] = await Promise.all([api('sandboxes/' + name), api('sandboxes/' + name + '/network'), api('accounts').catch(() => ({ accounts: [] }))]);
    if (state.view !== 'sandbox' || state.param !== name || state.signedOut) return;
    // A transition began or ended while this was read: what it read may be the phase before — read again.
    if (gen !== state.trGen) { sbxAgain = true; return; }
    state.sbx = { name, d, net, accounts };
    const parts = sandboxParts(name, d, net, accounts);
    $('sbx-bar').replaceChildren(parts.bar);
    $('sbx-details').replaceChildren(parts.details);
    $('sbx-body').classList.toggle('details-closed', !setting('ui.details_open', true));
    paintRowOps();
    paintTermEmpty();
    // 593 §9: saved panes go live once it runs (their sessions listed by the detail), or repaint.
    promoteSaved(name, d.info.phase === 'running' && !d.info.busy && d.sessions ? d.sessions.filter((x) => !x.ended).map((x) => x.name) : null);
    paintTabs();
    takeArrival(name);
    // An arrival that found it under way restores once it has settled (never over a tab opened since).
    const sv = sview(name);
    if (sv.deferred && !sv.restoring && !d.info.busy && d.info.phase !== 'booting' && !opRunningFor(name)) {
      if (pageTerminals(name).length) { sv.deferred = false; sv.restored = true; } else restorePanes(name);
    }
  } catch (e) {
    if (e.status === 404) { if (state.view === 'sandbox' && state.param === name) location.hash = '#/overview'; return; }
    if (!state.signedOut) toast(e.message || String(e), true);
  } finally {
    sbxRefreshing = false;
    if (sbxAgain) { sbxAgain = false; refreshSandbox(); }
  }
}
/// On arriving at a sandbox's page: an addressed session (#/sandbox/NAME/SESSION, from the grid)
/// gets its tab — opened, or selected; otherwise, when the sandbox runs and its own session runs,
/// the page attaches to it (explicit viewing of a live VM, which keeps nothing alive the VM does
/// not). A sandbox that is not running shows the empty area's actions instead.
async function sandboxArrived(name, want) {
  const s = state.sbx;
  if (!s || s.name !== name || !s.d) return;
  const mine = [...terminals.values()].filter((t) => !t.grid && t.sandbox === name);
  const running = s.d.info.phase === 'running';
  const live = (s.d.sessions || []).filter((x) => !x.ended).map((x) => x.name);
  // 593 §9 (S1): the panes the host kept for this sandbox, the first time this page shows it.
  if (!mine.length) await restorePanes(name);
  if (want) {
    const have = pageTerminals(name).find((t) => t.session === want && t.mode === 'interactive' && !t.ended);
    if (have) { const v = sview(name); v.selected[have.pane] = have.id; v.focusedPane = have.pane; renderTerminals(); if (!have.saved) focusTerm(have); }
    else if (running && live.includes(want)) openTerminal(name, want, 'interactive');
    else if (!running && (await savedRows(name)).some((r) => r.name === want)) openSavedTerminal(name, (await savedRows(name)).find((r) => r.name === want));
    else toast('Session ' + want + ' is not running in ' + name, true);
    return;
  }
  if (!pageTerminals(name).length && running && live.includes(s.d.defaultSession) && setting('ui.terminals', true) && !sview(name).restoredAny) {
    openTerminal(name, s.d.defaultSession, 'interactive');
  }
}

// ── the terminal layout (593 §9 — S1): the HOST keeps each sandbox's panes (`terminal-layout`, beside
// its doz.json), so a UI restart, a reload or another browser shows the same ones. The page writes it
// (one typed, CSRF-checked POST, debounced) whenever its panes change — only once it has restored the
// stored one, so arriving never overwrites it with an empty page.
function layoutOf(name) {
  const v = sview(name);
  const kept = pageTerminals(name).filter((t) => t.session && !t.ended && !t.errorText);
  const panes = (v.split ? [0, 1] : [0]).map((pi) => {
    const inPane = kept.filter((t) => (v.split ? t.pane : 0) === pi).slice(0, 16);
    const idx = inPane.findIndex((t) => t.id === v.selected[pi]);
    return { tabs: inPane.map((t) => ({ session: t.session, mode: t.mode === 'watch' ? 'watch' : 'interactive' })), selected: idx >= 0 ? idx : null };
  });
  return { split: !!v.split, focusedPane: v.split && v.focusedPane === 1 ? 1 : 0, panes };
}
function persistLayout(name) {
  const v = sview(name);
  if (!v.restored || v.restoring || !setting('ui.terminals', true)) return;
  // Shut down: no sessions, no panes to remember (the host cleared the layout with the shutdown).
  if (sandboxPhase(name) === 'off') return;
  const body = JSON.stringify(layoutOf(name));
  if (body === v.savedLayout) return;
  v.savedLayout = body;
  clearTimeout(v.layoutTimer);
  v.layoutTimer = setTimeout(() => {
    api('sandboxes/' + name + '/layout', { method: 'POST', json: JSON.parse(body) })
      .catch(() => { if (v.savedLayout === body) v.savedLayout = null; });
  }, 400);
}
/// Saved sessions of a sandbox that is not running (`sessions` answers from its saved screens).
async function savedRows(name) {
  try { return (await api('sandboxes/' + name + '/sessions')).filter((r) => r.saved); } catch (_) { return []; }
}
/// A tab (not yet loaded: `lazy` — its engine starts the first time it is shown).
function addTab(name, session, mode, pane, saved) {
  const t = newTerm(name, session, mode);
  t.pane = pane;
  t.saved = saved ? { savedAt: saved.savedAt, reason: saved.savedReason } : null;
  t.lazy = true;
  paintCover(t);
  return t;
}
/// A saved screen as a tab of the sandbox's page (the details' Show, a grid tile's click).
function openSavedTerminal(name, row, pane) {
  if (!terminalsAllowed() || !row) return;
  const v = sview(name);
  const have = pageTerminals(name).find((t) => t.session === row.name && t.saved);
  const t = have || addTab(name, row.name, 'interactive', v.split ? (pane ?? v.focusedPane) : 0, row);
  v.selected[t.pane] = t.id;
  renderTerminals();
}
/// The phases one wakes (or resumes) back into — the only ones with saved screens (owner, 2026-09-30:
/// a shut-down sandbox shows no session screens anywhere).
const SAVED_PHASES = ['paused', 'asleep', 'hibernated'];
/// Restore the stored layout: a RUNNING sandbox's tabs whose sessions run attach; a paused, asleep or
/// hibernated one shows every session it has a saved screen of (S3) — the layout's first, in their panes.
async function restorePanes(name) {
  const v = sview(name);
  if (v.restored || v.restoring) return;
  v.restoring = true;
  try {
    const s = state.sbx;
    if (!s || !s.d || !setting('ui.terminals', true)) return;
    const i = s.d.info;
    // Under way (booting, pausing, hibernating, waking…): what to show is not known yet — the next
    // refresh that finds it settled restores (refreshSandbox), and nothing is written meanwhile.
    if (i.busy || i.phase === 'booting' || opRunningFor(name)) { v.deferred = true; return; }
    v.deferred = false;
    let layout = null;
    try { layout = await api('sandboxes/' + name + '/layout'); } catch (_) { /* none */ }
    const plan = [];
    if (i.phase === 'running' && !i.busy) {
      const live = new Set((s.d.sessions || []).filter((x) => !x.ended).map((x) => x.name));
      if (layout) layout.panes.forEach((p, pi) => p.tabs.forEach((tb) => { if (live.has(tb.session)) plan.push({ pane: pi, session: tb.session, mode: tb.mode }); }));
    } else if (SAVED_PHASES.includes(i.phase)) {        // shut down or failed: no sessions, no screens
      const rows = new Map((await savedRows(name)).map((r) => [r.name, r]));
      if (layout) {
        layout.panes.forEach((p, pi) => p.tabs.forEach((tb) => {
          const r = rows.get(tb.session);
          if (r) { plan.push({ pane: pi, session: tb.session, mode: tb.mode, saved: r }); rows.delete(tb.session); }
        }));
      }
      for (const r of rows.values()) plan.push({ pane: 0, session: r.name, mode: 'interactive', saved: r });
    }
    // Something was opened meanwhile (a click, the grid), or the page moved on: leave it be.
    if (!plan.length || pageTerminals(name).length || state.view !== 'sandbox' || state.param !== name) return;
    const split = !!(layout && layout.split && plan.some((p) => p.pane === 1) && plan.some((p) => p.pane === 0));
    const made = plan.map((p) => addTab(name, p.session, p.mode, split ? p.pane : 0, p.saved));
    v.split = split;
    for (const pi of [0, 1]) {
      const inPane = made.filter((t) => t.pane === pi);
      if (!inPane.length) { v.selected[pi] = null; continue; }
      const lp = layout && layout.panes[pi];
      const want = lp && lp.selected !== null && lp.selected !== undefined ? lp.tabs[lp.selected] : null;
      v.selected[pi] = (want && inPane.find((t) => t.session === want.session && t.mode === want.mode) || inPane[0]).id;
    }
    v.focusedPane = split && layout.focusedPane === 1 ? 1 : 0;
    v.restoredAny = true;
  } finally {
    v.restoring = false;
    if (!v.deferred) v.restored = true;
    if (state.view === 'sandbox' && state.param === name) renderTerminals();
  }
}
function sandboxParts(name, d, net, accounts) {
  const i = d.info;
  const running = i.phase === 'running';
  // Sessions need a VM: running, or one a session request wakes (paused, asleep, hibernated) — never
  // while off, failed, booting, busy or while another operation on it runs (590 bug 2).
  const sessionsReady = ['running', 'paused', 'asleep', 'hibernated'].includes(i.phase) && !i.busy && !opRunningFor(name) && !transitionOf(name);
  const whyNot = sessionsReady ? null : i.phase === 'off' || i.phase === 'failed' ? 'Start it first' : 'Wait until it is running';
  const gated = (b) => { if (!sessionsReady) { b.disabled = true; b.title = whyNot; } return b; };
  const fact = (k, v) => h('div', null, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v));
  const copy = btn('Copy', async (ev) => {
    const b = ev.currentTarget;
    try { await navigator.clipboard.writeText(d.attachCommand); setButton(b, 'Copied'); } catch (_) { setButton(b, 'Select and copy'); }
    setTimeout(() => { setButton(b, 'Copy'); }, 1500);
  });
  const terminal = (session) => async () => {
    try {
      const r = await api('sandboxes/' + name + '/terminal', { method: 'POST', json: session ? { session } : {} });
      toast(r.message);
    } catch (e) { toast(e.message, true); }
  };
  // 593 §9: paused, asleep or hibernated — the sessions as last saved, each can be shown (its saved
  // screen). A shut-down sandbox has none (owner, 2026-09-30).
  const savedState = (s) => 'screen saved ' + when(s.savedAt) + (s.savedReason ? ' (' + s.savedReason + ')' : '');
  const sessions = (d.sessions || []).map((s) => h('tr', { 'data-session': s.name },
    h('td', null, s.name, s.name === d.defaultSession ? h('span', { class: 'tag' }, 'default') : null),
    h('td', null, s.saved ? h('span', { class: 'muted' }, savedState(s)) : s.ended ? h('span', { class: 'muted' }, 'ended (exit ' + s.exitCode + ')') : 'running'),
    h('td', { class: 'mono' }, s.command),
    h('td', { class: 'num' }, s.cols ? s.cols + '×' + s.rows : '—'),
    h('td', { class: 'num' }, s.saved ? '—' : String(s.clients)),
    h('td', null, s.saved ? h('div', { class: 'actions' },
      btn('Show', () => openSavedTerminal(name, s), { small: true, icon: 'eye', title: 'Its last saved screen in a tab (read-only; it goes live when the sandbox runs)' }))
    : s.ended ? null : h('div', { class: 'actions' },
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
      btn('Save as template…', () => templateDialog(name, d, p.id), { small: true, title: 'Its root disk becomes a template (never its state disk)' }),
      btn('Duplicate…', () => duplicateDialog(name, d, accounts, p.id), { small: true, title: 'A new sandbox from this point, with a new workspace, CPUs, memory, network' }),
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
  const busy = i.busy || i.phase === 'booting' || opRunningFor(name) || !!transitionOf(name);
  const detailsOpen = setting('ui.details_open', true);
  const netText = i.network + (i.deniedConnections ? ' (' + i.deniedConnections + ' denied)' : '');
  const bar = h('div', { class: 'sbx-bar-inner' },
    h('div', { class: 'sbx-title' },
      h('h1', null, name), sandboxPill(i),
      h('span', { class: 'sbx-meta' },
        h('span', { title: i.image + (i.dockerfile ? ' — Dockerfile ' + i.dockerfile : ''), 'data-image-title': '' }, i.imageTitle || i.image),
        h('span', null, (i.ramHeldMiB ? mib(i.ramHeldMiB) : '—') + ' of ' + mib(i.memoryMiB)),
        h('span', { class: i.deniedConnections ? 'st-warn' : null }, netText),
        i.accountApplies ? h('span', null, 'account ' + (i.account || '—')) : null,
        i.workspace ? null : h('span', { class: 'badge-isolated', 'data-isolated': '', title: ISOLATED_NOTE }, withIcon('shield', 'isolated')))),
    h('div', { class: 'sbx-actions' },
      lifecycleButtons(i, true),
      h('span', { class: 'sbx-sep', 'aria-hidden': 'true' }),
      gated(btn('Open in Terminal', terminal(null), { small: true, title: 'Your terminal app attaches to the ' + d.defaultSession + ' session (waking the sandbox if it sleeps)' })),
      gated(btn('New shell', () => newShellTerminal(name).catch((e) => toast(e.message || String(e), true)),
        { small: true, title: 'A new shell session (shell-2, shell-3, …) in a browser terminal' })),
      ((b) => { if (busy) b.disabled = true; return b; })(btn('Terminal…', () => newTerminalDialog(name), { small: true, title: 'A NEW session: a shell, or one running a command (a running session opens from Details › Sessions)' })),
      termUI.splitBtn || null,
      h('span', { class: 'sbx-sep', 'aria-hidden': 'true' }),
      ((b) => { if (busy || !d.hasRootDisk) { b.disabled = true; b.title = d.hasRootDisk ? 'Wait until it settles' : 'It has no disk yet — start it once'; } return b; })(
        btn('Duplicate…', () => duplicateDialog(name, d, accounts, null), { small: true, title: 'A new sandbox from this one’s disk: a new workspace, CPUs, memory, network, account' })),
      ((b) => { if (busy || !d.hasRootDisk) { b.disabled = true; b.title = d.hasRootDisk ? 'Wait until it settles' : 'It has no disk yet — start it once'; } return b; })(
        btn('Save as template…', () => templateDialog(name, d, null), { small: true, title: 'Its root disk becomes an image other sandboxes are created from (never its state disk)' })),
      btn('Boot log', () => bootLogDialog(name), { small: true, icon: 'history', title: 'Its last boots — the steps and the kernel console, as the boot view showed them (any phase)' }),
      btn(detailsOpen ? 'Hide details' : 'Details', () => {
        const open = !setting('ui.details_open', true);
        $('sbx-body').classList.toggle('details-closed', !open);
        saveSetting('ui.details_open', open).then(() => refreshSandbox()).catch((e) => toast('The setting was not saved: ' + (e.message || e), true));
      }, { small: true, title: 'The sessions, restore points, network and keys panel (remembered: ui.details_open)' })),
    h('div', { 'data-op-for': name, 'data-banner': '1', role: 'status' }),
    i.credentialProblem ? credentialBanner(name, i, accounts) : null,
    // 594 W28: its system disk came from an image an older doz made.
    i.olderImage ? h('div', { class: 'cred-banner img-banner', role: 'status', 'data-older-image': name },
      h('div', { class: 'cred-banner-text' }, icon('flame'), ' ' + name + ' was ' + i.olderImage + '.')) : null,
    // 596 (B8): its Dockerfile changed (or was built again) — offered, never rebuilt by itself.
    i.rebuildAvailable ? h('div', { class: 'cred-banner img-banner', role: 'status', 'data-rebuild-available': name },
      h('div', { class: 'cred-banner-text' }, icon('flame'), ' ' + i.rebuildAvailable + '.'),
      h('div', { class: 'actions' }, btn('Rebuild the image', () => dialog('Rebuild ' + i.image + '?',
        'Runs container build again (seconds when nothing changed: its cache), then bakes only if the built image changed. ' + DOCKERFILE_POLICY_NOTE + ' This sandbox keeps its disk until you reset it.',
        [], 'Rebuild', async () => { await actOrThrow({ action: 'image-bake', image: i.image }); }, { icon: 'flame' }), { small: true, icon: 'flame' }))) : null);
  const details = h('div', { class: 'sbx-details-inner' },
    h('div', { class: 'cards small-cards' },
      card('RAM held', mib(i.ramHeldMiB), 'of ' + mib(i.memoryMiB) + (i.memoryReturnedMiB ? ' · balloon returned ' + mib(i.memoryReturnedMiB) : '')),
      card('Disk', bytes(i.diskBytes), d.snapshotBytes ? 'snapshot ' + bytes(d.snapshotBytes) : (d.hasRootDisk ? 'root disk kept' : 'no root disk yet')),
      card('CPUs', String(d.cpus))),
    h('div', { class: 'panel' }, h('div', { class: 'cmd' }, h('code', null, d.attachCommand), copy)),
    h('div', { class: 'head' }, h('h2', null, 'Sessions'), h('div', { class: 'actions' },
      gated(btn('Run detached…', () => dialog('Run a command in ' + name, 'A new session running the command — no shell in front (say bash -lc \'…\' for one). It runs inside the sandbox; attach to see it.',
        [{ name: 'session', label: 'Session name', placeholder: 'e.g. worker', required: true },
         { name: 'command', label: 'Command', placeholder: 'sleep 600', required: true }], 'Run', async (v) => {
          const argv = splitArgs(v.command);
          if (!argv.length) throw new Error('the command is empty');
          await actOrThrow({ action: 'open-session', sandbox: name, session: v.session, argv });
        }), { small: true })))),
    panel(table(['Session', 'State', 'Command', 'Size', 'Viewers', ''], sessions, [3, 4]),
      running ? 'No sessions.' : i.phase === 'off' || i.phase === 'failed' ? 'No sessions — ' + (i.phase === 'off' ? 'shut down' : 'failed') + '. Start boots it fresh, with new sessions.'
        : 'No saved screens — sessions are listed while it runs, and saved when it pauses, sleeps or hibernates.'),
    h('div', { class: 'head' }, h('h2', null, 'Restore points'), h('div', { class: 'actions' },
      btn('Take a restore point…', () => dialog('Take a restore point of ' + name, running ? 'A running sandbox pauses for the clone (milliseconds); its copy gets e2fsck on the first boot from it.' : 'An instant APFS clone of the disks.',
        [{ name: 'point', label: 'Name', placeholder: 'default point-N' }, { name: 'note', label: 'Note' }], 'Take', async (v) => {
          const b = { action: 'point-take', sandbox: name };
          if (v.point) b.point = v.point;
          if (v.note) b.note = v.note;
          await actOrThrow(b);
        }), { small: true }))),
    panel(table(['Point', 'Taken', 'While', 'Note', ''], points), 'No restore points.'),
    h('div', { class: 'head' }, h('h2', null, 'Network'), proxied ? btn('Edit policy…', () => policyDialog(name, net.policy), { small: true }) : null),
    networkPanel(net),
    h('div', { class: 'head' }, h('h2', null, 'Keys & account'), h('div', { class: 'actions' },
      proxied ? btn('Key policy…', () => dialog('Key policy of ' + name, 'What the proxy does with a credential the guest brings itself. auto: strict when the account is not the Mac login, allow otherwise.',
        [{ name: 'policy', label: 'Policy', type: 'select', options: ['auto', 'allow', 'strict'], value: 'auto' }], 'Set', async (v) => {
          await actOrThrow({ action: 'key-policy', sandbox: name, policy: v.policy });
        }), { small: true }) : null,
      proxied ? btn('Account…', () => accountDialog(name, i, accounts), { small: true }) : null)),
    panel(table(['Key', 'Set', 'Source', 'State', 'Policy', ''], creds), 'No keys — the sandbox uses none.'),
    keyEntry(name, proxied),
    foreign.length ? h('h2', null, 'Credentials the guest brought itself (fingerprints only)') : null,
    foreign.length ? panel(table(['Kind', 'Prefix', 'Fingerprint', 'Header', 'Requests', 'Last seen'], foreign, [4])) : null,
    h('h2', null, 'Configuration'),
    h('div', { class: 'panel' }, h('div', { class: 'facts' },
      fact('Memory', mib(d.memoryMiB)), fact('Root disk', mib(d.rootfsMiB)), fact('State disk', mib(d.stateDiskMiB)),
      fact('Journal', d.journalMiB ? mib(d.journalMiB) : 'none'), fact('Network', d.networkMode + (d.subnet ? ' · ' + d.subnet : '')),
      fact('Account', i.accountApplies ? (i.account || '—') : 'n/a'),
      fact('Workspace', i.workspace ? i.workspace + ' → /workspace (live)' : 'isolated — ' + ISOLATED_NOTE),
      fact('Shares', d.shares.length ? d.shares.map((s) => s.hostPath + ' → ' + s.guestPath).join(', ') : 'none'),
      d.project ? fact('Project', d.project) : null,
      fact('Directory', d.directory))),
    h('h2', null, 'Environment prompt'),
    promptPanel(d));
  return { bar, details };
}
/// 594 (D15/D16): what the agent is told about where it runs, as its NEXT session gets it.
function promptPanel(d) {
  const p = d.agentPrompt;
  if (!p) return panel(null, 'This image runs no agent — there is no environment prompt.');
  if (!p.enabled) return panel(null, 'Off — agent.prompt is false (Settings): the agent gets no facts block and no dozer skill.');
  const how = p.agent === 'pi' ? 'pi’s --append-system-prompt ' + p.promptPath : 'Claude Code’s --append-system-prompt (its launcher reads ' + p.promptPath + ')';
  return h('div', { class: 'panel prompt-panel' },
    h('div', { class: 'muted' }, 'Written at every session start, from this sandbox’s current facts — ', how, '. Layers: ', p.layers.join(' + '),
      '. The dozer skill: ', h('code', null, p.skillPath), ' (' + p.skillLines + ' lines).'),
    p.error ? h('div', { class: 'notice bad' }, 'It does not render, so sessions do not start: ' + p.error)
            : h('pre', { class: 'prompt-text' }, p.text || ''),
    h('div', { class: 'muted' }, 'Your own template: agent-prompt.md beside doz.toml · this sandbox’s own lines: agent_prompt in doz_project.yaml, or doz create --agent-prompt FILE.'));
}

/// 593: Save as template — the ROOT disk only (never the state disk: logins and history stay out of a
/// disk meant to be shared). From the current disk (a live sandbox pauses for the clone) or a point.
function templateDialog(name, d, pointID) {
  const sources = [['', 'the current disk' + (d.info.phase === 'off' ? '' : ' (it pauses for the clone: milliseconds)')],
    ...d.restorePoints.map((p) => [p.id, 'restore point ' + p.name])];
  dialog('Save ' + name + ' as a template',
    'A template is an image other sandboxes are created from. Everything installed or written on the ROOT disk is in it: files in /root, /etc, /usr, /opt, caches — so do not save a secret you put there. The agent’s state disk (its logins, history) is never included.', [
      { name: 'image', label: 'Template name', placeholder: 'a-z 0-9 -', required: true },
      { name: 'source', label: 'From', type: 'select', options: sources, value: pointID || '' },
      { name: 'note', label: 'Note', placeholder: 'what is in it' },
    ], 'Save template', async (v) => {
      const b = { action: 'template-create', sandbox: name, image: v.image };
      if (v.source) b.point = v.source;
      if (v.note) b.note = v.note;
      await actOrThrow(b);
    });
}

/// 593: Duplicate — a new sandbox from this one's disk (or a point) with overrides. The root disk is
/// an APFS clone; the state disk starts fresh unless the person opts in.
function duplicateDialog(name, d, accounts, pointID) {
  const i = d.info;
  const sources = [['', 'the current disk' + (i.phase === 'off' ? '' : ' (it pauses for the clone: milliseconds)')],
    ...d.restorePoints.map((p) => [p.id, 'restore point ' + p.name])];
  const slot = h('div'), acctSlot = h('div');
  const dlg = dialog('Duplicate ' + name,
    'A new sandbox from ' + name + '’s root disk (an instant APFS clone). It is created off; Start boots it. Keys are not copied.', [
      { name: 'newName', label: 'New sandbox name', placeholder: 'a-z 0-9 -', required: true },
      // 596 (B1): the base and agent are the source's — shown, not changeable (the disk is a clone of its).
      { name: 'baseShown', type: 'custom', get: () => null, el: h('div', { class: 'field', 'data-duplicate-image': '' }, h('span', null, 'Image'),
        h('div', null, h('strong', null, i.imageTitle || i.image), ' ', h('span', { class: 'muted' }, '— ' + i.image + (i.dockerfile ? ', Dockerfile ' + i.dockerfile : '') + ' (the source’s; not changeable)'))) },
      { name: 'source', label: 'From', type: 'select', options: sources, value: pointID || '' },
      // 594: Shared folder (<projects_dir>/<new name> by default, made when missing) | Isolated.
      { name: 'ws', type: 'custom', el: slot, get: () => chooser.get() },
      { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: String(d.cpus) + ' (the same)' },
      { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: String(d.memoryMiB) + ' (the same)' },
      { name: 'network', label: 'Network', type: 'select', value: '',
        options: [['', i.network + ' (the same — its permissions and sites copied)'], ['agent', 'Standard permissions'], ['bake', 'bake'], ['locked', 'Locked — its AI model only'],
          ['open', 'Open — everything (logged)'], ['nat', 'nat'], ['none', 'none']] },
      // 594: only the accounts the agent can use ("the same" only when that one fits).
      { name: 'account', type: 'custom', el: acctSlot, get: () => {
        if (!acct.ok()) throw new Error((AGENT_NAMES[i.agent] || 'This agent') + ' needs an Anthropic API key — add one above.');
        return acct.get();
      } },
      { name: 'copyState', label: 'Copy the agent’s state disk too', type: 'checkbox',
        help: 'Off (the default): a fresh state disk. On: its logins and history are copied into the new sandbox.' },
    ], 'Duplicate', async (v) => {
      const b = { action: 'duplicate', sandbox: name, newName: v.newName, ...v.ws };
      if (v.source) b.point = v.source;
      if (v.cpus) b.cpus = Number(v.cpus);
      if (v.memoryMiB) b.memoryMiB = Number(v.memoryMiB);
      if (v.network) b.network = v.network;
      if (v.account) b.account = v.account;
      if (v.copyState) b.copyState = true;
      await actOrThrow(b);
    });
  const chooser = workspaceChooser({ nameInput: dlg.inputs.newName, image: () => i.image });
  slot.replaceWith(chooser.el);
  const submit = dlg.querySelector('button[type="submit"]');
  const acct = accountChooser({ accounts, agent: () => (['nat', 'none'].includes(dlg.inputs.network.value) ? null : i.agent),
    same: i.credentialProblem ? null : 'the same' + (i.account ? ' (' + i.account + ')' : ''), defaultValue: 'default',
    onChange: () => { submit.disabled = !acct.ok(); } });
  acctSlot.replaceWith(acct.el);
  submit.disabled = !acct.ok();
  dlg.inputs.network.addEventListener('change', () => acct.agentChanged());
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
    setButton(ui.submit, p.changed ? 'Apply' : 'Apply anyway');
    return 'keep-open';
  });
}

// ── 597: what the agent can do ────────────────────────────────────────────
// Owner ruling (2026-09-30, P1–P7): a proxied sandbox's network as plain-language permissions, each a
// switch; hosts only under details. Presets Locked / Standard / Open; a changed switch is "Custom".
// Install software has a sub-switch per ecosystem (preset from the sandbox's base). Stored BY NAME:
// the hosts behind a permission come from the running doz.
const PRESET_LABEL = { locked: 'Locked', agent: 'Standard', open: 'Open' };
/// The switches: `rows` (id, title, summary, locked, warning, group, hosts), `on` (a Set), `change(id, on)`.
function permissionSwitches(rows, on, change, opts = {}) {
  const sw = (r, indent) => {
    const box = h('input', { type: 'checkbox', role: 'switch', 'data-permission': r.id, 'aria-label': r.title });
    box.checked = on.has(r.id) || r.locked;
    box.disabled = !!r.locked || !!opts.disabled;
    box.addEventListener('change', () => { const v = box.checked; box.checked = !v; change(r.id, v); });
    return h('div', { class: 'perm' + (indent ? ' perm-sub' : '') + (box.checked ? ' perm-on' : ''), 'data-perm-row': r.id },
      h('label', { class: 'perm-main' }, box, h('span', { class: 'perm-title' }, r.title, r.locked ? h('span', { class: 'muted' }, ' — always') : null)),
      h('div', { class: 'perm-summary muted' }, r.summary, r.warning ? h('span', { class: 'perm-warn' }, ' ' + r.warning) : null),
      opts.hosts === false ? null : h('details', { class: 'perm-hosts' }, h('summary', null, 'hosts'), h('div', { class: 'mono muted' }, r.hosts.join(', '))));
  };
  const top = rows.filter((r) => r.group !== 'install'), inst = rows.filter((r) => r.group === 'install');
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
  for (const r of top) { out.push(sw(r, false)); if (r.id === 'update') out.push(installBlock); }
  return h('div', { class: 'perm-list', 'data-permissions': '' }, out);
}
/// "Browse the web" (and Open) warn first.
function confirmWeb(then) {
  dialog('Let the agent browse the web?', 'The agent could send your code anywhere — use with care. Every connection is still proxied and logged, and you can switch it off again.',
    [], 'Allow the web', async () => { await then(); }, { danger: true });
}
function permissionsPanel(name, net) {
  const p = net.permissions;
  if (!p) return null;
  const on = new Set(p.rows.filter((r) => r.on).map((r) => r.id));
  const send = async (body) => { try { await actOrThrow({ action: 'net-policy', sandbox: name, ...body }); } catch (e) { toast(e.message || String(e), true); } };
  const change = (id, v) => {
    if (id === 'web' && v) return confirmWeb(() => send({ grant: ['web'] }));
    send(v ? { grant: [id] } : { revoke: [id] });
  };
  const presetBtn = (id) => {
    const b = h('button', { type: 'button', class: 'seg' + (p.preset === id ? ' active' : ''), 'data-perm-preset': id, 'aria-pressed': p.preset === id ? 'true' : 'false' },
      withIcon(id === 'locked' ? 'shield' : id === 'open' ? 'eye' : 'check', PRESET_LABEL[id]));
    b.addEventListener('click', () => { if (id === 'open') confirmWeb(() => send({ preset: 'open' })); else send({ preset: id }); });
    return b;
  };
  const suggestions = p.suggestions.map((s) => h('div', { class: 'perm-suggest', 'data-suggest': s.grant },
    icon('shield'), ' The agent tried to ', h('strong', null, s.permission ? s.what : 'reach ' + s.what),
    ' (' + s.hosts.join(', ') + ', ' + s.count + ' time' + (s.count === 1 ? '' : 's') + ') ',
    btn(s.permission ? 'Allow' : 'Allow this site', () => (s.permission === 'web' ? confirmWeb(() => send({ grant: [s.grant] })) : send({ grant: [s.grant] })),
      { small: true, icon: 'check' })));
  const sites = p.sites.map((host) => h('span', { class: 'tag perm-site', 'data-site': host }, host, ' ',
    h('button', { type: 'button', class: 'link-button', title: 'Deny ' + host, on: { click: () => send({ revoke: ['site:' + host] }) } }, '×')));
  const siteInput = h('input', { type: 'text', placeholder: 'api.example.com', 'aria-label': 'A site to allow', 'data-site-input': '', spellcheck: 'false' });
  return h('div', { class: 'panel perm-panel', 'data-perm-panel': name },
    h('div', { class: 'perm-head' }, h('strong', null, 'What the agent can do'),
      h('div', { class: 'segmented', role: 'group', 'aria-label': 'Preset' }, presetBtn('locked'), presetBtn('agent'), presetBtn('open')),
      p.preset ? null : h('span', { class: 'tag', 'data-perm-custom': '' }, 'Custom'),
      p.inferred ? h('span', { class: 'muted' }, ' an older policy, shown as permissions (stored as names at its first change)') : null),
    suggestions.length ? h('div', { class: 'perm-suggestions' }, suggestions) : null,
    permissionSwitches(p.rows, on, change),
    h('div', { class: 'perm-sites' }, h('span', null, 'Other sites: '), sites.length ? sites : h('span', { class: 'muted' }, 'none'), ' ', siteInput,
      btn('Allow site', () => { const v = siteInput.value.trim().toLowerCase(); if (v) send({ grant: ['site:' + v] }); }, { small: true, icon: 'plus' })));
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

/// 593: Images › Table | Lineage. The lineage is measured by the host (every disk's extent map), so
/// it is fetched only when shown, or on Refresh — never on a live update.
function imagesToggle() {
  const mk = (mode, label) => {
    const b = h('button', { type: 'button', class: 'seg' + (state.imagesMode === mode ? ' active' : ''), 'aria-pressed': state.imagesMode === mode ? 'true' : 'false', 'data-mode': mode },
      withIcon(iconFor(label), label));
    b.addEventListener('click', () => { if (state.imagesMode !== mode) { state.imagesMode = mode; refresh(false); } });
    return b;
  };
  return h('div', { class: 'segmented', role: 'group', 'aria-label': 'View' }, mk('table', 'Table'), mk('lineage', 'Lineage'));
}
// ── 595 (R9, owner: "show the shared block reuse size and percentage per image and use a different
// colour in the size bar … a legend in the bar column header Own / Shared"). Own = the blocks only this
// disk holds (what deleting it frees — Resources' "freed if deleted"); Shared = the blocks it reuses
// from the disk it was made from (APFS clones — 587's DiskAccounting). Each also as a % of its size.
function pct(part, whole) { return whole > 0 && part != null ? Math.round((part / whole) * 100) + '%' : '—'; }
function sizeBar(size, own, shared) {
  const whole = Math.max(1, size || 0);
  const bar = h('div', { class: 'lin-bar', 'data-own': String(own || 0), 'data-shared': String(shared || 0),
    title: 'own ' + bytes(own || 0) + ' (' + pct(own || 0, size) + ') · shared ' + bytes(shared || 0) + ' (' + pct(shared || 0, size) + ')' +
      ((size - (own || 0) - (shared || 0)) > 0 ? ' · the rest is shared with other disks' : '') });
  const a = h('span', { class: 'lin-shared' }), b = h('span', { class: 'lin-own' });
  a.style.width = Math.min(100, ((shared || 0) / whole) * 100).toFixed(1) + '%';
  b.style.width = Math.min(100, ((own || 0) / whole) * 100).toFixed(1) + '%';
  bar.append(a, b);
  return bar;
}
function barLegend() {
  return h('span', { class: 'bar-legend', 'data-legend': '' },
    h('span', { class: 'sw sw-own', 'aria-hidden': 'true' }), 'Own', h('span', { class: 'sw sw-shared', 'aria-hidden': 'true' }), 'Shared');
}
function sizePart(n, size) { return n == null ? '—' : [bytes(n), h('span', { class: 'muted pct' }, ' · ' + pct(n, size))]; }
/// The lineage node of an Images row (built-in: `image` NAME@KEY12; lab: its prepared disk; a template by name).
function treeNodeFor(tree, r) {
  if (!tree) return null;
  return tree.nodes.find((n) => r.kind === 'custom' ? n.kind === 'template' && n.name === r.name
    : r.name === 'lab' ? n.kind === 'prepared' && r.key && (n.name + '-' + String(n.detail || '').split(' ').pop()) === r.key
    : n.kind === 'image' && n.name === r.name && !!r.key && n.detail === r.key) || null;
}
/// A measurement (the Resources report, the lineage): read when a page is arrived at, on Refresh and
/// when an operation ends — never on a live update (it reads every disk's extent map).
state.measured = { stale: new Set(['resources', 'tree']), resources: null, tree: null };
function remeasure() { state.measured.stale.add('resources'); state.measured.stale.add('tree'); }
async function measured(key, path) {
  if (state.measured[key] && !state.measured.stale.has(key)) return state.measured[key];
  const v = await api(path);
  state.measured[key] = v;
  state.measured.stale.delete(key);
  if (key === 'resources') paintResTotal(v);
  return v;
}
async function viewImages() {
  if (state.imagesMode === 'lineage') return viewLineage();
  const [images, tree] = await Promise.all([api('images'), measured('tree', 'images/tree').catch(() => null)]);
  const rows = images.map((r) => {
    const n = treeNodeFor(tree, r);
    const size = n ? n.allocatedBytes : r.allocatedBytes;
    // Shared: with the disk it was made from (none for a disk with no parent — the lab's prepared disk).
    const own = n ? n.uniqueBytes : null, shared = n ? n.sharedWithParentBytes ?? null : null;
    return h('tr', { 'data-image': r.name, 'data-status': r.status || '' },
    h('td', null, r.name, r.kind === 'custom' ? h('span', { class: 'tag tpl' }, 'template') : null,
      // 594 W28: out of date — a badge, and the line that says why (never rebuilt by itself).
      r.status === 'older recipe' || r.status === 'update available' ? h('span', { class: 'tag img-status st-' + r.status.replace(/ /g, '-'), 'data-image-badge': r.status }, r.status) : null,
      r.standing ? h('div', { class: 'muted img-standing', 'data-image-standing': '' }, r.standing) : null),
    // 596 (B1): base × agent ("Python · Claude Code").
    h('td', { 'data-image-base': r.base || '' }, r.kind === 'custom' ? 'template' : (r.title || r.kind)),
    // W32: what the image's state means, in words — never a bare dash.
    h('td', { 'data-image-status-cell': '' }, h('span', { class: r.status === 'up to date' ? 'muted' : '' }, r.status || 'up to date')),
    h('td', null, r.baked ? (r.bakedAt ? full(r.bakedAt) : 'yes') : h('span', { class: 'muted' }, 'no — bakes on first start')),
    h('td', { class: 'num' }, r.allocatedBytes ? bytes(r.allocatedBytes) : '—'),
    h('td', { class: 'num', 'data-own-cell': '' }, n ? sizePart(own, size) : '—'),
    h('td', { class: 'num', 'data-shared-cell': '' }, n ? sizePart(shared, size) : '—'),
    h('td', { class: 'bar-cell' }, n ? sizeBar(size, own, shared) : null),
    // 594: an agent image's version — the one a new sandbox gets, and a newer one available (594 W28:
    // said, never prepared by itself — Rebuild).
    h('td', { 'data-version': r.version || '', 'data-available': r.available || '' },
      r.versionSetting ? [
        r.version ? h('span', { class: 'mono' }, r.version)
          : h('span', { class: 'muted' }, (r.available ? r.available + ' ' : '') + 'when prepared' + (r.preparing ? ' — preparing' : '')),
        r.version && r.available ? h('span', { class: 'tag ver-available', title: 'a new sandbox gets ' + (r.version || 'it') + ' until you rebuild the image' },
          r.available + ' available' + (r.preparing ? ' — preparing' : '')) : null,
        h('div', { class: 'muted' }, r.versionSetting === 'latest'
          ? 'latest' + (r.latest ? ' (npm: ' + r.latest + ')' : '') : 'pinned: ' + r.versionSetting),
      ] : '—'),
    h('td', null, [r.versionSetting ? null : r.note, r.fromSandbox ? 'from ' + r.fromSandbox : null, r.dockerfile ? 'Dockerfile ' + r.dockerfile : null,
      r.baseUpdate].filter(Boolean).join(' · ') || '—'),
    h('td', { class: 'mono muted' }, r.key ? r.key.slice(0, 16) : ''),
    h('td', null, h('div', { class: 'actions' },
      // 594 W28: rebuilding is one explained step.
      r.kind === 'builtin' ? (r.baked
        ? btn('Rebuild', () => dialog('Rebuild the ' + r.name + ' image?',
            'About 2 minutes, needs network. Existing sandboxes keep their disks — nothing in them changes. New sandboxes, and Reset, use the new image (a reset keeps the agent’s own state and /workspace, and drops other system changes).',
            [], 'Rebuild', async () => { await actOrThrow({ action: 'image-bake', image: r.name }); }, { icon: 'flame' }),
          { small: true, primary: !!r.standing, icon: 'flame', title: 'Minutes, needs network' })
        : btn('Bake', () => act({ action: 'image-bake', image: r.name }), { small: true, title: 'Minutes, needs network' })) : null,
      r.baked || r.kind === 'custom' ? btn('Remove', () => confirmAction('Remove ' + (r.kind === 'custom' ? 'template ' : 'image ') + r.name,
        r.kind === 'custom' ? 'The template is deleted; sandboxes created from it keep working.' : 'Its baked disk is deleted (it is baked again when next needed); sandboxes cloned from it keep working.',
        r.name, { action: 'image-rm', image: r.name }), { small: true, danger: true }) : null)));
  });
  return h('div', null, h('div', { class: 'head' }, h('h1', null, 'Images'),
      h('div', { class: 'actions' }, btn('Refresh', () => { remeasure(); refresh(false); }, { small: true, title: 'Measure again' }), imagesToggle())),
    h('p', { class: 'sub' }, 'Built-in images, and templates saved from sandboxes (a sandbox’s root disk — never its state disk). Own is what only this image holds (what removing it frees); shared is what it reuses from the disk it was made from. Progress of a bake shows under Operations. Everything Dozer uses: ',
      h('a', { href: '#/resources' }, 'Resources'), '.'),
    panel(table(['Image', 'Base · Agent', 'Status', 'Baked', 'Size', 'Own', 'Shared', barLegend(), 'Version', 'Note', 'Key', ''], rows, [4, 5, 6])));
}
async function viewLineage() {
  const t = await measured('tree', 'images/tree');
  const labels = { base: 'OCI base', image: 'image', template: 'template', prepared: 'prepared disk', sandbox: 'sandbox', restorePoint: 'restore point' };
  const rows = t.nodes.map((n) => {
    const own = n.uniqueBytes || 0;
    const bar = sizeBar(n.allocatedBytes, own, n.sharedWithParentBytes || 0);
    const name = n.kind === 'sandbox' ? h('a', { href: '#/sandbox/' + n.sandbox }, n.name) : h('span', null, n.name);
    return h('div', { class: 'lin-row depth-' + Math.min(n.depth, 8) + ' lin-' + n.kind, 'data-kind': n.kind, 'data-name': n.name, 'data-depth': String(n.depth) },
      h('div', { class: 'lin-name' }, h('span', { class: 'lin-branch', 'aria-hidden': 'true' }, n.depth ? '└ ' : ''), name,
        h('span', { class: 'tag lin-kind' }, labels[n.kind] || n.kind), n.detail ? h('span', { class: 'muted mono lin-detail' }, n.detail) : null),
      h('div', { class: 'num lin-size' }, bytes(n.allocatedBytes), n.stateAllocatedBytes ? h('div', { class: 'muted' }, '+ state ' + bytes(n.stateAllocatedBytes)) : null),
      h('div', { class: 'num lin-shared-n' }, n.sharedWithParentBytes != null ? sizePart(n.sharedWithParentBytes, n.allocatedBytes) : '—'),
      h('div', { class: 'num lin-own-n' }, sizePart(own, n.allocatedBytes)),
      bar);
  });
  return h('div', null, h('div', { class: 'head' }, h('h1', null, 'Images'),
      h('div', { class: 'actions' }, btn('Refresh', () => { remeasure(); refresh(false); }, { small: true, title: 'Measure again' }), imagesToggle())),
    h('p', { class: 'sub' }, 'The lineage: OCI base → image → template → the sandboxes on each. Size is what the disk holds; shared is what it reuses from its parent (APFS clones); own is what removing it frees — each also as a % of its size. All disks together: ' +
      bytes(t.unionBytes) + ' (measured in ' + Math.round(t.milliseconds) + ' ms).'),
    t.nodes.length
      ? h('div', { class: 'panel lineage' },
          h('div', { class: 'lin-row lin-headrow' }, h('div', null, 'Image / sandbox'), h('div', { class: 'num' }, 'Size'), h('div', { class: 'num' }, 'Shared'), h('div', { class: 'num' }, 'Own'), h('div', null, barLegend())),
          rows)
      : panel(null, 'No disks yet — bake an image or start a sandbox.'));
}

// ── 595: Resources ──────────────────────────────────────────────────────────
// Owner (2026-09-30): "the Resources section should break down ALL the usage". An ACCOUNT first: every
// byte of the store on a row (the last, "unattributed", is ~0 — red when not), the memory and CPUs Dozer
// holds, the proxy's traffic, the kernels. Management stays where it lives — a row links to Images, the
// sandbox's page or Accounts & keys; this page deletes only what has no other home. A deletion is
// previewed (POST resources/preview — changes nothing), confirmed once (no typed names: the owner's
// ruling), and runs as ONE operation (`resources-rm` with exactly the ids shown).
const RES_GROUPS = [['sandboxes', 'Sandboxes'], ['images', 'Images & templates'], ['caches', 'Caches'], ['logs', 'Logs & metrics'],
                    ['stray', 'Stray files'], ['store', 'Dozer’s own'], ['outside', 'Outside the store']];
state.resSel = new Set();
state.resToggled = new Set();
let resTotalTimer = null;
function paintResTotal(r) {
  const el = $('res-total');
  if (!el || !r) return;
  el.hidden = false;
  el.textContent = bytes(r.totalBytes);
  el.title = 'Dozer uses ' + bytes(r.totalBytes) + ' of disk' + (r.unattributedBytes ? ' — ' + bytes(r.unattributedBytes) + ' unattributed' : '');
  el.classList.toggle('bad', r.unattributedBytes !== 0);
}
/// The nav's total, measured a moment after an operation ends (or at load) — never on a live update.
function scheduleResTotal(delay = 2000) {
  clearTimeout(resTotalTimer);
  resTotalTimer = setTimeout(async () => {
    if (state.view === 'resources') return;            // the page measures (and paints the total) itself
    try { await measured('resources', 'resources'); } catch (_) { /* the last total */ }
  }, delay);
}
function resOpen(it) { return (it.group === 'sandboxes') !== state.resToggled.has(it.id); }
function resLink(link) {
  if (!link) return null;
  if (link === 'images') return h('a', { href: '#/images', 'data-link': 'images' }, 'Images');
  if (link === 'accounts') return h('a', { href: '#/accounts', 'data-link': 'accounts' }, 'Accounts & keys');
  if (link === 'settings') return h('a', { href: '#/settings', 'data-link': 'settings' }, 'Settings');
  if (link.startsWith('sandbox:')) { const n = link.slice(8); return h('a', { href: '#/sandbox/' + n, 'data-link': 'sandbox' }, n); }
  return null;
}
function resSelectable(it) { return it.deletable && !it.refusal; }
function resRow(it, kids) {
  const cb = h('input', { type: 'checkbox', 'data-res-check': it.id, 'aria-label': 'Select ' + it.name });
  cb.checked = state.resSel.has(it.id);
  if (!resSelectable(it)) { cb.disabled = true; cb.title = it.refusal || 'not deleted here'; cb.checked = false; }
  cb.addEventListener('change', () => {
    if (cb.checked) state.resSel.add(it.id); else state.resSel.delete(it.id);
    paintResSelection();
  });
  let toggle = null;
  if (kids) {
    const open = resOpen(it);
    toggle = h('button', { type: 'button', class: 'res-toggle' + (open ? ' open' : ''), 'aria-expanded': open ? 'true' : 'false',
                           title: (open ? 'Hide' : 'Show') + ' its ' + kids + ' part' + (kids === 1 ? '' : 's') }, icon('chevron-down'));
    toggle.addEventListener('click', () => {
      if (state.resToggled.has(it.id)) state.resToggled.delete(it.id); else state.resToggled.add(it.id);
      renderResources();
    });
  }
  const bad = it.id === 'unattributed' && it.sizeBytes !== 0;
  const notes = [];
  if (it.refusal && it.deletable) notes.push(h('div', { class: 'res-refusal' }, 'Not now: ' + it.refusal));
  else if (it.refusal) notes.push(h('div', { class: 'muted' }, it.refusal));
  if (it.later && !it.refusal) notes.push(h('div', null, h('span', { class: 'muted' }, 'Later: '), it.later));
  if (it.warning) notes.push(h('div', { class: 'res-warn' }, '⚠ ' + it.warning));
  if (it.id === 'unattributed') notes.push(h('div', { class: bad ? 'res-refusal' : 'muted' }, it.detail));
  // 596: Apple's container storage is shown, never deleted by Dozer — no checkbox at all (its own commands are named).
  const foreign = it.id.startsWith('outside:apple-container');
  return h('tr', { class: 'res-row' + (it.parent ? ' res-child' : '') + (bad ? ' res-bad' : ''), 'data-res': it.id, 'data-group': it.group },
    h('td', { class: 'res-check' }, foreign ? null : cb),
    h('td', { class: 'res-name' }, h('div', { class: 'res-name-line' }, toggle, h('span', null, it.name),
        it.current ? h('span', { class: 'tag res-current' }, 'current') : null,
        it.cleanable && resSelectable(it) ? h('span', { class: 'tag res-clean', title: 'Clean up removes it: re-creatable and unused' }, 'clean-up') : null),
      it.detail && it.id !== 'unattributed' ? h('div', { class: 'muted res-detail' }, it.detail) : null,
      h('div', { class: 'muted mono res-id' }, it.id)),
    h('td', { class: 'num' }, it.sizeBytes == null ? '—' : bytes(it.sizeBytes)),
    h('td', { class: 'num' }, it.freedBytes == null ? '—' : bytes(it.freedBytes)),
    h('td', null, it.usedBy.length ? it.usedBy.join(', ') : h('span', { class: 'muted' }, '—')),
    h('td', { class: 'res-notes' }, notes),
    h('td', null, resLink(it.link)));
}
function resGroupPanel(r, group, title) {
  const items = r.items.filter((i) => i.group === group);
  if (!items.length) return null;
  const rows = [];
  let total = 0;
  for (const p of items.filter((i) => !i.parent)) {
    const kids = items.filter((i) => i.parent === p.id);
    total += p.sizeBytes || 0;
    rows.push(resRow(p, kids.length));
    if (kids.length && resOpen(p)) for (const k of kids) rows.push(resRow(k, 0));
  }
  return h('section', { class: 'res-group', 'data-res-group': group },
    h('div', { class: 'head' }, h('h2', null, title), h('span', { class: 'muted' }, group === 'outside' ? 'shown, never deleted here' : bytes(total))),
    panel(table(['', 'Item', 'Size', 'Freed if deleted', 'Used by', 'Notes', 'Managed in'], rows, [2, 3])));
}
/// The top bar is Dozer's own split only (owner, 595): what stays, what Clean up frees, and what `du`
/// counts again for blocks APFS clones share — the whole is Dozer's total. The volume's free space is
/// text beside it, never part of the bar.
function resTotalBar(r) {
  const clean = Math.min(r.cleanableBytes, r.occupiedBytes);
  const keep = Math.max(0, r.occupiedBytes - clean);
  const shared = Math.max(0, r.totalBytes - r.occupiedBytes);
  const whole = Math.max(1, keep + clean + shared);
  const seg = (cls, n, label) => {
    const s = h('span', { class: cls, 'data-seg': cls, title: label + ': ' + bytes(n) });
    s.style.width = ((n / whole) * 100).toFixed(2) + '%';
    if (n > 0) s.style.minWidth = '4px';
    return s;
  };
  return h('div', { class: 'res-total' },
    h('div', { class: 'res-total-line' },
      h('div', { class: 'res-bar', 'data-res-bar': '' }, seg('res-seg-used', keep, 'Kept'), seg('res-seg-clean', clean, 'Clean up frees'),
        seg('res-seg-shared', shared, 'Shared blocks du counts again')),
      h('span', { class: 'res-free', 'data-res-free': '' }, r.volumeFreeBytes != null ? bytes(r.volumeFreeBytes) + ' free on the volume' : '')),
    h('div', { class: 'res-legend' },
      h('span', null, 'Dozer ', h('strong', { 'data-total': '' }, bytes(r.totalBytes)), h('span', { class: 'muted' }, ' as du counts it')),
      h('span', null, h('span', { class: 'sw res-sw-used', 'aria-hidden': 'true' }), 'Kept ', h('strong', null, bytes(keep))),
      h('span', null, h('span', { class: 'sw res-sw-clean', 'aria-hidden': 'true' }), 'Clean up frees ', h('strong', { 'data-cleanable': '' }, bytes(r.cleanableBytes))),
      h('span', null, h('span', { class: 'sw res-sw-shared', 'aria-hidden': 'true' }), 'Shared (APFS clones, counted again by du) ', h('strong', null, bytes(shared)))));
}
function resMemoryPanel(r) {
  const held = r.memory.reduce((a, m) => a + m.heldBytes, 0);
  const kinds = { sandbox: 'sandbox', host: 'the host', ui: 'this UI' };
  const rows = r.memory.map((m) => h('tr', { 'data-mem': m.kind + ':' + m.name },
    h('td', null, m.kind === 'sandbox' ? h('a', { href: '#/sandbox/' + m.name }, m.name) : m.name, h('span', { class: 'muted' }, ' · ' + (kinds[m.kind] || m.kind))),
    h('td', null, m.phase ? phasePill(m.phase) : '—'),
    h('td', { class: 'num' }, bytes(m.heldBytes), m.allocationBytes ? meter(m.heldBytes, m.allocationBytes) : null),
    h('td', { class: 'num' }, m.allocationBytes ? bytes(m.allocationBytes) : '—'),
    h('td', { class: 'num' }, m.cpus ?? '—')));
  return h('section', { class: 'res-group', 'data-res-group': 'memory' },
    h('div', { class: 'head' }, h('h2', null, 'Memory and CPUs'), h('span', { class: 'muted' }, bytes(held) + ' held · ' + r.allocatedCPUs + ' of ' + r.machineCPUs + ' CPUs given to sandboxes')),
    panel(table(['What', 'Phase', 'Held now', 'Allocation', 'CPUs'], rows, [2, 3, 4]), 'No sandbox has a VM, and no host is running.'));
}
function resNetworkPanel(r) {
  const rows = r.network.map((n) => h('tr', { 'data-net': n.sandbox },
    h('td', null, h('a', { href: '#/sandbox/' + n.sandbox }, n.sandbox)),
    h('td', { class: 'num' }, bytes(n.upToday)), h('td', { class: 'num' }, bytes(n.downToday)),
    h('td', { class: 'num' }, bytes(n.upTotal)), h('td', { class: 'num' }, bytes(n.downTotal)), h('td', { class: 'num' }, n.connectionsTotal)));
  return h('section', { class: 'res-group', 'data-res-group': 'network' },
    h('div', { class: 'head' }, h('h2', null, 'Network'), h('span', { class: 'muted' }, 'through each sandbox’s proxy, from the metrics')),
    panel(table(['Sandbox', 'Up today', 'Down today', 'Up in all', 'Down in all', 'Connections'], rows, [1, 2, 3, 4, 5]), 'No proxied traffic recorded yet.'));
}
function resKernelsPanel(r) {
  const rows = r.kernels.map((k) => h('tr', { 'data-kernel': k.id },
    h('td', null, h('span', { class: 'mono' }, k.version), k.current ? h('span', { class: 'tag res-current' }, 'current') : null, k.pinned ? h('span', { class: 'tag' }, 'this build’s') : null,
      k.inStore ? null : h('div', { class: 'muted' }, 'in a kernel cache outside this store')),
    h('td', { class: 'mono muted' }, k.sha256 || '—'),
    h('td', { class: 'num' }, bytes(k.sizeBytes)),
    h('td', null, k.usedBy.length ? k.usedBy.join(', ') : h('span', { class: 'muted' }, 'none')),
    h('td', null, k.current ? h('span', { class: 'muted' }, 'new sandboxes boot it')
      : btn('Use this kernel', () => act({ action: 'resources-kernel', kernel: k.id }), { small: true, title: 'New sandboxes boot it; existing ones keep theirs (a wake keeps its snapshot’s kernel)' }))));
  return h('section', { class: 'res-group', 'data-res-group': 'kernels' },
    h('div', { class: 'head' }, h('h2', null, 'Kernels'), h('span', { class: 'muted' }, '“Use this kernel” is for sandboxes created from now on')),
    panel(table(['Version', 'sha256', 'Size', 'Needed by', ''], rows, [2]), 'No kernel yet — the first start fetches it.'));
}
function paintResSelection() {
  const n = [...state.resSel].length;
  const b = document.querySelector('[data-res-delete]');
  if (b) { b.disabled = n === 0; setButton(b, n ? 'Delete ' + n + ' selected…' : 'Delete selected…', 'trash-2'); }
}
async function viewResources() {
  const r = await measured('resources', 'resources');
  // A selection that no longer exists (or can no longer go) is dropped.
  const ok = new Set(r.items.filter(resSelectable).map((i) => i.id));
  for (const id of [...state.resSel]) if (!ok.has(id)) state.resSel.delete(id);
  return resourcesNode(r);
}
function renderResources() {
  if (state.view !== 'resources' || !state.measured.resources) return;
  const top = $('main').scrollTop;
  $('view').replaceChildren(resourcesNode(state.measured.resources));
  $('main').scrollTop = top;
}
function resourcesNode(r) {
  const del = btn('Delete selected…', () => resDelete([...state.resSel], false), { danger: true, icon: 'trash-2' });
  del.setAttribute('data-res-delete', '');
  const selAll = btn('Select all re-creatable', () => {
    for (const i of r.items) if (resSelectable(i) && i.recreatable && !(i.parent && state.resSel.has(i.parent))) state.resSel.add(i.id);
    // A parent selected covers its parts.
    for (const i of r.items) if (i.parent && state.resSel.has(i.parent)) state.resSel.delete(i.id);
    renderResources();
  }, { icon: 'list-checks', title: 'Everything that is re-created when next needed (built-in images, caches, kernels, the guest init)' });
  const clear = btn('Clear selection', () => { state.resSel.clear(); renderResources(); }, { icon: 'x' });
  const node = h('div', { class: 'resources' },
    h('div', { class: 'head' }, h('h1', null, 'Resources'),
      h('div', { class: 'actions' }, btn('Refresh', () => { remeasure(); refresh(false); }, { small: true, title: 'Measure again' }),
        btn('Clean up…', () => resDelete([], true), { primary: true, icon: 'badge-check',
          title: 'Re-creatable AND unused: the download cache, base disks, old kernels, images no sandbox was created from in ' + r.unusedDays + ' days, leftovers. Never templates, sandboxes, restore points, settings or keys.' }))),
    h('p', { class: 'sub' }, 'Everything Dozer uses. Images are managed on ', h('a', { href: '#/images' }, 'Images'), ', a sandbox on its page, accounts on ',
      h('a', { href: '#/accounts' }, 'Accounts & keys'), ' — the rows link there. Deleting here is for what has no other home. Measured in ' + Math.round(r.milliseconds) + ' ms.'),
    resTotalBar(r),
    h('div', { class: 'res-toolbar' }, selAll, clear, del),
    RES_GROUPS.map(([g, t]) => resGroupPanel(r, g, t)),
    h('p', { class: 'res-sum', 'data-res-sum': '' }, 'The rows add up to ' + bytes(r.attributedBytes) + ' of the ' + bytes(r.totalBytes) + ' measured — unattributed: ',
      h('strong', { class: r.unattributedBytes ? 'res-refusal' : null }, bytes(r.unattributedBytes)), '.'),
    resMemoryPanel(r), resNetworkPanel(r), resKernelsPanel(r));
  const n = state.resSel.size;
  del.disabled = n === 0;
  if (n) setButton(del, 'Delete ' + n + ' selected…', 'trash-2');
  return node;
}
/// Preview (changes nothing), then ONE plain confirmation listing what goes, what it frees and what
/// each costs later; the operation deletes exactly those ids (a change since is refused, never widened).
async function resDelete(ids, clean) {
  if (!clean && !ids.length) return;
  let plan;
  try { plan = await api('resources/preview', { method: 'POST', json: clean ? { clean: true } : { ids } }); }
  catch (e) { toast(e.message || String(e), true); return; }
  if (!plan.items.length) {
    toast(clean ? 'Nothing to clean up — everything re-creatable is in use or already gone.' : 'Nothing can be deleted: ' + (plan.refused[0] ? plan.refused[0].reason : 'no such item'), !clean);
    return;
  }
  const n = plan.items.length;
  const list = h('div', { class: 'res-plan', 'data-res-plan': '' },
    table(['Item', 'Frees', 'Later'], plan.items.map((e) => h('tr', { 'data-plan-item': e.id },
      h('td', null, e.name, h('div', { class: 'muted mono' }, e.id)),
      h('td', { class: 'num' }, bytes(e.freedBytes)),
      h('td', null, e.later || '—', e.warning ? h('div', { class: 'res-warn' }, '⚠ ' + e.warning) : null))), [1]),
    plan.refused.length ? h('div', { class: 'res-refused' }, h('strong', null, 'Not deleted: '),
      plan.refused.map((x) => h('div', { 'data-plan-refused': x.id }, x.id + ' — ' + x.reason))) : null,
    h('p', { class: 'res-plan-total' }, 'Frees ', h('strong', { 'data-plan-freed': '' }, bytes(plan.freedBytes)), ' in all (blocks shared between them counted once).'));
  const title = clean ? 'Clean up' : 'Delete ' + n + ' item' + (n === 1 ? '' : 's');
  const d = dialog(title, (clean ? 'Re-creatable and unused — never templates, sandboxes, restore points, settings or keys. Logs and metrics are kept — select them to clear. ' : '') +
    'One operation: the host waits until nothing that uses the disks is under way.', [],
    clean ? 'Clean up' : 'Delete', async () => {
      const op = await actOrThrow({ action: 'resources-rm', ids: plan.items.map((e) => e.id) });
      state.resSel.clear();
      return op;
    }, { danger: true, icon: clean ? 'badge-check' : 'trash-2' });
  d.querySelector('.dlg-extra').append(list);
  d.classList.add('dlg-wide');
}

// ── adding an account from a key or a token (594, owner ruling) ──────────────
// While ui.allow_secret_entry (default on), the wizard's account step and this page take an API key or
// a setup token in a MASKED field. The value is read once, the field is emptied at once, and it goes
// out only in the body of one CSRF-checked POST /api/v1/accounts — never a URL, the page's state, a
// toast or an operation. The host stores it exactly as `doz account add` does (the login keychain,
// one check request). Off: the terminal commands instead.
function secretEntryAllowed() { return setting('ui.allow_secret_entry', true) === true; }
const ACCOUNT_COMMANDS = {
  'api-key': ['doz account add work --api-key       (it asks for the key, not echoed)', 'doz account default work'],
  'setup-token': ['claude setup-token                    (on this Mac: prints a 1-year token)',
    'doz account add work --setup-token   (paste it; not echoed)', 'doz account default work'],
};
function accountCommandsNode(kind) {
  return h('div', { class: 'panel wiz-cmds' },
    h('div', null, 'In a terminal on this Mac' + (secretEntryAllowed() ? ':' : ' (keys and tokens are not taken in this browser — ui.allow_secret_entry is off):')),
    h('pre', { class: 'mono' }, ACCOUNT_COMMANDS[kind].join('\n')));
}
/// opts: {kind (fixed) | null (a choice), name, onAdded(result, name)}.
function accountForm(opts) {
  const kindSel = h('select', { name: 'acct-kind', 'aria-label': 'Kind' },
    h('option', { value: 'api-key' }, 'Anthropic API key'), h('option', { value: 'setup-token' }, 'Claude setup token'));
  if (opts.kind) kindSel.value = opts.kind;
  const name = h('input', { type: 'text', name: 'acct-name', autocomplete: 'off', spellcheck: 'false', placeholder: 'a-z 0-9 -' });
  name.value = opts.name || 'work';
  const plan = h('select', { name: 'acct-plan', 'aria-label': 'Plan' }, ['max', 'pro', 'team', 'enterprise'].map((p) => h('option', { value: p }, p)));
  const secret = h('input', { type: 'password', name: 'acct-secret', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
                              'data-secret': '1', placeholder: 'paste it here' });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const planRow = h('label', { class: 'field' }, h('span', null, 'Plan (what Claude Code shows; it picks its default model by it)'), plan);
  const secretLabel = h('span', null, '');
  const hint = h('small', null, '');
  const paint = () => {
    const token = kindSel.value === 'setup-token';
    planRow.hidden = !token;
    secretLabel.textContent = token ? 'Setup token' : 'API key';
    hint.textContent = token ? 'Run claude setup-token on this Mac and paste what it prints (it starts sk-ant-oat…; valid a year). Not shown, not kept in this page.'
                             : 'An Anthropic API key (sk-ant-api…). Not shown, not kept in this page.';
  };
  kindSel.addEventListener('change', paint);
  paint();
  const add = btn('Add account', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const value = secret.value;
    secret.value = '';                                     // gone from the page before the request
    const n = name.value.trim();
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(n) || n === 'default' || n === 'none') { error.textContent = 'The name: 1–40 of a-z 0-9 - (not default or none).'; return; }
    if (value.trim().length < 20) { error.textContent = 'Paste the whole ' + (kindSel.value === 'setup-token' ? 'token' : 'key') + '.'; return; }
    b.disabled = true;
    try {
      const body = { name: n, kind: kindSel.value, secret: value };
      if (kindSel.value === 'setup-token') body.plan = plan.value;
      const r = await api('accounts', { method: 'POST', json: body });
      opts.onAdded(r, n);
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      b.disabled = false;
    }
  }, { primary: true, icon: 'key-round' });
  return h('div', { class: 'panel acct-form' },
    opts.kind ? null : h('label', { class: 'field' }, h('span', null, 'Kind'), kindSel),
    h('label', { class: 'field' }, h('span', null, 'Account name'), name),
    planRow,
    h('label', { class: 'field' }, secretLabel, secret, hint),
    error,
    h('div', { class: 'wiz-buttons' }, add));
}

// ── 594: an agent's credential prerequisite in a create form ────────────────
// Owner (2026-09-30): "creating a Pi sandbox should have pre-requisites for things like API key so that
// this is not the first experience". The account picker offers only the accounts the chosen image's
// agent can use (the host's table: WebAccounts.agents — pi: an Anthropic API key); an incompatible
// store default is not preselected. When the agent needs one and none fits: "pi needs an Anthropic API
// key", with the masked key field right there (accountForm: the same route and guarantees) — or, with
// ui.allow_secret_entry off, the commands. `ok()` says whether the form may create.
const AGENT_NAMES = { 'claude-code': 'Claude Code', pi: 'pi' };
const KIND_LABELS = { mac: 'this Mac’s login', 'setup-token': 'setup token', 'api-key': 'API key' };
function accountChooser({ accounts, agent, same = null, defaultValue = '', onChange = () => {} }) {
  let acc = accounts, current = agent(), chosen = null;
  const el = h('div', { class: 'field acct-chooser', 'data-acct-chooser': '' });
  const kindsOf = (a) => (a && acc.agents ? acc.agents[a] : null);
  const fits = (kinds) => acc.accounts.filter((x) => !kinds || kinds.includes(x.kind));
  function state() {
    const kinds = kindsOf(current);
    const needs = !!kinds && !kinds.includes('mac');
    const usable = fits(kinds);
    const def = acc.accounts.find((x) => x.name === acc.defaultAccount);
    const defFits = acc.defaultAccount !== 'none' ? (!!def && (!kinds || kinds.includes(def.kind))) : !needs;
    return { kinds, needs, usable, defFits };
  }
  function render() {
    const s = state();
    const opts = [];
    if (same) opts.push(['', same]);
    if (s.defFits) opts.push([defaultValue, 'the store default (' + acc.defaultAccount + ')']);
    for (const x of s.usable) opts.push([x.name, x.name + ' (' + (KIND_LABELS[x.kind] || x.kind) + ')']);
    if (!s.needs) opts.push(['none', 'none']);
    const sel = h('select', { name: 'account', 'aria-label': 'Account' }, opts.map(([v, l]) => h('option', { value: v }, l)));
    if (chosen !== null && opts.some(([v]) => v === chosen)) sel.value = chosen;
    chosen = sel.value;
    sel.addEventListener('change', () => { chosen = sel.value; onChange(); });
    const name = AGENT_NAMES[current] || current;
    const missing = s.needs && !s.usable.length;
    el.dataset.acctOk = String(!missing);
    const parts = [h('span', null, 'Account')];
    if (!missing) parts.push(sel);
    if (s.kinds && current) {
      parts.push(h('small', { class: 'muted' }, name + ' can use: ' + s.kinds.map((k) => KIND_LABELS[k] || k).join(', ')
        + (s.needs ? ' — never a Claude subscription' : '')));
    }
    if (missing) {
      parts.push(h('div', { class: 'acct-need', 'data-acct-need': current },
        h('div', { class: 'acct-need-title' }, icon('key-round'), ' ' + name + ' needs an Anthropic API key'),
        h('small', null, 'Add one now — it is stored as `doz account add` stores it (the login keychain), and this sandbox uses it.'),
        secretEntryAllowed()
          ? accountForm({ kind: 'api-key', name: acc.accounts.some((x) => x.name === 'anthropic') ? 'anthropic-2' : 'anthropic',
              onAdded: (r, n) => { acc = r; chosen = n; toast('account ' + n + ' added'); render(); onChange(); } })
          : accountCommandsNode('api-key')));
    }
    el.replaceChildren(...parts);
  }
  render();
  return {
    el,
    /// The image changed: its agent's accounts.
    agentChanged() { current = agent(); chosen = null; render(); onChange(); },
    ok() { return el.dataset.acctOk === 'true'; },
    /// The account to send (undefined: the store default / the same).
    get() { return chosen ? chosen : undefined; },
  };
}

/// 594: which account a sandbox uses — only the ones its agent can use (and the key right there when
/// none fits). It applies to the sandbox's next session.
function accountDialog(name, i, accounts) {
  const slot = h('div');
  let acct = null;
  const dlg = dialog('Account of ' + name, 'Which Anthropic account the proxy uses for it — from its next session. The guest only ever sees a placeholder.',
    [{ name: 'account', type: 'custom', el: slot, get: () => {
      if (!acct.ok()) throw new Error((AGENT_NAMES[i.agent] || 'This agent') + ' needs an Anthropic API key — add one above.');
      return acct.get() || 'default';
    } }], 'Use', async (v) => {
      await actOrThrow({ action: 'account-use', sandbox: name, account: v.account });
    });
  const submit = dlg.querySelector('button[type="submit"]');
  acct = accountChooser({ accounts, agent: () => i.agent, defaultValue: 'default', onChange: () => { submit.disabled = !acct.ok(); } });
  slot.replaceWith(acct.el);
  submit.disabled = !acct.ok();
}

/// 594: an existing sandbox whose account does not fit its agent — "pi can't use the account mac —
/// choose an API-key account" — with the accounts that fit (or the key field) right there.
function credentialBanner(name, i, accounts) {
  return h('div', { class: 'cred-banner', role: 'alert', 'data-cred-banner': name },
    h('div', { class: 'cred-banner-text' }, icon('key-round'), ' ' + i.credentialProblem),
    h('div', { class: 'actions' },
      btn('Choose an account…', () => accountDialog(name, i, accounts), { small: true, primary: true, icon: 'key-round' })));
}

/// 594 (owner ruling: sandbox keys in the browser too): a sandbox's own Anthropic key — what `doz key set
/// NAME --anthropic` does — under the same setting and rules as accountForm: a masked field, emptied
/// before the request, one CSRF-checked POST /api/v1/sandboxes/NAME/key body; off: the commands.
function keyEntry(name, proxied) {
  if (!proxied) return h('p', { class: 'muted' }, 'Not proxied: a key would have to enter the sandbox — create it with a proxied network (agent, open, …) to give it one.');
  if (!secretEntryAllowed()) {
    return h('div', { class: 'panel wiz-cmds', 'data-key-commands': name },
      h('div', null, 'In a terminal on this Mac (keys are not taken in this browser — ui.allow_secret_entry is off):'),
      h('pre', { class: 'mono' }, ['doz key set ' + name + ' --anthropic                       (it asks for the key, not echoed)',
        'doz key set ' + name + ' --anthropic --keychain SERVICE      (read from a keychain item)'].join('\n')));
  }
  const secret = h('input', { type: 'password', name: 'key-secret', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
                              'data-secret': '1', placeholder: 'sk-ant-api… — paste it here' });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const set = btn('Set key', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const value = secret.value;
    secret.value = '';                                     // gone from the page before the request
    if (value.trim().length < 20) { error.textContent = 'Paste the whole key.'; return; }
    b.disabled = true;
    try {
      await api('sandboxes/' + name + '/key', { method: 'POST', json: { secret: value } });
      toast('anthropic key set for ' + name + ' (held by the host, in memory; never in the sandbox)');
      refreshSandbox();
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      b.disabled = false;
    }
  }, { primary: true, small: true, icon: 'key-round' });
  return h('div', { class: 'panel acct-form key-form', 'data-key-form': name },
    h('label', { class: 'field' }, h('span', null, 'Set an Anthropic API key for ' + name), secret,
      h('small', null, 'Held by the host in memory (as doz key set from a prompt): it lasts while the host runs, replaces this sandbox’s account, and the guest only ever sees a placeholder. Not shown, not kept in this page.')),
    error, h('div', { class: 'wiz-buttons' }, set),
    h('div', { class: 'muted' }, 'From a keychain item instead: ', h('code', null, 'doz key set ' + name + ' --anthropic --keychain SERVICE'), ' in a terminal.'));
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
    h('h2', null, 'Add an account'),
    secretEntryAllowed()
      ? accountForm({ kind: null, onAdded: (r, name) => {
          const row = r.accounts.find((x) => x.name === name);
          toast('account ' + name + ' added' + (row && row.verification ? ' (' + row.verification + ')' : ''));
          refresh(false);
        } })
      : h('div', null, accountCommandsNode('setup-token'), accountCommandsNode('api-key')),
    h('p', { class: 'muted' }, 'Stored exactly as doz account add stores it: the login keychain (doz-claude:NAME, doz-anthropic:NAME), after one tiny check request. ',
      'This page keeps no copy. ui.allow_secret_entry (Settings) turns the field off.'));
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
  const csv = h('a', { class: 'btn small', href: '/api/v1/metrics.csv?' + qs, download: 'dozer-metrics.csv' }, withIcon('download', 'Download CSV'));
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
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Doctor'),
      btn('Run onboarding again', () => { state.wiz = null; location.hash = '#/onboarding'; },
        { title: 'The setup wizard: checks, the Claude account, settings, images — it prepares only what is missing' })),
    h('p', { class: 'sub' }, 'doz doctor: this Mac, the store, the host and the Claude login (re-checked at most every 30 s).'),
    panel(table(['', 'Check', 'Detail'], rows)));
}

// ── onboarding (594) ────────────────────────────────────────────────────────
// The wizard (D11): Welcome → Checks → Claude account → Images → Preparing → First sandbox → Done.
// The same model as every page: facts from GET /api/v1/onboarding; changes through the typed actions
// (account-default, onboard, prepare-cancel, create) and ONE typed route for the settings file and
// the prompt template (POST /api/v1/onboarding/config — each written only when missing, never
// overwritten). A key or a setup token: the masked field (accountForm) while ui.allow_secret_entry,
// else the CLI command. The preparation runs in the HOST: "Continue in the background" leaves it
// running (Operations shows it), and closing this tab changes nothing.
const WIZ_STEPS = ['Welcome', 'Checks', 'Claude account', 'Images', 'Preparing', 'First sandbox', 'Done'];
const WIZ_ORDER = ['claude-code', 'pi', 'lab'];
let wizTimer = null;
function wizardStopPolling() { clearInterval(wizTimer); wizTimer = null; }
function wizardPoll() {
  if (wizTimer) return;
  wizTimer = setInterval(async () => {
    if (state.view !== 'onboarding' || !state.wiz || state.wiz.step !== 4) { wizardStopPolling(); return; }
    try { state.preps = await api('preparations'); } catch (_) { return; }
    renderOps();
    renderWizard();
  }, 1000);
}
async function viewOnboarding() {
  if (!state.wiz) state.wiz = { step: 0, data: null, account: null, images: null, config: null, created: null, busy: false };
  const w = state.wiz;
  if (!w.data || w.step <= 1) w.data = await api('onboarding');
  if (w.step === 4) { await loadPreparations(); wizardPoll(); }
  return wizardNode();
}
/// Re-render in place (a preparation's progress; a step change). The first-sandbox form is never
/// re-rendered under the person typing in it.
function renderWizard(force) {
  if (state.view !== 'onboarding' || !state.wiz) return;
  if (!force && state.wiz.step !== 4) return;
  $('view').replaceChildren(wizardNode());
}
function wizGo(step) {
  const w = state.wiz;
  w.step = step;
  if (step === 4) { loadPreparations().then(() => renderWizard(true)); wizardPoll(); } else wizardStopPolling();
  if (step >= 5) refreshNav();          // the nav's Onboarding dot goes once the record is written
  renderWizard(true);
  $('main').scrollTop = 0;
}
function wizButtons(...buttons) { return h('div', { class: 'wiz-buttons' }, buttons); }
function wizChosenImages() {
  const w = state.wiz, d = w.data;
  if (!w.images) w.images = new Set(d.images.filter((i) => i.recommended || i.prepared).map((i) => i.name));
  return WIZ_ORDER.filter((n) => w.images.has(n));
}
function wizDiskNeed() {
  const d = state.wiz.data;
  const todo = d.images.filter((i) => state.wiz.images.has(i.name) && !i.prepared);
  if (!todo.length) return 0;
  const base = todo.some((i) => i.name === 'claude-code' || i.name === 'pi') ? d.nodeBaseBytes : 0;
  return d.commonBytes + base + d.headroomBytes + todo.reduce((s, i) => s + i.diskBytes, 0);
}
function wizardNode() {
  const w = state.wiz, d = w.data;
  // 596: the base catalogue for the First sandbox step, read early (a late answer never re-renders a typed form).
  if (!w.basesAsked) { w.basesAsked = true; api('bases').then((b) => { w.bases = b; }).catch(() => { w.bases = null; }); }
  const stepper = h('ol', { class: 'wiz-steps', 'aria-label': 'Steps' }, WIZ_STEPS.map((s, i) =>
    h('li', { class: i === w.step ? 'current' : i < w.step ? 'done' : null, 'aria-current': i === w.step ? 'step' : null }, h('span', { class: 'wiz-n' }, String(i + 1)), s)));
  const body = [wizStep0, wizStep1, wizStep2, wizStep3, wizStep4, wizStep5, wizStep6][w.step](d, w);
  return h('div', { class: 'wizard', 'data-step': String(w.step) },
    h('h1', null, 'Set up Dozer Sandbox'),
    h('p', { class: 'sub' }, 'Once for this Mac (store ', h('code', null, $('store-path').textContent), '). The same as ', h('code', null, 'doz onboard'), ' in a terminal.'),
    stepper, h('section', { class: 'wiz-body panel' }, body));
}
function wizStep0(d) {
  return [
    h('h2', null, 'Welcome'),
    h('p', null, 'Dozer Sandbox runs each project in its own small Linux virtual machine on this Mac — an agent like Claude Code works there, not on your Mac. A sandbox pauses in a millisecond, hibernates to disk and wakes in a third of a second.'),
    h('p', null, 'Setting up takes a few minutes, once: this Mac is checked, you choose how sandboxes reach Claude, the settings file is written, and the images you pick are downloaded and prepared — in the background, so the first sandbox starts in seconds instead of minutes.'),
    d.onboarded ? h('div', { class: 'notice' }, 'This store was set up on ' + full(d.onboarded.date) + ' (doz ' + d.onboarded.dozVersion + ')' +
      (d.onboarded.images.length ? ', with ' + d.onboarded.images.join(', ') : '') + '. Running it again checks again and prepares only what is missing.') : null,
    wizButtons(btn('Get started', () => wizGo(1), { primary: true })),
  ];
}
function wizStep1(d, w) {
  const rows = d.checks.map((c) => h('tr', { 'data-check': c.check },
    h('td', null, statusPill(c.status === 'fail' && !c.hard ? 'warn' : c.status)),
    h('td', null, c.check, c.hard ? h('span', { class: 'tag' }, 'required') : null),
    h('td', null, c.detail)));
  const next = btn('Next', () => wizGo(2), { primary: true });
  if (d.blocked) next.disabled = true;
  return [
    h('h2', null, 'Checks'),
    h('p', { class: 'sub' }, 'The doctor’s checks. A required one that fails stops the setup; the others only say what will not work yet (Claude Code missing or signed out: add an account later; vmnet: only --network nat needs it).'),
    table(['', 'Check', 'Detail'], rows),
    d.blocked ? h('div', { class: 'notice bad' }, 'A required check failed — fix it, then Check again.') : null,
    wizButtons(btn('Back', () => wizGo(0)), btn('Check again', async () => { w.data = await api('onboarding'); renderWizard(true); }), next),
  ];
}
function wizStep2(d, w) {
  if (!w.account) w.account = d.preferredAccount;
  const opts = d.accountOptions.map((o) => {
    const input = h('input', { type: 'radio', name: 'wiz-account', value: o.value });
    input.checked = o.value === w.account;
    input.addEventListener('change', () => { w.account = o.value; renderWizard(true); });
    return h('label', { class: 'wiz-choice' + (o.value === w.account ? ' chosen' : ''), 'data-account': o.value }, input,
      h('span', null, o.label, o.value === d.preferredAccount ? h('span', { class: 'tag' }, 'recommended') : null));
  });
  const keyed = w.account === 'api-key' || w.account === 'setup-token';
  let entry = null;
  if (keyed && w.added) {
    entry = h('div', { class: 'notice', 'data-added': w.added.name }, 'Account ', h('strong', null, w.added.name), ' added (' + w.added.kind +
      (w.added.verification ? ', ' + w.added.verification : '') + ') — the store’s default account. Its secret is in the login keychain, not in this page.');
  } else if (keyed && secretEntryAllowed()) {
    entry = accountForm({ kind: w.account, name: 'work', onAdded: async (r, name) => {
      const row = r.accounts.find((x) => x.name === name) || { kind: w.account };
      try { await actOrThrow({ action: 'account-default', account: name }); } catch (e) { toast(e.message || String(e), true); }
      w.added = { name, kind: row.kind, verification: row.verification };
      renderWizard(true);
    } });
  } else if (keyed) {
    entry = accountCommandsNode(w.account);
  }
  return [
    h('h2', null, 'Claude account'),
    h('p', null, d.macSignedIn
      ? 'Claude Code is signed in on this Mac. Sandboxes can use that login: nothing is copied into them — the Mac’s proxy adds it to their requests to Anthropic, and the Mac keeps renewing it.'
      : 'Claude Code is not signed in on this Mac. A sandbox can use an Anthropic API key or a Claude setup token instead, or you can decide later.'),
    h('fieldset', { class: 'wiz-choices' }, h('legend', null, 'How should sandboxes reach Claude?'), opts),
    entry,
    h('p', { class: 'muted' }, 'The setup never logs in for you and never copies Claude Code’s refresh token. A key or a token is stored as doz account add stores it (the login keychain). The store’s default account now: ' +
      (w.added ? w.added.name : d.defaultAccount) + '.'),
    wizButtons(btn('Back', () => wizGo(1)), btn('Next', async (ev) => {
      const b = ev.currentTarget;
      b.disabled = true;
      try {
        if (w.account === 'mac' && d.defaultAccount !== 'mac') await actOrThrow({ action: 'account-default', account: 'mac' });
        wizGo(3);
      } catch (e) { toast(e.message || String(e), true); b.disabled = false; }
    }, { primary: true })),
  ];
}
function wizStep3(d, w) {
  wizChosenImages();
  const items = d.images.map((i) => {
    const input = h('input', { type: 'checkbox', value: i.name });
    input.checked = w.images.has(i.name);
    input.addEventListener('change', () => { if (input.checked) w.images.add(i.name); else w.images.delete(i.name); renderWizard(true); });
    return h('label', { class: 'wiz-choice wiz-image' + (input.checked ? ' chosen' : ''), 'data-image': i.name }, input,
      h('span', null, h('strong', null, i.name), i.recommended ? h('span', { class: 'tag' }, 'recommended') : null,
        i.prepared ? h('span', { class: 'pill st-ok' }, 'ready') : null,
        h('div', null, i.summary),
        h('div', { class: 'muted' }, i.prepared ? 'already prepared in this store' : i.download + ' · ' + i.estimate)));
  });
  const need = wizDiskNeed();
  const short = d.freeBytes != null && need > d.freeBytes;
  const chosen = wizChosenImages();
  const todo = chosen.filter((n) => !d.images.find((i) => i.name === n).prepared);
  const go = btn(todo.length ? 'Prepare and continue' : 'Continue', async (ev) => {
    const b = ev.currentTarget;
    b.disabled = true;
    try {
      w.config = await api('onboarding/config', { method: 'POST', json: { defaultImage: chosen[0] || 'claude-code', account: w.account || d.preferredAccount } });
      await actOrThrow({ action: 'onboard', images: chosen });
      w.prepImages = todo;
      wizGo(todo.length ? 4 : 5);
    } catch (e) { toast(e.message || String(e), true); b.disabled = false; }
  }, { primary: true });
  if (short) go.disabled = true;
  return [
    h('h2', null, 'Images'),
    h('p', { class: 'sub' }, 'Preparing an image downloads its base and bakes it — the part a first start would otherwise make you wait for. claude-code is ticked; pi and lab are optional (each can also be prepared later, or by its first start).'),
    h('div', { class: 'wiz-choices' }, items),
    h('p', { class: short ? 'st-fail' : 'muted', 'data-disk': '1' }, need ? 'About ' + bytes(need) + ' of disk needed (with room for a first sandbox)' +
      (d.freeBytes != null ? '; ' + bytes(d.freeBytes) + ' free' : '') + (short ? ' — free some space or choose fewer images.' : '.') : 'Nothing to download.'),
    wizButtons(btn('Back', () => wizGo(2)), go),
  ];
}
/// 594 (owner: "more progress detail"): ONE card for a host preparation — the wizard's Preparing step and
/// the Operations page both draw it — from the host's model (593's ProgressBoard: the step under way, the
/// transfer, the output's last lines; plus step N of M, the finished steps, the last run's times).
///   · overall: "Step N of M" and a DETERMINATE bar (steps done / M), about how long is left;
///   · the step under way: its label, its seconds, "usually ~X" — and an animated strip, never a full bar;
///   · a download: its own determinate bar with bytes, speed and time left;
///   · the output's last lines (guest text, already inert; cut to the width here);
///   · the finished steps (open in the wizard), ✓ with the time each took, ✕ with why and its last output.
function dur(s) { return s == null ? '—' : s < 1 ? Math.round(s * 1000) + ' ms' : s < 60 ? (s < 10 ? s.toFixed(1) : Math.round(s)) + ' s' : Math.floor(s / 60) + ' min ' + Math.round(s % 60) + ' s'; }
function approx(s) { return s < 60 ? '~' + Math.max(1, Math.round(s)) + ' s' : '~' + Math.round(s / 60) + ' min'; }
function determinate(fraction, cls, label) {
  const bar = h('div', { class: 'wiz-bar ' + (cls || ''), role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-label': label || null,
                         'aria-valuenow': (fraction * 100).toFixed(0), 'data-fraction': fraction.toFixed(3) });
  const fill = h('span');
  fill.style.width = (Math.max(0, Math.min(1, fraction)) * 100).toFixed(1) + '%';
  bar.append(fill);
  return bar;
}
function prepCard(p, opts = {}) {
  const running = prepRunning(p);
  const n = p.stepIndex || 0, m = p.plannedSteps;
  const done = running ? Math.max(0, n - 1) : n;
  const overall = m ? h('div', { class: 'prep-overall', 'data-step': String(n), 'data-steps': String(m) },
    h('div', { class: 'prep-overall-line' },
      h('span', null, 'Step ' + n + ' of ' + m),
      h('span', { class: 'muted prep-estimate' }, running
        ? (p.remainingSeconds != null ? 'about ' + approx(p.remainingSeconds).slice(1) + ' left' : (p.estimateBasis || ''))
        : '')),
    determinate(done / m, 'prep-overall-bar', 'steps done')) : null;
  const current = running && p.step ? h('div', { class: 'prep-current' },
    h('div', { class: 'prep-step' }, h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), ' ', p.step,
      h('span', { class: 'muted' }, '  ' + dur(p.stepSeconds || 0) + (p.stepUsualSeconds != null ? ' · usually ' + approx(p.stepUsualSeconds) : ''))),
    h('div', { class: 'wiz-bar indeterminate prep-step-bar', 'aria-hidden': 'true' }, h('span'))) : null;
  const pulling = running && p.transferLine && (p.transferFraction == null || p.transferFraction < 1);
  const transfer = pulling ? h('div', { class: 'prep-transfer-block' },
    p.transferFraction != null ? determinate(p.transferFraction, 'prep-transfer-bar', 'downloaded') : null,
    h('div', { class: 'mono prep-transfer' }, p.transferLine)) : null;
  const tail = running && p.output.length ? h('div', { class: 'mono prep-output', 'data-tail': String(p.output.length) },
    p.output.map((l) => h('div', null, '│ ' + l))) : null;
  const items = p.steps.map((s) => h('li', { class: 'prep-done-' + s.kind },
    h('span', { class: 'op-state' }, s.kind === 'failed' ? '✕' : s.kind === 'transfer' ? '↓' : '✓'), ' ', s.label,
    h('span', { class: 'muted' }, s.kind === 'transfer' ? '' : ' — ' + dur(s.seconds) + (s.usualSeconds != null ? ' (last time ' + dur(s.usualSeconds) + ')' : '')),
    s.error ? h('div', { class: 'st-fail' }, s.error) : null,
    s.output ? h('div', { class: 'mono prep-output' }, s.output.map((l) => h('div', null, '│ ' + l))) : null));
  const key = 'prep-open-' + p.id;
  const details = items.length ? h('details', { class: 'prep-lines' },
    h('summary', null, 'Finished steps (' + p.steps.filter((s) => s.kind !== 'transfer').length + ')'),
    h('ul', { class: 'prep-steps' }, items)) : null;
  if (details) {
    const want = state[key] ?? !!opts.open;
    if (want) details.open = true;
    details.addEventListener('toggle', () => { state[key] = details.open; });
  }
  return h('div', { class: 'prep-card prep-' + p.state, 'data-prep': p.image },
    h('div', { class: 'prep-head' }, running ? h('span', { class: 'mini-spin', 'aria-hidden': 'true' }) : h('span', { class: 'op-state' }, p.state === 'done' ? '✓' : '✕'),
      h('strong', null, p.image), h('span', { class: 'muted' }, ' · ' + (running ? dur(p.seconds) + ' so far' : p.state + ' in ' + dur(p.seconds)) + ' · asked by ' + p.requestedBy.join(', '))),
    overall, current, transfer, tail,
    p.error && p.state !== 'cancelled' ? h('div', { class: 'notice bad' }, p.error) : null,
    running && p.estimateBasis && p.remainingSeconds == null && !m ? h('div', { class: 'muted' }, p.estimateBasis) : null,
    details);
}
function wizStep4(d, w) {
  const mine = w.prepImages || [];
  // Every preparation the host runs (another image's too — each with its own progress), and this
  // wizard's own; the newest of each image.
  const preps = state.preps.filter((p) => mine.includes(p.image) || prepRunning(p)).filter((p, i, a) => a.findIndex((x) => x.image === p.image) === i);
  const ours = preps.filter((p) => mine.includes(p.image));
  const running = ours.some(prepRunning);
  const failed = ours.filter((p) => !prepRunning(p) && p.state !== 'done');
  const next = btn('Next', () => wizGo(5), { primary: true });
  if (running || failed.length) next.disabled = true;
  return [
    h('h2', null, 'Preparing'),
    h('p', { class: 'sub' }, 'In the host — not in this page: closing the tab changes nothing, and doz onboard --status in a terminal shows the same. Whoever starts a sandbox of these images meanwhile joins this preparation instead of starting another.'),
    preps.length ? h('div', { class: 'prep-cards' }, preps.map((p) => prepCard(p, { open: true }))) : h('p', { class: 'muted' }, 'Starting…'),
    wizButtons(
      running ? btn('Cancel preparation', () => act({ action: 'prepare-cancel', images: mine }), { danger: true }) : null,
      failed.length ? btn('Try again', async () => {
        try { await actOrThrow({ action: 'onboard', images: failed.map((p) => p.image) }); await loadPreparations(); renderWizard(true); } catch (e) { toast(e.message || String(e), true); }
      }) : null,
      running ? btn('Continue in the background', () => { toast('It goes on in the host — Operations shows it.'); wizGo(5); }) : null,
      next),
  ];
}
function wizStep5(d, w) {
  const chosen = wizChosenImages();
  const imgs = [...new Set([...chosen, ...d.images.filter((i) => i.prepared).map((i) => i.name)])];
  const name = h('input', { type: 'text', name: 'wiz-name', placeholder: 'a-z 0-9 -', autocomplete: 'off', spellcheck: 'false' });
  name.value = w.firstName || '';
  // 596 (B1): the same Agent × Base choice as New Sandbox (the catalogue read when the wizard opened).
  let chooser = null;
  const picker = imagePicker({ images: [], bases: w.bases || null, value: w.firstImage || imgs[0] || 'claude-code', dockerfile: w.firstDockerfile || '',
    onChange: () => { w.firstImage = picker.image(); w.firstDockerfile = picker.dockerfile() || ''; if (chooser) chooser.imageChanged(); if (acct) acct.agentChanged(); },
    onDockerfile: (folder) => { if (chooser) chooser.suggest(folder); } });
  const image = { get value() { return picker.image(); } };
  // 594: the name from the image (claude-sandbox, -2 when taken), its folder under the projects folder
  // (made when missing) — both follow until typed in; Choose… is the Mac's own folder picker; or Isolated.
  chooser = workspaceChooser({ nameInput: name, image: () => pickerNameHint(picker), initialPath: w.firstWorkspace || '', initialIsolated: !!w.firstIsolated });
  if (w.firstName) name.dispatchEvent(new Event('input'));
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  // 594: the agent's credential prerequisite — only accounts it can use; pi with none: the key here.
  if (!w.accounts) api('accounts').then((a) => { w.accounts = a; if (w.step === 5) renderWizard(true); }).catch(() => { w.accounts = { accounts: [] }; });
  let acct = null;
  const create = btn('Create sandbox', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const n = name.value.trim();
    w.firstName = n;
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(n)) { error.textContent = 'The name: 1–40 of a-z 0-9 - (not starting with -).'; return; }
    let ws;
    try { ws = chooser.get(); } catch (e) { error.textContent = e.message; return; }
    if (acct && !acct.ok()) { error.textContent = (AGENT_NAMES[picker.agent()] || 'This agent') + ' needs an Anthropic API key — add one above.'; return; }
    const blocked = picker.blocked();
    if (blocked) { error.textContent = blocked; return; }
    w.firstWorkspace = ws.workspace || '';
    w.firstIsolated = !!ws.isolated;
    b.disabled = true;
    try {
      const account = acct ? acct.get() : undefined;
      const df = picker.dockerfile();
      await actOrThrow({ action: 'create', sandbox: n, image: image.value, ...ws, ...(account ? { account } : {}), ...(df ? { dockerfile: df } : {}) });
      w.created = n;
      wizGo(6);
    } catch (e) { error.textContent = e.message || String(e); b.disabled = false; }
  }, { primary: true });
  if (w.accounts) {
    acct = accountChooser({ accounts: w.accounts, agent: () => picker.agent(),
      onChange: () => { create.disabled = !acct.ok(); api('accounts').then((a) => { w.accounts = a; }).catch(() => {}); } });
    create.disabled = !acct.ok();
  } else create.disabled = true;
  return [
    h('h2', null, 'First sandbox (optional)'),
    h('p', { class: 'sub' }, 'A sandbox for one project. Its workspace is a folder on this Mac, shared live at /workspace — Dozer makes it when it does not exist yet. Or Isolated: nothing is shared. It is created off; Start boots it.'),
    h('label', { class: 'field' }, h('span', null, 'Name'), name),
    picker.el,
    acct ? acct.el : null,
    chooser.el,
    error,
    h('p', { class: 'muted' }, 'In a terminal the same is: doz init in the project folder, then doz up.'),
    wizButtons(btn('Skip', () => wizGo(6)), create),
  ];
}
function wizStep6(d, w) {
  const c = w.config;
  const fileLine = (label, outcome, path) => h('li', null, label + ': ', h('code', null, path || '—'),
    outcome === 'written' ? ' — written' : outcome === 'kept' ? ' — it existed, left exactly as it was' : ' — none');
  const preps = state.preps.filter((p) => (w.prepImages || []).includes(p.image));
  const still = preps.filter(prepRunning).map((p) => p.image);
  return [
    h('h2', null, 'Done'),
    h('p', null, still.length ? 'This Mac is set up; ' + still.join(', ') + ' ' + (still.length === 1 ? 'is' : 'are') + ' still being prepared in the host (Operations shows it) — the onboarding is recorded when it is ready.'
                              : 'This Mac is set up.'),
    h('ul', { class: 'plain wiz-summary' },
      h('li', null, 'Claude account: ' + (w.added ? 'the account ' + w.added.name + ' (' + w.added.kind + '), the store default'
        : (d.accountOptions.find((o) => o.value === w.account) || { label: w.account || '—' }).label)),
      c ? fileLine('Settings', c.settings, c.settingsPath) : null,
      c ? fileLine('Your environment prompt template', c.promptTemplate, c.promptTemplatePath) : null,
      h('li', null, 'Images: ' + (wizChosenImages().join(', ') || 'none now (each is prepared by its first start)')),
      w.created ? h('li', null, 'First sandbox: ', h('a', { href: '#/sandbox/' + w.created }, w.created)) : null),
    h('p', { class: 'muted' }, 'From a terminal: doz init in a project folder, then doz up there. This wizard is always here: Doctor › Run onboarding again.'),
    wizButtons(w.created ? btn('Open ' + w.created, () => { location.hash = '#/sandbox/' + w.created; }, { icon: 'box' }) : null,
      btn('Open Sandboxes', () => { state.wiz = null; location.hash = '#/overview'; }, { primary: true })),
  ];
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
const termUI = { built: false, by: {}, nextId: 1, dropped: 0 };
/// 593: each sandbox's page keeps its own split, selected tab per pane and focused pane.
function sview(name) {
  if (!termUI.by[name]) termUI.by[name] = { split: false, selected: [null, null], focusedPane: 0 };
  return termUI.by[name];
}
const PASTE_CONFIRM_BYTES = 64 * 1024;
const PASTE_MAX_BYTES = 1024 * 1024;
const INPUT_CHUNK = 16 * 1024;
const utf8 = new TextEncoder();

// This page never opens windows.
window.open = function refuseToOpen() { return null; };

function wasmURL() {
  const m = document.querySelector('meta[name="doz-ghostty-wasm"]');
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
    case 'key': return n === 1;
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
    case 'key': savedKey(t); break;
  }
});

/// Open the image's own session (starting it when needed — an explicit request), then attach.
async function openDefaultTerminal(name) {
  if (!terminalsAllowed()) return;
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

/// The setting ui.terminals: off, the UI opens no browser terminal (and the server refuses a ticket).
function terminalsAllowed() {
  if (setting('ui.terminals', true)) return true;
  toast('Browser terminals are off (Settings → ui.terminals). Open in Terminal still works.', true);
  return false;
}

/// 593: a terminal record (a page terminal, or a grid tile's when `grid`).
function newTerm(sandbox, session, mode) {
  const t = { id: termUI.nextId++, sandbox, session, mode, pane: 0, grid: false, saved: null, lazy: false,
              ws: null, frame: null, cols: 80, rows: 24, state: null, ended: false, endText: '', errorText: '', disconnected: '',
              closed: false, title: '', pinger: null, coverAction: null, onReady: null, onOpened: null, onFailed: null };
  t.els = terminalElements(t);
  terminals.set(t.id, t);
  return t;
}
/// Load the engine into the terminal's frame, then connect. False when it could not.
async function bootTerm(t, fontSize) {
  try {
    const wasm = await engineBytes();
    if (t.closed) return false;
    const opened = new Promise((resolve, reject) => { t.onOpened = resolve; t.onFailed = reject; });
    t.onReady = () => {
      t.initMode = t.saved ? 'saved' : t.mode;
      toFrame(t, { t: 'init', wasm: wasm.slice(0), mode: t.initMode, fontSize: isInt(fontSize, 9, 32) ? fontSize : 13 });
    };
    // The engine's frame: an opaque origin (allow-scripts only — no same-origin, no popups, no forms).
    t.frame = h('iframe', { class: 'term-frame', src: '/terminal-frame', sandbox: 'allow-scripts', allow: 'clipboard-write',
                            referrerpolicy: 'no-referrer', name: 'term-' + t.id, title: 'Terminal: ' + t.sandbox + ' · ' + (t.session || 'default') });
    t.els.host.append(t.frame);
    await opened;
  } catch (e) {
    t.errorText = 'the terminal engine did not load (' + (e.message || e) + ')';
    paintCover(t);
    return false;
  }
  if (t.closed) return false;
  t.booted = true;
  if (t.saved) { loadSavedScreen(t); return true; }       // 593 §9: no socket — the saved screen
  // A saved pane whose sandbox ran again while its engine loaded: the frame leaves saved mode first.
  if (t.initMode === 'saved') toFrame(t, { t: 'live', mode: t.mode });
  connectTerminal(t);
  return true;
}
/// A terminal on the sandbox's page (593: each sandbox's page has its own tabs and split).
async function openTerminal(sandbox, session, mode, pane, opts = {}) {
  if (!terminalsAllowed()) return;
  const v = sview(sandbox);
  const t = newTerm(sandbox, session, mode);
  t.bootIntent = !!opts.bootIntent;
  t.pane = v.split ? (pane ?? v.focusedPane) : 0;
  v.selected[t.pane] = t.id;
  paintCover(t);
  if (state.view !== 'sandbox' || state.param !== sandbox) location.hash = '#/sandbox/' + sandbox;
  else renderTerminals();
  // The body must be laid out before the engine measures it.
  await new Promise((r) => setTimeout(r, 0));
  renderTerminals();
  if (await bootTerm(t, setting('ui.terminal_font_size', 13))) focusTerm(t);
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
                           ['doz-terminal.v1', 'doz-ticket.' + ticket]);
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
    if (t.bootIntent && m.cover && !['shutDown', 'failed', 'reattaching'].includes(m.cover.kind)) t.bootIntent = false;
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
  } else if (m.t === 'notice') {
    if (typeof m.kind === 'string' && typeof m.text === 'string') bridgeNotice(m.kind, m.text);
    return;
  } else if (m.t === 'boot-done') {
    toFrame(t, { t: 'keep-scrollback' });           // the boot log's end scrolls into the scrollback
    return;
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
    : ev.reason === 'shutdown' ? 'the doz ui process stopped'
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
  if (t.grid) return;
  const v = sview(t.sandbox);
  for (const p of [0, 1]) if (v.selected[p] === id) v.selected[p] = null;
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
  const glyph = h('div', { class: 'tc-glyph', hidden: true });
  const head = h('div', { class: 'tc-head' });
  const detail = h('div', { class: 'tc-detail' });
  const action = h('button', { type: 'button', class: 'btn small tc-act' });
  action.addEventListener('click', (ev) => { ev.stopPropagation(); coverAction(t); });
  const cover = h('div', { class: 'term-cover', role: 'status', 'aria-live': 'polite' }, h('div', { class: 'tc-box' }, spin, glyph, head, detail, action));
  const wrap = h('div', { class: 'term-wrap', 'data-terminal': String(t.id) }, host, cover, note);
  return { wrap, host, cover, spin, glyph, head, detail, action, note };
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
  const ok = h('button', { type: 'button', class: 'btn primary' }, withIcon('clipboard-paste', 'Paste'));
  const cancel = h('button', { type: 'button', class: 'btn' }, withIcon('x', 'Cancel'));
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
  let kind = 'none', headline = '', detail = '', action = null, spinner = false, glyphKey = null;
  if (t.errorText) { kind = 'error'; headline = 'This terminal could not open'; detail = t.errorText; }
  else if (t.bootlog) { kind = t.savedShown ? 'none' : 'reattaching'; headline = 'Loading…'; spinner = !t.savedShown; }
  else if (t.saved) { ({ headline, detail, action, glyphKey } = savedCover(t)); kind = 'saved'; }
  // A boot view asked for by Start: "Starting…" from its first paint until the host's steps take over
  // (never the shut-down cover the sandbox had a moment before the start reached the host).
  else if (t.bootIntent && !t.ended && (!t.state || ['shutDown', 'failed', 'reattaching'].includes(t.state.cover.kind))) {
    kind = 'working'; headline = 'Starting the sandbox…'; spinner = true;
  }
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
  e.wrap.dataset.phase = (t.saved ? sandboxPhase(t.sandbox) : t.state && t.state.phase) || '';
  e.wrap.dataset.reports = String((t.state && t.state.reportsIgnored) || 0);
  e.wrap.dataset.wakes = String((t.state && t.state.keystrokeWakes) || 0);
  // The boot view draws the boot in the terminal itself: no cover.
  e.cover.hidden = kind === 'none' || kind === 'boot';
  e.head.textContent = headline;
  e.detail.textContent = detail;
  e.detail.hidden = !detail;
  e.spin.hidden = !spinner;
  // 593: the state's own glyph over the cover (the two sleeps told apart: RAM kept / on disk).
  const g = PHASE_GLYPH[glyphKey || kind] || null;
  e.glyph.hidden = !g || spinner;
  if (g && e.glyph.dataset.icon !== g) { e.glyph.dataset.icon = g; e.glyph.replaceChildren(icon(g)); }
  e.action.hidden = !action;
  if (action) setButton(e.action, action); else e.action.replaceChildren();
  e.action.title = action === 'Reconnect' ? 'Open the terminal again' : action === 'Start' ? 'Start it (a cold boot: new sessions)'
    : action ? action + ' — so does any key typed in the terminal' : '';
  t.coverAction = action;
}
function coverAction(t) {
  const a = t.coverAction;
  if (a === 'Reconnect') {
    t.disconnected = '';
    t.state = null;
    paintCover(t);
    connectTerminal(t);
  } else if (a === 'Start' && t.saved) {
    lifecycle('start', t.sandbox);                        // 593: a saved screen's Start is the page's Start
    return;
  } else if (a) {
    act({ action: { Resume: 'resume', Wake: 'wake', Start: 'start' }[a], sandbox: t.sandbox });
  }
  focusTerm(t);
}

// ── saved screens (593 §9 — S3): a session's last saved screen, drawn read-only (and selectable) by the
// engine in its sandboxed frame while the sandbox does not run; no socket, so it keeps no host alive.
// A key pressed on it wakes (or resumes) the sandbox — the frame only says that a key was pressed —
// and once the sandbox runs, each pane becomes its live session IN PLACE (`goLive`).
/// The sandbox's phase as this page last read it (its own page's detail, else the overview).
/// 599 (594.B4): a terminal's tab says what `doz attach` puts in the terminal's title — ui.terminal_title
/// ({sandbox} {session} {image} {time} {phase}; "" = the session's name, as before). {time} is this Mac's
/// (the page runs on it), refreshed each minute.
const TITLE_PHASES = { asleep: 'asleep', hibernated: 'hibernated', paused: 'paused', booting: 'starting', off: 'shut down' };
function sandboxImage(name) {
  if (state.sbx && state.sbx.name === name && state.sbx.d) return state.sbx.d.info.image || '';
  const row = state.overview && state.overview.sandboxes.find((s) => s.name === name);
  return row ? row.image || '' : '';
}
function terminalTitle(t) {
  const tpl = String(setting('ui.terminal_title', '{sandbox} · {session} · {time}'));
  if (!tpl) return t.session || '…';
  const d = new Date();
  const time = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  const phase = (t.state && t.state.phase) || sandboxPhase(t.sandbox) || '';
  const vars = { sandbox: t.sandbox, session: t.session || '…', image: String(sandboxImage(t.sandbox)).replace(/^custom:/, ''),
                 time, phase: TITLE_PHASES[phase] || phase };
  return tpl.replace(/\{([a-z]+)\}/g, (m, k) => (k in vars ? vars[k] : m)).replace(/[\u0000-\u001f\u007f-\u009f]/g, '').slice(0, 200);
}
function sandboxPhase(name) {
  if (state.sbx && state.sbx.name === name && state.sbx.d) return state.sbx.d.info.phase;
  const row = state.overview && state.overview.sandboxes.find((s) => s.name === name);
  return row ? row.phase : '';
}
function sandboxBusy(name) {
  if (state.transitions.has(name)) return true;
  if (state.sbx && state.sbx.name === name && state.sbx.d) return !!state.sbx.d.info.busy || opRunningFor(name);
  const row = state.overview && state.overview.sandboxes.find((s) => s.name === name);
  return (row && row.busy) || opRunningFor(name);
}
const SAVED_WAKE = { paused: ['Resume', 'resume'], asleep: ['Wake', 'wake'], hibernated: ['Wake', 'wake'] };
const PHASE_WORD = { paused: 'paused', asleep: 'asleep', hibernated: 'hibernated', off: 'shut down', failed: 'failed', booting: 'starting', running: 'running' };
function savedCover(t) {
  const c = savedCoverFor(t);
  // A grid tile takes no keys (its overlay opens the page): the tile's head has the Wake button.
  if (t.grid) { c.detail = ''; c.action = null; }
  return c;
}
function savedCoverFor(t) {
  const s = t.saved, phase = sandboxPhase(t.sandbox);
  const saved = 'saved ' + when(s.savedAt);
  // An action under way: say what (never the phase it is leaving).
  const tr = transitionOf(t.sandbox);
  if (tr) return { headline: TRANSITION_LABEL[tr.action] + ' — its saved screen', detail: saved, action: null, glyphKey: null };
  const w = SAVED_WAKE[phase];
  if (phase === 'running') return { headline: 'Attaching…', detail: saved, action: null, glyphKey: null };
  return { headline: (PHASE_WORD[phase] || phase || 'not running').replace(/^./, (c) => c.toUpperCase()) + ' ' + when(s.savedAt) + ' — its saved screen',
           detail: w && !sandboxBusy(t.sandbox) ? 'press any key to ' + w[1] : sandboxBusy(t.sandbox) ? 'under way…' : '',
           action: w && !sandboxBusy(t.sandbox) ? w[0] : null, glyphKey: phase };
}
/// A key on a saved screen: the ordinary wake / resume action (the page's own; never a cold boot).
function savedKey(t) {
  if (!t.saved || t.grid) return;
  const w = SAVED_WAKE[sandboxPhase(t.sandbox)];
  if (!w || sandboxBusy(t.sandbox)) return;
  act({ action: w[1], sandbox: t.sandbox });
}
/// The saved screen's VT (base64 from the API) into the frame, in writes the frame accepts (≤ 1 MiB).
async function loadSavedScreen(t) {
  let s;
  try {
    // 593: a Boot log terminal draws a kept boot (rendered by the host's boot-view renderer) the same way.
    s = await api(t.bootlog ? 'sandboxes/' + t.sandbox + '/boots/' + t.bootlog : 'sandboxes/' + t.sandbox + '/sessions/' + t.session + '/screen');
  } catch (e) {
    t.errorText = e.status === 404 ? (t.bootlog ? 'that boot is no longer kept' : 'no saved screen of ' + t.session) : e.message || String(e);
    paintCover(t);
    return;
  }
  if (t.closed || !t.saved) return;
  if (!t.bootlog) t.saved = { ...t.saved, savedAt: s.savedAt, reason: s.reason };
  const bin = atob(s.vt);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  for (let i = 0; i < bytes.length; i += 1 << 20) {
    const chunk = bytes.slice(i, i + (1 << 20)).buffer;
    toFrame(t, { t: 'write', data: chunk }, [chunk]);
  }
  if (t.bootlog) toFrame(t, { t: 'top' });            // a Boot log opens at its steps
  t.savedShown = true;
  if (t.els.wrap) t.els.wrap.dataset.saved = t.bootlog ? 'boot' : s.reason;
  paintCover(t);
  paintTabs();
}
// ── the Boot log (593 — owner: "where is the bootup terminal output stored so i can look at it after the
// machine has booted"): the host keeps the last host.boot_logs_kept boots of each sandbox; this draws one
// EXACTLY as the boot view did (the host renders it with the boot view's own renderer), read-only and
// selectable in the terminal frame's saved mode. A picker switches boots; the latest opens first (a
// failed one is marked ✕). Any phase — it reads files; nothing is woken.
function bootLabel(b) {
  const took = b.milliseconds ? ms(b.milliseconds) : '…';
  const res = b.result === 'failed' ? '✕ failed' : b.result === 'ok' ? '✓' : 'booting…';
  return '#' + b.number + ' · ' + new Date(b.startedAt).toLocaleString() + ' · ' + b.kind + ' · ' + took + ' · ' + res;
}
async function bootLogDialog(name) {
  let boots;
  try { boots = (await api('sandboxes/' + name + '/boots')).boots; } catch (e) { toast(e.message || String(e), true); return; }
  const d = h('dialog', { class: 'dlg bootlog-dialog', 'data-sandbox': name });
  const picker = h('select', { 'aria-label': 'Which boot', class: 'bootlog-picker' },
    boots.map((b) => h('option', { value: String(b.number), 'data-result': b.result }, bootLabel(b))));
  const area = h('div', { class: 'bootlog-area' });
  const why = h('div', { class: 'bootlog-error', role: 'status' });
  const close = h('button', { type: 'button', class: 'btn' }, withIcon('x', 'Close'));
  d.append(h('div', { class: 'bootlog-head' }, h('h2', null, 'Boot log — ' + name), picker, close),
    h('p', { class: 'sub' }, 'Each start and wake of ' + name + ': Dozer’s steps as the boot view showed them, then the kernel console. The last '
      + setting('host.boot_logs_kept', 5) + ' are kept (Settings › host.boot_logs_kept); doz console ' + name + ' --list shows them too.'),
    why, area);
  let term = null;
  const show = (n) => {
    if (term) closeTerminal(term.id);
    const b = boots.find((x) => x.number === n);
    why.textContent = b && b.result === 'failed' ? '✕ This boot failed' + (b.error ? ': ' + b.error : '') : '';
    why.hidden = !why.textContent;
    const t = newTerm(name, null, 'watch');
    t.grid = true;                                      // not a tab of the page
    t.bootlog = n;
    t.saved = { reason: 'boot' };
    paintCover(t);
    area.replaceChildren(t.els.wrap);
    bootTerm(t, setting('ui.terminal_font_size', 13));
    term = t;
    d.dataset.boot = String(n);
  };
  picker.addEventListener('change', () => show(Number(picker.value)));
  close.addEventListener('click', () => d.close());
  d.addEventListener('close', () => { if (term) closeTerminal(term.id); d.remove(); });
  document.body.append(d);
  d.showModal();
  if (boots.length) show(1);
  else area.replaceChildren(h('div', { class: 'empty' }, 'No boot of ' + name + ' is kept yet — one is recorded each time it starts or wakes.'));
}

/// The sandbox runs again: this saved pane becomes its session's live terminal, in place — the saved
/// screen is cleared and the attach's SNAPSHOT draws the live one.
function goLive(t) {
  if (!t.saved) return;
  t.saved = null;
  t.state = null;
  if (t.els.wrap) delete t.els.wrap.dataset.saved;
  paintCover(t);
  // Not booted yet (a hidden tab, or its engine still loading): it attaches once it is (bootTerm).
  if (!t.booted) return;
  const clear = utf8.encode('\x1bc\x1b[3J\x1b[H\x1b[2J').buffer;
  toFrame(t, { t: 'write', data: clear }, [clear]);
  toFrame(t, { t: 'live', mode: t.mode });
  t.initMode = t.mode;
  connectTerminal(t);
}
/// After the sandbox's state changed: saved panes of a sandbox that runs go live (their session runs)
/// or close (it is gone); the others repaint their cover (the phase, the wake hint). A sandbox that is
/// SHUT DOWN shows no session screens anywhere (owner, 2026-09-30): every pane of it — saved, or a live
/// one whose session died with the VM — closes, and the area shows the off state. (A FAILED start keeps
/// its boot view: that is where the failure is.)
function promoteSaved(name, live) {
  const phase = sandboxPhase(name);
  const running = phase === 'running' && !sandboxBusy(name);
  const gone = phase === 'off' && !sandboxBusy(name);
  // The plain off state is one area, not an empty split.
  if (gone && !pageTerminals(name).some((t) => t.bootIntent)) { const v = sview(name); v.split = false; v.focusedPane = 0; }
  for (const t of [...terminals.values()]) {
    if (t.sandbox !== name || t.bootlog) continue;       // a Boot log terminal is never a session's
    if (gone && !t.bootIntent) { if (t.grid) continue; closeTerminal(t.id); continue; }
    if (!t.saved) continue;
    if (running && live) {
      if (live.includes(t.session)) goLive(t);
      else if (!t.grid) closeTerminal(t.id);
    } else {
      paintCover(t);
    }
  }
}

// ── a sandbox's terminal area: tabs, and a split (593: per sandbox; the grid's tiles are apart)
function paintTabs() { if (state.view === 'sandbox') renderTerminals(); }
function pageTerminals(name) { return [...terminals.values()].filter((t) => !t.grid && t.sandbox === name); }
function renderTerminals() {
  const root = $('terminals');
  if (!termUI.built) {
    // Split is a split button (owner, 591): the main part splits and ALWAYS fills the right pane
    // with the chosen kind (or, when split, unsplits); the ▾ menu picks the kind — and when already
    // split, adds that kind to the right pane at once.
    const unsplit = () => {
      const v = sview(state.param);
      v.split = false;
      for (const t of pageTerminals(state.param)) t.pane = 0;
      v.selected[0] = v.selected[0] ?? v.selected[1];
      v.selected[1] = null;
      v.focusedPane = 0;
      renderTerminals();
    };
    termUI.splitMain = btn('Split', () => {
      if (sview(state.param).split) unsplit();
      else splitWith(termUI.splitKind).catch((e) => toast(e.message || String(e), true));
    }, { small: true, title: 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind] });
    termUI.splitMenu = h('div', { class: 'menu', role: 'menu', hidden: true },
      Object.entries(SPLIT_KINDS).map(([kind, label]) => h('button', { type: 'button', role: 'menuitem', class: 'menu-item', 'data-kind': kind,
        on: { click: (ev) => {
          ev.stopPropagation();
          termUI.splitMenu.hidden = true;
          termUI.splitKind = kind;
          // The choice is the setting ui.split_default (doz.toml), not this browser's.
          if (setting('ui.split_default', 'shell') !== kind) saveSetting('ui.split_default', kind).catch((e) => toast('The setting was not saved: ' + (e.message || e), true));
          paintSplitButton();
          splitWith(kind).catch((e) => toast(e.message || String(e), true));
        } } }, label)));
    const caret = h('button', { type: 'button', class: 'btn small split-caret', title: 'What the split adds', 'aria-haspopup': 'menu',
      'aria-label': 'What the split adds', on: { click: (ev) => { ev.stopPropagation(); termUI.splitMenu.hidden = !termUI.splitMenu.hidden; } } },
      icon('chevron-down'));
    document.addEventListener('click', () => { termUI.splitMenu.hidden = true; });
    termUI.splitBtn = h('div', { class: 'split-button' }, termUI.splitMain, caret, termUI.splitMenu);
    termUI.panes = [0, 1].map((i) => {
      const strip = h('div', { class: 'tabs', role: 'tablist' });
      const body = h('div', { class: 'term-body' });
      const empty = h('div', { class: 'term-empty' });
      const pane = h('div', { class: 'term-pane', 'data-pane': String(i) }, strip, body);
      body.append(empty);
      pane.addEventListener('focusin', () => { if (state.param) sview(state.param).focusedPane = i; });
      pane.addEventListener('mousedown', () => { if (state.param) sview(state.param).focusedPane = i; });
      return { root: pane, strip, body, empty };
    });
    termUI.grid = h('div', { class: 'term-grid' }, termUI.panes[0].root, termUI.panes[1].root);
    root.replaceChildren(termUI.grid);
    termUI.built = true;
  }
  const name = state.view === 'sandbox' ? state.param : null;
  const v = name ? sview(name) : { split: false, selected: [null, null] };
  termUI.grid.classList.toggle('split', v.split);
  paintSplitButton();
  termUI.panes[1].root.hidden = !v.split;
  // Another sandbox's terminals stay open (hidden) — going back to it is instant.
  for (const t of terminals.values()) if (!t.grid && t.sandbox !== name) t.els.wrap.hidden = true;
  termUI.panes.forEach((p, i) => {
    const mine = name ? pageTerminals(name).filter((t) => t.pane === i) : [];
    if (!mine.some((t) => t.id === v.selected[i])) v.selected[i] = mine.length ? mine[mine.length - 1].id : null;
    p.strip.replaceChildren(...mine.map((t) => tabElement(t, i)));
    scrollActiveTab(p.strip);
    p.empty.hidden = mine.length > 0;
    for (const t of mine) {
      if (t.els.wrap.parentNode !== p.body) p.body.append(t.els.wrap);
      t.els.wrap.hidden = t.id !== v.selected[i];
      // 593 §9: a restored tab loads its engine the first time it is shown — a hidden frame has no size,
      // and an interactive attach at no size would resize its session.
      if (t.lazy && !t.els.wrap.hidden) {
        t.lazy = false;
        setTimeout(() => bootTerm(t, setting('ui.terminal_font_size', 13)), 0);
      }
    }
  });
  paintTermEmpty();
  if (name) persistLayout(name);
  // The URL names the session shown (replaceState: no route).
  const sel = name && terminals.get(v.selected[v.focusedPane] ?? v.selected[0]);
  if (sel && sel.session && state.session !== sel.session) {
    state.session = sel.session;
    history.replaceState(null, '', location.pathname + '#/sandbox/' + name + '/' + sel.session);
  }
}
/// A pane's tab strip scrolls sideways when its tabs overflow; the selected tab is always in view
/// (orchestrator ruling, 593 follow-up).
function scrollActiveTab(strip) {
  const w = strip.querySelector('.tab.active')?.closest('.tab-wrap');
  if (!w) return;
  const sr = strip.getBoundingClientRect(), wr = w.getBoundingClientRect();
  if (!sr.width) return;
  if (wr.left < sr.left) strip.scrollLeft += wr.left - sr.left;
  else if (wr.right > sr.right) strip.scrollLeft += wr.right - sr.right;
}
/// The terminal area with no terminal: what it can open, from the sandbox's state.
function paintTermEmpty() {
  if (!termUI.built) return;
  const s = state.sbx;
  const p = termUI.panes[0];
  if (p.empty.hidden) return;
  if (!s || !s.d || s.name !== state.param) { p.empty.replaceChildren(h('div', { class: 'term-empty-box' }, 'Loading…')); return; }
  const i = s.d.info;
  const tr = transitionOf(s.name);
  const busy = i.busy || i.phase === 'booting' || opRunningFor(s.name) || !!tr;
  const live = (s.d.sessions || []).filter((x) => !x.ended);
  const box = h('div', { class: 'term-empty-box' });
  if (busy) {
    box.append(h('div', { class: 'term-empty-head' }, tr ? TRANSITION_LABEL[tr.action] : i.phaseLabel + '…'), h('div', null, 'The terminal opens when it can.'));
  } else if (i.phase === 'off' || i.phase === 'failed') {
    // The plain off state (owner, 2026-09-30): no session screens — its sessions ended with the VM.
    box.dataset.off = i.phase;
    box.append(h('div', { class: 'term-empty-head' }, i.phase === 'off' ? 'Shut down' : s.name + ' failed to start'),
      h('div', { class: 'term-empty-note' }, 'Starting boots it fresh — new sessions.'),
      h('div', { class: 'actions center' },
        btn('Start', () => lifecycle('start', s.name), { primary: true, title: bootViewOnStart() ? 'Boot it, and watch it boot here' : 'Boot it' })));
  } else {
    // 593 §9 (S4): "New shell" always makes a NEW session; a running session is opened by its own name
    // (the sessions list). The image's own session is offered by name: opened when it runs, started when not.
    const saved = (s.d.sessions || []).filter((x) => x.saved);
    const defaultRuns = live.some((x) => x.name === s.d.defaultSession && !x.saved);
    const defaultSaved = saved.some((x) => x.name === s.d.defaultSession);
    box.append(h('div', { class: 'term-empty-head' }, 'No terminal open'),
      h('div', { class: 'actions center' },
        defaultSaved ? null : defaultRuns
          ? btn('Open ' + s.d.defaultSession, () => openTerminal(s.name, s.d.defaultSession, 'interactive'), { primary: true, icon: 'terminal',
            title: 'A terminal on the running ' + s.d.defaultSession + ' session' })
          : btn('Start ' + s.d.defaultSession, () => openDefaultTerminal(s.name), { primary: true, icon: 'play',
            title: 'Start the image’s own session (' + s.d.defaultSession + ')' + (i.phase === 'running' ? '' : ' — it wakes the sandbox') }),
        ...live.filter((x) => x.name !== s.d.defaultSession && !x.saved).slice(0, 8).map((x) => btn('Open ' + x.name, () => openTerminal(s.name, x.name, 'interactive'), { icon: 'terminal' })),
        ...saved.slice(0, 8).map((x) => btn('Show ' + x.name, () => openSavedTerminal(s.name, x), { icon: 'eye', title: 'Its last saved screen (read-only)' })),
        btn('New shell', () => newShellTerminal(s.name).catch((e) => toast(e.message || String(e), true)), { title: 'A NEW shell session (shell-2, shell-3, …)' })));
  }
  p.empty.replaceChildren(box);
}
function tabElement(t, pane) {
  const phase = t.ended || t.errorText || t.disconnected ? 'ended'
    : t.saved ? sandboxPhase(t.sandbox) || 'unknown' : (t.state && t.state.phase) || 'unknown';
  const v = sview(t.sandbox);
  // Tabs are numbered (1, 2, …) per sandbox, so a shared session can say which tab it is shared with.
  const order = pageTerminals(t.sandbox).map((x) => x.id);
  const num = order.indexOf(t.id) + 1;
  const label = num + ' · ' + terminalTitle(t);
  const twins = t.session && !t.ended ? pageTerminals(t.sandbox).filter((o) => o.id !== t.id && !o.ended && o.session === t.session) : [];
  const shared = twins.length ? h('span', { class: 'tag shared', title: 'Two views of ONE session: what is typed in either shows in both' },
    'shared with tab ' + twins.map((o) => order.indexOf(o.id) + 1).join(', ')) : null;
  const select = h('button', { type: 'button', role: 'tab', class: 'tab' + (t.id === v.selected[pane] ? ' active' : ''),
                               // 594 (W14): the one hint a mouse-using program needs.
                               title: (t.title ? t.title + ' — ' + label : label) + '\nShift+drag selects text while the program uses the mouse',
                               'data-term': String(t.id),
                               on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); focusTerm(t); } } },
    h('span', { class: 'tab-dot ph-' + phase, 'aria-hidden': 'true' }), icon(t.mode === 'watch' ? 'eye' : 'terminal'), label,
    t.mode === 'watch' ? h('span', { class: 'tag' }, 'watch') : null,
    t.saved ? h('span', { class: 'tag saved', title: 'Its last saved screen (' + (t.saved.reason || 'saved') + ', ' + when(t.saved.savedAt) + ') — it goes live when the sandbox runs' }, 'saved') : null,
    shared);
  const move = v.split ? h('button', { type: 'button', class: 'tab-x', title: 'Move to the other pane', 'aria-label': 'Move ' + label + ' to the other pane',
    on: { click: () => { t.pane = 1 - t.pane; v.selected[t.pane] = t.id; renderTerminals(); focusTerm(t); } } }, icon('arrow-left-right')) : null;
  const close = h('button', { type: 'button', class: 'tab-x', title: 'Close this terminal (the session keeps running)', 'aria-label': 'Close ' + label,
    on: { click: () => closeTerminal(t.id) } }, icon('x'));
  return h('div', { class: 'tab-wrap' }, select, move, close);
}

/// What a split adds on the right (the Split button's ▾ menu). Remembered per browser.
const SPLIT_KINDS = {
  shell: 'new shell',
  watch: 'watch of the left terminal’s session (read-only)',
  attach: 'second view of the left terminal’s session (shared)',
  dialog: 'terminal you choose (New terminal…)',
};
termUI.splitKind = 'shell';   // until the settings load (ui.split_default)
const SPLIT_ICONS = { shell: 'plus', watch: 'eye', attach: 'link', dialog: 'terminal' };
function paintSplitButton() {
  if (!termUI.splitMain) return;
  const split = state.param ? sview(state.param).split : false;
  setButton(termUI.splitMain, split ? 'Unsplit' : 'Split', 'columns-2');
  termUI.splitMain.title = split ? 'Back to one pane (the right pane’s terminals move left)'
                                 : 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind];
  for (const item of termUI.splitMenu.children) {
    item.replaceChildren(icon(SPLIT_ICONS[item.dataset.kind]), h('span', { class: 'btn-label' },
      (split ? 'Add a ' : 'Split with a ') + SPLIT_KINDS[item.dataset.kind]),
      item.dataset.kind === termUI.splitKind ? h('span', { class: 'menu-check', title: 'the default (ui.split_default)' }, icon('check')) : null);
  }
}
/// Split (if needed) and fill the right pane with `kind` — so a split always creates something.
/// With no terminal on the left there is nothing to watch, attach to or put a shell beside: the
/// New terminal dialog opens instead (for the right pane).
async function splitWith(kind) {
  const name = state.param;
  if (state.view !== 'sandbox' || !name) return;
  const v = sview(name);
  const left = terminals.get(v.selected[0]) || pageTerminals(name).find((t) => t.pane === 0);
  if (!v.split) { v.split = true; renderTerminals(); }
  v.focusedPane = 1;
  if (kind === 'dialog' || !left) { await newTerminalDialog(name); return; }
  if (kind === 'watch' || kind === 'attach') {
    if (!left.session) throw new Error('the left terminal has no session yet — wait for it to start');
    openTerminal(name, left.session, kind === 'watch' ? 'watch' : 'interactive', 1);
    return;
  }
  await newShellTerminal(name, 1);
}

async function newTerminalDialog(sandbox) {
  const names = [sandbox || state.param].filter(Boolean);
  if (!names.length) { toast('Open a sandbox first', true); return; }
  const first = names[0];
  // What to open: ALWAYS a new session (593 §9 S4, owner — after "New terminal" attached to a session that
  // already ran): a new shell, or a new session running a command. A running session is reached through
  // its pane or the sessions list (Details › Sessions: Open / Watch), never from here.
  const d = dialog('New terminal in ' + first, 'A new session: a shell, or a command. A session that already runs is opened from the Sessions list.', [
    { name: 'sandbox', label: 'Sandbox', type: 'select', options: names, value: first },
    { name: 'what', label: 'Open', type: 'select', options: [['new', 'New shell'], ['command', 'New session running a command…']] },
    { name: 'session', label: 'Session name (new session only)', placeholder: 'e.g. worker' },
    { name: 'command', label: 'Command (new session only)', placeholder: 'e.g. htop — no shell in front (say bash -lc \'…\' for one)' },
  ], 'Open', async (v) => {
    const sv = sview(v.sandbox);
    const pane = sv.split ? sv.focusedPane : 0;
    if (v.what === 'new') { await newShellTerminal(v.sandbox, pane); return; }
    if (v.what === 'command') {
      const argv = splitArgs(v.command);
      if (!argv.length) throw new Error('the command is empty');
      if (!v.session) throw new Error('a new session needs a name');
      const done = await waitForOp(await actOrThrow({ action: 'open-session', sandbox: v.sandbox, session: v.session, argv }));
      if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
      if (!done.text.startsWith('started')) throw new Error('a session named ' + v.session + ' already runs — pick another name (open it from the Sessions list)');
      openTerminal(v.sandbox, v.session, 'interactive', pane);
      return;
    }
    throw new Error('pick what to open');
  });
  const sandboxSel = d.querySelector('[name="sandbox"]'), whatSel = d.querySelector('[name="what"]');
  sandboxSel.closest('label').hidden = true;             // 593: the page's sandbox
  const nameField = d.querySelector('[name="session"]').closest('label'), cmdField = d.querySelector('[name="command"]').closest('label');
  const showFields = () => { const c = whatSel.value === 'command'; nameField.hidden = !c; cmdField.hidden = !c; };
  whatSel.addEventListener('change', showFields);
  showFields();
}

/// A NEW shell session in `sandbox` — `shell-2`, `shell-3`, … (the next name not taken), running a
/// login shell — opened with the ordinary open-session action (one HostOp; its idempotency unchanged:
/// a name that turns out to be taken answers "already running", and the next name is tried).
async function newShellTerminal(sandbox, pane) {
  if (!terminalsAllowed()) return;
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

// ── All sessions: the grid (593) ────────────────────────────────────────────
// A tile per session of every RUNNING sandbox — a live, read-only (watch) view: the same ticket,
// socket and frame as any terminal, laid out at a fixed virtual size (960 × 560) and scaled, so it
// is a thumbnail of the session at its own geometry. A sandbox that is not running is one static
// tile (no engine, no socket: an open grid never keeps a host alive for it). Engines exist only
// for tiles on screen (IntersectionObserver), and at most ui.grid_live_tiles at once. Sessions are
// listed on entry, on Refresh, and on a live change at most every 10 s (listing asks the guest).
const grid = { built: false, active: false, tiles: new Map(), io: null, sandbox: '', phase: '', lastList: 0, listTimer: null,
               sessions: {}, scheduled: false, status: null, body: null };
const TILE_SCALE = { small: 0.3, medium: 0.42, large: 0.62 };

function gridBuild() {
  const root = $('grid');
  const sandboxSel = h('select', { 'aria-label': 'Sandbox' });
  const phaseSel = h('select', { 'aria-label': 'Phase' }, [['', 'every phase'], ['running', 'running'], ['paused', 'paused'], ['asleep', 'asleep'],
    ['hibernated', 'hibernated'], ['off', 'shut down'], ['failed', 'failed']].map(([v, l]) => h('option', { value: v }, l)));
  const sizeSel = h('select', { 'aria-label': 'Tile size' }, ['small', 'medium', 'large'].map((s) => h('option', { value: s }, s + ' tiles')));
  sandboxSel.addEventListener('change', () => { grid.sandbox = sandboxSel.value; gridRender(); });
  phaseSel.addEventListener('change', () => { grid.phase = phaseSel.value; gridRender(); });
  sizeSel.addEventListener('change', () => {
    gridApplySize(sizeSel.value);
    saveSetting('ui.grid_tile_size', sizeSel.value).catch((e) => toast('The setting was not saved: ' + (e.message || e), true));
  });
  grid.status = h('span', { class: 'grid-status', role: 'status' });
  grid.body = h('div', { class: 'tiles' });
  grid.sandboxSel = sandboxSel;
  grid.sizeSel = sizeSel;
  root.replaceChildren(
    h('div', { class: 'head' }, h('h1', null, 'All sessions'), h('div', { class: 'actions' }, btn('Refresh', () => gridRefresh(true), { small: true }))),
    h('p', { class: 'sub' }, 'Every session of every running sandbox, live and read-only. Click one to open it on its sandbox’s page.'),
    h('div', { class: 'toolbar' }, sandboxSel, phaseSel, sizeSel, grid.status),
    grid.body);
  grid.io = new IntersectionObserver((entries) => {
    for (const e of entries) { const tile = grid.tiles.get(e.target.dataset.key); if (tile) tile.visible = e.isIntersecting; }
    gridSchedule();
  }, { root: null, rootMargin: '100px' });
  grid.built = true;
}
function gridApplySize(size) {
  const s = TILE_SCALE[size] ? size : 'medium';
  for (const k of Object.keys(TILE_SCALE)) $('grid').classList.toggle('tiles-' + k, k === s);
  if (grid.sizeSel) grid.sizeSel.value = s;
}
async function gridEnter() {
  if (!grid.built) gridBuild();
  grid.active = true;
  gridApplySize(setting('ui.grid_tile_size', 'medium'));
  await gridRefresh(true);
}
function gridLeave() {
  if (!grid.active) return;
  grid.active = false;
  clearTimeout(grid.listTimer);
  for (const tile of grid.tiles.values()) detachTile(tile);
}
async function gridRefresh(force) {
  if (!grid.active) return;
  const wait = 10000 - (Date.now() - grid.lastList);
  if (!force && wait > 0) {
    clearTimeout(grid.listTimer);
    grid.listTimer = setTimeout(() => gridRefresh(true), wait);
    return;
  }
  grid.lastList = Date.now();
  let o;
  try { o = await api('overview'); } catch (e) { toast(e.message || String(e), true); return; }
  state.overview = o;
  renderNavSandboxes();
  // A running sandbox's sessions come from its guest; any other's from its saved screens (593 §9 — S3:
  // read from the sandbox's directory, nothing woken).
  await Promise.all(o.sandboxes.filter((s) => s.phase !== 'booting').map(async (s) => {
    try {
      const rows = await api('sandboxes/' + s.name + '/sessions');
      grid.sessions[s.name] = s.phase === 'running'
        ? rows.filter((r) => !r.ended && !r.saved).map((r) => ({ name: r.name, command: r.command }))
        : rows.filter((r) => r.saved).map((r) => ({ name: r.name, command: r.command, saved: r }));
    } catch (_) { /* it changed meanwhile: its last list stays */ }
  }));
  if (!grid.active) return;
  gridRender();
}
/// The tiles the filters ask for, made to match the DOM (a kept tile keeps its live terminal).
function gridRender() {
  const o = state.overview;
  if (!o) return;
  const names = o.sandboxes.map((s) => s.name).sort();
  grid.sandboxSel.replaceChildren(h('option', { value: '' }, 'every sandbox'), ...names.map((n) => h('option', { value: n }, n)));
  grid.sandboxSel.value = names.includes(grid.sandbox) ? grid.sandbox : '';
  const want = [];
  for (const s of o.sandboxes.slice().sort((a, b) => a.name.localeCompare(b.name))) {
    if (grid.sandbox && s.name !== grid.sandbox) continue;
    if (grid.phase && s.phase !== grid.phase) continue;
    if (s.phase === 'running') {
      const live = (grid.sessions[s.name] || []).filter((x) => !x.saved);
      for (const x of live) want.push({ key: s.name + '/' + x.name, sandbox: s.name, session: x.name, command: x.command, s });
      if (!live.length) want.push({ key: s.name + '/', sandbox: s.name, session: null, s, none: true });
    } else {
      // 593 §9 (S3): its saved screens, a tile each (same key as the live tile: waking swaps it in place).
      // Shut down or failed: no tiles of sessions (owner, 2026-09-30) — one static tile with Start.
      const saved = !SAVED_PHASES.includes(s.phase) ? [] : (grid.sessions[s.name] || []).filter((x) => x.saved);
      for (const x of saved) want.push({ key: s.name + '/' + x.name, sandbox: s.name, session: x.name, command: x.command, s, saved: x.saved });
      if (!saved.length) want.push({ key: s.name + '/', sandbox: s.name, session: null, s });
    }
  }
  const keep = new Set(want.map((w) => w.key));
  for (const [k, tile] of grid.tiles) if (!keep.has(k)) { detachTile(tile); grid.io.unobserve(tile.el); tile.el.remove(); grid.tiles.delete(k); }
  let prev = null;
  for (const w of want) {
    let tile = grid.tiles.get(w.key);
    if (!tile) { tile = makeTile(w); grid.tiles.set(w.key, tile); grid.io.observe(tile.el); }
    paintTile(tile, w);
    const next = prev ? prev.nextSibling : grid.body.firstChild;
    if (next !== tile.el) grid.body.insertBefore(tile.el, next);
    prev = tile.el;
  }
  if (!want.length) grid.body.replaceChildren(h('div', { class: 'empty' }, o.sandboxes.length ? 'Nothing matches the filters.' : 'No sandboxes yet.'));
  else for (const n of [...grid.body.children]) if (!n.dataset.key) n.remove();
  gridSchedule();
}
function makeTile(w) {
  const dot = h('span', { class: 'ph-dot', 'aria-hidden': 'true' });
  const title = h('span', { class: 'tile-title' });
  const phase = h('span', { class: 'tile-phase' });
  const act = h('span', { class: 'tile-act' });
  const screen = h('div', { class: 'tile-screen' });
  const note = h('div', { class: 'tile-note', hidden: true });
  const hit = h('button', { type: 'button', class: 'tile-hit', title: 'Open on its sandbox’s page',
                            'aria-label': 'Open ' + (w.session ? w.sandbox + ' · ' + w.session : w.sandbox) + ' on its page' },
    h('span', { class: 'tile-hit-icon' }, icon('maximize-2')));
  const el = h('div', { class: 'tile', 'data-key': w.key, 'data-sandbox': w.sandbox, 'data-session': w.session || '' },
    h('div', { class: 'tile-head' }, dot, title, phase, act),
    h('div', { class: 'tile-body' }, screen, note, hit));
  const tile = { key: w.key, sandbox: w.sandbox, session: w.session, el, dot, title, phase, act, screen, note, hit, term: null, visible: false, liveable: !!w.session };
  hit.addEventListener('click', () => { location.hash = '#/sandbox/' + w.sandbox + (tile.session ? '/' + tile.session : ''); });
  return tile;
}
function paintTile(tile, w) {
  const s = w.s;
  tile.liveable = !!w.session;
  // 593 §9: a tile is live (a watch terminal), saved (the session's saved screen — an engine, no
  // socket) or static. Saved → live swaps in place; live → saved lets go of the socket first (an
  // open grid never keeps a host alive for a sandbox that does not run).
  const kind = !w.session ? 'static' : w.saved ? 'saved' : 'live';
  if (tile.term && tile.kind && tile.kind !== kind) {
    if (tile.kind === 'saved' && kind === 'live' && tile.term.saved) goLive(tile.term);
    else detachTile(tile);
  }
  tile.kind = kind;
  tile.saved = w.saved || null;
  if (tile.term && tile.term.saved && w.saved) paintCover(tile.term);
  tile.el.dataset.kind = kind;
  tile.el.dataset.phase = s.phase;
  tile.dot.className = 'ph-dot ph-' + s.phase;
  tile.title.textContent = w.session ? w.sandbox + ' · ' + w.session : w.sandbox;
  tile.title.title = w.command ? w.command : '';
  tile.phase.textContent = w.saved ? s.phaseLabel + ' · saved ' + when(w.saved.savedAt) : s.phaseLabel;
  const verb = { paused: 'resume', asleep: 'wake', hibernated: 'wake', off: 'start', failed: 'start' }[s.phase];
  tile.act.replaceChildren(verb && (!w.session || w.saved) && !s.busy ? btn(VERBS[verb][0], () => lifecycle(verb, w.sandbox), { small: true }) : '');
  if (!w.session) {
    const known = grid.sessions[w.sandbox] || [];
    tile.note.hidden = false;
    tile.note.className = 'tile-note static';
    tile.note.replaceChildren(
      !w.none && PHASE_GLYPH[s.phase] ? h('div', { class: 'tc-glyph' }, icon(PHASE_GLYPH[s.phase])) : null,
      h('div', { class: 'tile-note-head' }, w.none ? 'No sessions running' : s.phaseLabel),
      h('div', null, w.none ? 'Open one from its page.' : s.phase === 'off' ? 'Starting boots it fresh — new sessions.'
        : known.length ? 'Sessions when it last ran: ' + known.map((x) => x.name).join(', ') : 'Its sessions are listed while it runs.'));
  }
}
function gridSchedule() {
  if (grid.scheduled) return;
  grid.scheduled = true;
  setTimeout(() => {
    grid.scheduled = false;
    if (!grid.active) return;
    const cap = setting('ui.grid_live_tiles', 8);
    const tiles = [...grid.body.children].map((el) => grid.tiles.get(el.dataset.key)).filter(Boolean);
    for (const t of tiles) if (t.term && (!t.visible || !t.liveable)) detachTile(t);
    // A lowered cap: the live tiles beyond it (the later ones, in page order) let go.
    tiles.filter((t) => t.term).slice(cap).forEach(detachTile);
    let live = tiles.filter((t) => t.term).length;
    let capped = 0;
    for (const t of tiles) {
      if (!t.liveable) continue;
      if (t.term) { t.note.hidden = true; continue; }
      if (!t.visible) { t.note.hidden = false; t.note.className = 'tile-note'; t.note.textContent = 'Off screen — not live'; continue; }
      if (live < cap) { attachTile(t); live++; t.note.hidden = true; continue; }
      capped++;
      t.note.hidden = false;
      t.note.className = 'tile-note capped';
      t.note.replaceChildren(h('div', { class: 'tile-note-head' }, 'Not live'),
        h('div', null, live + ' tiles are live (the cap: Settings › ui.grid_live_tiles). Scroll, filter, or click to open.'));
    }
    const total = tiles.filter((t) => t.liveable).length;
    grid.status.textContent = total + ' session' + (total === 1 ? '' : 's') + ' · ' + live + ' live' + (capped ? ' · ' + capped + ' more on screen not live (cap ' + cap + ')' : '');
    grid.el = grid.body;
    $('grid').dataset.live = String(live);
    $('grid').dataset.capped = String(capped);
  }, 50);
}
function attachTile(tile) {
  if (!setting('ui.terminals', true)) return;
  const t = newTerm(tile.sandbox, tile.session, 'watch');
  t.grid = true;
  if (tile.saved) t.saved = { savedAt: tile.saved.savedAt, reason: tile.saved.savedReason };
  tile.term = t;
  paintCover(t);
  tile.screen.append(t.els.wrap);
  bootTerm(t, 13);
}
function detachTile(tile) {
  if (!tile.term) return;
  const t = tile.term;
  tile.term = null;
  closeTerminal(t.id);                                   // the socket closes; the frame and its engine go
}

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { overview: 'box', sessions: 'layout-grid', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', onboarding: 'rocket', doctor: 'stethoscope', settings: 'settings' };
for (const a of document.querySelectorAll('#nav > a[data-view]')) if (NAV_ICONS[a.dataset.view]) a.prepend(icon(NAV_ICONS[a.dataset.view]));
setButton($('sign-out'), 'Sign out');

(async () => {
  if (await bootstrap()) {
    if (!/^#\/[a-z]/.test(location.hash)) history.replaceState(null, '', location.pathname + '#/overview');
    await loadSettings();
    // 594 (D8): a store never onboarded opens on the setup wizard (once per page load).
    try {
      const o = await api('overview');
      state.overview = o;
      renderNavSandboxes();
      if (o.onboarded === false && location.hash === '#/overview') history.replaceState(null, '', location.pathname + '#/onboarding');
    } catch (_) { /* the overview says so itself */ }
    route();
    connect();
    if (state.view !== 'resources') scheduleResTotal(0);   // 595: the nav's total (the page measures on its own)
    setInterval(() => {
      if (![...state.ops.values()].some((o) => o.state === 'running')) return;
      paintRowOps();
      if (state.view === 'operations') renderOperations();     // the running ones count their seconds
    }, 1000);
    setInterval(paintRowOps, 15000);
    setInterval(() => { for (const t of terminals.values()) paintCover(t); }, 30000);   // "asleep 7 min"
    // 599 (594.B4): the tabs' {time}, at each minute.
    setTimeout(() => { paintTabs(); setInterval(paintTabs, 60000); }, 60000 - (Date.now() % 60000) + 50);
  }
})();
