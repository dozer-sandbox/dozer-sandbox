// components/host — The host (594 W18): the sidebar's foot, Start/Restart host, the host's transitions told once.
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { liveRefresh } from '../core/events-07131f7db0573eef.js';
import { plural, when } from '../core/format-b2e68384da8d2f36.js';
import { act, actOrThrow } from '../core/operations-c7eeae66c46d4582.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { card } from './blocks-53c969feeec8fe89.js';
import { btn } from './button-72d87e1085f00b4e.js';
import { dialog } from './dialog-eda31d5dbf8a6de4.js';
import { refreshNav } from './nav-baacb3a712d5064d.js';
import { banner, dropBanner } from './notices-f4d7053b68a08d1e.js';

function sandboxLinks(names) {
  return names.map((n) => h('a', { href: '#/sandbox/' + n, 'data-sandbox-link': n }, n));
}
/// The host's fact in the footer: from the last overview, or — while doz ui is away — what the page last
/// knew, said as such.
export function renderHostFoot() {
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
export function hostChanged(c) {
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

export function hostCard(host) {
  if (host.running) {
    return card('Host', 'running', 'pid ' + host.pid + ' · ' + (host.version || '') + ' · since ' + when(host.startedAt) +
      (host.idleSeconds ? ' · idle ' + Math.round(host.idleSeconds) + ' s' : ''));
  }
  // 594 W18: every action starts a host on demand (as the CLI does); this starts one on its own.
  const c = card('Host', 'not running', host.recoveryPending.length ? 'recovery pending: ' + host.recoveryPending.join(', ') : 'nothing is running — shown from the store');
  c.append(h('div', { class: 'n-act' }, startHostButton()));
  return c;
}
