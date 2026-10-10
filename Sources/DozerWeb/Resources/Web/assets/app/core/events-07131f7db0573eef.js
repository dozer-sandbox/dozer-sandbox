// core/events — Live updates: the server's event stream (SSE).
import { upcall } from './hooks-a4b871a481b363cd.js';
import { api } from './api-0a712b05e0caf823.js';
import { adoptOperations, loadPreparations, trackOp } from './operations-c7eeae66c46d4582.js';
import { buildUiOverlay, checkBuild, movedAway, uiBack, uiLost } from './reconnect-6fcdc87b3144a63a.js';
import { refresh } from './router-317300748e6e69ca.js';
import { setLive, signedOut } from './session-54591f6f727fe191.js';
import { state } from './state-c0289349b457ba56.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const hostChanged = upcall('hostChanged'), reattachTerminals = upcall('reattachTerminals'),
  refreshNav = upcall('refreshNav'), renderActivity = upcall('renderActivity'), renderOps = upcall('renderOps'),
  renderWizard = upcall('renderWizard'), toast = upcall('toast');

/// What a live change re-renders: not Settings (a half-typed value), Operations (its own events) or the
/// onboarding wizard (its own), nor a page whose masked key field is being filled in.
export function liveRefresh() {
  const typing = [...document.querySelectorAll('[data-secret]')].some((e) => e.value);
  if (state.view !== 'settings' && state.view !== 'operations' && state.view !== 'onboarding' && !typing) refresh(false);
}

export function connect() {
  if (state.signedOut) return;
  const es = new EventSource('/api/v1/stream');
  state.es = es;
  es.addEventListener('hello', async (ev) => {
    let hello = {};
    try { hello = JSON.parse(ev.data); } catch (_) { /* an older doz ui: no build named */ }
    setLive('on', 'live');
    uiBack();
    buildUiOverlay();
    checkBuild(hello);
    try { adoptOperations(await api('operations')); } catch (_) { /* */ }
    loadPreparations();
    refreshNav();
    refresh(true);
    reattachTerminals();
  });
  // The Settings page is not about the store's live state: re-rendering it would drop a half-typed
  // value; nor is Operations (its own events keep it current), nor the onboarding wizard (its own).
  es.addEventListener('changed', () => {
    refreshNav();
    liveRefresh();
  });
  // 594 W19: a line from doz ui itself ("doz ui restarted — 0.12.0-rc.4").
  // 606: a browser was let in, removed or renamed — the Devices page re-reads.
  es.addEventListener('devices', () => { if (state.view === 'devices') refresh(false); });
  es.addEventListener('notice', (ev) => { try { toast(JSON.parse(ev.data).text, false, 'info'); } catch (_) { /* */ } });
  es.addEventListener('host', (ev) => { try { hostChanged(JSON.parse(ev.data)); } catch (_) { /* ignore a malformed line */ } });
  // 594: the host's image preparations, while any runs (and once when the last ends).
  es.addEventListener('preparations', (ev) => {
    try { state.preps = JSON.parse(ev.data); } catch (_) { return; }
    renderOps();
    if (state.modal === 'onboarding') renderWizard();
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
    if (reason === 'session-ended') { signedOut('This browser’s session ended.', 'signed-out'); return; }
    // 606: doz serve — this browser was removed from the devices (Devices, or doz serve revoke).
    if (reason === 'revoked') { signedOut('This browser was removed from Dozer’s devices — to come back, open a new invite link or type a new code.', 'device-revoked'); return; }
    if (reason === 'shutdown') { uiLost(true); return; }
    // 605: `doz ui restart` — calm; the same port and session.
    if (reason === 'restarting') { uiLost(false, 'restarting'); return; }
    // 605: `doz ui restart` moved the UI to another port: say where (it opened a page there itself).
    if (reason === 'moved') { let to = ''; try { to = JSON.parse(ev.data).origin; } catch (_) { /* */ } movedAway(to); return; }
    // 594 W19: `doz ui --new-link` / `doz ui link --rotate` ended every session.
    if (reason === 'rotated') { signedOut('A new link was made for this UI (doz ui --new-link, or doz ui link --rotate): every page signed out. Open the new link — or run doz ui link.', 'session-rotated'); return; }
    setTimeout(connect, 500);
  });
  // A broken stream (doz ui killed, the Mac asleep): the page's own retry, never the browser's
  // (which would hammer a new doz ui with a session it does not know).
  es.onerror = () => {
    if (state.signedOut || state.uiMoved || state.es !== es) return;
    uiLost(false);
  };
}
