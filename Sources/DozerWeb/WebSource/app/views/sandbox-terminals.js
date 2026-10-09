// views/sandbox-terminals — A sandbox's terminal area: tabs, the split, New shell / New terminal.
import { upcall } from '../core/hooks.js';
import { $, h } from '../dom/h.js';
import { icon, setButton } from '../dom/icons.js';
import { api } from '../core/api.js';
import { when } from '../core/format.js';
import { actOrThrow, TRANSITION_LABEL, transitionOf, waitForOp } from '../core/operations.js';
import { opRunningFor, sandboxPhase } from '../core/sandboxes.js';
import { bootViewOnStart, saveSetting, setting, terminalsAllowed } from '../core/settings.js';
import { state } from '../core/state.js';
import { pageTerminals, SPLIT_KINDS, sview, terminals, termUI } from '../core/terminals.js';
import { splitArgs } from '../core/util.js';
import { isRemote } from '../core/session.js';
import { btn } from '../components/button.js';
import { dialog } from '../components/dialog.js';
import { lifecycle, sessionsWhyNot } from '../components/lifecycle.js';
import { menuButton } from '../components/menus.js';
import { agentChip } from '../components/agent-status.js';
import { failureFor, pageFailure } from '../components/notices.js';
import { bootTerm, closeTerminal, focusTerm, openDefaultTerminal, openTerminal, terminalTitle } from '../components/terminal.js';
import { openInTerminal, runDetachedDialog } from './sandbox-dialogs.js';
import { sessionMenuItems } from '../components/session-actions.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const openSavedTerminal = upcall('openSavedTerminal'), persistLayout = upcall('persistLayout');

