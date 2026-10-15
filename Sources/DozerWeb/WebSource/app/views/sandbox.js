// views/sandbox — A sandbox's page (593): the control bar, the terminal area, the inspector.
import { $, h } from '../dom/h.js';
import { icon, setButton, withIcon } from '../dom/icons.js';
import { DOCKERFILE_POLICY_NOTE } from '../core/agents.js';
import { api } from '../core/api.js';
import { bytes, full, mib, plural, when } from '../core/format.js';
import { act, actOrThrow, transitionOf } from '../core/operations.js';
import { DESTRUCTIVE, opRunningFor } from '../core/sandboxes.js';
import { saveSetting, setting } from '../core/settings.js';
import { state } from '../core/state.js';
import { isAux, pageTerminals, sview, terminals } from '../core/terminals.js';
import { isRemote } from '../core/session.js';
import { accountDialog, credentialBanner, keyEntry } from '../components/accounts.js';
import { chip, panel, stat, table } from '../components/blocks.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { confirmAction, confirmWithCheck, dialog } from '../components/dialog.js';
import { lifecycle, lifecycleBar, sessionsWhyNot } from '../components/lifecycle.js';
import { menuButton, moreMenu } from '../components/menus.js';
import { sessionMenuItems } from '../components/session-actions.js';
import { GUIDE_TAB, guideHead, guidePanel } from '../components/try-guide.js';
import { failureFor, pageFailure, paintRowOps } from '../components/notices.js';
import { sandboxPill } from '../components/pills.js';
import { agentChip } from '../components/agent-status.js';
import { bootLogDialog, focusTerm, openTerminal, PHASE_WORD } from '../components/terminal.js';
import { ISOLATED_NOTE } from '../components/workspace-chooser.js';
import { duplicateDialog, openInTerminal, policyDialog, runDetachedDialog, takePointDialog, templateDialog } from './sandbox-dialogs.js';
import { openSavedTerminal, promoteSaved, restorePanes, savedRows } from './sandbox-layout.js';
import { networkPanel } from './sandbox-network.js';
import { paintStripActs, paintTabs, paintTermEmpty, renderTerminals, syncBuildLogTab, syncConsoleTab } from './sandbox-terminals.js';
import { tildePath } from '../core/paths.js';

// ── a sandbox's page (593): a control bar, the terminal area, a collapsible details panel ──────
// #sbx is persistent: refreshSandbox() re-renders the bar and the details, never #terminals.
let sbxRefreshing = false, sbxAgain = false;
/// 617: the header's "N denied" — a menu: what was refused (each opens the Network tab), and Review in Network.
function deniedChip(name, denied, suggestions, review) {
  const b = h('button', { type: 'button', class: 'tag warn denied-chip', 'data-denied-chip': name, title: 'What the agent was refused — and how to decide' },
    denied + ' denied');
  const items = suggestions.slice(0, 6).map((s) => ({ label: s.what + ' (' + s.count + ')', icon: 'ban', desc: s.permission ? 'its permission: ' + s.permission : 'a site', onSelect: review }));
  if (items.length) items.push({ sep: true });
  items.push({ label: 'Review in Network', icon: 'shield', desc: 'Allow what it needs, or keep it out', onSelect: review, data: { 'review-network': name } });
  return menuButton(b, items, { label: 'Refused for ' + name, align: 'start' }).el;
}
/// 617 (RP-1): a web port's Open button — the forward on this Mac's loopback (127.0.0.1). From another device
/// (doz serve) 127.0.0.1 is that device's own, so the button says so instead of opening the wrong machine.
function portButton(name, p) {
  const label = 'Open ' + p.title;
  if (isRemote()) {
    return h('span', { class: 'tag outline', 'data-port-open': String(p.port), title: p.title + ' is forwarded to the Mac’s 127.0.0.1:' + p.macPort + ' — open it on the Mac (doz open ' + name + ' ' + p.port + ')' },
      withIcon('link', p.title + ' (on the Mac)'));
  }
  // Nothing listens on it in the sandbox yet: the button is there, disabled, and says how to start it.
  if (p.serving === false) {
    return h('button', { type: 'button', class: 'btn small', disabled: true, 'data-port-open': String(p.port), 'data-port-idle': '', title: notServing(p) },
      withIcon('link', label));
  }
  const tip = p.title + ' — the sandbox’s port ' + p.port + ' at ' + p.url + (p.moved ? ' (' + p.port + ' was taken on this Mac)' : '')
    + (p.auth === 'token' && p.askHint ? ' · it asks for a token: ' + p.askHint : '');
  return h('a', { class: 'btn small', href: p.url, target: '_blank', rel: 'noopener noreferrer', 'data-port-open': String(p.port), title: tip },
    withIcon('link', label));
}
/// What a port nothing serves yet says: start it in a session — the recipe's own command when it has one.
function notServing(p) {
  return 'Not serving yet — start it in a session' + (p.serveHint ? ' (' + p.serveHint + ')' : ' (the program that listens on port ' + p.port + ')');
}
/// 617 (RP-1): the details' list of web ports (every state), with what to do when one is not listening.
function portRows(name, i) {
  return (i.ports || []).map((p) => h('div', { class: 'sub2', 'data-port-row': String(p.port) },
    p.title + ' — port ' + p.port + ' → ' + (p.state === 'listening'
      ? (p.serving === false ? (p.url || '127.0.0.1:' + p.macPort) + ' — ' + notServing(p).replace(/^N/, 'n') : (p.url || '127.0.0.1:' + p.macPort))
      : p.state + (p.why ? ': ' + p.why : ''))
      + (p.origin === 'added' ? ' (added)' : '') + (p.moved && p.state === 'listening' ? ' (moved: ' + p.port + ' was taken)' : '')));
}
/// 617: a try's exit choice. Delete removes it (asked with a box to tick) — and its folder when the folder is empty
/// (the host does it); a folder with the agent's files is kept, and said; Keep hides this for the page. (Sleep and
/// Hibernate are the action bar's — owner.)
function tryBar(name, i) {
  const folder = i.trialFolder ? ' Its folder ' + tildePath(i.trialFolder) + ' is removed with it when empty, and kept when the agent left files there.' : '';
  return callout('info', { compact: true, attrs: { 'data-try-bar': name },
    // 617 (owner): the banner keeps its message, Keep and Delete — Sleep and Hibernate are the action bar's.
    body: 'This is a try: when you are done with it, Delete removes it (Keep hides this note).' + folder,
    actions: [
      // 617 (owner: no typed name for a try — "i hate this"): a box to tick.
      btn('Delete…', () => confirmWithCheck('Delete ' + name + '?', DESTRUCTIVE.rm + (i.trialFolder ? ' Its folder is removed too when it is empty.' : ''),
        'Yes, delete ' + name + ' and everything it has on disk', name, { action: 'rm', sandbox: name }, 'Delete'),
        { small: true, danger: true, icon: 'trash-2' }),
      btn('Keep', () => { sview(name).tryKept = true; const el = document.querySelector('[data-try-bar="' + CSS.escape(name) + '"]'); if (el) el.remove(); }, { small: true, quiet: true, icon: 'check' }),
    ].filter(Boolean) });
}

