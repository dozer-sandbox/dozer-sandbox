// core/reconnect — doz ui gone (594 W21, 605): the calm reconnect, the paused page, a newer build, a moved port.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { withIcon } from '../dom/icons-75c107270d336b51.js';
import { clock, plural } from './format-b2e68384da8d2f36.js';
import { adopt, pausedParts, setLive, signedOut } from './session-54591f6f727fe191.js';
import { state } from './state-c0289349b457ba56.js';
import { terminals } from './terminals-fa5cf7fc28fdb48f.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const banner = upcall('banner'), btn = upcall('btn'), connect = upcall('connect'), dropBanner = upcall('dropBanner'),
  modalInert = upcall('modalInert'), renderHostFoot = upcall('renderHostFoot'), toast = upcall('toast');

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
///
/// 605 (C.2): the first 15 s are CALM — a neutral "Reconnecting to Dozer…" (doz ui restarting is routine:
/// an upgrade, `doz ui restart`, the Mac waking) — and `end: restarting` keeps it calm for a minute. The
/// alarming wording comes at once only when doz ui said it STOPPED (`end: shutdown`), else after 15 s.
/// After a minute the overlay adds that doz ui may run on another port, and which one this page expected.
const UI_OVERLAY_AFTER_MS = 1500;
const UI_CALM_MS = 15000, UI_RESTART_CALM_MS = 60000, UI_OTHER_PORT_MS = 60000;
export function uiLost(said, reason) {
  if (state.signedOut || state.uiMoved) return;
  if (state.es) { state.es.close(); state.es = null; }
  state.uiDown = true;
  if (reason === 'restarting') state.uiRestarting = true; else state.uiSaid = state.uiSaid || said;
  renderHostFoot();
  if (!state.uiDownSince) {
    state.uiDownSince = Date.now();
    state.lastConnected = state.uiDownSince;   // connected until this moment
  }
  setLive(uiCalm() ? '' : 'bad', state.uiRestarting ? 'restarting…' : state.uiSaid ? 'stopped — retrying' : 'reconnecting…');
  if (state.uiRetry) return;
  state.uiRetry = setTimeout(uiRetryTick, said ? 400 : 250);
}
/// Still the calm part of being away (see uiLost).
function uiCalm() {
  const away = state.uiDownSince ? Date.now() - state.uiDownSince : 0;
  if (state.uiRestarting) return away < UI_RESTART_CALM_MS;
  return !state.uiSaid && away < UI_CALM_MS;
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
export async function uiRetryTick() {
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
    // doz ui is back, but this page's session did not carry over: say why (605: the 401's code) —
    // never hang on "reconnecting".
    let code = '';
    try { code = (await r.json()).error.code; } catch (_) { /* unknown */ }
    const msg = code === 'session-expired' ? 'doz ui is back, and this browser’s sign-in had expired (14 days unused).'
      : code === 'session-rotated' ? 'doz ui restarted with a new link — this page’s sign-in did not carry over.'
      : 'doz ui restarted, and this page’s sign-in did not carry over (it listens on another port, or its sign-in was lost).';
    const wasPaused = state.uiOverlay;
    uiBack();
    if (wasPaused) banner('ui-stopped', 'bad', [code === 'session-expired' ? 'doz ui is back — this browser’s sign-in expired.' : 'doz ui restarted with a new link — this page is signed out.']);
    signedOut(msg, code || 'session-rotated');
    return;
  }
  // Still away.
  if (Date.now() - state.uiDownSince >= UI_OVERLAY_AFTER_MS) showUiOverlay(); else updateUiOverlay();
  state.uiRetry = setTimeout(uiRetryTick, state.uiOverlay ? 1000 : 400);
}
export function showUiOverlay() {
  if (state.uiOverlay) { updateUiOverlay(); return; }
  state.uiOverlay = true;
  uiStoppedBanner();
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
export function buildUiOverlay() {
  const o = $('ui-overlay');
  if (o.querySelector('#ui-try-now') || state.signedOut) return;
  const tryNow = h('button', { type: 'button', class: 'btn lg primary', id: 'ui-try-now', on: { click: () => { updateUiOverlay('trying…'); uiRetryTick(); } } },
    withIcon('refresh-cw', 'Try now'));
  o.replaceChildren(h('div', { class: 'ui-ov-card' },
    h('div', { class: 'ui-ov-head' }, h('span', { class: 'ui-ov-spin spin lg', 'aria-hidden': 'true' }),
      h('h2', { id: 'ui-ov-title' }, 'Paused — reconnecting to doz ui…')),
    h('div', { id: 'ui-ov-desc' },
      h('p', { id: 'ui-ov-what' }, 'Nothing on this page works until it reconnects. Run ', h('code', null, 'doz ui'),
        ' in a terminal — this page reconnects by itself (same port), still signed in.'),
      h('p', { class: 'muted', id: 'ui-ov-when' }),
      h('p', { class: 'muted', id: 'ui-ov-port', hidden: true }),
      h('p', { class: 'muted', id: 'ui-ov-host' })),
    h('div', { class: 'ui-ov-acts' }, tryNow)));
}
function updateUiOverlay(status) {
  const w = $('ui-ov-when');
  if (!w) return;
  const ago = state.lastConnected ? Math.round((Date.now() - state.lastConnected) / 1000) : null;
  w.textContent = 'Last connected ' + clock(state.lastConnected) + (ago != null ? ' (' + ago + ' s ago)' : '') + '. ' + (status || 'Retrying every second.');
  paintUiOverlayTone();
}
/// 605: the banner and the overlay's words follow the tone — calm while it is routine, then what to do.
function uiStoppedBanner() {
  const calm = uiCalm();
  const key = calm ? 'calm' : 'stopped';
  const have = $('banners').querySelector('[data-banner="ui-stopped"]');
  if (have && have.dataset.tone === key) return;
  const el = calm ? banner('ui-stopped', 'info', [state.uiRestarting ? 'doz ui is restarting — reconnecting…' : 'Reconnecting to Dozer…'])
    : banner('ui-stopped', 'bad', [(state.uiSaid ? 'The doz ui process stopped' : 'This page lost its doz ui server') +
      ' (last connected ' + clock(state.lastConnected) + ').']);
  el.dataset.tone = key;
}
function paintUiOverlayTone() {
  const t = $('ui-ov-title'), what = $('ui-ov-what');
  if (!t || !what || state.signedOut) return;
  const calm = uiCalm();
  uiStoppedBanner();
  $('ui-overlay').dataset.tone = calm ? 'calm' : 'stopped';
  setLive(calm ? '' : 'bad', state.uiRestarting && calm ? 'restarting…' : state.uiSaid ? 'stopped — retrying' : 'reconnecting…');
  if (calm) {
    t.textContent = 'Reconnecting to Dozer…';
    what.replaceChildren(state.uiRestarting ? 'doz ui is restarting — this page resumes by itself, still signed in, and its terminals reattach.'
      : 'This page resumes by itself as soon as doz ui answers again — still signed in, its terminals reattach.');
  } else {
    t.textContent = 'Paused — reconnecting to doz ui…';
    what.replaceChildren('Nothing on this page works until it reconnects. Run ', h('code', null, 'doz ui'),
      ' in a terminal — this page reconnects by itself (same port), still signed in.');
  }
  const port = $('ui-ov-port');
  const away = state.uiDownSince ? Date.now() - state.uiDownSince : 0;
  if (port) {
    port.hidden = away < UI_OTHER_PORT_MS;
    if (!port.hidden && !port.childNodes.length) {
      port.append('If doz ui is running on another port, run ', h('code', null, 'doz ui'), ' — it opens the right page. This page expected ',
        h('code', null, location.host), '.');
    }
  }
}
/// Reconnected: the overlay goes by itself; the page refreshes (on `hello`).
export function uiBack() {
  state.uiDown = false;
  state.uiDownSince = null;
  state.uiSaid = false;
  state.uiRestarting = false;
  clearTimeout(state.uiRetry);
  state.uiRetry = null;
  dropBanner('ui-stopped');
  if (!state.uiOverlay || state.signedOut) return;
  state.uiOverlay = false;
  for (const el of pausedParts()) el.inert = false;
  if (state.modal) modalInert(true);                   // 603: a wizard's modal keeps the page under it inert
  document.body.classList.remove('ui-paused');
  $('ui-overlay').hidden = true;
  delete $('ui-overlay').dataset.tone;
  (state.modal ? $('wm-box') : $('main')).focus();
}
/// 605: `hello` names the build's page files; this document's differ → doz ui was updated underneath it.
export function checkBuild(hello) {
  if (!hello || !hello.script) return;
  const script = document.querySelector('script[src^="/assets/app-"]');
  const style = document.querySelector('link[rel="stylesheet"][href^="/assets/app-"]');
  const mine = (script && script.getAttribute('src')) + '|' + (style && style.getAttribute('href'));
  if (mine === hello.script + '|' + hello.style) return;
  state.updateTo = hello.version || 'a new build';
  banner('ui-updated', 'info', ['Dozer was updated to ' + state.updateTo + ' — reload this page to use it.'],
    [btn('Reload', () => location.reload(), { small: true, primary: true, icon: 'refresh-cw' })]);
  // It reloads by itself once nothing would be lost; until then the banner waits for the click.
  clearInterval(state.reloadTimer);
  state.reloadTimer = setInterval(() => { if (!state.uiDown && !state.signedOut && pageIsIdle()) location.reload(); }, 3000);
}
/// Nothing would be lost by a reload now: no wizard or dialog open, no interactive terminal focused, no
/// field focused, nothing typed in a field.
function pageIsIdle() {
  if (state.modal || document.querySelector('dialog[open]')) return false;
  const a = document.activeElement;
  if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT')) return false;
  if (a && a.tagName === 'IFRAME') {
    const t = [...terminals.values()].find((x) => x.frame === a);
    if (t && t.mode === 'interactive') return false;
  }
  return ![...document.querySelectorAll('input[data-typed], textarea[data-typed]')].some((e) => e.isConnected && e.value !== '');
}
// A field the person typed in (a value set by the page itself is not "typed").
document.addEventListener('input', (ev) => { const t = ev.target; if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) t.dataset.typed = ''; }, true);
/// 605: `doz ui restart` moved doz ui to another port (ui.port). A page cannot follow by itself — a
/// script's navigation to another port is "same-site", which the server's Fetch-Metadata rule refuses —
/// so the new doz ui opened the dashboard there, and this page says where it went (and stops retrying).
export function movedAway(to) {
  if (!/^https?:\/\/(127\.0\.0\.1|\[::1\]):\d{2,5}$/.test(to || '')) { uiLost(true); return; }
  state.uiMoved = true;
  if (state.es) { state.es.close(); state.es = null; }
  clearTimeout(state.uiRetry);
  state.uiRetry = null;
  setLive('', 'moved');
  const addr = to.replace(/^https?:\/\//, '');
  const b = banner('ui-stopped', 'info', ['doz ui moved to ' + addr + '.']);
  b.dataset.tone = 'calm';
  const o = $('ui-overlay');
  const copy = h('button', { type: 'button', class: 'btn', id: 'ui-copy-addr' }, withIcon('copy', 'Copy the address'));
  copy.addEventListener('click', () => {
    // 606: an http page (doz serve on the LAN) is not a secure context — it has no clipboard API.
    if (!navigator.clipboard) { toast('Copy it by hand: ' + to, true); return; }
    navigator.clipboard.writeText(to).then(() => toast('Copied ' + to, false), () => toast('Copy it by hand: ' + to, true));
  });
  o.replaceChildren(h('div', { class: 'ui-ov-card' },
    h('div', { class: 'ui-ov-head' }, h('h2', { id: 'ui-ov-title' }, 'Dozer moved to ' + addr)),
    h('div', { id: 'ui-ov-desc' },
      h('p', null, 'doz ui now listens on another port (the setting ui.port), and opened the dashboard there in a new tab — this one can be closed.'),
      h('p', { class: 'muted' }, 'An installed Dozer app belongs to its port: install it again from the new page. In a terminal, ', h('code', null, 'doz ui link'),
        ' opens a page on the new port.')),
    h('div', { class: 'ui-ov-acts' }, copy)));
  for (const el of pausedParts()) el.inert = true;
  document.body.classList.add('ui-paused');
  o.dataset.tone = 'calm';
  o.setAttribute('role', 'dialog');
  o.setAttribute('aria-modal', 'true');
  o.setAttribute('aria-labelledby', 'ui-ov-title');
  o.setAttribute('aria-describedby', 'ui-ov-desc');
  o.hidden = false;
  state.uiOverlay = true;
  copy.focus();
}
