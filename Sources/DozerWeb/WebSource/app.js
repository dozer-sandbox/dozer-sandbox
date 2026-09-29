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
    refreshNav();
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
      h('td', { class: 'op-text' }, o.text));
  });
  box.replaceChildren(h('h1', null, 'Operations'),
    state.preps.length ? preparationsSection() : null,
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
  const rows = state.preps.map((p) => h('tr', { class: 'op-row op-' + (prepRunning(p) ? 'running' : p.state === 'done' ? 'done' : 'failed'), 'data-prep': p.image },
    h('td', null, prepRunning(p) ? h('span', { class: 'mini-spin', title: p.state }) : h('span', { class: 'op-state', title: p.state }, p.state === 'done' ? '✓' : '✕')),
    h('td', { class: 'op-action' }, icon('flame'), 'prepare ' + p.image),
    h('td', null, p.requestedBy.join(', ')),
    h('td', null, clock(p.startedAt)), h('td', { class: 'num' }, Math.round(p.seconds) + ' s'),
    h('td', { class: 'op-text' }, prepProgressText(p)),
    h('td', null, prepRunning(p) && p.state !== 'cancelling'
      ? btn('Cancel preparation', () => act({ action: 'prepare-cancel', images: [p.image] }), { small: true, danger: true }) : null)));
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
  ui: 'This UI', host: 'The host', store: 'The store', claude: 'Claude Code', defaults: 'New sandboxes',
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
function connect() {
  if (state.signedOut) return;
  const es = new EventSource('/api/v1/stream');
  state.es = es;
  es.addEventListener('hello', async () => {
    setLive('on', 'live');
    try { for (const o of await api('operations')) state.ops.set(o.id, o); renderOps(); } catch (_) { /* */ }
    loadPreparations();
    refreshNav();
    refresh(true);
  });
  // The Settings page is not about the store's live state: re-rendering it would drop a half-typed
  // value; nor is Operations (its own events keep it current), nor the onboarding wizard (its own).
  es.addEventListener('changed', () => {
    refreshNav();
    // (Nor a page whose masked key field is being filled in: a re-render would drop it.)
    const typing = [...document.querySelectorAll('[data-secret]')].some((e) => e.value);
    if (state.view !== 'settings' && state.view !== 'operations' && state.view !== 'onboarding' && !typing) refresh(false);
  });
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
    if (reason === 'shutdown') { setLive('bad', 'the UI stopped'); notice('The doz ui process stopped. Start it again with doz ui.', true); return; }
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
    const views = { overview: viewOverview, images: viewImages, operations: viewOperations, accounts: viewAccounts,
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
  const before = new Set(terminals.keys());
  openTerminal(name, null, 'interactive');
  const t = [...terminals.values()].find((x) => !before.has(x.id));
  const end = Date.now() + 15000;
  while (t && Date.now() < end && !t.closed && !t.errorText && !(t.state && ['shutDown', 'failed', 'boot'].includes(t.state.cover.kind))) {
    await new Promise((r) => setTimeout(r, 100));
  }
  await act({ action: 'start', sandbox: name });
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
  renderNavSandboxes();
  const rows = o.sandboxes.map((s) => h('tr', { class: 'click', on: { click: () => { location.hash = '#/sandbox/' + s.name; } } },
    h('td', null, h('a', { href: '#/sandbox/' + s.name }, s.name), h('div', { class: 'muted' }, s.image),
      s.workspace ? null : h('div', { class: 'muted no-ws', title: '/workspace is private to the VM: nothing is shared with the Mac' }, 'no workspace'),
      h('div', { 'data-op-for': s.name })),
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
      'No sandboxes yet — New sandbox, or doz create NAME --image lab'));
}

async function createDialog() {
  let images = [], accounts = { accounts: [] };
  try { [images, accounts] = await Promise.all([api('images'), api('accounts')]); } catch (_) { /* defaults */ }
  dialog('New sandbox', 'It is created off; Start boots it (the first start of an image not yet prepared prepares it — minutes, needs network).', [
    { name: 'sandbox', label: 'Name', placeholder: 'a-z 0-9 -', required: true },
    { name: 'image', label: 'Image', type: 'select', value: setting('defaults.image', 'lab'),
      options: images.length ? images.map((i) => [i.name, i.name + (i.kind === 'custom' ? ' (template)' : '')]) : ['lab', 'claude-code', 'pi'] },
    { name: 'network', label: 'Network', type: 'select', value: '',
      options: [['', 'default (per image, Settings)'],['agent', 'agent — proxied, Anthropic + registries'], ['bake', 'bake — proxied, package registries'],
        ['locked', 'locked — proxied, nothing'], ['open', 'open — proxied, everything (logged)'], ['nat', 'nat — a real interface (vmnet)'], ['none', 'none']] },
    { name: 'account', label: 'Account', type: 'select', value: '',
      options: [['', 'the store default'], ['none', 'none'], ...accounts.accounts.map((a) => [a.name, a.name + ' (' + a.kind + ')'])] },
    { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: 'default (' + setting('defaults.cpus', 2) + ', Settings)' },
    { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: 'default (per image, Settings)' },
    { name: 'workspace', label: 'Workspace (a folder on this Mac, shared at /workspace)', placeholder: '/Users/you/code/project',
      help: 'Type or paste its path (a browser cannot pick a local folder for the host).' },
    { name: 'noWorkspace', label: 'No workspace — /workspace is private to the VM (nothing is shared with the Mac)', type: 'checkbox' },
  ], 'Create', async (v) => {
    // 594 (D17): creating without a workspace is allowed, but chosen — never by leaving a field empty.
    if (!v.workspace && !v.noWorkspace) throw new Error('Give a workspace folder, or tick “No workspace”.');
    if (v.workspace && v.noWorkspace) throw new Error('Either a workspace folder or “No workspace”, not both.');
    const body = { action: 'create', sandbox: v.sandbox, image: v.image };
    if (v.network) body.network = v.network;
    if (v.account) body.account = v.account;
    if (v.cpus) body.cpus = Number(v.cpus);
    if (v.memoryMiB) body.memoryMiB = Number(v.memoryMiB);
    if (v.workspace) body.workspace = v.workspace;
    await actOrThrow(body);
  });
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
  await refreshSandbox();
  sandboxArrived(name, want);
}
async function refreshSandbox() {
  if (sbxRefreshing) { sbxAgain = true; return; }
  sbxRefreshing = true;
  const name = state.param;
  try {
    const [d, net, accounts] = await Promise.all([api('sandboxes/' + name), api('sandboxes/' + name + '/network'), api('accounts').catch(() => ({ accounts: [] }))]);
    if (state.view !== 'sandbox' || state.param !== name || state.signedOut) return;
    state.sbx = { name, d, net, accounts };
    const parts = sandboxParts(name, d, net, accounts);
    $('sbx-bar').replaceChildren(parts.bar);
    $('sbx-details').replaceChildren(parts.details);
    $('sbx-body').classList.toggle('details-closed', !setting('ui.details_open', true));
    paintRowOps();
    paintTermEmpty();
  } catch (e) {
    if (e.status === 404) { location.hash = '#/overview'; return; }
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
function sandboxArrived(name, want) {
  const s = state.sbx;
  if (!s || s.name !== name || !s.d) return;
  const mine = [...terminals.values()].filter((t) => !t.grid && t.sandbox === name);
  const running = s.d.info.phase === 'running';
  const live = (s.d.sessions || []).filter((x) => !x.ended).map((x) => x.name);
  if (want) {
    const have = mine.find((t) => t.session === want && t.mode === 'interactive' && !t.ended);
    if (have) { const v = sview(name); v.selected[have.pane] = have.id; renderTerminals(); focusTerm(have); }
    else if (running && live.includes(want)) openTerminal(name, want, 'interactive');
    else toast('Session ' + want + ' is not running in ' + name, true);
    return;
  }
  if (!mine.length && running && live.includes(s.d.defaultSession) && setting('ui.terminals', true)) {
    openTerminal(name, s.d.defaultSession, 'interactive');
  }
}
function sandboxParts(name, d, net, accounts) {
  const i = d.info;
  const running = i.phase === 'running';
  // Sessions need a VM: running, or one a session request wakes (paused, asleep, hibernated) — never
  // while off, failed, booting, busy or while another operation on it runs (590 bug 2).
  const sessionsReady = ['running', 'paused', 'asleep', 'hibernated'].includes(i.phase) && !i.busy && !opRunningFor(name);
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
  const busy = i.busy || i.phase === 'booting' || opRunningFor(name);
  const detailsOpen = setting('ui.details_open', true);
  const netText = i.network + (i.deniedConnections ? ' (' + i.deniedConnections + ' denied)' : '');
  const bar = h('div', { class: 'sbx-bar-inner' },
    h('div', { class: 'sbx-title' },
      h('h1', null, name), phasePill(i.phase, i.phaseLabel, i.busy),
      h('span', { class: 'sbx-meta' },
        h('span', null, i.image),
        h('span', null, (i.ramHeldMiB ? mib(i.ramHeldMiB) : '—') + ' of ' + mib(i.memoryMiB)),
        h('span', { class: i.deniedConnections ? 'st-warn' : null }, netText),
        i.accountApplies ? h('span', null, 'account ' + (i.account || '—')) : null,
        i.workspace ? null : h('span', { class: 'st-warn', title: '/workspace is private to the VM: nothing is shared with the Mac' }, 'no workspace'))),
    h('div', { class: 'sbx-actions' },
      lifecycleButtons(i, true),
      h('span', { class: 'sbx-sep', 'aria-hidden': 'true' }),
      gated(btn('Open in Terminal', terminal(null), { small: true, title: 'Your terminal app attaches to the ' + d.defaultSession + ' session (waking the sandbox if it sleeps)' })),
      gated(btn('New shell', () => newShellTerminal(name).catch((e) => toast(e.message || String(e), true)),
        { small: true, title: 'A new shell session (shell-2, shell-3, …) in a browser terminal' })),
      ((b) => { if (busy) b.disabled = true; return b; })(btn('Terminal…', () => newTerminalDialog(name), { small: true, title: 'Attach to or watch a session, or start one running a command' })),
      termUI.splitBtn || null,
      h('span', { class: 'sbx-sep', 'aria-hidden': 'true' }),
      ((b) => { if (busy || !d.hasRootDisk) { b.disabled = true; b.title = d.hasRootDisk ? 'Wait until it settles' : 'It has no disk yet — start it once'; } return b; })(
        btn('Duplicate…', () => duplicateDialog(name, d, accounts, null), { small: true, title: 'A new sandbox from this one’s disk: a new workspace, CPUs, memory, network, account' })),
      ((b) => { if (busy || !d.hasRootDisk) { b.disabled = true; b.title = d.hasRootDisk ? 'Wait until it settles' : 'It has no disk yet — start it once'; } return b; })(
        btn('Save as template…', () => templateDialog(name, d, null), { small: true, title: 'Its root disk becomes an image other sandboxes are created from (never its state disk)' })),
      btn(detailsOpen ? 'Hide details' : 'Details', () => {
        const open = !setting('ui.details_open', true);
        $('sbx-body').classList.toggle('details-closed', !open);
        saveSetting('ui.details_open', open).then(() => refreshSandbox()).catch((e) => toast('The setting was not saved: ' + (e.message || e), true));
      }, { small: true, title: 'The sessions, restore points, network and keys panel (remembered: ui.details_open)' })),
    h('div', { 'data-op-for': name, 'data-banner': '1', role: 'status' }));
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
      running ? 'No sessions.' : 'Sessions are listed while the sandbox runs.'),
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
      proxied ? btn('Account…', () => dialog('Account of ' + name, 'Which Anthropic account the proxy uses for it. The guest only ever sees a placeholder.',
        [{ name: 'account', label: 'Account', type: 'select', value: i.account || 'default',
           options: [['default', 'the store default'], ['none', 'none'], ...accounts.accounts.map((a) => [a.name, a.name + ' (' + a.kind + ')'])] }], 'Use', async (v) => {
          await actOrThrow({ action: 'account-use', sandbox: name, account: v.account });
        }), { small: true }) : null)),
    panel(table(['Key', 'Set', 'Source', 'State', 'Policy', ''], creds), 'No keys — the sandbox uses none.'),
    keyEntry(name, proxied),
    foreign.length ? h('h2', null, 'Credentials the guest brought itself (fingerprints only)') : null,
    foreign.length ? panel(table(['Kind', 'Prefix', 'Fingerprint', 'Header', 'Requests', 'Last seen'], foreign, [4])) : null,
    h('h2', null, 'Configuration'),
    h('div', { class: 'panel' }, h('div', { class: 'facts' },
      fact('Memory', mib(d.memoryMiB)), fact('Root disk', mib(d.rootfsMiB)), fact('State disk', mib(d.stateDiskMiB)),
      fact('Journal', d.journalMiB ? mib(d.journalMiB) : 'none'), fact('Network', d.networkMode + (d.subnet ? ' · ' + d.subnet : '')),
      fact('Account', i.accountApplies ? (i.account || '—') : 'n/a'),
      fact('Workspace', i.workspace ? i.workspace + ' → /workspace (live)' : 'not shared — /workspace is private to the VM'),
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
  const ws = d.shares.find((s) => s.guestPath === '/workspace');
  dialog('Duplicate ' + name,
    'A new sandbox from ' + name + '’s root disk (an instant APFS clone). It is created off; Start boots it. Keys are not copied.', [
      { name: 'newName', label: 'New sandbox name', placeholder: 'a-z 0-9 -', required: true },
      { name: 'source', label: 'From', type: 'select', options: sources, value: pointID || '' },
      { name: 'workspace', label: 'Workspace (a folder on this Mac, shared at /workspace)', placeholder: ws ? ws.hostPath + ' (the same)' : 'none (the same)',
        help: 'It must exist — Dozer never creates it.' },
      { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: String(d.cpus) + ' (the same)' },
      { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: String(d.memoryMiB) + ' (the same)' },
      { name: 'network', label: 'Network', type: 'select', value: '',
        options: [['', i.network + ' (the same, its policy included)'], ['agent', 'agent'], ['bake', 'bake'], ['locked', 'locked'], ['open', 'open'], ['nat', 'nat'], ['none', 'none']] },
      { name: 'account', label: 'Account', type: 'select', value: '',
        options: [['', 'the same'], ['default', 'the store default'], ['none', 'none'], ...accounts.accounts.map((a) => [a.name, a.name + ' (' + a.kind + ')'])] },
      { name: 'copyState', label: 'Copy the agent’s state disk too', type: 'checkbox',
        help: 'Off (the default): a fresh state disk. On: its logins and history are copied into the new sandbox.' },
    ], 'Duplicate', async (v) => {
      const b = { action: 'duplicate', sandbox: name, newName: v.newName };
      if (v.source) b.point = v.source;
      if (v.workspace) b.workspace = v.workspace;
      if (v.cpus) b.cpus = Number(v.cpus);
      if (v.memoryMiB) b.memoryMiB = Number(v.memoryMiB);
      if (v.network) b.network = v.network;
      if (v.account) b.account = v.account;
      if (v.copyState) b.copyState = true;
      await actOrThrow(b);
    });
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
async function viewImages() {
  if (state.imagesMode === 'lineage') return viewLineage();
  const rows = (await api('images')).map((r) => h('tr', null,
    h('td', null, r.name, r.kind === 'custom' ? h('span', { class: 'tag tpl' }, 'template') : null),
    h('td', null, r.kind === 'custom' ? 'template' : r.kind),
    h('td', null, r.baked ? (r.bakedAt ? full(r.bakedAt) : 'yes') : h('span', { class: 'muted' }, 'no — bakes on first start')),
    h('td', { class: 'num' }, r.allocatedBytes ? bytes(r.allocatedBytes) : '—'),
    h('td', null, [r.note, r.fromSandbox ? 'from ' + r.fromSandbox : null].filter(Boolean).join(' · ') || '—'),
    h('td', { class: 'mono muted' }, r.key ? r.key.slice(0, 16) : ''),
    h('td', null, h('div', { class: 'actions' },
      r.kind === 'builtin' ? btn(r.baked ? 'Re-bake' : 'Bake', () => act({ action: 'image-bake', image: r.name }), { small: true, title: 'Minutes, needs network' }) : null,
      r.baked || r.kind === 'custom' ? btn('Remove', () => confirmAction('Remove ' + (r.kind === 'custom' ? 'template ' : 'image ') + r.name,
        r.kind === 'custom' ? 'The template is deleted; sandboxes created from it keep working.' : 'Its baked disk is deleted (it is baked again when next needed); sandboxes cloned from it keep working.',
        r.name, { action: 'image-rm', image: r.name }), { small: true, danger: true }) : null))));
  return h('div', null, h('div', { class: 'head' }, h('h1', null, 'Images'), imagesToggle()),
    h('p', { class: 'sub' }, 'Built-in images, and templates saved from sandboxes (a sandbox’s root disk — never its state disk). Progress of a bake shows under Operations.'),
    panel(table(['Image', 'Kind', 'Baked', 'Size', 'Note', 'Key', ''], rows, [3])));
}
async function viewLineage() {
  const t = await api('images/tree');
  const labels = { base: 'OCI base', image: 'image', template: 'template', prepared: 'prepared disk', sandbox: 'sandbox', restorePoint: 'restore point' };
  const rows = t.nodes.map((n) => {
    const shared = n.sharedWithParentBytes || 0;
    const own = n.uniqueBytes || 0;
    const whole = Math.max(1, n.allocatedBytes);
    const bar = h('div', { class: 'lin-bar', title: 'shared with its parent ' + bytes(shared) + ' · its own ' + bytes(own) });
    const a = h('span', { class: 'lin-shared' }), b = h('span', { class: 'lin-own' });
    a.style.width = Math.min(100, (shared / whole) * 100).toFixed(1) + '%';
    b.style.width = Math.min(100, (own / whole) * 100).toFixed(1) + '%';
    bar.append(a, b);
    const name = n.kind === 'sandbox' ? h('a', { href: '#/sandbox/' + n.sandbox }, n.name) : h('span', null, n.name);
    return h('div', { class: 'lin-row depth-' + Math.min(n.depth, 8) + ' lin-' + n.kind, 'data-kind': n.kind, 'data-name': n.name, 'data-depth': String(n.depth) },
      h('div', { class: 'lin-name' }, h('span', { class: 'lin-branch', 'aria-hidden': 'true' }, n.depth ? '└ ' : ''), name,
        h('span', { class: 'tag lin-kind' }, labels[n.kind] || n.kind), n.detail ? h('span', { class: 'muted mono lin-detail' }, n.detail) : null),
      h('div', { class: 'num lin-size' }, bytes(n.allocatedBytes), n.stateAllocatedBytes ? h('div', { class: 'muted' }, '+ state ' + bytes(n.stateAllocatedBytes)) : null),
      h('div', { class: 'num lin-shared-n' }, n.sharedWithParentBytes != null ? bytes(n.sharedWithParentBytes) : '—'),
      h('div', { class: 'num lin-own-n' }, bytes(own)),
      bar);
  });
  return h('div', null, h('div', { class: 'head' }, h('h1', null, 'Images'),
      h('div', { class: 'actions' }, btn('Refresh', () => refresh(false), { small: true, title: 'Measure again' }), imagesToggle())),
    h('p', { class: 'sub' }, 'The lineage: OCI base → image → template → the sandboxes on each. Size is what the disk holds; shared is what it shares with its parent (APFS clones); own is what removing it frees. All disks together: ' +
      bytes(t.unionBytes) + ' (measured in ' + Math.round(t.milliseconds) + ' ms).'),
    t.nodes.length
      ? h('div', { class: 'panel lineage' },
          h('div', { class: 'lin-row lin-headrow' }, h('div', null, 'Image / sandbox'), h('div', { class: 'num' }, 'Size'), h('div', { class: 'num' }, 'Shared'), h('div', { class: 'num' }, 'Own'), h('div', null, '')),
          rows)
      : panel(null, 'No disks yet — bake an image or start a sandbox.'));
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
function prepCard(p) {
  const running = prepRunning(p);
  const bar = h('div', { class: 'wiz-bar', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '100' });
  const fill = h('span');
  if (p.transferFraction != null) { fill.style.width = (p.transferFraction * 100).toFixed(1) + '%'; bar.setAttribute('aria-valuenow', (p.transferFraction * 100).toFixed(0)); }
  else bar.classList.add('indeterminate');
  bar.append(fill);
  return h('div', { class: 'prep-card prep-' + p.state, 'data-prep': p.image },
    h('div', { class: 'prep-head' }, running ? h('span', { class: 'mini-spin', 'aria-hidden': 'true' }) : h('span', { class: 'op-state' }, p.state === 'done' ? '✓' : '✕'),
      h('strong', null, p.image), h('span', { class: 'muted' }, ' · ' + (running ? Math.round(p.seconds) + ' s so far' : p.state + ' in ' + ms(p.seconds * 1000)) + ' · asked by ' + p.requestedBy.join(', '))),
    running && p.step ? h('div', { class: 'prep-step' }, p.step, h('span', { class: 'muted' }, '  ' + Math.round(p.stepSeconds || 0) + ' s')) : null,
    running && (p.transferLine || p.step) ? bar : null,
    running && p.transferLine ? h('div', { class: 'mono prep-transfer' }, p.transferLine) : null,
    running && p.output.length ? h('div', { class: 'mono muted prep-output' }, p.output.map((l) => h('div', null, '│ ' + l))) : null,
    p.error && p.state !== 'cancelled' ? h('div', { class: 'notice bad' }, p.error) : null,
    p.lines.length ? h('details', { class: 'prep-lines' }, h('summary', null, 'Finished steps (' + p.lines.length + ')'),
      h('div', { class: 'mono' }, p.lines.map((l) => h('div', null, l)))) : null);
}
function wizStep4(d, w) {
  const mine = w.prepImages || [];
  const preps = state.preps.filter((p) => mine.includes(p.image)).filter((p, i, a) => a.findIndex((x) => x.image === p.image) === i);
  const running = preps.some(prepRunning);
  const failed = preps.filter((p) => !prepRunning(p) && p.state !== 'done');
  const next = btn('Next', () => wizGo(5), { primary: true });
  if (running || failed.length) next.disabled = true;
  return [
    h('h2', null, 'Preparing'),
    h('p', { class: 'sub' }, 'In the host — not in this page: closing the tab changes nothing, and doz onboard --status in a terminal shows the same. Whoever starts a sandbox of these images meanwhile joins this preparation instead of starting another.'),
    preps.length ? h('div', { class: 'prep-cards' }, preps.map(prepCard)) : h('p', { class: 'muted' }, 'Starting…'),
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
  name.value = w.firstName || 'first';
  const image = h('select', { name: 'wiz-image' }, (imgs.length ? imgs : ['claude-code', 'pi', 'lab']).map((n) => h('option', { value: n }, n)));
  const ws = h('input', { type: 'text', name: 'wiz-workspace', placeholder: '/Users/you/code/project', autocomplete: 'off', spellcheck: 'false' });
  ws.value = w.firstWorkspace || '';
  const none = h('input', { type: 'checkbox', name: 'wiz-no-workspace' });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const create = btn('Create sandbox', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const n = name.value.trim(), path = ws.value.trim();
    w.firstName = n;
    w.firstWorkspace = path;
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(n)) { error.textContent = 'The name: 1–40 of a-z 0-9 - (not starting with -).'; return; }
    if (!path && !none.checked) { error.textContent = 'Give a workspace folder, or tick “No workspace”.'; return; }
    if (path && none.checked) { error.textContent = 'Either a workspace folder or “No workspace”, not both.'; return; }
    b.disabled = true;
    try {
      const body = { action: 'create', sandbox: n, image: image.value };
      if (path) body.workspace = path;
      await actOrThrow(body);
      w.created = n;
      wizGo(6);
    } catch (e) { error.textContent = e.message || String(e); b.disabled = false; }
  }, { primary: true });
  return [
    h('h2', null, 'First sandbox (optional)'),
    h('p', { class: 'sub' }, 'A sandbox for one project. Its workspace is a folder on this Mac, shared live at /workspace — type or paste its path (a browser cannot open a folder picker for the host). It is created off; Start boots it.'),
    h('label', { class: 'field' }, h('span', null, 'Name'), name),
    h('label', { class: 'field' }, h('span', null, 'Image'), image),
    h('label', { class: 'field' }, h('span', null, 'Workspace (a folder on this Mac)'), ws),
    h('label', { class: 'field check' }, h('span', null, 'No workspace — /workspace is private to the VM (nothing is shared with the Mac)'), none),
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
  const t = { id: termUI.nextId++, sandbox, session, mode, pane: 0, grid: false,
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
    t.onReady = () => toFrame(t, { t: 'init', wasm: wasm.slice(0), mode: t.mode, fontSize: isInt(fontSize, 9, 32) ? fontSize : 13 });
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
  connectTerminal(t);
  return true;
}
/// A terminal on the sandbox's page (593: each sandbox's page has its own tabs and split).
async function openTerminal(sandbox, session, mode, pane) {
  if (!terminalsAllowed()) return;
  const v = sview(sandbox);
  const t = newTerm(sandbox, session, mode);
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
  // 593: the state's own glyph over the cover (the two sleeps told apart: RAM kept / on disk).
  const g = PHASE_GLYPH[kind] || null;
  e.glyph.hidden = !g || spinner;
  if (g && e.glyph.dataset.icon !== g) { e.glyph.dataset.icon = g; e.glyph.replaceChildren(icon(g)); }
  e.action.hidden = !action;
  if (action) setButton(e.action, action); else e.action.replaceChildren();
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
    p.empty.hidden = mine.length > 0;
    for (const t of mine) {
      if (t.els.wrap.parentNode !== p.body) p.body.append(t.els.wrap);
      t.els.wrap.hidden = t.id !== v.selected[i];
    }
  });
  paintTermEmpty();
  // The URL names the session shown (replaceState: no route).
  const sel = name && terminals.get(v.selected[v.focusedPane] ?? v.selected[0]);
  if (sel && sel.session && state.session !== sel.session) {
    state.session = sel.session;
    history.replaceState(null, '', location.pathname + '#/sandbox/' + name + '/' + sel.session);
  }
}
/// The terminal area with no terminal: what it can open, from the sandbox's state.
function paintTermEmpty() {
  if (!termUI.built) return;
  const s = state.sbx;
  const p = termUI.panes[0];
  if (p.empty.hidden) return;
  if (!s || !s.d || s.name !== state.param) { p.empty.replaceChildren(h('div', { class: 'term-empty-box' }, 'Loading…')); return; }
  const i = s.d.info;
  const busy = i.busy || i.phase === 'booting' || opRunningFor(s.name);
  const live = (s.d.sessions || []).filter((x) => !x.ended);
  const box = h('div', { class: 'term-empty-box' });
  if (busy) {
    box.append(h('div', { class: 'term-empty-head' }, i.phaseLabel + '…'), h('div', null, 'The terminal opens when it can.'));
  } else if (i.phase === 'off' || i.phase === 'failed') {
    box.append(h('div', { class: 'term-empty-head' }, s.name + ' is ' + i.phaseLabel.toLowerCase()),
      h('div', { class: 'actions center' },
        btn('Start', () => lifecycle('start', s.name), { primary: true, title: bootViewOnStart() ? 'Boot it, and watch it boot here' : 'Boot it' })));
  } else {
    box.append(h('div', { class: 'term-empty-head' }, 'No terminal open'),
      h('div', { class: 'actions center' },
        btn('Open ' + s.d.defaultSession, () => openDefaultTerminal(s.name), { primary: true,
          title: 'A terminal on the ' + s.d.defaultSession + ' session (started when it is not running' + (i.phase === 'running' ? '' : '; it wakes the sandbox') + ')' }),
        ...live.filter((x) => x.name !== s.d.defaultSession).slice(0, 8).map((x) => btn('Open ' + x.name, () => openTerminal(s.name, x.name, 'interactive'))),
        btn('New shell', () => newShellTerminal(s.name).catch((e) => toast(e.message || String(e), true)))));
  }
  p.empty.replaceChildren(box);
}
function tabElement(t, pane) {
  const phase = t.ended || t.errorText || t.disconnected ? 'ended' : (t.state && t.state.phase) || 'unknown';
  const v = sview(t.sandbox);
  // Tabs are numbered (1, 2, …) per sandbox, so a shared session can say which tab it is shared with.
  const order = pageTerminals(t.sandbox).map((x) => x.id);
  const num = order.indexOf(t.id) + 1;
  const label = num + ' · ' + (t.session || '…');
  const twins = t.session && !t.ended ? pageTerminals(t.sandbox).filter((o) => o.id !== t.id && !o.ended && o.session === t.session) : [];
  const shared = twins.length ? h('span', { class: 'tag shared', title: 'Two views of ONE session: what is typed in either shows in both' },
    'shared with tab ' + twins.map((o) => order.indexOf(o.id) + 1).join(', ')) : null;
  const select = h('button', { type: 'button', role: 'tab', class: 'tab' + (t.id === v.selected[pane] ? ' active' : ''),
                               title: t.title ? t.title + ' — ' + label : label, 'data-term': String(t.id),
                               on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); focusTerm(t); } } },
    h('span', { class: 'tab-dot ph-' + phase, 'aria-hidden': 'true' }), icon(t.mode === 'watch' ? 'eye' : 'terminal'), label,
    t.mode === 'watch' ? h('span', { class: 'tag' }, 'watch') : null, shared);
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
  // What to open: a NEW shell by default (591 owner feedback: an empty form must never mirror an
  // existing session); attaching to or watching a running session is an explicit choice.
  const d = dialog('New terminal in ' + first, 'A new shell session by default. To see a session that already runs, pick Attach or Watch.', [
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
      if (!done.text.startsWith('started')) throw new Error('a session named ' + v.session + ' already runs — pick another name, or Attach to it');
      openTerminal(v.sandbox, v.session, 'interactive', pane);
      return;
    }
    const m = /^(attach|watch):(.+)$/.exec(v.what);
    if (!m) throw new Error('pick what to open');
    openTerminal(v.sandbox, m[2], m[1] === 'watch' ? 'watch' : 'interactive', pane);
  });
  const sandboxSel = d.querySelector('[name="sandbox"]'), whatSel = d.querySelector('[name="what"]');
  sandboxSel.closest('label').hidden = true;             // 593: the page's sandbox
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
  await Promise.all(o.sandboxes.filter((s) => s.phase === 'running').map(async (s) => {
    try { grid.sessions[s.name] = (await api('sandboxes/' + s.name + '/sessions')).filter((r) => !r.ended).map((r) => ({ name: r.name, command: r.command })); }
    catch (_) { /* it stopped meanwhile: its last list stays */ }
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
      for (const x of grid.sessions[s.name] || []) want.push({ key: s.name + '/' + x.name, sandbox: s.name, session: x.name, command: x.command, s });
      if (!(grid.sessions[s.name] || []).length) want.push({ key: s.name + '/', sandbox: s.name, session: null, s, none: true });
    } else {
      want.push({ key: s.name + '/', sandbox: s.name, session: null, s });
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
  tile.el.dataset.phase = s.phase;
  tile.dot.className = 'ph-dot ph-' + s.phase;
  tile.title.textContent = w.session ? w.sandbox + ' · ' + w.session : w.sandbox;
  tile.title.title = w.command ? w.command : '';
  tile.phase.textContent = s.phaseLabel;
  const verb = { paused: 'resume', asleep: 'wake', hibernated: 'wake', off: 'start', failed: 'start' }[s.phase];
  tile.act.replaceChildren(verb && !w.session && !s.busy ? btn(VERBS[verb][0], () => lifecycle(verb, w.sandbox), { small: true }) : '');
  if (!w.session) {
    const known = grid.sessions[w.sandbox] || [];
    tile.note.hidden = false;
    tile.note.className = 'tile-note static';
    tile.note.replaceChildren(
      !w.none && PHASE_GLYPH[s.phase] ? h('div', { class: 'tc-glyph' }, icon(PHASE_GLYPH[s.phase])) : null,
      h('div', { class: 'tile-note-head' }, w.none ? 'No sessions running' : s.phaseLabel),
      h('div', null, w.none ? 'Open one from its page.' : known.length ? 'Sessions when it last ran: ' + known.map((x) => x.name).join(', ') : 'Its sessions are listed while it runs.'));
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
const NAV_ICONS = { overview: 'box', sessions: 'layout-grid', images: 'layers', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', doctor: 'stethoscope', settings: 'settings' };
for (const a of document.querySelectorAll('#nav > a[data-view]')) if (NAV_ICONS[a.dataset.view]) a.prepend(icon(NAV_ICONS[a.dataset.view]));
setButton($('sign-out'), 'Sign out');

(async () => {
  if (await bootstrap()) {
    if (!/^#\/[a-z]/.test(location.hash)) history.replaceState(null, '', location.pathname + '#/overview');
    await loadSettings();
    // 594 (D8): a store never onboarded opens on the setup wizard (once per page load).
    try {
      const o = await api('overview');
      if (o.onboarded === false && location.hash === '#/overview') history.replaceState(null, '', location.pathname + '#/onboarding');
    } catch (_) { /* the overview says so itself */ }
    route();
    connect();
    setInterval(() => {
      if (![...state.ops.values()].some((o) => o.state === 'running')) return;
      paintRowOps();
      if (state.view === 'operations') renderOperations();     // the running ones count their seconds
    }, 1000);
    setInterval(paintRowOps, 15000);
    setInterval(() => { for (const t of terminals.values()) paintCover(t); }, 30000);   // "asleep 7 min"
  }
})();
