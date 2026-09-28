// snooze ui — the terminal frame (591, owner ruling T2).
//
// The terminal engine (vendored ghostty-web, pinned) runs HERE, in an iframe the page loads with
// `sandbox="allow-scripts"` only: an OPAQUE origin. This document has no cookie, no storage, no
// access to the page, and its CSP lets it connect to nothing (`connect-src 'none'`) — so an engine
// compromise by hostile terminal output cannot reach the API, the CSRF token or the session. The
// page owns the WebSocket; this frame only draws and reports keys, over a narrow message protocol:
//
//   page → frame   {t:'init', wasm: ArrayBuffer, mode}   once: compile the engine (one WASM instance)
//                  {t:'write', data: ArrayBuffer}         terminal bytes to draw
//                  {t:'paste', text}                      a paste the PAGE made safe (and confirmed)
//                  {t:'focus'} · {t:'keep-scrollback'} (after a boot view, before the session's screen)
//   frame → page   {t:'ready'} · {t:'opened', cols, rows} · {t:'data', s} (keys, reports)
//                  {t:'resize', cols, rows} · {t:'title', s} · {t:'paste', text, bracketed}
//                  {t:'paste-too-big', bytes} · {t:'failed'} (the engine did not load)
//
// Every message is checked here (source = the parent, known type, typed fields, capped sizes); anything
// else is dropped and counted. The hardening that was the page's is kept, inside the frame:
//   · links are never activated (Cmd/Ctrl clicks dropped; window.open refused — and this sandbox has no
//     allow-popups anyway): upstream #194;
//   · the engine's own paste handler never runs: a paste goes to the page, which encodes it (Ghostty
//     1.3.0's encode), asks when unsafe or large, refuses over 1 MiB (CVE-2026-26982, upstream #193);
//   · drops are refused; Cmd-chords stay the browser's; focus reports are sent (the engine does not);
//   · one WASM instance per terminal — one frame per terminal (upstream #141).
'use strict';

const MAX_WRITE = 1 << 20;
const MAX_PASTE = 1 << 20;
const THEME = { background: '#16171c', foreground: '#e3e5ea', cursor: '#c9ccd6', selectionBackground: '#3b4a6b' };
const frameStats = { dropped: 0 };
let term = null;
let mode = 'interactive';
let focused = false;

window.open = function refuseToOpen() { return null; };

function toPage(msg) { window.parent.postMessage(msg, '*'); }
function quietly(fn, fallback) { try { return fn(); } catch (_) { return fallback; } }

async function init(wasm, m) {
  mode = m;
  // The page fetched the engine's WebAssembly from its own origin; this frame compiles it
  // ('wasm-unsafe-eval') into its OWN instance — no fetch from here (connect-src 'none').
  const { instance } = await WebAssembly.instantiate(wasm, { env: { log: () => {} } });
  const engine = new GhosttyWeb.Ghostty(instance);
  const host = document.getElementById('term');
  // `scrollback` is BYTES in 0.4.0's WASM (upstream #140), not lines: the default 10 000 kept ~10 KB,
  // too little for a boot log. 4 MiB.
  term = new GhosttyWeb.Terminal({ ghostty: engine, fontSize: 13, fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
                                   theme: THEME, cursorBlink: false, disableStdin: mode === 'watch', scrollback: 4 * 1024 * 1024 });
  term.open(host);
  const fit = new GhosttyWeb.FitAddon();
  term.loadAddon(fit);
  fit.fit();
  fit.observeResize();
  term.onData((s) => { if (mode === 'interactive') toPage({ t: 'data', s }); });
  term.onResize((d) => toPage({ t: 'resize', cols: d.cols, rows: d.rows }));
  term.onTitleChange((s) => toPage({ t: 'title', s: String(s).slice(0, 120) }));
  guard(document.documentElement);
  toPage({ t: 'opened', cols: term.cols, rows: term.rows });
  term.focus();
}

function guard(root) {
  // Links: never activated — the engine opens a link on a Cmd/Ctrl click; drop those clicks first.
  for (const type of ['click', 'auxclick', 'mousedown', 'mouseup']) {
    root.addEventListener(type, (ev) => { if (ev.metaKey || ev.ctrlKey) { ev.preventDefault(); ev.stopPropagation(); } }, true);
  }
  // Paste: to the page (which makes it safe), never the engine's own handler. Drops refused.
  root.addEventListener('paste', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (mode !== 'interactive' || !term) return;
    const text = ev.clipboardData ? ev.clipboardData.getData('text/plain') : '';
    if (!text) return;
    if (text.length > MAX_PASTE) { toPage({ t: 'paste-too-big', bytes: text.length }); return; }
    toPage({ t: 'paste', text, bracketed: quietly(() => term.hasBracketedPaste(), false) });
  }, true);
  root.addEventListener('drop', (ev) => { ev.preventDefault(); ev.stopPropagation(); }, true);
  // Keys: Cmd-C copies a selection; Cmd-V pastes (the paste event above); every other Cmd-chord is
  // the browser's and never reaches the guest.
  root.addEventListener('keydown', (ev) => {
    if (!ev.metaKey) return;
    if (ev.code === 'KeyV') return;
    if (ev.code === 'KeyC' && term && quietly(() => term.hasSelection(), false)) {
      ev.preventDefault();
      navigator.clipboard.writeText(term.getSelection()).catch(() => {});
    }
    ev.stopPropagation();
  }, true);
  // Focus reports (DEC 1004): the engine tracks the mode but does not send them. They are reports:
  // the UI process never wakes a sandbox for one.
  window.addEventListener('focus', () => {
    if (focused) return;
    focused = true;
    if (term && quietly(() => term.hasFocusEvents(), false)) toPage({ t: 'data', s: '\x1b[I' });
  });
  window.addEventListener('blur', () => {
    if (!focused) return;
    focused = false;
    if (term && quietly(() => term.hasFocusEvents(), false)) toPage({ t: 'data', s: '\x1b[O' });
  });
}

// ── the protocol: only the parent, only these messages, each field typed and capped.
function valid(m) {
  if (!m || typeof m !== 'object' || typeof m.t !== 'string') return false;
  switch (m.t) {
    case 'init': return !term && m.wasm instanceof ArrayBuffer && (m.mode === 'interactive' || m.mode === 'watch') && Object.keys(m).length === 3;
    case 'write': return !!term && m.data instanceof ArrayBuffer && m.data.byteLength <= MAX_WRITE && Object.keys(m).length === 2;
    case 'paste': return !!term && typeof m.text === 'string' && m.text.length <= MAX_PASTE && Object.keys(m).length === 2;
    case 'focus': case 'keep-scrollback': return !!term && Object.keys(m).length === 1;
    default: return false;
  }
}
window.addEventListener('message', (ev) => {
  if (ev.source !== window.parent || !valid(ev.data)) { frameStats.dropped++; return; }
  const m = ev.data;
  switch (m.t) {
    case 'init': init(m.wasm, m.mode).catch(() => toPage({ t: 'failed' })); break;
    case 'write': term.write(new Uint8Array(m.data)); break;
    case 'paste': if (mode === 'interactive') term.paste(m.text); break;
    case 'focus': term.focus(); break;
    // After the boot view: the screen (the boot log's end) scrolls into the scrollback before the
    // session's first screen replaces it — the terminal alone knows how tall it is.
    case 'keep-scrollback': term.write('\x1b[999;1H' + '\r\n'.repeat(term.rows)); break;
  }
});

toPage({ t: 'ready' });
