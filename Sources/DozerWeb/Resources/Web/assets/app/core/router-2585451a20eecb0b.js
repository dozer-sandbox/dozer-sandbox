// core/router — Routing: #/VIEW, #/sandbox/NAME[/SESSION]; the wizards are modals over the page; refresh() renders the view.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { $ } from '../dom/h-d909ae8eb40113fe.js';
import { remeasure } from './measure-d1b8f65758e1ac8f.js';
import { loadPreparations } from './operations-d824956fc29841f7.js';
import { state } from './state-6efaa5d4aa08116b.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const acknowledgeOps = upcall('acknowledgeOps'), callout = upcall('callout'),
  closeWizardModal = upcall('closeWizardModal'), gridEnter = upcall('gridEnter'), gridLeave = upcall('gridLeave'),
  gridRefresh = upcall('gridRefresh'), openWizardModal = upcall('openWizardModal'), paintNav = upcall('paintNav'),
  paintRowOps = upcall('paintRowOps'), refreshSandbox = upcall('refreshSandbox'),
  showSandbox = upcall('showSandbox'), viewAccounts = upcall('viewAccounts'), viewActivity = upcall('viewActivity'),
  viewDoctor = upcall('viewDoctor'), viewImages = upcall('viewImages'), viewMetrics = upcall('viewMetrics'),
  viewOperations = upcall('viewOperations'), viewOverview = upcall('viewOverview'),
  viewResources = upcall('viewResources'), viewSettings = upcall('viewSettings'), viewDevices = upcall('viewDevices'),
  wizardStopPolling = upcall('wizardStopPolling');

// ── routing ─────────────────────────────────────────────────────────────────
// #/VIEW, #/sandbox/NAME and #/sandbox/NAME/SESSION (a session addressed: its tab opened or selected).
// 603 (owner, on rc.1): #/new and #/onboarding are MODALS over the page under them — that page (state.view, its
// hash state.bgHash) is never re-rendered or torn down by opening or closing one (the sandbox page's terminals
// stay as they are). A deep link opens the modal over Sandboxes.
export const MODAL_VIEWS = new Set(['new', 'onboarding']);
export function route() {
  const m = /^#\/([a-z]+)(?:\/([a-z0-9-]{1,40})(?:\/([A-Za-z0-9_-][A-Za-z0-9._-]{0,63}))?)?$/.exec(location.hash);
  if (m && m[1] === 'terminals') { location.replace('#/sessions'); return; }      // 591's name for the grid's place
  const v = m ? m[1] : 'overview';
  if (MODAL_VIEWS.has(v) && !m[2]) {
    const first = !state.bgHash;
    if (first) { state.view = 'overview'; state.param = null; state.session = null; state.bgHash = '#/overview'; routePage(); }
    openWizardModal(v, !first);
    return;
  }
  if (state.modal) {
    closeWizardModal();
    if (location.hash === state.bgHash) return;                   // back to the page under it, as it was
  }
  state.view = v;
  state.param = m && m[2] ? m[2] : null;
  state.session = m && m[3] ? m[3] : null;
  if (state.view === 'sandbox' && !state.param) state.view = 'overview';
  state.bgHash = location.hash;
  routePage();
}
function routePage() {
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
  if (state.modal !== 'onboarding') wizardStopPolling();
  if (state.view === 'images' || state.view === 'resources') remeasure();   // 595: measured on arrival, Refresh, an op's end
  if (onSbx) { showSandbox(); return; }
  if (onGrid) { gridEnter(); return; }
  refresh(true);
}
window.addEventListener('hashchange', () => {
  // 605: a link opened in this tab while it waits to sign in signs it in, in place.
  if (state.signedOut && /^#cap=[A-Za-z0-9_-]{16,256}$/.test(location.hash)) {
    const link = location.href;
    history.replaceState(null, '', location.pathname + (state.bgHash || '#/overview'));
    const field = $('signin-link');
    if (field) { field.value = link; $('signin-form').requestSubmit(); }
    return;
  }
  if (!state.signedOut) route();
});

let refreshing = false, again = false;
export async function refresh(scrollTop) {
  if (state.signedOut) return;
  if (state.view === 'sandbox') { refreshSandbox(); return; }
  if (state.view === 'sessions') { gridRefresh(false); return; }
  if (refreshing) { again = true; return; }
  refreshing = true;
  try {
    const views = { overview: viewOverview, images: viewImages, resources: viewResources, operations: viewOperations, accounts: viewAccounts,
                    metrics: viewMetrics, activity: viewActivity, doctor: viewDoctor, settings: viewSettings, devices: viewDevices };
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
      $('view').replaceChildren(callout('bad', { cls: 'notice', title: 'This page could not be read', body: e.message || String(e) }));
    }
  } finally {
    refreshing = false;
    if (again) { again = false; refresh(false); }
  }
}
