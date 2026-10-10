// components/terminal — A browser terminal (591): its sandboxed frame, socket, cover, paste, saved screen and boot log.
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, PHASE_GLYPH, setButton, withIcon } from '../dom/icons-75c107270d336b51.js';
import { api } from '../core/api-129e35835156aceb.js';
import { bytes, elapsedText, ms, when } from '../core/format-b2e68384da8d2f36.js';
import { act, TRANSITION_LABEL, transitionOf, waitForOp } from '../core/operations-24912c84c13d7e09.js';
import { sandboxBusy, sandboxImage, sandboxPhase } from '../core/sandboxes-5eed88567d9ef0c0.js';
import { setting, terminalsAllowed } from '../core/settings-4557874815573b31.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { INPUT_CHUNK, PASTE_CONFIRM_BYTES, PASTE_MAX_BYTES, sview, terminals, termUI } from '../core/terminals-fa5cf7fc28fdb48f.js';
import { isInt, quietly, utf8 } from '../core/util-1195caf40612902f.js';
import { bridgeNotice, failureFor } from './notices-4ade591a3c0f51da.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const lifecycle = upcall('lifecycle'), paintTabs = upcall('paintTabs'), renderTerminals = upcall('renderTerminals');

// This page never opens windows.
window.open = function refuseToOpen() { return null; };

function wasmURL() {
  const m = document.querySelector('meta[name="doz-ghostty-wasm"]');
  return m ? m.getAttribute('content') : null;
}
/// The engine's WebAssembly, fetched once from this origin; each frame gets its own copy to compile.
let engineWasm = null;
function engineBytes() {
  if (!engineWasm) engineWasm = fetch(wasmURL(), { credentials: 'omit' }).then((r) => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); });
  return engineWasm;
}
/// 608: scroll what the pane shows into its scrollback (a restarted session's new screen then starts below it).
export function keepScrollback(t) { toFrame(t, { t: 'keep-scrollback' }); }
function toFrame(t, msg, transfer) {
  if (t.frame && t.frame.contentWindow) t.frame.contentWindow.postMessage(msg, '*', transfer || []);
}
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
    case 'paste-too-big': failureFor(t.sandbox, 'That paste is too big — a terminal takes at most 1 MiB at once'); break;
    case 'key': savedKey(t); break;
  }
});

/// Open the image's own session (starting it when needed — an explicit request), then attach.
export async function openDefaultTerminal(name) {
  if (!terminalsAllowed()) return;
  const op = await act({ action: 'open-session', sandbox: name });
  if (!op) return;
  const done = await waitForOp(op);
  if (done && done.state === 'done') openTerminal(name, null, 'interactive');
}

