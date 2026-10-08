// core/session — The session: the link exchanged once, renewal, the service worker, signing in again inside the page (605).
import { upcall } from './hooks-a4b871a481b363cd.js';
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { withIcon } from '../dom/icons-8392ebb8cb8879e3.js';
import { api } from './api-1817573a49f0ab85.js';
import { loadSettings } from './settings-171e705abeccb983.js';
import { state } from './state-6efaa5d4aa08116b.js';
import { terminals } from './terminals-fa5cf7fc28fdb48f.js';
import { quietly } from './util-1195caf40612902f.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const banner = upcall('banner'), connect = upcall('connect'), dropBanner = upcall('dropBanner'), modalInert = upcall('modalInert'),
  paintCover = upcall('paintCover'), startApp = upcall('startApp');

// ── session ─────────────────────────────────────────────────────────────────
export async function bootstrap() {
  const m = /^#cap=([A-Za-z0-9_-]{16,256})$/.exec(location.hash);
  if (m) {
    // The capability leaves the address bar and the history entry before anything else happens.
    history.replaceState(null, '', location.pathname + '#/overview');
    try {
      adopt(await api('session', { method: 'POST', bearer: m[1] }));
      return true;
    } catch (e) {
      signedOut(e.message, e.code);
      return false;
    }
  }
  try {
    adopt(await api('session'));
    // 605 (remember this browser): every page load renews the sign-in (14 days from now).
    try { adopt(await api('session/renew', { method: 'POST' })); } catch (_) { /* the session stands */ }
    return true;
  } catch (e) {
    if (!state.signedOut) signedOut(e.message, e.code);
    return false;
  }
}
export function adopt(info) {
  state.csrf = info.csrf;
  state.expiresAt = new Date(info.expiresAt);
  // 606: doz serve — another computer's browser: the Mac's name in the title and the brand line.
  state.serve = info.serve || null;
  state.chatgptSignIn = info.chatgptSignIn !== false;   // a public build has no ChatGPT sign-in of its own
  const mac = state.serve ? (state.serve.mac || 'the Mac') : null;
  const sp = $('store-path');
  sp.textContent = mac ? 'on ' + mac + ' · ' + info.store : info.store;
  sp.title = info.store;
  $('version').textContent = 'doz ' + info.version;
  document.title = (mac ? 'Dozer on ' + mac : 'Dozer') + ' — ' + info.store.split('/').pop();
  const k = document.querySelector('#live .foot-k');
  if (k) k.textContent = state.serve ? 'doz serve' : 'doz ui';
  $('sign-out').hidden = false;
  // 611: an update — a newer doz (how to upgrade, its notes), or one an automatic update installed that this
  // dashboard is older than (restart to apply). From the last check; the page itself never asks the network.
  const u = info.update;
  if (u) {
    const parts = [u.text + ' — ', h('code', null, u.command)];
    if (u.notes && /^https:\/\//.test(u.notes)) parts.push(' · ', h('a', { href: u.notes, target: '_blank', rel: 'noopener noreferrer' }, 'release notes'));
    banner('update', u.kind === 'installed' ? 'warn' : 'info', parts);
  } else dropBanner('update');
  state.everSignedIn = true;
  scheduleRenew();
  registerWorker();
}
/// 605: the service worker — ONLY the offline page (an installed app opened, or a reload, while doz ui is
/// not running). It never answers /api or the event stream (sw.js). Registered once signed in; a browser
/// that cannot (a private window) simply has no offline page.
function registerWorker() {
  if (state.swAsked || !('serviceWorker' in navigator)) return;
  state.swAsked = true;
  navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' }).catch(() => { /* the page works without it */ });
}

function scheduleRenew() {
  clearTimeout(state.renewTimer);
  const half = Math.max(30000, (state.expiresAt.getTime() - Date.now()) / 2);
  state.renewTimer = setTimeout(async () => {
    try { adopt(await api('session/renew', { method: 'POST' })); } catch (_) { /* signedOut() handles 401 */ }
  }, half);
}
/// 605 (C.4): signed out — the page asks for a new link INSIDE itself, over what it shows: the view, an
/// open wizard's choices and the terminals stay as they are (the terminals reattach after the sign-in).
/// `code` says why (the server's 401 code): a new link was made, the sign-in expired, this browser signed
/// out — or unknown (another port, a lost sign-in, or never signed in here).
export function signedOut(message, code) {
  if (state.signedOut) return;
  state.signedOut = true;
  state.csrf = null;
  clearTimeout(state.renewTimer);
  if (state.es) { state.es.close(); state.es = null; }
  for (const d of document.querySelectorAll('dialog')) d.close();
  setLive('bad', 'signed out');
  $('sign-out').hidden = true;
  // 591: the server closes this session's terminals; 605: the page keeps them and reattaches them later.
  for (const t of terminals.values()) if (!t.closed && t.opened && !t.ended && !t.errorText) { t.reattach = true; paintCover(t); }
  showSignIn(message, code);
}
const SIGN_IN_TITLE = {
  'session-rotated': 'This page was signed out', 'session-expired': 'This browser’s sign-in expired', 'signed-out': 'You signed out',
  'not-admitted': 'Let this browser in', 'device-revoked': 'This browser was removed', 'admission-rejected': 'Let this browser in',
  'admission-used': 'Let this browser in', 'too-many-attempts': 'Let this browser in',
};
/// 606: what only doz serve answers (a page on another computer): it signs in with an access code or an invite link.
const SERVE_CODES = new Set(['not-admitted', 'device-revoked', 'admission-rejected', 'admission-used', 'too-many-attempts']);
/// 606: this page is another computer's (doz serve) — what opens a window on the Mac's own screen is not offered.
export const isRemote = () => !!state.serve;
function showSignIn(message, code) {
  if (SERVE_CODES.has(code) || state.serveSignIn || state.serve) { showServeSignIn(message, code); return; }
  const o = $('ui-overlay');
  const title = SIGN_IN_TITLE[code] || (state.everSignedIn ? 'This page was signed out' : 'Sign in to Dozer');
  const field = h('input', { type: 'password', id: 'signin-link', name: 'link', autocomplete: 'off', spellcheck: 'false',
    placeholder: 'http://127.0.0.1:…/#cap=…', 'aria-describedby': 'signin-help' });
  const err = h('p', { class: 'signin-err', id: 'signin-err', role: 'alert', hidden: true });
  const go = h('button', { type: 'submit', class: 'btn primary', id: 'signin-go' }, withIcon('key-round', 'Sign in'));
  const form = h('form', { class: 'signin-form', id: 'signin-form' },
    h('label', { class: 'signin-label', for: 'signin-link' }, 'Sign in with a new link'),
    h('div', { class: 'signin-row' }, field, go), err);
  form.addEventListener('submit', (ev) => { ev.preventDefault(); signInWith(field, err, go); });
  o.replaceChildren(h('div', { class: 'ui-ov-card signin-card' },
    h('div', { class: 'ui-ov-head' }, h('h2', { id: 'ui-ov-title' }, title)),
    h('div', { id: 'ui-ov-desc' },
      h('p', null, message || 'This page is not signed in.'),
      form,
      h('p', { class: 'muted', id: 'signin-help' }, 'In a terminal on this Mac: ', h('code', null, 'doz ui link'),
        ' opens a fresh one-use link in your browser; ', h('code', null, 'doz ui link --print-url'), ' prints one to paste here. (Not running? ',
        h('code', null, 'doz ui'), '.)'),
      h('p', { class: 'muted' }, 'A link works once, for five minutes. Everything on this page stays as it is while you sign in.'))));
  for (const el of pausedParts()) el.inert = true;
  document.body.classList.add('ui-paused', 'signing-in');
  o.setAttribute('role', 'dialog');
  o.setAttribute('aria-modal', 'true');
  o.setAttribute('aria-labelledby', 'ui-ov-title');
  o.setAttribute('aria-describedby', 'ui-ov-desc');
  o.hidden = false;
  state.uiOverlay = true;
  quietly(() => field.focus());
}
/// 606: doz serve's sign-in — an access code (typed; 8 characters, ABCD-EFGH) or an invite link (pasted, like doz
/// ui's). Each admits ONE browser, within five minutes; this browser then stays in until it is removed.
function showServeSignIn(message, code) {
  state.serveSignIn = true;
  const k = document.querySelector('#live .foot-k');
  if (k) k.textContent = 'doz serve';
  const o = $('ui-overlay');
  const title = SIGN_IN_TITLE[code] || (state.everSignedIn ? 'This browser was signed out' : 'Let this browser in');
  const codeField = h('input', { type: 'text', id: 'signin-code', name: 'code', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'characters',
    inputmode: 'text', maxlength: '12', placeholder: 'ABCD-EFGH', 'aria-describedby': 'signin-help', class: 'mono signin-code' });
  const field = h('input', { type: 'password', id: 'signin-link', name: 'link', autocomplete: 'off', spellcheck: 'false',
    placeholder: location.origin + '/#cap=…', 'aria-describedby': 'signin-help' });
  const err = h('p', { class: 'signin-err', id: 'signin-err', role: 'alert', hidden: true });
  const go = h('button', { type: 'submit', class: 'btn primary', id: 'signin-go' }, withIcon('key-round', 'Sign in'));
  const form = h('form', { class: 'signin-form', id: 'signin-form' },
    h('label', { class: 'signin-label', for: 'signin-code' }, 'Access code'),
    h('div', { class: 'signin-row' }, codeField, go),
    h('label', { class: 'signin-label', for: 'signin-link' }, 'Or paste an invite link'),
    h('div', { class: 'signin-row' }, field), err);
  form.addEventListener('submit', (ev) => { ev.preventDefault(); serveSignInWith(codeField, field, err, go); });
  o.replaceChildren(h('div', { class: 'ui-ov-card signin-card', 'data-serve-signin': code || '' },
    h('div', { class: 'ui-ov-head' }, h('h2', { id: 'ui-ov-title' }, title)),
    h('div', { id: 'ui-ov-desc' },
      h('p', null, message || 'This browser is not let in to Dozer on this Mac yet.'),
      form,
      h('p', { class: 'muted', id: 'signin-help' }, 'An invite comes from a browser that is already in (Devices › ', h('strong', null, 'Add another browser'),
        ') or from the Mac: ', h('code', null, 'doz serve share'), '. Scan its QR code, type its code here, or open its link — each lets ONE browser in, within five minutes.'),
      h('p', { class: 'muted' }, 'This browser then stays in until it is removed (Devices, or doz serve revoke).'))));
  for (const el of pausedParts()) el.inert = true;
  document.body.classList.add('ui-paused', 'signing-in');
  o.setAttribute('role', 'dialog');
  o.setAttribute('aria-modal', 'true');
  o.setAttribute('aria-labelledby', 'ui-ov-title');
  o.setAttribute('aria-describedby', 'ui-ov-desc');
  o.hidden = false;
  state.uiOverlay = true;
  quietly(() => codeField.focus());
}
async function serveSignInWith(codeField, field, err, go) {
  const text = field.value.trim(), typed = codeField.value.trim();
  field.value = '';
  err.hidden = true;
  const fail = (t) => { err.textContent = t; err.hidden = false; quietly(() => (text ? field : codeField).focus()); };
  let body;
  if (text) {
    const m = /#cap=([A-Za-z0-9_-]{16,256})$/.exec(text);
    if (!m) { fail('That is not an invite link — it ends #cap=… (Add another browser, or doz serve share).'); return; }
    // An invite works on any of this Mac's names (the same doz serve): only its port must be this page's.
    try { const u = new URL(text); if (u.port !== location.port && u.origin !== location.origin) { fail('That link is for another dashboard (' + u.origin + '); this page is ' + location.origin + '.'); return; } } catch (_) { /* the regex decides */ }
    body = { method: 'POST', bearer: m[1] };
  } else if (typed) {
    if (!/^[0-9A-Za-z]{4}-?[0-9A-Za-z]{4}$/.test(typed.replace(/\s+/g, ''))) { fail('An access code is 8 letters and digits, like ABCD-EFGH.'); return; }
    body = { method: 'POST', json: { code: typed } };
  } else {
    fail('Type the access code, or paste an invite link.');
    return;
  }
  go.disabled = true;
  try {
    adopt(await api('session', body));
  } catch (e) {
    go.disabled = false;
    fail(e.message || String(e));
    return;
  }
  codeField.value = '';
  state.serveSignIn = false;
  signedIn();
}
/// The pasted link's `#cap=` is sent as a link's is (Authorization: Bearer, once); the field is emptied
/// first — the link never reaches storage, a log or the address bar.
async function signInWith(field, err, go) {
  const text = field.value.trim();
  field.value = '';
  err.hidden = true;
  const m = /#cap=([A-Za-z0-9_-]{16,256})$/.exec(text);
  let other = null;
  try { const u = new URL(text); if (u.origin !== location.origin) other = u.origin; } catch (_) { /* not a URL: the regex decides */ }
  const fail = (t) => { err.textContent = t; err.hidden = false; quietly(() => field.focus()); };
  if (!m) { fail('That is not a sign-in link — it looks like http://127.0.0.1:PORT/#cap=… (doz ui link --print-url).'); return; }
  if (other) { fail('That link is for another doz ui (' + other + '); this page is ' + location.origin + '. Make one for this page: doz ui link --print-url.'); return; }
  go.disabled = true;
  try {
    adopt(await api('session', { method: 'POST', bearer: m[1] }));
  } catch (e) {
    go.disabled = false;
    fail(e.message || String(e));
    return;
  }
  signedIn();
}
/// Signed in again (or for the first time): the page carries on where it was.
function signedIn() {
  state.signedOut = false;
  hideOverlay();
  dropBanner('ui-stopped');
  setLive('', 'connecting…');
  if (!state.started) { startApp(); return; }
  loadSettings();
  connect();                         // `hello` refreshes everything and reattaches the terminals
}
function hideOverlay() {
  state.uiOverlay = false;
  for (const el of pausedParts()) el.inert = false;
  if (state.modal) modalInert(true);
  document.body.classList.remove('ui-paused', 'signing-in');
  $('ui-overlay').hidden = true;
  $('ui-overlay').replaceChildren();
  (state.modal ? $('wm-box') : $('main')).focus();
}

// ── live updates ────────────────────────────────────────────────────────────
export function setLive(kind, text) {
  const el = $('live');
  el.className = 'live' + (kind ? ' ' + kind : '');
  $('live-text').textContent = text;
}
/// Everything but the banner strip: the sidebar and main's other children (an inert ancestor would
/// take the banners with it).
export function pausedParts() {
  return [document.querySelector('.side'), ...[...$('main').children].filter((e) => e.id !== 'banners')];
}
