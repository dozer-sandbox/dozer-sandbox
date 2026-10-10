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
import { icon, setButton } from './app/dom/icons-75c107270d336b51.js';
import './app/core/agents-66154a04b9c4696c.js';
import { api } from './app/core/api-129e35835156aceb.js';
import { connect } from './app/core/events-f88a72ac6bf29e2e.js';
import './app/core/format-b2e68384da8d2f36.js';
import { scheduleResTotal } from './app/core/measure-93b2fe0a1b136d9b.js';
import { act } from './app/core/operations-24912c84c13d7e09.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect-997d191bf14a2908.js';
import { refresh, route } from './app/core/router-007bb37dea7abb80.js';
import './app/core/sandboxes-5eed88567d9ef0c0.js';
import { bootstrap, signedOut } from './app/core/session-dadf7d9e3e1cb59e.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings-4557874815573b31.js';
import { state } from './app/core/state-c0289349b457ba56.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals-fa5cf7fc28fdb48f.js';
import './app/core/util-1195caf40612902f.js';
import { WIZ } from './app/core/wizards-e3999d6ea48c0026.js';
import './app/components/access-step-17bcd211ef1212a8.js';
import './app/components/accounts-0163894cf98f27a3.js';
import './app/components/blocks-53c969feeec8fe89.js';
import { btn } from './app/components/button-72d87e1085f00b4e.js';
import { callout } from './app/components/callout-48fdacc012091bbe.js';
import './app/components/create-dialog-1c003a22796e06f9.js';
import './app/components/dialog-627b79752657f161.js';
import { hostChanged, renderHostFoot } from './app/components/host-267429b496c07f84.js';
import './app/components/image-picker-d15ab7a3129ec3c3.js';
import './app/components/keyboard-fef22a2ed99de61c.js';
import { lifecycle } from './app/components/lifecycle-b29647b90c8cfeab.js';
import './app/components/menus-08caea0a1297bf90.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal-dc7becbd881e4fe2.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav-d7f524cafd4ab419.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices-4ade591a3c0f51da.js';
import './app/components/permissions-e9607edc7162cb98.js';
import { paintTransition } from './app/components/pills-5d9961b7c3bb32b1.js';
import './app/components/prep-card-7b7f710f7b5f41a8.js';
import { quickAdd } from './app/components/quick-add-23449ee632d9e044.js';
import './app/components/rules-step-124b3dfb793c8146.js';
import './app/components/stepper-eb70a810bda2f73e.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal-dbe11db76e4ec0d5.js';
import './app/components/workspace-chooser-230a56e0dc237932.js';
import { viewAccounts } from './app/views/accounts-83c7a39b32b3b942.js';
import { renderActivity, viewActivity } from './app/views/activity-fda3e62b91554654.js';
import { viewDevices } from './app/views/devices-fbc115757bf79eef.js';
import { viewDoctor } from './app/views/doctor-d447486719c28d26.js';
import { viewImages } from './app/views/images-e9c3a786ae97c5b1.js';
import { viewMetrics } from './app/views/metrics-6382a13596ea7ec6.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox-8cae5074d30a57ff.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding-50efd6892a964dc9.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations-4599794813474853.js';
import { viewOverview } from './app/views/overview-1dc9f5cede3efcaa.js';
import { viewResources } from './app/views/resources-a0b05281d182b3ce.js';
import './app/views/sandbox-dialogs-536d7e4924011232.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout-29823c5de0f2b7e3.js';
import './app/views/sandbox-network-26613ec5a80b8ff4.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals-eaedace087d551c0.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox-8eda324f1152b798.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions-1ae70a38801050fd.js';
import { viewSettings } from './app/views/settings-72f2dd4bad517af3.js';
import './app/views/shortcuts-b8239cf593b1c7e9.js';

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