// ── a sandbox's terminal area: tabs, and a split (593: per sandbox; the grid's tiles are apart)
export function paintTabs() { if (state.view === 'sandbox') renderTerminals(); }
export function renderTerminals() {
  const root = $('terminals');
  if (!termUI.built) {
    // Split is a split button (owner, 591): the main part splits and ALWAYS fills the right pane
    // with the chosen kind (or, when split, unsplits); the ▾ menu picks the kind — and when already
    // split, adds that kind to the right pane at once.
    const unsplit = () => {
      const v = sview(state.param);
      v.split = false;
      for (const t of pageTerminals(state.param)) t.pane = 0;
      v.selected[0] = v.selected[0] ?? v.selected[1];
      v.selected[1] = null;
      v.focusedPane = 0;
      renderTerminals();
    };
    termUI.splitMain = btn('Split', () => {
      if (sview(state.param).split) unsplit();
      else splitWith(termUI.splitKind).catch((e) => failureFor(state.param, e.message || String(e)));
    }, { small: true, quiet: true, iconOnly: true, icon: 'columns-2', title: 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind] });
    // 603: the caret is a menuButton (kept on screen; the old menu opened off the left edge and its items
    // ended in a literal "null" — replaceChildren writes a null as text, h() skips it).
    const caret = h('button', { type: 'button', class: 'btn sm quiet split-caret caret', title: 'What the split adds', 'aria-label': 'What the split adds' },
      icon('chevron-down'));
    termUI.splitBtn = h('div', { class: 'btn-group split-button', role: 'group', 'aria-label': 'Split' }, termUI.splitMain, caret);
    termUI.splitCtl = menuButton(caret, [], { wrap: termUI.splitBtn, label: 'What the split adds' });
    termUI.splitMenu = termUI.splitCtl.menu;
    // 603 (E3): what makes or arranges terminals sits on the tab strip it changes.
    termUI.newShell = btn('New shell', () => { const n = state.param; newShellTerminal(n).catch((e) => failureFor(n, e.message || String(e))); },
      { small: true, quiet: true, title: 'A new shell session (shell-2, shell-3, …) in a browser terminal' });
    const nsCaret = h('button', { type: 'button', class: 'btn sm quiet caret', title: 'Other terminals', 'aria-label': 'Other terminals' }, icon('chevron-down'));
    const nsGroup = h('div', { class: 'btn-group', role: 'group', 'aria-label': 'New terminal' }, termUI.newShell, nsCaret);
    termUI.nsCtl = menuButton(nsCaret, [], { wrap: nsGroup, label: 'Other terminals' });
    termUI.openTerm = btn('Open in Terminal', () => openInTerminal(state.param, null), { small: true, quiet: true, iconOnly: true, icon: 'square-terminal' });
    termUI.acts = h('div', { class: 'strip-acts', role: 'toolbar', 'aria-label': 'Terminals' }, nsGroup, termUI.splitBtn, isRemote() ? null : termUI.openTerm);
    termUI.panes = [0, 1].map((i) => {
      const strip = h('div', { class: 'tabs', role: 'tablist', 'aria-label': 'Terminals' });
      const head = h('div', { class: 'term-strip' }, strip);
      const body = h('div', { class: 'term-body' });
      const empty = h('div', { class: 'term-empty' });
      const pane = h('div', { class: 'term-pane', 'data-pane': String(i) }, head, body);
      body.append(empty);
      pane.addEventListener('focusin', () => { if (state.param) sview(state.param).focusedPane = i; });
      pane.addEventListener('mousedown', () => { if (state.param) sview(state.param).focusedPane = i; });
      return { root: pane, strip, head, body, empty };
    });
    termUI.grid = h('div', { class: 'term-grid' }, termUI.panes[0].root, termUI.panes[1].root);
    root.replaceChildren(termUI.grid);
    termUI.built = true;
  }
  const name = state.view === 'sandbox' ? state.param : null;
  const v = name ? sview(name) : { split: false, selected: [null, null] };
  termUI.grid.classList.toggle('split', v.split);
  paintSplitButton();
  termUI.panes[1].root.hidden = !v.split;
  // Another sandbox's terminals stay open (hidden) — going back to it is instant.
  for (const t of terminals.values()) if (!t.grid && t.sandbox !== name) t.els.wrap.hidden = true;
  termUI.panes.forEach((p, i) => {
    const mine = name ? pageTerminals(name).filter((t) => t.pane === i) : [];
    if (!mine.some((t) => t.id === v.selected[i])) v.selected[i] = mine.length ? mine[mine.length - 1].id : null;
    p.strip.replaceChildren(...mine.map((t) => tabElement(t, i)));
    scrollActiveTab(p.strip);
    p.empty.hidden = mine.length > 0;
    for (const t of mine) {
      if (t.els.wrap.parentNode !== p.body) p.body.append(t.els.wrap);
      t.els.wrap.hidden = t.id !== v.selected[i];
      // 593 §9: a restored tab loads its engine the first time it is shown — a hidden frame has no size,
      // and an interactive attach at no size would resize its session.
      if (t.lazy && !t.els.wrap.hidden) {
        t.lazy = false;
        setTimeout(() => bootTerm(t, setting('ui.terminal_font_size', 13)), 0);
      }
    }
  });
  paintTermEmpty();
  // The strip's actions on the rightmost pane shown.
  const host = (v.split ? termUI.panes[1] : termUI.panes[0]).head;
  if (termUI.acts.parentNode !== host) host.append(termUI.acts);
  paintStripActs();
  if (name) persistLayout(name);
  // The URL names the session shown (replaceState: no route).
  const sel = name && terminals.get(v.selected[v.focusedPane] ?? v.selected[0]);
  // (603: never under a wizard's modal — its URL is #/new or #/onboarding; the page's hash follows.)
  if (sel && sel.session && state.session !== sel.session && !state.modal) {
    state.session = sel.session;
    history.replaceState(null, '', location.pathname + '#/sandbox/' + name + '/' + sel.session);
    state.bgHash = location.hash;
  }
}
/// The strip's actions follow the sandbox: a session needs a VM (New shell, Run detached, Open in Terminal); a new
/// terminal waits while something is under way.
export function paintStripActs() {
  if (!termUI.acts) return;
  const name = state.param, s = state.sbx;
  const i = s && s.name === name && s.d ? s.d.info : null;
  const why = i ? sessionsWhyNot(name, i) : 'Loading…';
  const busy = !i || i.busy || i.phase === 'booting' || opRunningFor(name) || !!transitionOf(name);
  termUI.newShell.disabled = !!why;
  termUI.newShell.title = why || 'A new shell session (shell-2, shell-3, …) in a browser terminal';
  termUI.openTerm.disabled = !!why;
  termUI.openTerm.title = why || 'Open in Terminal — your terminal app attaches to the ' + (s && s.d ? s.d.defaultSession : 'default') + ' session';
  if (termUI.nsCtl.isOpen()) return;
  termUI.nsCtl.setItems([
    { label: 'Terminal…', icon: 'terminal', desc: 'A new session: a shell, or a command', disabled: busy, why: 'Wait until it settles', onSelect: () => newTerminalDialog(name) },
    { label: 'Run detached…', icon: 'play', desc: 'A new session running a command, not opened here', disabled: !!why, why, onSelect: () => runDetachedDialog(name) },
  ]);
}
/// A pane's tab strip scrolls sideways when its tabs overflow; the selected tab is always in view
/// (orchestrator ruling, 593 follow-up).
function scrollActiveTab(strip) {
  const w = strip.querySelector('.tab.active')?.closest('.tab-wrap');
  if (!w) return;
  const sr = strip.getBoundingClientRect(), wr = w.getBoundingClientRect();
  if (!sr.width) return;
  if (wr.left < sr.left) strip.scrollLeft += wr.left - sr.left;
  else if (wr.right > sr.right) strip.scrollLeft += wr.right - sr.right;
}
/// The terminal area with no terminal: what it can open, from the sandbox's state.
export function paintTermEmpty() {
  if (!termUI.built) return;
  const s = state.sbx;
  const p = termUI.panes[0];
  if (p.empty.hidden) return;
  if (!s || !s.d || s.name !== state.param) { p.empty.replaceChildren(h('div', { class: 'term-empty-box' }, 'Loading…')); return; }
  const i = s.d.info;
  const tr = transitionOf(s.name);
  const busy = i.busy || i.phase === 'booting' || opRunningFor(s.name) || !!tr;
  const live = (s.d.sessions || []).filter((x) => !x.ended);
  const box = h('div', { class: 'term-empty-box' });
  if (busy) {
    box.append(h('div', { class: 'term-empty-head' }, tr ? TRANSITION_LABEL[tr.action] : i.phaseLabel + '…'), h('div', null, 'The terminal opens when it can.'));
  } else if (i.phase === 'off' || i.phase === 'failed') {
    // The plain off state (owner, 2026-09-30): no session screens — its sessions ended with the VM.
    box.dataset.off = i.phase;
    box.append(h('div', { class: 'term-empty-head' }, i.phase === 'off' ? 'Shut down' : s.name + ' failed to start'),
      h('div', { class: 'term-empty-note' }, 'Starting boots it fresh — new sessions.'),
      h('div', { class: 'actions center' },
        // The bar's Start is the page's one primary; here it is the terminal's own button, as on the covers.
        ((b) => { b.classList.add('tc-act'); return b; })(btn('Start', () => lifecycle('start', s.name), { small: true, title: bootViewOnStart() ? 'Boot it, and watch it boot here' : 'Boot it' }))));
  } else {
    // 593 §9 (S4): "New shell" always makes a NEW session; a running session is opened by its own name
    // (the sessions list). The image's own session is offered by name: opened when it runs, started when not.
    const saved = (s.d.sessions || []).filter((x) => x.saved);
    const defaultRuns = live.some((x) => x.name === s.d.defaultSession && !x.saved);
    const defaultSaved = saved.some((x) => x.name === s.d.defaultSession);
    box.append(h('div', { class: 'term-empty-head' }, 'No terminal open'),
      h('div', { class: 'actions center' },
        defaultSaved ? null : defaultRuns
          ? btn('Open ' + s.d.defaultSession, () => openTerminal(s.name, s.d.defaultSession, 'interactive'), { icon: 'terminal',
            title: 'A terminal on the running ' + s.d.defaultSession + ' session' })
          : btn('Start ' + s.d.defaultSession, () => openDefaultTerminal(s.name), { icon: 'play',
            title: 'Start the image’s own session (' + s.d.defaultSession + ')' + (i.phase === 'running' ? '' : ' — it wakes the sandbox') }),
        ...live.filter((x) => x.name !== s.d.defaultSession && !x.saved).slice(0, 8).map((x) => btn('Open ' + x.name, () => openTerminal(s.name, x.name, 'interactive'), { icon: 'terminal' })),
        ...saved.slice(0, 8).map((x) => btn('Show ' + x.name, () => openSavedTerminal(s.name, x), { icon: 'eye', title: 'Its last saved screen (read-only)' })),
        btn('New shell', () => newShellTerminal(s.name).catch((e) => failureFor(s.name, e.message || String(e))), { title: 'A NEW shell session (shell-2, shell-3, …)' })));
  }
  p.empty.replaceChildren(box);
}
function tabElement(t, pane) {
  const phase = t.ended || t.errorText || t.disconnected ? 'ended'
    : t.saved ? sandboxPhase(t.sandbox) || 'unknown' : (t.state && t.state.phase) || 'unknown';
  const v = sview(t.sandbox);
  // Tabs are numbered (1, 2, …) per sandbox, so a shared session can say which tab it is shared with.
  const order = pageTerminals(t.sandbox).map((x) => x.id);
  const num = order.indexOf(t.id) + 1;
  const label = num + ' · ' + terminalTitle(t);
  const twins = t.session && !t.ended ? pageTerminals(t.sandbox).filter((o) => o.id !== t.id && !o.ended && o.session === t.session) : [];
  const shared = twins.length ? h('span', { class: 'tag shared', title: 'Two views of ONE session: what is typed in either shows in both' },
    'shared with tab ' + twins.map((o) => order.indexOf(o.id) + 1).join(', ')) : null;
  const select = h('button', { type: 'button', role: 'tab', class: 'tab' + (t.id === v.selected[pane] ? ' active' : ''),
                               // 594 (W14): the one hint a mouse-using program needs.
                               title: (t.title ? t.title + ' — ' + label : label) + '\nShift+drag selects text while the program uses the mouse',
                               'data-term': String(t.id),
                               on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); focusTerm(t); } } },
    h('span', { class: 'tab-dot ph-' + phase, 'aria-hidden': 'true' }), icon(t.mode === 'watch' ? 'eye' : 'terminal'), label,
    t.mode === 'watch' ? h('span', { class: 'tag' }, 'watch') : null,
    t.session && !t.bootlog ? agentChip(t.sandbox, t.session) : null,     // 612: what its agent is doing
    t.saved ? h('span', { class: 'tag saved', title: 'Its last saved screen (' + (t.saved.reason || 'saved') + ', ' + when(t.saved.savedAt) + ') — it goes live when the sandbox runs' }, 'saved') : null,
    shared);
  const move = v.split ? h('button', { type: 'button', class: 'tab-x', title: 'Move to the other pane', 'aria-label': 'Move ' + label + ' to the other pane',
    on: { click: () => { t.pane = 1 - t.pane; v.selected[t.pane] = t.id; renderTerminals(); focusTerm(t); } } }, icon('arrow-left-right')) : null;
  const close = h('button', { type: 'button', class: 'tab-x', title: 'Close this terminal (the session keeps running)', 'aria-label': 'Close ' + label,
    on: { click: () => closeTerminal(t.id) } }, icon('x'));
  // 608: Restart session / End session — for a running session of a running sandbox.
  const live = t.session && !t.saved && !t.ended && !t.restarting && !t.bootlog && sandboxPhase(t.sandbox) === 'running';
  // The menu is kept on the terminal across re-renders (a title or phase change re-renders the strip — an open
  // menu must not vanish under the pointer).
  if (live && !t.sessionMenu) {
    t.sessionMenu = menuButton(h('button', { type: 'button', class: 'tab-x', title: 'Session ' + t.session + ': restart or end it',
      'aria-label': 'More for session ' + t.session, 'data-session-menu': t.session }, icon('ellipsis')), sessionMenuItems(t.sandbox, t.session, null),
      { align: 'end', label: 'Session ' + t.session });
  } else if (!live && t.sessionMenu) t.sessionMenu = null;
  const menu = live ? t.sessionMenu.el : null;
  return h('div', { class: 'tab-wrap' }, select, move, menu, close);
}
const SPLIT_ICONS = { shell: 'plus', watch: 'eye', attach: 'link', dialog: 'terminal' };
export function paintSplitButton() {
  if (!termUI.splitMain) return;
  const split = state.param ? sview(state.param).split : false;
  setButton(termUI.splitMain, split ? 'Unsplit' : 'Split', 'columns-2');
  termUI.splitMain.title = split ? 'Back to one pane (the right pane’s terminals move left)'
                                 : 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind];
  termUI.splitCtl.setItems(Object.entries(SPLIT_KINDS).map(([kind, label]) => ({
    label: (split ? 'Add a ' : 'Split with a ') + label, icon: SPLIT_ICONS[kind], check: kind === termUI.splitKind, data: { kind },
    desc: kind === termUI.splitKind ? 'the default (ui.split_default)' : null,
    onSelect: () => {
      termUI.splitKind = kind;
      // The choice is the setting ui.split_default (doz.toml), not this browser's.
      if (setting('ui.split_default', 'shell') !== kind) saveSetting('ui.split_default', kind).catch((e) => pageFailure('ui.split_default was not saved: ' + (e.message || e)));
      paintSplitButton();
      splitWith(kind).catch((e) => failureFor(state.param, e.message || String(e)));
    },
  })));
}
/// Split (if needed) and fill the right pane with `kind` — so a split always creates something.
/// With no terminal on the left there is nothing to watch, attach to or put a shell beside: the
/// New terminal dialog opens instead (for the right pane).
export async function splitWith(kind) {
  const name = state.param;
  if (state.view !== 'sandbox' || !name) return;
  const v = sview(name);
  const left = terminals.get(v.selected[0]) || pageTerminals(name).find((t) => t.pane === 0);
  if (!v.split) { v.split = true; renderTerminals(); }
  v.focusedPane = 1;
  if (kind === 'dialog' || !left) { await newTerminalDialog(name); return; }
  if (kind === 'watch' || kind === 'attach') {
    if (!left.session) throw new Error('the left terminal has no session yet — wait for it to start');
    openTerminal(name, left.session, kind === 'watch' ? 'watch' : 'interactive', 1);
    return;
  }
  await newShellTerminal(name, 1);
}