export async function showSandbox() {
  const name = state.param;
  const want = state.session;                  // the addressed session (renderTerminals re-points the URL)
  const first = !state.sbx || state.sbx.name !== name;
  if (first) {
    // 617 (owner: the real page at once — nothing appears later that moves it): a page whose detail was read just
    // before it was shown (a try's Start) draws its header, action bar and banners in its first frame.
    const pre = state.sbxPrefetch && state.sbxPrefetch.name === name && Date.now() - state.sbxPrefetch.at < 10000 ? state.sbxPrefetch : null;
    state.sbxPrefetch = null;
    state.sbx = pre ? { name, d: pre.d, net: pre.net, accounts: pre.accounts } : { name, d: null };
    if (pre) drawParts(name, pre.d, pre.net, pre.accounts);
    else if (state.pendingTry && state.pendingTry.name === name) drawPendingTry(name);
    else {
      $('sbx-bar').replaceChildren(h('div', { class: 'sbx-title' }, h('h1', null, name)));
      $('sbx-details').replaceChildren();
    }
    $('main').scrollTop = 0;
  }
  renderTerminals();
  // What arriving does needs the sandbox's detail: it runs once, after whichever refresh loads it first
  // (a refresh already in flight — the stream's hello — may be the one; this one then returns early).
  state.arrival = { name, want };
  await refreshSandbox();
  takeArrival(name);
}
function takeArrival(name) {
  const a = state.arrival;
  if (!a || a.name !== name || !state.sbx || state.sbx.name !== name || !state.sbx.d) return;
  state.arrival = null;
  sandboxArrived(a.name, a.want);
}
export async function refreshSandbox() {
  // A re-run queued while the page was a sandbox's may come after it left for another page (593 §9:
  // it asked for sandboxes/null, got a 404 and sent the grid to the overview).
  if (state.view !== 'sandbox' || !state.param) return;
  if (sbxRefreshing) { sbxAgain = true; return; }
  sbxRefreshing = true;
  const name = state.param;
  try {
    const gen = state.trGen;
    const [d, net, accounts] = await Promise.all([api('sandboxes/' + name), api('sandboxes/' + name + '/network'), api('accounts').catch(() => ({ accounts: [] }))]);
    if (state.view !== 'sandbox' || state.param !== name || state.signedOut) return;
    // A transition began or ended while this was read: what it read may be the phase before — read again.
    if (gen !== state.trGen) { sbxAgain = true; return; }
    state.sbx = { name, d, net, accounts };
    if ($('sbx-bar').querySelector('.menu:not([hidden])') || $('sbx-details').querySelector('.menu:not([hidden])')) { state.sbxHeld = true; return; }
    drawParts(name, d, net, accounts);
    paintRowOps();
    paintTermEmpty();
    paintStripActs();
    // 593 §9: saved panes go live once it runs (their sessions listed by the detail), or repaint.
    promoteSaved(name, d.info.phase === 'running' && !d.info.busy && d.sessions ? d.sessions.filter((x) => !x.ended).map((x) => x.name) : null);
    paintTabs();
    takeArrival(name);
    // 617: tab zero (Console) follows the VM's power.
    syncConsoleTab(name, d.info.phase);
    // 617: and the build log's small tab, to its left, follows the image's kept build log.
    syncBuildLogTab(name);
    // An arrival that found it under way restores once it has settled (never over a tab opened since).
    const sv = sview(name);
    if (sv.deferred && !sv.restoring && !d.info.busy && d.info.phase !== 'booting' && !opRunningFor(name)) {
      if (sessionTerminals(name).length) { sv.deferred = false; sv.restored = true; } else restorePanes(name);
    }
  } catch (e) {
    // 617: a try whose create is under way (or failed) has its page before its sandbox exists.
    if (e.status === 404 && state.pendingTry && state.pendingTry.name === name) { drawPendingTry(name); return; }
    if (e.status === 404) { if (state.view === 'sandbox' && state.param === name) location.hash = '#/overview'; return; }
    if (!state.signedOut) failureFor(name, e.message || String(e));
  } finally {
    sbxRefreshing = false;
    if (sbxAgain) { sbxAgain = false; refreshSandbox(); }
  }
}
function drawParts(name, d, net, accounts) {
  // 617.11: a try's first visit opens the details on its Guide, whatever ui.details_open says (until Details is pressed).
  if (d.guide && d.info.trial && sview(name).guideShown === undefined) { sview(name).guideShown = true; if (!sview(name).inspTab) sview(name).inspTab = 'guide'; }
  const parts = sandboxParts(name, d, net, accounts);
  $('sbx-bar').replaceChildren(parts.bar);
  $('sbx-details').replaceChildren(parts.details);
  $('sbx-body').classList.toggle('details-closed', !detailsShown(name));
}
/// 617: a try's page from its plan, before its create returns (`state.pendingTry`): the same header as its detail will
/// draw (so nothing moves when it arrives — the try banner with its folder, the chips, the transition's buttons), the
/// details pane as a try's first visit has it (open on its Guide), and no tab strip (the build panel has the area).
export function drawPendingTry(name) {
  const p = state.pendingTry;
  if (!p || p.name !== name || (state.sbx && state.sbx.name === name && state.sbx.d)) return;
  const failed = !!p.error;
  const i = { name, phase: failed ? 'failed' : 'off', busy: !failed, image: p.image, imageTitle: p.imageTitle, ramHeldMiB: 0, memoryMiB: 2048,
    network: p.network, accountApplies: !!p.account, account: p.account, workspace: p.workspace, trial: true, trialFolder: p.workspace };
  const d = { info: i, sessions: [], restorePoints: [], credentials: [], attachCommand: 'doz attach ' + name, defaultSession: null, guide: null,
    cpus: 2, hasRootDisk: false, memoryMiB: 2048, shares: [], agentPrompt: null };
  if (sview(name).guideShown === undefined) { sview(name).guideShown = true; if (!sview(name).inspTab) sview(name).inspTab = 'guide'; }
  try {
    const parts = sandboxParts(name, d, { proxied: false, note: '' }, [])   // only the bar is used;
    $('sbx-bar').replaceChildren(parts.bar);
  } catch (_) {
    $('sbx-bar').replaceChildren(h('div', { class: 'sbx-title' }, h('h1', null, name)));
  }
  $('sbx-details').replaceChildren();
  $('sbx-body').classList.toggle('details-closed', !detailsShown(name));
}
/// The details panel is open: the setting, or a try's first visit (its Guide).
function detailsShown(name) { return setting('ui.details_open', true) || sview(name).guideShown === true; }
/// The page's terminals that are a session's (617: never tab zero, the console).
function sessionTerminals(name) { return pageTerminals(name).filter((t) => !isAux(t)); }
/// On arriving at a sandbox's page: an addressed session (#/sandbox/NAME/SESSION, from the grid)
/// gets its tab — opened, or selected; otherwise, when the sandbox runs and its own session runs,
/// the page attaches to it (explicit viewing of a live VM, which keeps nothing alive the VM does
/// not). A sandbox that is not running shows the empty area's actions instead.
async function sandboxArrived(name, want) {
  const s = state.sbx;
  if (!s || s.name !== name || !s.d) return;
  const mine = sessionTerminals(name);
  const running = s.d.info.phase === 'running';
  const live = (s.d.sessions || []).filter((x) => !x.ended).map((x) => x.name);
  // 593 §9 (S1): the panes the host kept for this sandbox, the first time this page shows it.
  if (!mine.length) await restorePanes(name);
  if (want) {
    const have = pageTerminals(name).find((t) => t.session === want && t.mode === 'interactive' && !t.ended);
    if (have) { const v = sview(name); v.selected[have.pane] = have.id; v.focusedPane = have.pane; renderTerminals(); if (!have.saved) focusTerm(have); }
    else if (running && live.includes(want)) openTerminal(name, want, 'interactive');
    else if (!running && (await savedRows(name)).some((r) => r.name === want)) openSavedTerminal(name, (await savedRows(name)).find((r) => r.name === want));
    // 617: a sandbox that is off has no sessions — its page's address (kept by a reload) drops the session quietly; a
    // notice there pushed the page down (browser-start-sequence C). A running one without it is still said.
    else if (s.d.info.phase === 'off' || s.d.info.phase === 'failed') history.replaceState(null, '', '#/sandbox/' + name);
    else failureFor(name, 'Session ' + want + ' is not running in ' + name);
    return;
  }
  if (!sessionTerminals(name).length && running && live.includes(s.d.defaultSession) && setting('ui.terminals', true) && !sview(name).restoredAny) {
    openTerminal(name, s.d.defaultSession, 'interactive');
  }
}
/// 603: the inspector's tabs — the selected one is kept per sandbox in this page (owner decision 4).
const INSP_TABS = [['overview', 'Overview', 'Overview', 'info'], ['sessions', 'Sessions', 'Sessions', 'terminal'], ['points', 'Points', 'Restore points', 'history'],
                   ['network', 'Network', 'Network', 'shield'], ['keys', 'Keys', 'Keys & account', 'key-round'], ['config', 'Config', 'Configuration', 'settings']];