/// 593: a terminal record (a page terminal, or a grid tile's when `grid`).
export function newTerm(sandbox, session, mode) {
  const t = { id: termUI.nextId++, sandbox, session, mode, pane: 0, grid: false, saved: null, lazy: false,
              ws: null, frame: null, cols: 80, rows: 24, state: null, ended: false, endText: '', errorText: '', disconnected: '',
              closed: false, title: '', pinger: null, coverAction: null, onReady: null, onOpened: null, onFailed: null };
  t.els = terminalElements(t);
  terminals.set(t.id, t);
  return t;
}
/// Load the engine into the terminal's frame, then connect. False when it could not.
export async function bootTerm(t, fontSize) {
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
export async function openTerminal(sandbox, session, mode, pane, opts = {}) {
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

/// 605: `opts.reattach` — the page had this terminal (doz ui restarted, or a sign-in again): the server
/// keeps its scrollback; the answer is 'ok', 'retry' (busy: too many terminals or tickets) or 'failed'.
async function connectTerminal(t, opts = {}) {
  const body = { mode: t.mode };
  if (t.session) body.session = t.session;
  if (opts.reattach) body.reattach = true;
  if (t.mode === 'interactive') {
    body.cols = Math.max(2, Math.min(1000, t.cols));
    body.rows = Math.max(1, Math.min(500, t.rows));
  }
  let ticket;
  try {
    ticket = (await api('sandboxes/' + t.sandbox + '/terminal-ticket', { method: 'POST', json: body })).ticket;
  } catch (e) {
    if (opts.reattach) {
      if (e.status === 503) return 'retry';
      if (e.status === 401) { t.reattach = true; paintCover(t); return 'failed'; }     // signedOut() follows
      t.disconnected = 'it could not reattach (' + (e.message || e) + ')';
    } else {
      t.errorText = e.message || String(e);
    }
    paintCover(t);
    paintTabs();
    return 'failed';
  }
  if (t.closed) return 'failed';
  // The ticket rides in the subprotocol list, never in the URL; it works once, within 30 s. 605: wss on an
  // https page (the dashboard served to other machines).
  const scheme = location.protocol === 'https:' ? 'wss://' : 'ws://';
  const ws = new WebSocket(scheme + location.host + '/api/v1/sandboxes/' + t.sandbox + '/terminal-socket',
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
  return 'ok';
}

/// 605 (C.2): terminals come back by themselves — after doz ui restarted (`hello`), a sign-in again, or a
/// socket that dropped while doz ui still answers. One at a time, at most 16, a back-off when the server
/// is busy. What was typed in the gap is dropped, never queued (591).
export async function reattachTerminals() {
  if (state.reattaching) { state.reattachAgain = true; return; }
  state.reattaching = true;
  try {
    let n = 0;
    for (const t of [...terminals.values()]) {
      if (!t.reattach || t.closed) continue;
      if (state.uiDown || state.signedOut || state.uiMoved || !state.csrf) break;
      if (++n > 16) break;
      for (let attempt = 0; attempt < 4; attempt++) {
        t.reattach = false;
        t.state = null;
        t.disconnected = '';
        t.reattached = true;
        paintCover(t);
        const r = await connectTerminal(t, { reattach: true });
        if (r !== 'retry') break;
        t.reattach = true;
        await new Promise((res) => setTimeout(res, 1000 * 2 ** attempt));
      }
      if (t.reattach && !state.signedOut && !state.uiDown) { t.reattach = false; t.disconnected = 'it could not reattach — the server is busy'; paintCover(t); }
    }
  } finally {
    state.reattaching = false;
    if (state.reattachAgain) { state.reattachAgain = false; reattachTerminals(); }
  }
  paintTabs();
}
function termNote(t, text, ms = 4000) {
  const n = t.els.note;
  n.textContent = text.slice(0, 80);
  n.hidden = false;
  t.els.wrap.dataset.notice = n.textContent;
  clearTimeout(t.noticeTimer);
  t.noticeTimer = setTimeout(() => { n.hidden = true; }, ms);
}

function onTerminalMessage(t, ev) {
  if (typeof ev.data !== 'string') {
    toFrame(t, { t: 'write', data: ev.data }, [ev.data]);
    if (t.reattached) { t.reattached = false; t.els.wrap.dataset.reattached = String((+t.els.wrap.dataset.reattached || 0) + 1); termNote(t, 'Reconnected', 3000); }
    return;
  }
  let m;
  try { m = JSON.parse(ev.data); } catch (_) { return; }
  if (m.t === 'state') {
    t.state = m;
    if (t.bootIntent && m.cover && !['shutDown', 'failed', 'reattaching'].includes(m.cover.kind)) t.bootIntent = false;
    if (m.session) t.session = m.session;
    // "woke in 0.4 s": one line over the screen, for a few seconds.
    if (typeof m.notice === 'string' && m.notice) termNote(t, m.notice);
  } else if (m.t === 'notice') {
    if (typeof m.kind === 'string' && typeof m.text === 'string') bridgeNotice(m.kind, m.text);
    return;
  } else if (m.t === 'boot-done') {
    toFrame(t, { t: 'keep-scrollback' });           // the boot log's end scrolls into the scrollback
    return;
  } else if (m.t === 'ended') {
    // 608: a restart under way (session-actions.js) — the pane waits for the session to come back.
    if (t.restarting) { paintCover(t); return; }
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
  if (t.restarting) { paintCover(t); paintTabs(); return; }       // 608: it reattaches when the restart is done
  // 605: a terminal that was attached comes back by itself — when doz ui restarts or stops (it reattaches
  // on the next `hello`), when this page must sign in again (after the sign-in), or when the socket
  // dropped while doz ui still answers (now). Never after an end, a long silence or a refusal.
  if (t.opened && (['session-ended', 'shutdown', 'restarting'].includes(ev.reason) || ev.code === 1006)) {
    t.reattach = true;
    t.disconnected = '';
    paintCover(t);
    paintTabs();
    setTimeout(() => { if (!state.uiDown && !state.signedOut) reattachTerminals(); }, 1000);
    return;
  }
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
export function sendInput(t, s) {
  if (t.mode !== 'interactive' || !t.ws || t.ws.readyState !== WebSocket.OPEN) return;
  const b = utf8.encode(s);
  for (let i = 0; i < b.length; i += INPUT_CHUNK) t.ws.send(b.subarray(i, i + INPUT_CHUNK));
}

export function closeTerminal(id) {
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
export function focusTerm(t) {
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
  const action = h('button', { type: 'button', class: 'btn sm tc-act' });
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
  if (size > PASTE_MAX_BYTES) { failureFor(t.sandbox, 'That paste is ' + bytes(size) + ' — a terminal takes at most 1 MiB at once'); return; }
  const { text, replaced } = encodePaste(raw);
  const reasons = [];
  if (replaced) reasons.push(replaced + ' control character' + (replaced === 1 ? ' was' : 's were') + ' replaced with spaces.');
  if (!bracketed && text.includes('\r')) reasons.push('It has line breaks and the program did not turn on bracketed paste — each line may run as a command.');
  if (size > PASTE_CONFIRM_BYTES) reasons.push('It is large (' + bytes(size) + ').');
  if (!reasons.length) { toFrame(t, { t: 'paste', text }); return; }
  const lines = text.split('\r');
  const d = h('dialog', { class: 'dlg paste-dialog' });
  const ok = h('button', { type: 'button', class: 'btn primary' }, withIcon('clipboard-paste', 'Paste'));
  const cancel = h('button', { type: 'button', class: 'btn quiet' }, withIcon('x', 'Cancel'));
  ok.addEventListener('click', () => { d.close(); toFrame(t, { t: 'paste', text }); focusTerm(t); });
  cancel.addEventListener('click', () => { d.close(); focusTerm(t); });
  d.append(h('form', { method: 'dialog' },
    h('div', { class: 'dlg-head' }, h('h2', { class: 'h-title' }, 'Paste ' + lines.length + ' line' + (lines.length === 1 ? '' : 's') + ' (' + bytes(size) + ') into ' + t.sandbox + '?')),
    h('div', { class: 'dlg-body' }, ...reasons.map((r) => h('p', { class: 'sub' }, r)),
      h('pre', { class: 'paste-preview' }, lines.slice(0, 5).join('\n').slice(0, 2000) + (lines.length > 5 ? '\n…' : ''))),
    h('div', { class: 'dlg-foot dlg-buttons' }, cancel, ok)));
  d.addEventListener('close', () => d.remove());
  document.body.append(d);
  d.showModal();
  ok.focus();
}
export function paintCover(t) {
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
  else if (t.restarting) { kind = 'reattaching'; headline = 'Restarting the session…'; detail = 'it comes back here when it is running again'; spinner = true; }
  else if (t.ended) { kind = 'ended'; headline = 'The session ended'; detail = t.endText; }
  else if (t.reattach) {
    kind = 'reattaching'; headline = 'Reconnecting…'; spinner = true;
    detail = state.signedOut ? 'it reattaches once this page is signed in again' : 'it reattaches by itself when doz ui answers again';
  }
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
export function terminalTitle(t) {
  const tpl = String(setting('ui.terminal_title', '{sandbox} · {session} · {time}'));
  if (!tpl) return t.session || '…';
  const d = new Date();
  const time = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  const phase = (t.state && t.state.phase) || sandboxPhase(t.sandbox) || '';
  const vars = { sandbox: t.sandbox, session: t.session || '…', image: String(sandboxImage(t.sandbox)).replace(/^custom:/, ''),
                 time, phase: TITLE_PHASES[phase] || phase };
  return tpl.replace(/\{([a-z]+)\}/g, (m, k) => (k in vars ? vars[k] : m)).replace(/[\u0000-\u001f\u007f-\u009f]/g, '').slice(0, 200);
}
const SAVED_WAKE = { paused: ['Resume', 'resume'], asleep: ['Wake', 'wake'], hibernated: ['Wake', 'wake'] };
export const PHASE_WORD = { paused: 'paused', asleep: 'asleep', hibernated: 'hibernated', off: 'shut down', failed: 'failed', booting: 'starting', running: 'running' };
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
export async function bootLogDialog(name) {
  let boots;
  try { boots = (await api('sandboxes/' + name + '/boots')).boots; } catch (e) { failureFor(name, e.message || String(e)); return; }
  const d = h('dialog', { class: 'dlg bootlog-dialog', 'data-sandbox': name });
  const picker = h('select', { 'aria-label': 'Which boot', class: 'bootlog-picker' },
    boots.map((b) => h('option', { value: String(b.number), 'data-result': b.result }, bootLabel(b))));
  const area = h('div', { class: 'bootlog-area' });
  const why = h('div', { class: 'bootlog-error', role: 'status' });
  const close = h('button', { type: 'button', class: 'btn quiet' }, withIcon('x', 'Close'));
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
export function goLive(t) {
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