async function newTerminalDialog(sandbox) {
  const names = [sandbox || state.param].filter(Boolean);
  if (!names.length) { pageFailure('Open a sandbox first'); return; }
  const first = names[0];
  // What to open: ALWAYS a new session (593 §9 S4, owner — after "New terminal" attached to a session that
  // already ran): a new shell, or a new session running a command. A running session is reached through
  // its pane or the sessions list (Details › Sessions: Open / Watch), never from here.
  const d = dialog('New terminal in ' + first, 'A new session: a shell, or a command. A session that already runs is opened from the Sessions list.', [
    { name: 'sandbox', label: 'Sandbox', type: 'select', options: names, value: first },
    { name: 'what', label: 'Open', type: 'select', options: [['new', 'New shell'], ['command', 'New session running a command…']] },
    { name: 'session', label: 'Session name (new session only)', placeholder: 'e.g. worker' },
    { name: 'command', label: 'Command (new session only)', placeholder: 'e.g. htop — no shell in front (say bash -lc \'…\' for one)' },
  ], 'Open', async (v) => {
    const sv = sview(v.sandbox);
    const pane = sv.split ? sv.focusedPane : 0;
    if (v.what === 'new') { await newShellTerminal(v.sandbox, pane); return; }
    if (v.what === 'command') {
      const argv = splitArgs(v.command);
      if (!argv.length) throw new Error('the command is empty');
      if (!v.session) throw new Error('a new session needs a name');
      const done = await waitForOp(await actOrThrow({ action: 'open-session', sandbox: v.sandbox, session: v.session, argv }));
      if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
      if (!done.text.startsWith('started')) throw new Error('a session named ' + v.session + ' already runs — pick another name (open it from the Sessions list)');
      openTerminal(v.sandbox, v.session, 'interactive', pane);
      return;
    }
    throw new Error('pick what to open');
  });
  const sandboxSel = d.querySelector('[name="sandbox"]'), whatSel = d.querySelector('[name="what"]');
  sandboxSel.closest('label').hidden = true;             // 593: the page's sandbox
  const nameField = d.querySelector('[name="session"]').closest('label'), cmdField = d.querySelector('[name="command"]').closest('label');
  const showFields = () => { const c = whatSel.value === 'command'; nameField.hidden = !c; cmdField.hidden = !c; };
  whatSel.addEventListener('change', showFields);
  showFields();
}

