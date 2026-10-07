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
//   · 605: the page outlives its server. doz ui restarting is a calm pause (terminals reattach, operations
//     resolve, a newer build offers a reload); a sign-in again happens INSIDE the page, over what it shows.

import { expose, provide } from './app/core/hooks-a4b871a481b363cd.js';
import { $ } from './app/dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from './app/dom/icons-c0c96726ac1ee67b.js';
import './app/core/agents-30faadc83708a5b4.js';
import { api } from './app/core/api-fdcae3512c62073e.js';
import { connect } from './app/core/events-9d73a74bb31d8ac9.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-e0a8c6c6f385cfae.js';
import { act } from './app/core/operations-42c200ff280c0cd3.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-0bb085ccd361cc04.js';
import { refresh, route } from './app/core/router-58067a817bdb8a5e.js';
import './app/core/sandboxes-3e934908ffd1ebe4.js';
import { bootstrap, signedOut } from './app/core/session-a3fb68fd0a96bf5e.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-984a49e33f0f7f1a.js';
import { state } from './app/core/state-0bc303c3470c675e.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-fa5cf7fc28fdb48f.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-f3940647fbf5e4d3.js';
import './app/components/access-step-c4dcb0e02dd1e4fe.js';
import './app/components/accounts-52ab3ec478c2152e.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-9ac88c4084153417.js';
import { callout } from './app/components/callout-0caec0630ecb401a.js';
import './app/components/create-dialog-735d3daa5b1103ce.js';
import './app/components/dialog-ccc23a96cd6cb858.js';
import { hostChanged, renderHostFoot } from './app/components/host-0b47709689fd9be6.js';
import './app/components/image-picker-10ebca58a7bb6227.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-8c16c9ea2c9da097.js';
import './app/components/menus-3ac34030bcd506c4.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-94892131c80c7a95.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-c9dbfdb9c2d516ce.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-7f50dafbb39e4bd3.js';
import './app/components/permissions-b50d88943f431baf.js';
import { paintTransition } from './app/components/pills-aa88664fd58f9cc0.js';
import './app/components/prep-card-da946bfedee86e2e.js';
import { quickAdd } from './app/components/quick-add-4b9df46f423363c9.js';
import './app/components/rules-step-9919171a64ebbca5.js';
import './app/components/stepper-b9d24fa5354820b5.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-cce3fa4f70f7dfe2.js';
import './app/components/workspace-chooser-cde952d08b56748a.js';
import { viewAccounts } from './app/views/accounts-291c85db707c2cf6.js';
import { renderActivity, viewActivity } from './app/views/activity-6c23feb47fa05246.js';
import { viewDoctor } from './app/views/doctor-f147e536dd07f3dc.js';
import { viewImages } from './app/views/images-cdf5b5e68f70f798.js';
import { viewMetrics } from './app/views/metrics-329ebe649e48f738.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-343ed2ed0588c2bd.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-b0deaa7ffd0ac7cb.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-cd7282da80c0d04d.js';
import { viewOverview } from './app/views/overview-f5756d03f4fb7915.js';
import { viewResources } from './app/views/resources-5cc31e3369a66770.js';
import './app/views/sandbox-dialogs-51506c394026fc9d.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-3f8fab9d3eba4e1f.js';
import './app/views/sandbox-network-7240fe7bef670f27.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals-f86e6585f3df3424.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-a1b17c549ef50b2e.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-d5bd64306d2cda72.js';
import { viewSettings } from './app/views/settings-9a66a03d4bf80933.js';
import './app/views/shortcuts-edd9593f0867d9cf.js';

// 599c: Quick add in the sidebar, beside Sandboxes.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozer.', 'signed-out');
});

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { overview: 'box', sessions: 'layout-grid', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', onboarding: 'rocket', doctor: 'stethoscope', settings: 'settings' };
for (const a of document.querySelectorAll('#nav > a[data-view]')) {
  if (NAV_ICONS[a.dataset.view]) a.prepend(icon(NAV_ICONS[a.dataset.view]));
  a.title = a.querySelector('.lbl').textContent;       // the rail's tooltip (the label stays readable to assistive tech)
}
setButton($('sign-out'), 'Sign out');
$('nav-toggle').replaceChildren(icon('panel-right'));
$('nav-toggle').addEventListener('click', (ev) => { ev.stopPropagation(); navRail(!document.body.classList.contains('nav-open')); });
document.addEventListener('click', (ev) => { if (document.body.classList.contains('nav-open') && !ev.target.closest('.side')) navRail(false); });
document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && document.body.classList.contains('nav-open')) navRail(false); });

/// The page's start, once signed in (at load, or — 605 — after its first sign-in inside the page).
async function startApp() {
  if (state.started) return;
  state.started = true;
  {
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
}

// The calls that go UP the layers (core/hooks.js): every upcall('name') a lower module makes is provided here, once,
// before anything runs.
provide({
  acknowledgeOps, banner, btn, callout, closeWizardModal, connect, dropBanner, failureFor, gridEnter, gridLeave,
  gridRefresh, hostChanged, lifecycle, modalInert, opFailed, openSavedTerminal, openWizardModal, pageFailure,
  paintCover, paintNav, paintResTotal, paintRowOps, paintSplitButton, paintTabs, paintTermEmpty, paintTransition,
  persistLayout, reattachTerminals, refresh, refreshNav, refreshSandbox, renderActivity, renderHostFoot, renderOps,
  renderTerminals, renderWizard, showSandbox, signedOut, startApp, toast, viewAccounts, viewActivity, viewDoctor,
  viewImages, viewMetrics, viewNew, viewOnboarding, viewOperations, viewOverview, viewResources, viewSettings,
  wizardStopPolling,
});
// The browser probes' names. The one script's top-level names were globals, and the workspace's browser probes
// (probes/*, over CDP Runtime.evaluate) read and call some of them; module names are not globals, so these stay
// reachable by name as before (only this page's own scripts run here: script-src 'self'). One a lower layer calls
// up is reached through its hook — a probe that wraps it wraps what the page calls. The page itself never uses them.
expose({
  act, api, closeTerminal, focusTerm, gridRefresh, gridSchedule, newSandboxWizard, newShellTerminal, openTerminal,
  pageTerminals, paintTabs, refresh, renderTerminals, resetSetting, saveSetting, sendInput, showUiOverlay, splitWith,
  state, sview, terminals, termUI, uiLost, uiRetryTick, WIZ, wizGo,
});

(async () => { if (await bootstrap()) startApp(); })();
