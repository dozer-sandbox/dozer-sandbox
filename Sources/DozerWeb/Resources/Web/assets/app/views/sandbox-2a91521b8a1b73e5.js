// views/sandbox — A sandbox's page (593): the control bar, the terminal area, the inspector.
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, setButton, withIcon } from '../dom/icons-8392ebb8cb8879e3.js';
import { DOCKERFILE_POLICY_NOTE } from '../core/agents-66154a04b9c4696c.js';
import { api } from '../core/api-1817573a49f0ab85.js';
import { bytes, full, mib, plural, when } from '../core/format-b2e68384da8d2f36.js';
import { act, actOrThrow, transitionOf } from '../core/operations-d824956fc29841f7.js';
import { opRunningFor } from '../core/sandboxes-d24059f81c7268c1.js';
import { saveSetting, setting } from '../core/settings-171e705abeccb983.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { pageTerminals, sview, terminals } from '../core/terminals-fa5cf7fc28fdb48f.js';
import { isRemote } from '../core/session-545fa19d53ba02cc.js';
import { accountDialog, credentialBanner, keyEntry } from '../components/accounts-82ffc2d668ed27ac.js';
import { chip, panel, stat, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-8e61dd531eed2262.js';
import { callout } from '../components/callout-295f8e0570c7e239.js';
import { confirmAction, dialog } from '../components/dialog-d48442e03113646f.js';
import { lifecycle, lifecycleBar, sessionsWhyNot } from '../components/lifecycle-79b5f1ef7313bbc0.js';
import { moreMenu } from '../components/menus-95968d15addcffdf.js';
import { sessionMenuItems } from '../components/session-actions-0e89b24ac6ecd876.js';
import { failureFor, pageFailure, paintRowOps } from '../components/notices-688e5d5eba5dbe51.js';
import { sandboxPill } from '../components/pills-1563abe498b6c549.js';
import { agentChip } from '../components/agent-status-ebfb70d5a2a35264.js';
import { bootLogDialog, focusTerm, openTerminal, PHASE_WORD } from '../components/terminal-c13dcc4c5b747b61.js';
import { ISOLATED_NOTE } from '../components/workspace-chooser-f6907863038dbeff.js';
import { duplicateDialog, openInTerminal, policyDialog, runDetachedDialog, takePointDialog, templateDialog } from './sandbox-dialogs-4d4765888ed00db0.js';
import { openSavedTerminal, promoteSaved, restorePanes, savedRows } from './sandbox-layout-8c53a13d0eee186f.js';
import { networkPanel } from './sandbox-network-9d881ca6cfefcecc.js';
import { paintStripActs, paintTabs, paintTermEmpty, renderTerminals } from './sandbox-terminals-ae094eb21ef14182.js';

// ── a sandbox's page (593): a control bar, the terminal area, a collapsible details panel ──────
// #sbx is persistent: refreshSandbox() re-renders the bar and the details, never #terminals.
let sbxRefreshing = false, sbxAgain = false;
export async function showSandbox() {
  const name = state.param;
  const want = state.session;                  // the addressed session (renderTerminals re-points the URL)
  const first = !state.sbx || state.sbx.name !== name;
  if (first) {
    state.sbx = { name, d: null };
    $('sbx-bar').replaceChildren(h('div', { class: 'sbx-title' }, h('h1', null, name)));
    $('sbx-details').replaceChildren();
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
    const parts = sandboxParts(name, d, net, accounts);
    $('sbx-bar').replaceChildren(parts.bar);
    $('sbx-details').replaceChildren(parts.details);
    $('sbx-body').classList.toggle('details-closed', !setting('ui.details_open', true));
    paintRowOps();
    paintTermEmpty();
    paintStripActs();
    // 593 §9: saved panes go live once it runs (their sessions listed by the detail), or repaint.
    promoteSaved(name, d.info.phase === 'running' && !d.info.busy && d.sessions ? d.sessions.filter((x) => !x.ended).map((x) => x.name) : null);
    paintTabs();
    takeArrival(name);
    // An arrival that found it under way restores once it has settled (never over a tab opened since).
    const sv = sview(name);
    if (sv.deferred && !sv.restoring && !d.info.busy && d.info.phase !== 'booting' && !opRunningFor(name)) {
      if (pageTerminals(name).length) { sv.deferred = false; sv.restored = true; } else restorePanes(name);
    }
  } catch (e) {
    if (e.status === 404) { if (state.view === 'sandbox' && state.param === name) location.hash = '#/overview'; return; }
    if (!state.signedOut) failureFor(name, e.message || String(e));
  } finally {
    sbxRefreshing = false;
    if (sbxAgain) { sbxAgain = false; refreshSandbox(); }
  }
}
/// On arriving at a sandbox's page: an addressed session (#/sandbox/NAME/SESSION, from the grid)
/// gets its tab — opened, or selected; otherwise, when the sandbox runs and its own session runs,
/// the page attaches to it (explicit viewing of a live VM, which keeps nothing alive the VM does
/// not). A sandbox that is not running shows the empty area's actions instead.
async function sandboxArrived(name, want) {
  const s = state.sbx;
  if (!s || s.name !== name || !s.d) return;
  const mine = [...terminals.values()].filter((t) => !t.grid && t.sandbox === name);
  const running = s.d.info.phase === 'running';
  const live = (s.d.sessions || []).filter((x) => !x.ended).map((x) => x.name);
  // 593 §9 (S1): the panes the host kept for this sandbox, the first time this page shows it.
  if (!mine.length) await restorePanes(name);
  if (want) {
    const have = pageTerminals(name).find((t) => t.session === want && t.mode === 'interactive' && !t.ended);
    if (have) { const v = sview(name); v.selected[have.pane] = have.id; v.focusedPane = have.pane; renderTerminals(); if (!have.saved) focusTerm(have); }
    else if (running && live.includes(want)) openTerminal(name, want, 'interactive');
    else if (!running && (await savedRows(name)).some((r) => r.name === want)) openSavedTerminal(name, (await savedRows(name)).find((r) => r.name === want));
    else failureFor(name, 'Session ' + want + ' is not running in ' + name);
    return;
  }
  if (!pageTerminals(name).length && running && live.includes(s.d.defaultSession) && setting('ui.terminals', true) && !sview(name).restoredAny) {
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
  const detailsOpen = setting('ui.details_open', true);
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
    const open = !setting('ui.details_open', true);
    $('sbx-body').classList.toggle('details-closed', !open);
    saveSetting('ui.details_open', open).then(() => refreshSandbox()).catch((e) => pageFailure('ui.details_open was not saved: ' + (e.message || e)));
  }, { quiet: true, iconOnly: true, icon: 'panel-right', title: (detailsOpen ? 'Hide' : 'Show') + ' the details: sessions, restore points, network, keys (remembered: ui.details_open)' });
  detailsBtn.setAttribute('aria-pressed', detailsOpen ? 'true' : 'false');
  const suggestions = net.permissions ? net.permissions.suggestions : [];
  const refused = suggestions.reduce((n, s) => n + s.count, 0);
  const bar = h('div', { class: 'sbx-bar-inner' },
    h('div', { class: 'sbx-title' },
      h('h1', null, name), sandboxPill(i),
      h('span', { class: 'chips sbx-meta' },
        chip('Image', h('span', { 'data-image-title': '' }, i.imageTitle || i.image), { title: i.image + (i.dockerfile ? ' — Dockerfile ' + i.dockerfile : '') }),
        chip('RAM', (i.ramHeldMiB ? mib(i.ramHeldMiB) : '—') + ' of ' + mib(i.memoryMiB)),
        chip('Network', [i.network, i.deniedConnections ? h('span', { class: 'tag warn' }, i.deniedConnections + ' denied') : null, icon('panel-right')],
          { onClick: showTab('network'), title: 'Its network — the Network tab', data: { 'data-network-chip': '' } }),
        i.accountApplies ? chip('Account', i.account || '—') : null,
        i.workspace ? null : h('span', { class: 'tag outline badge-isolated', 'data-isolated': '', title: ISOLATED_NOTE }, withIcon('shield', 'isolated')),
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
    // 594 W28: its system disk came from an image an older doz made.
    i.olderImage ? callout('warn', { compact: true, cls: 'cred-banner img-banner', icon: 'flame', attrs: { 'data-older-image': name }, body: name + ' was ' + i.olderImage + '.' }) : null,
    // 596 (B8): its Dockerfile changed (or was built again) — offered, never rebuilt by itself.
    i.rebuildAvailable ? callout('warn', { compact: true, cls: 'cred-banner img-banner', icon: 'flame', attrs: { 'data-rebuild-available': name }, body: i.rebuildAvailable + '.',
      actions: [btn('Rebuild the image', () => dialog('Rebuild ' + i.image + '?',
        'Runs container build again (seconds when nothing changed: its cache), then bakes only if the built image changed. ' + DOCKERFILE_POLICY_NOTE + ' This sandbox keeps its disk until you reset it.',
        [], 'Rebuild', async () => { await actOrThrow({ action: 'image-bake', image: i.image }); }, { icon: 'flame' }), { small: true, icon: 'flame' })] }) : null,
    // 597: what the agent was refused, said once here with the way to decide (the Network tab).
    refused ? callout('warn', { compact: true, attrs: { 'data-refused': name }, body: ['The agent was refused ' + plural(refused, 'time', 'times') + ' — ',
      ...suggestions.slice(0, 3).flatMap((s, n) => [n ? ', ' : '', h('strong', null, s.permission ? s.what : s.what), ' (' + s.count + ')']), '.'],
      actions: [btn('Review in Network', showTab('network'), { small: true, icon: 'shield' })] }) : null);
  // ── the inspector: six tabs instead of nine stacked sections ──
  const tab = sview(name).inspTab || 'overview';
  const counts = { sessions: live.length ? h('span', { class: 'count' }, String(live.length)) : null,
                   network: i.deniedConnections ? h('span', { class: 'count warn' }, String(i.deniedConnections)) : null };
  const tabs = h('div', { class: 'itabs', role: 'tablist', 'aria-label': 'Details of ' + name },
    INSP_TABS.map(([id, label, title, ic]) => h('button', { type: 'button', role: 'tab', class: 'itab', id: 'itab-' + id, 'data-insp-tab': id, 'aria-controls': 'ipanel-' + id,
      'aria-selected': id === tab ? 'true' : 'false', title, on: { click: () => inspShow(name, id) } }, icon(ic), h('span', { class: 'itab-l' }, label), counts[id] || null)));
  const panel_ = (id, ...kids) => h('section', { class: 'ipanel', role: 'tabpanel', id: 'ipanel-' + id, 'data-insp': id, 'aria-labelledby': 'itab-' + id, hidden: id !== tab }, ...kids);
  const head = (title, ...acts) => h('div', { class: 'head' }, h('h2', null, title), acts.length ? h('div', { class: 'actions' }, acts) : null);
  const last = d.restorePoints.length ? d.restorePoints[d.restorePoints.length - 1] : null;
  const details = h('div', { class: 'sbx-details-inner' }, tabs,
    panel_('overview',
      h('div', { class: 'stats' },
        stat('RAM held', mib(i.ramHeldMiB), 'of ' + mib(i.memoryMiB) + (i.memoryReturnedMiB ? ' · balloon returned ' + mib(i.memoryReturnedMiB) : '')),
        stat('Disk', bytes(i.diskBytes), d.snapshotBytes ? 'snapshot ' + bytes(d.snapshotBytes) : (d.hasRootDisk ? 'root disk kept' : 'no root disk yet')),
        stat('CPUs', String(d.cpus))),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Attach from a terminal'), h('div', { class: 'cmd' }, h('code', null, d.attachCommand), copy)),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Workspace'),
        h('div', { class: i.workspace ? null : 'muted' }, i.workspace ? [h('code', null, i.workspace), ' → /workspace (live)'] : 'Isolated — ' + ISOLATED_NOTE),
        i.workspaceRules ? h('p', { class: 'muted', 'data-workspace-rules-line': '' },
          'Workspace rules: ' + i.workspaceRules + '. Which rule decides a path: doz ignore check ' + name + ' PATH. Not a security boundary.')
          // 599g (owner A3): a shared folder with no rule file says so, rather than nothing (isolated: nothing to say).
          : i.workspace ? h('p', { class: 'muted', 'data-workspace-rules-none': '' },
            'Workspace rules: none — the folder is shared as is. A .dozignore or .dozreadonly in it keeps the agent away from some files.') : null),
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
        fact('Workspace', i.workspace ? i.workspace + ' → /workspace (live)' : 'isolated — ' + ISOLATED_NOTE),
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