/// A NEW shell session in `sandbox` — `shell-2`, `shell-3`, … (the next name not taken), running a
/// login shell — opened with the ordinary open-session action (one HostOp; its idempotency unchanged:
/// a name that turns out to be taken answers "already running", and the next name is tried).
export async function newShellTerminal(sandbox, pane) {
  if (!terminalsAllowed()) return;
  let rows = [], detail = null;
  try { [detail, rows] = await Promise.all([api('sandboxes/' + sandbox), api('sandboxes/' + sandbox + '/sessions')]); } catch (_) { /* asleep: listed after the wake */ }
  const argv = loginShell(detail, rows);
  const taken = new Set(rows.map((r) => r.name));
  for (let n = 2, tries = 0; tries < 20; n++) {
    const name = 'shell-' + n;
    if (taken.has(name)) continue;
    tries++;
    const op = await actOrThrow({ action: 'open-session', sandbox, session: name, argv });
    const done = await waitForOp(op);
    if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
    if (done.text.startsWith('started')) { openTerminal(sandbox, name, 'interactive', pane); return; }
    taken.add(name);                                   // it already ran (a sandbox that was asleep): the next one
  }
  throw new Error('no free shell-N name');
}
/// `bash -l` where the image has bash (the built-in images, and custom images made from them; or
/// any running session that is bash), else `sh -l`.
function loginShell(detail, rows) {
  const image = detail && detail.info ? detail.info.image : '';
  const hasBash = ['lab', 'claude-code', 'pi', 'codex'].includes(image) || rows.some((r) => /(^|\/)bash(\s|$)/.test(r.command));
  return hasBash ? ['bash', '-l'] : ['sh', '-l'];
}
