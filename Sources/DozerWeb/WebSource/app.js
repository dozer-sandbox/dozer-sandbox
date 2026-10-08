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

import { expose, provide } from './app/core/hooks.js';
import { $ } from './app/dom/h.js';
import { icon, setButton } from './app/dom/icons.js';
import './app/core/agents.js';
import { api } from './app/core/api.js';
import { connect } from './app/core/events.js';
import './app/core/format.js';
import { scheduleResTotal } from './app/core/measure.js';
import { act } from './app/core/operations.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect.js';
import { refresh, route } from './app/core/router.js';
import './app/core/sandboxes.js';
import { bootstrap, signedOut } from './app/core/session.js';
import { loadSettings, resetSetting, saveSetting } from './app/core/settings.js';
import { state } from './app/core/state.js';
import { pageTerminals, sview, terminals, termUI } from './app/core/terminals.js';
import './app/core/util.js';
import { WIZ } from './app/core/wizards.js';
import './app/components/access-step.js';
import './app/components/accounts.js';
import './app/components/blocks.js';
import { btn } from './app/components/button.js';
import { callout } from './app/components/callout.js';
import './app/components/create-dialog.js';
import './app/components/dialog.js';
import { hostChanged, renderHostFoot } from './app/components/host.js';
import './app/components/image-picker.js';
import './app/components/keyboard.js';
import { lifecycle } from './app/components/lifecycle.js';
import './app/components/menus.js';
import { closeWizardModal, modalInert, openWizardModal } from './app/components/modal.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices.js';
import './app/components/permissions.js';
import { paintTransition } from './app/components/pills.js';
import './app/components/prep-card.js';
import { quickAdd } from './app/components/quick-add.js';
import './app/components/rules-step.js';
import './app/components/stepper.js';
import { closeTerminal, focusTerm, openTerminal, paintCover, reattachTerminals, sendInput } from './app/components/terminal.js';
import './app/components/workspace-chooser.js';
import { viewAccounts } from './app/views/accounts.js';
import { renderActivity, viewActivity } from './app/views/activity.js';
import { viewDevices } from './app/views/devices.js';
import { viewDoctor } from './app/views/doctor.js';
import { viewImages } from './app/views/images.js';
import { viewMetrics } from './app/views/metrics.js';
import { newSandboxWizard, viewNew } from './app/views/new-sandbox.js';
import { renderWizard, viewOnboarding, wizardStopPolling, wizGo } from './app/views/onboarding.js';
import { acknowledgeOps, renderOperations, renderOps, viewOperations } from './app/views/operations.js';
import { viewOverview } from './app/views/overview.js';
import { viewResources } from './app/views/resources.js';
import './app/views/sandbox-dialogs.js';
import { openSavedTerminal, persistLayout } from './app/views/sandbox-layout.js';
import './app/views/sandbox-network.js';
import { newShellTerminal, paintSplitButton, paintTabs, paintTermEmpty, renderTerminals, splitWith } from './app/views/sandbox-terminals.js';
import { refreshSandbox, showSandbox } from './app/views/sandbox.js';
import { gridEnter, gridLeave, gridRefresh, gridSchedule } from './app/views/sessions.js';
import { viewSettings } from './app/views/settings.js';
import './app/views/shortcuts.js';

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