function inspShow(name, tab) {
  sview(name).inspTab = tab;
  const root = $('sbx-details');
  for (const b of root.querySelectorAll('.itab')) b.setAttribute('aria-selected', b.dataset.inspTab === tab ? 'true' : 'false');
  for (const p of root.querySelectorAll('.ipanel')) p.hidden = p.dataset.insp !== tab;
  root.scrollTop = 0;
}
function sandboxParts(name, d, net, accounts) {
  const i = d.info;
  const running = i.phase === 'running';
  const whyNot = sessionsWhyNot(name, i);
  const gated = (b) => { if (whyNot) { b.disabled = true; b.title = whyNot; } return b; };
  const fact = (k, v) => [h('dt', null, k), h('dd', null, v)];
  const copy = btn('Copy the command', async (ev) => {
    const b = ev.currentTarget;
    try { await navigator.clipboard.writeText(d.attachCommand); setButton(b, 'Copied', 'check'); } catch (_) { setButton(b, 'Select and copy', 'clipboard'); }
    setTimeout(() => { setButton(b, 'Copy the command', 'copy'); }, 1500);
  }, { small: true, quiet: true, iconOnly: true, icon: 'copy' });
  // 593 §9: paused, asleep or hibernated — the sessions as last saved, each can be shown (its saved
  // screen). A shut-down sandbox has none (owner, 2026-09-30).
  const savedState = (s) => 'screen saved ' + when(s.savedAt) + (s.savedReason ? ' (' + s.savedReason + ')' : '');
  const live = (d.sessions || []).filter((s) => !s.ended && !s.saved);
  const sessions = (d.sessions || []).map((s) => h('tr', { 'data-session': s.name },
    h('td', null, h('div', { class: 'cell-name' }, h('span', { class: 'dot ph-' + (s.saved ? i.phase : s.ended ? 'off' : 'running'), 'aria-hidden': 'true' }),
        h('span', { class: 'nm' }, s.name), s.name === d.defaultSession ? h('span', { class: 'tag' }, 'default') : null,
        agentChip(name, s.name)),                                  // 612: what its agent is doing
      s.status && s.status.message ? h('div', { class: 'sub2 ag-msg', title: s.status.message }, s.status.message) : null,
      h('div', { class: 'sub2' }, s.saved ? savedState(s) : s.ended ? 'ended (exit ' + s.exitCode + ')' : 'running' + (s.cols ? ' · ' + s.cols + '×' + s.rows : '') + ' · ' + plural(s.clients, 'viewer', 'viewers'))),
    h('td', { class: 'mono trunc', title: s.command }, s.command),
    h('td', { class: 'row-acts-cell' }, h('div', { class: 'row-acts' }, s.saved
      ? btn('Show', () => openSavedTerminal(name, s), { small: true, quiet: true, icon: 'eye', title: 'Its last saved screen in a tab (read-only; it goes live when the sandbox runs)' })
      : s.ended ? null : [
        btn('Open', () => openTerminal(name, s.name, 'interactive'), { small: true, quiet: true, title: 'A terminal on this session, here in the browser' }),
        moreMenu('More for ' + s.name, [
          { label: 'Watch', icon: 'eye', desc: 'Read-only: nothing you type reaches it, it never resizes', onSelect: () => openTerminal(name, s.name, 'watch') },
          isRemote() ? null : { label: 'Open in Terminal', icon: 'square-terminal', desc: 'In your terminal app (doz attach)', disabled: !!whyNot, why: whyNot, onSelect: () => openInTerminal(name, s.name) },
          ...(running ? sessionMenuItems(name, s.name, whyNot) : []),
        ].filter(Boolean), { small: true, onClose: sbxMenuClosed }).el]))));
  const pointMenu = (p) => moreMenu('More for ' + p.name, [
    { label: 'Fork…', icon: 'git-fork', desc: 'A new sandbox whose disks are this point’s', onSelect: () => dialog('Fork ' + p.name, 'A new sandbox whose disks are this point’s (it cold-boots on start).',
      [{ name: 'newName', label: 'New sandbox name', required: true }], 'Fork', async (v) => { await actOrThrow({ action: 'point-fork', sandbox: name, point: p.id, newName: v.newName }); }) },
    { label: 'Save as template…', icon: 'layout-template', desc: 'Its root disk becomes a template (never its state disk)', onSelect: () => templateDialog(name, d, p.id) },
    { label: 'Duplicate…', icon: 'copy', desc: 'A new sandbox from this point', onSelect: () => duplicateDialog(name, d, accounts, p.id) },
    { sep: true },
    { label: 'Delete…', icon: 'trash-2', danger: true, desc: 'Only this restore point', onSelect: () => confirmAction('Delete ' + p.name, 'Delete the restore point “' + p.name + '” of ' + name + '.', name,
      { action: 'point-rm', sandbox: name, point: p.id }) },
  ], { small: true, onClose: sbxMenuClosed });
  const points = d.restorePoints.map((p) => h('tr', null,
    h('td', null, h('div', { class: 'nm' }, p.name), h('div', { class: 'sub2 mono trunc', title: p.id }, p.id)),
    h('td', { title: full(p.createdAt) }, when(p.createdAt), h('div', { class: 'sub2' }, p.takenWhile + (p.automatic ? ' (auto)' : '')),
      p.needsFsck ? h('div', { class: 'st-warn sub2' }, 'e2fsck on next boot') : null, p.note ? h('div', { class: 'sub2' }, p.note) : null),
    h('td', { class: 'row-acts-cell' }, h('div', { class: 'row-acts' },
      btn('Revert', () => confirmAction('Revert ' + name, 'Revert to “' + p.name + '”: it shuts down (running programs end); the current disk is kept as a restore point first. Start boots it.', name,
        { action: 'point-revert', sandbox: name, point: p.id }), { small: true, quiet: true, danger: true }),
      pointMenu(p).el))));
  const creds = d.credentials.map((c) => h('tr', null,
    h('td', null, c.binding, h('div', { class: 'sub2 trunc', title: c.hosts.join(', ') }, c.hosts.join(', '))),
    h('td', null, c.set ? 'set' : 'not set', ((t) => h('div', { class: 'sub2 trunc', title: t }, t))([c.source || '—', c.account ? 'account ' + c.account : null].filter(Boolean).join(' · '))),
    h('td', null, c.state || '—', c.expiresAt ? h('div', { class: 'sub2' }, 'expires ' + when(c.expiresAt)) : null, c.policy ? h('div', { class: 'sub2' }, 'policy ' + c.policy) : null),
    h('td', { class: 'row-acts-cell' }, c.set && c.source && !c.source.startsWith('account:')
      ? btn('Remove', () => act({ action: 'key-rm', sandbox: name, binding: c.binding }), { small: true, quiet: true }) : null)));
  const foreign = d.credentials.flatMap((c) => c.foreign).map((f) => h('tr', null,
    h('td', null, f.kind + (f.matches ? ' (= ' + f.matches + ')' : ''), h('div', { class: 'sub2 mono' }, f.prefix + '…')),
    h('td', { class: 'mono trunc', title: f.fingerprint }, f.fingerprint),
    h('td', null, f.header, h('div', { class: 'sub2' }, plural(f.requests, 'request', 'requests') + ' · ' + when(f.lastSeen)))));
  const proxied = net.proxied;
  const busy = i.busy || i.phase === 'booting' || opRunningFor(name) || !!transitionOf(name);
  const detailsOpen = detailsShown(name);
  const noDisk = !d.hasRootDisk;
  const holdWhy = busy ? 'Wait until it settles' : noDisk ? 'It has no disk yet — start it once' : null;
  const showTab = (tab) => () => {
    if (!setting('ui.details_open', true)) { $('sbx-body').classList.remove('details-closed'); saveSetting('ui.details_open', true).then(() => refreshSandbox()).catch(() => {}); }
    inspShow(name, tab);
  };
  // ── the bar: title row (name, phase, labelled chips) · toolbar (lifecycle, Shut down, ⋯ | status, details) ──
  const more = moreMenu('More: duplicate, save as template, boot log, reset, remove', [
    { label: 'Duplicate…', icon: 'copy', desc: 'A new sandbox from this disk', disabled: !!holdWhy, why: holdWhy, onSelect: () => duplicateDialog(name, d, accounts, null) },
    { label: 'Save as template…', icon: 'layout-template', desc: 'Its root disk becomes an image (never its state disk)', disabled: !!holdWhy, why: holdWhy, onSelect: () => templateDialog(name, d, null) },
    { label: 'Boot log', icon: 'history', desc: 'Its last boots: the steps and the kernel console', onSelect: () => bootLogDialog(name) },
    { sep: true },
    { label: 'Reset…', icon: 'rotate-ccw', danger: true, desc: 'Discard the disk — back to the image', disabled: busy, why: 'Wait until it settles', data: { 'lifecycle-item': name }, onSelect: () => lifecycle('reset', name) },
    { label: 'Remove…', icon: 'trash-2', danger: true, desc: 'The sandbox, its disks and restore points', disabled: busy, why: 'Wait until it settles', data: { 'lifecycle-item': name }, onSelect: () => lifecycle('rm', name) },
  ], { data: { sbxMore: name }, onClose: sbxMenuClosed });
  more.button.dataset.lifecycleMore = name;
  const detailsBtn = btn(detailsOpen ? 'Hide details' : 'Details', () => {
    const open = !detailsShown(name);
    sview(name).guideShown = false;                       // the person decides from now on
    $('sbx-body').classList.toggle('details-closed', !open);
    saveSetting('ui.details_open', open).then(() => refreshSandbox()).catch((e) => pageFailure('ui.details_open was not saved: ' + (e.message || e)));
  }, { quiet: true, iconOnly: true, icon: 'panel-right', title: (detailsOpen ? 'Hide' : 'Show') + ' the details: sessions, restore points, network, keys (remembered: ui.details_open)' });
  detailsBtn.setAttribute('aria-pressed', detailsOpen ? 'true' : 'false');
  const suggestions = net.permissions ? net.permissions.suggestions : [];
  const bar = h('div', { class: 'sbx-bar-inner' },
    h('div', { class: 'sbx-title' },
      h('h1', null, name), sandboxPill(i),
      h('span', { class: 'chips sbx-meta' },
        chip('Image', h('span', { 'data-image-title': '' }, i.imageTitle || i.image), { title: i.image + (i.dockerfile ? ' — Dockerfile ' + tildePath(i.dockerfile) : '') }),
        chip('RAM', (i.ramHeldMiB ? mib(i.ramHeldMiB) : '—') + ' of ' + mib(i.memoryMiB)),
        chip('Network', [i.network, icon('panel-right')], { onClick: showTab('network'), title: 'Its network — the Network tab', data: { 'data-network-chip': '' } }),
        // 617 (owner: nothing pushes the terminal down): what the agent was refused is this chip's menu, not a banner.
        i.deniedConnections ? deniedChip(name, i.deniedConnections, suggestions, showTab('network')) : null,
        i.accountApplies ? chip('Account', i.account || '—') : null,
        i.workspace ? null : h('span', { class: 'tag outline badge-isolated', 'data-isolated': '', title: ISOLATED_NOTE }, withIcon('shield', 'isolated')),
        // 617: a try (Quick try, doz try).
        i.trial ? h('span', { class: 'tag outline', 'data-try-tag': '', title: 'A try — Sleep, Delete or Keep it when you are done' }, withIcon('play', 'try')) : null,
        // 617 (RP-1): its web ports, forwarded to this Mac while it runs.
        ...(running ? (i.ports || []).filter((p) => p.state === 'listening' && p.url).map((p) => portButton(name, p)) : []),
        // 599g: the workspace's .dozignore / .dozreadonly (the details say how many patterns and whether in force).
        i.workspaceRules ? h('span', { class: 'tag outline', 'data-workspace-rules': i.workspaceRulesView || '', title: 'Workspace rules: ' + i.workspaceRules + ' — doz ignore show ' + name },
          withIcon('shield', 'rules')) : null)),
    h('div', { class: 'sbx-actions toolbar', role: 'toolbar', 'aria-label': name },
      lifecycleBar(i), more.el,
      h('span', { class: 'spacer' }),
      // The status slot: the operation under way (a quiet line), or how it ended (a callout that stays on failure).
      h('div', { 'data-op-for': name, 'data-banner': '1', role: 'status' }),
      detailsBtn),
    i.credentialProblem ? credentialBanner(name, i, accounts) : null,
    // 617: a try's way out — doz try's "Keep this try? Sleep / Delete / Keep running", here.
    i.trial && !sview(name).tryKept ? tryBar(name, i) : null,
    // 594 W28: its system disk came from an image an older doz made.
    i.olderImage ? callout('warn', { compact: true, cls: 'cred-banner img-banner', icon: 'flame', attrs: { 'data-older-image': name }, body: name + ' was ' + i.olderImage + '.' }) : null,
    // 596 (B8): its Dockerfile changed (or was built again) — offered, never rebuilt by itself.
    i.rebuildAvailable ? callout('warn', { compact: true, cls: 'cred-banner img-banner', icon: 'flame', attrs: { 'data-rebuild-available': name }, body: i.rebuildAvailable + '.',
      actions: [btn('Rebuild the image', () => dialog('Rebuild ' + i.image + '?',
        'Runs container build again (seconds when nothing changed: its cache), then bakes only if the built image changed. ' + DOCKERFILE_POLICY_NOTE + ' This sandbox keeps its disk until you reset it.',
        [], 'Rebuild', async () => { await actOrThrow({ action: 'image-bake', image: i.image }); }, { icon: 'flame' }), { small: true, icon: 'flame' })] }) : null,
    null);
  // ── the inspector: six tabs instead of nine stacked sections ──
  // 617.11: a recipe agent's Guide — first (and chosen) on a try, last elsewhere.
  const tabList = d.guide ? (i.trial ? [GUIDE_TAB, ...INSP_TABS] : [...INSP_TABS, GUIDE_TAB]) : INSP_TABS;
  const tab = tabList.some(([id]) => id === sview(name).inspTab) ? sview(name).inspTab : (d.guide && i.trial ? 'guide' : 'overview');
  const counts = { sessions: live.length ? h('span', { class: 'count' }, String(live.length)) : null,
                   network: i.deniedConnections ? h('span', { class: 'count warn' }, String(i.deniedConnections)) : null };
  const tabs = h('div', { class: 'itabs', role: 'tablist', 'aria-label': 'Details of ' + name },
    tabList.map(([id, label, title, ic]) => h('button', { type: 'button', role: 'tab', class: 'itab', id: 'itab-' + id, 'data-insp-tab': id, 'aria-controls': 'ipanel-' + id,
      'aria-selected': id === tab ? 'true' : 'false', title, on: { click: () => inspShow(name, id) } }, icon(ic), h('span', { class: 'itab-l' }, label), counts[id] || null)));
  const panel_ = (id, ...kids) => h('section', { class: 'ipanel', role: 'tabpanel', id: 'ipanel-' + id, 'data-insp': id, 'aria-labelledby': 'itab-' + id, hidden: id !== tab }, ...kids);
  const head = (title, ...acts) => h('div', { class: 'head' }, h('h2', null, title), acts.length ? h('div', { class: 'actions' }, acts) : null);
  const last = d.restorePoints.length ? d.restorePoints[d.restorePoints.length - 1] : null;
  const details = h('div', { class: 'sbx-details-inner' }, tabs,
    d.guide ? panel_('guide', guideHead(), guidePanel(name, d.guide, (t) => inspShow(name, t))) : null,
    panel_('overview',
      h('div', { class: 'stats' },
        stat('RAM held', mib(i.ramHeldMiB), 'of ' + mib(i.memoryMiB) + (i.memoryReturnedMiB ? ' · balloon returned ' + mib(i.memoryReturnedMiB) : '')),
        stat('Disk', bytes(i.diskBytes), d.snapshotBytes ? 'snapshot ' + bytes(d.snapshotBytes) : (d.hasRootDisk ? 'root disk kept' : 'no root disk yet')),
        stat('CPUs', String(d.cpus))),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Attach from a terminal'), h('div', { class: 'cmd' }, h('code', null, d.attachCommand), copy)),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Workspace'),
        h('div', { class: i.workspace ? null : 'muted' }, i.workspace ? [h('code', null, tildePath(i.workspace)), ' → /workspace (live)'] : 'Isolated — ' + ISOLATED_NOTE),
        i.workspaceRules ? h('p', { class: 'muted', 'data-workspace-rules-line': '' },
          'Workspace rules: ' + i.workspaceRules + '. Which rule decides a path: doz ignore check ' + name + ' PATH. Not a security boundary.')
          // 599g (owner A3): a shared folder with no rule file says so, rather than nothing (isolated: nothing to say).
          : i.workspace ? h('p', { class: 'muted', 'data-workspace-rules-none': '' },
            'Workspace rules: none — the folder is shared as is. A .dozignore or .dozreadonly in it keeps the agent away from some files.') : null),
      i.ports ? h('div', { 'data-ports': name }, h('div', { class: 'insp-lbl' }, 'Web ports'), portRows(name, i),
        h('p', { class: 'muted' }, running ? 'Each listens on this Mac’s 127.0.0.1 only. Add another: doz ports add ' + name + ' PORT.'
          : 'They listen while it runs — on this Mac’s 127.0.0.1 only.')) : null,
      h('div', null, h('div', { class: 'insp-lbl' }, 'Sessions'),
        live.length ? h('div', null, live.map((s) => s.name).join(', '), ' ', h('a', { href: '#/sandbox/' + name, on: { click: (ev) => { ev.preventDefault(); inspShow(name, 'sessions'); } } }, 'All sessions'))
          : h('div', { class: 'muted' }, running ? 'None running.' : 'None running — it is ' + (PHASE_WORD[i.phase] || i.phase) + '.')),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Last restore point'),
        last ? h('div', null, last.name + ' · ' + when(last.createdAt) + ' ', h('a', { href: '#/sandbox/' + name, on: { click: (ev) => { ev.preventDefault(); inspShow(name, 'points'); } } }, 'All points'))
          : h('div', { class: 'muted' }, 'None yet.'))),
    panel_('sessions',
      head('Sessions', gated(btn('Run detached…', () => runDetachedDialog(name), { small: true }))),
      panel(table(['Session', 'Command', ''], sessions),
        running ? 'No sessions.' : i.phase === 'off' || i.phase === 'failed' ? 'No sessions — ' + (i.phase === 'off' ? 'shut down' : 'failed') + '. Start boots it fresh, with new sessions.'
          : 'No saved screens — sessions are listed while it runs, and saved when it pauses, sleeps or hibernates.')),
    panel_('points',
      head('Restore points', btn('Take a restore point…', () => takePointDialog(name, running), { small: true })),
      panel(table(['Point', 'Taken', ''], points), 'No restore points yet.')),
    panel_('network',
      head('Network', proxied ? btn('Edit policy…', () => policyDialog(name, net.policy), { small: true }) : null),
      networkPanel(net)),
    panel_('keys',
      head('Keys & account',
        proxied ? btn('Key policy…', () => dialog('Key policy of ' + name, 'What the proxy does with a credential the guest brings itself. auto: strict when the account is not the Mac login, allow otherwise.',
          [{ name: 'policy', label: 'Policy', type: 'select', options: ['auto', 'allow', 'strict'], value: 'auto' }], 'Set', async (v) => {
            await actOrThrow({ action: 'key-policy', sandbox: name, policy: v.policy });
          }), { small: true }) : null,
        proxied ? btn('Account…', () => accountDialog(name, i, accounts), { small: true }) : null),
      panel(table(['Key', 'Set', 'State', ''], creds), 'No keys — the sandbox uses none.'),
      keyEntry(name, proxied),
      foreign.length ? h('h2', null, 'Credentials the guest brought itself (fingerprints only)') : null,
      foreign.length ? panel(table(['Kind', 'Fingerprint', 'Header'], foreign)) : null),
    panel_('config',
      head('Configuration'),
      h('div', { class: 'panel' }, h('div', { class: 'panel-body' }, h('dl', { class: 'facts' },
        fact('Memory', mib(d.memoryMiB)), fact('Root disk', mib(d.rootfsMiB)), fact('State disk', mib(d.stateDiskMiB)),
        fact('Journal', d.journalMiB ? mib(d.journalMiB) : 'none'), fact('Network', d.networkMode + (d.subnet ? ' · ' + d.subnet : '')),
        fact('Account', i.accountApplies ? (i.account || '—') : 'n/a'),
        fact('Workspace', i.workspace ? tildePath(i.workspace) + ' → /workspace (live)' : 'isolated — ' + ISOLATED_NOTE),
        fact('Shares', d.shares.length ? d.shares.map((s) => s.hostPath + ' → ' + s.guestPath).join(', ') : 'none'),
        d.project ? fact('Project', d.project) : null,
        fact('Directory', d.directory)))),
      h('h2', null, 'Environment prompt'),
      promptPanel(d)),
    h('div', { class: 'insp-resize', role: 'separator', 'aria-orientation': 'vertical', 'aria-label': 'Resize the details', title: 'Drag to resize the details (320–560 px)',
      on: { pointerdown: inspResizeStart } }));
  return { bar, details };
}
/// A menu on the sandbox page closed: a re-render it held back runs now.
function sbxMenuClosed() { if (state.sbxHeld) { state.sbxHeld = false; refreshSandbox(); } }
/// 603: the inspector's width — dragged between 300 and 560 px, kept in this browser (a layout convenience).
function inspWidth(w) {
  const px = Math.max(320, Math.min(560, Math.round(w)));
  $('sbx-body').style.setProperty('--insp-w', px + 'px');
  return px;
}
(() => { try { const w = Number(localStorage.getItem('doz.inspectorWidth')); if (w) inspWidth(w); } catch (_) { /* no storage: the default */ } })();
function inspResizeStart(ev) {
  ev.preventDefault();
  const body = $('sbx-body'), right = body.getBoundingClientRect().right;
  let px = 0;
  const move = (e) => { px = inspWidth(right - e.clientX); };
  const up = () => {
    document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', up);
    document.body.classList.remove('resizing');
    if (px) { try { localStorage.setItem('doz.inspectorWidth', String(px)); } catch (_) { /* */ } }
  };
  document.body.classList.add('resizing');
  document.addEventListener('pointermove', move);
  document.addEventListener('pointerup', up);
}
/// 594 (D15/D16): what the agent is told about where it runs, as its NEXT session gets it.
function promptPanel(d) {
  const p = d.agentPrompt;
  if (!p) return panel(null, 'This image runs no agent — there is no environment prompt.');
  if (!p.enabled) return panel(null, 'Off — agent.prompt is false (Settings): the agent gets no facts block and no dozer skill.');
  const how = p.agent === 'pi' ? 'pi’s --append-system-prompt ' + p.promptPath
    : p.agent === 'codex' ? 'Codex’s developer instructions (its launcher reads ' + p.promptPath + ')'
    : 'Claude Code’s --append-system-prompt (its launcher reads ' + p.promptPath + ')';
  return h('div', { class: 'panel prompt-panel' },
    h('div', { class: 'muted' }, 'Written at every session start, from this sandbox’s current facts — ', how, '. Layers: ', p.layers.join(' + '),
      '. The dozer skill: ', h('code', null, p.skillPath), ' (' + p.skillLines + ' lines).'),
    p.error ? callout('bad', { cls: 'notice', body: 'It does not render, so sessions do not start: ' + p.error })
            : h('pre', { class: 'prompt-text' }, p.text || ''),
    h('div', { class: 'muted' }, 'Your own template: agent-prompt.md beside doz.toml · this sandbox’s own lines: agent_prompt in doz_project.yaml, or doz create --agent-prompt FILE.'));
}
