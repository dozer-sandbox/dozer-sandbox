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
import { icon, setButton } from './app/dom/icons-8392ebb8cb8879e3.js';
import './app/core/agents-30faadc83708a5b4.js';
import { api } from './app/core/api-fde5b3cbd7091e33.js';
import { connect } from './app/core/events-8b65df4bc91b4903.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-d4e0b2fb0ddb548d.js';
import { act } from './app/core/operations-4c1f59c249615405.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-befddd8b1fbf60d1.js';
import { refresh, route } from './app/core/router-bc6475b319716d81.js';
import './app/core/sandboxes-31b203bfcabfe221.js';
import { bootstrap, signedOut } from './app/core/session-822695b1266e88c3.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-265e96add2494862.js';
import { state } from './app/core/state-d393c12b794a3f10.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-fa5cf7fc28fdb48f.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-f3940647fbf5e4d3.js';
import './app/components/access-step-f76718af45393f32.js';
import './app/components/accounts-85f57bda5562a4ef.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-8e61dd531eed2262.js';
import { callout } from './app/components/callout-295f8e0570c7e239.js';
import './app/components/create-dialog-657c61067dad125c.js';
import './app/components/dialog-28078aaa2d068a1e.js';
import { hostChanged, renderHostFoot } from './app/components/host-7680a0af8ea66d01.js';
import './app/components/image-picker-8e307c2cf5be1bdf.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-9307e49bb0c3be84.js';
import './app/components/menus-95968d15addcffdf.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-714313309ad4200d.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-207ac9e8f8879ea1.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-0170b06a2323aa78.js';
import './app/components/permissions-84a4fe4360bac4b5.js';
import { paintTransition } from './app/components/pills-57c55d9eba2fffc2.js';
import './app/components/prep-card-bb27e67e762cea2d.js';
import { quickAdd } from './app/components/quick-add-f76a5e6fb57610fa.js';
import './app/components/rules-step-caa581df445e9800.js';
import './app/components/stepper-19d0f8aab00bfb93.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-8accd4d583784e48.js';
import './app/components/workspace-chooser-cafd4b19f43a7e5b.js';
import { viewAccounts } from './app/views/accounts-9af6aec210cbaeb2.js';
import { renderActivity, viewActivity } from './app/views/activity-b9dcf561f48d9bcc.js';
import { viewDevices } from './app/views/devices-3a27e1a2f17d5ddf.js';
import { viewDoctor } from './app/views/doctor-3bf113c21435da80.js';
import { viewImages } from './app/views/images-db1bd117e3fe4ae3.js';
import { viewMetrics } from './app/views/metrics-1db54b3f7b08d5d3.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-b5ffa65d2f455f40.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-3813c3c6be4fbedd.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-7d02431a319c8cfa.js';
import { viewOverview } from './app/views/overview-2d59972ce7372fad.js';
import { viewResources } from './app/views/resources-6d52b4360256c7cd.js';
import './app/views/sandbox-dialogs-8e11ce3b80400bd9.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-27a05829b5dcf962.js';
import './app/views/sandbox-network-4f32a2ec91b56086.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals-df0077c15a9d376b.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-90fbc756f7e0ba22.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-f8b152459db3030a.js';
import { viewSettings } from './app/views/settings-4a5ffc9f2715e07e.js';
import './app/views/shortcuts-88438893d630801e.js';

// 599c: Quick add in the sidebar, beside Sandboxes.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozer.', 'signed-out');
});

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { devices: 'user-round', overview: 'box', sessions: 'layout-grid', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
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
  renderTerminals, renderWizard, showSandbox, signedOut, startApp, toast, viewAccounts, viewActivity, viewDevices, viewDoctor,
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
