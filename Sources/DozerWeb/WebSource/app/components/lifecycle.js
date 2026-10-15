// components/lifecycle — Lifecycle controls: a row's next verb + ⋯, the sandbox page's bar, the boot view on Start.
import { h } from '../dom/h.js';
import { iconFor } from '../dom/icons.js';
import { act, actOrThrow, beginTransition, TRANSITION_LABEL, transitionOf } from '../core/operations.js';
import { DESTRUCTIVE, NEXT_VERB, opRunningFor, PRIMARY_VERB, VERBS, verbsFor } from '../core/sandboxes.js';
import { saveSetting, setting } from '../core/settings.js';
import { state } from '../core/state.js';
import { pageTerminals } from '../core/terminals.js';
import { btn } from './button.js';
import { confirmAction, dialog } from './dialog.js';
import { moreMenu } from './menus.js';
import { pageFailure } from './notices.js';
import { openPendingTerminal } from './terminal.js';

/// Shut Down keeps the disk, so it asks with a plain confirmation (and can stop asking); Reset and
/// Remove destroy data and keep the typed name. "Don't ask again" is the setting ui.confirm_shutdown
/// (doz.toml — every browser, and the Settings page turns it back on).
function confirmShutdown(name) {
  const body = { action: 'shutdown', sandbox: name };
  if (!setting('ui.confirm_shutdown', true)) { act(body); return; }
  dialog('Shut down ' + name + '?', DESTRUCTIVE.shutdown + ' Start cold-boots the same disk.', [
    { name: 'dontAsk', label: 'Don’t ask again', type: 'checkbox', help: 'Sets ui.confirm_shutdown = false in the settings (Settings turns it back on).' },
  ], 'Shut down', async (v) => {
    if (v.dontAsk) await saveSetting('ui.confirm_shutdown', false).catch((e) => pageFailure('ui.confirm_shutdown was not saved: ' + (e.message || e)));
    return await actOrThrow(body);
  }, { danger: true });
}
export function lifecycle(verb, name) {
  if (verb === 'shutdown') confirmShutdown(name);
  else if (DESTRUCTIVE[verb]) confirmAction(VERBS[verb][0] + ' ' + name, DESTRUCTIVE[verb], name, { action: verb, sandbox: name });
  // 617: from its own page, the start sequence; elsewhere (a row of Sandboxes) the plain start — its page, when
  // opened, shows the boot as it is (tab zero, Console).
  else if (verb === 'start' && state.view === 'sandbox' && state.param === name) startWithBootView(name);
  else act({ action: verb, sandbox: name });
}
/// 591 — Start shows the boot: a terminal pane streams the host's steps and the kernel's console,
/// then becomes the image's own session (the UI process does the switch; the boot stays in the scrollback).
/// 617 (owner: one stable page after Start — the build panel, then tab zero Console, then the agent's tab, nothing
/// moving): the start of a sandbox from its page. The agent's terminal is prepared at once but stays out of sight
/// (`openPendingTerminal`: it attaches QUIETLY once the sandbox runs and becomes a tab when it has drawn its first
/// frame); while the image is prepared the terminal area shows the build (components/start-progress.js); tab zero,
/// Console, appears when the VM powers on (`syncConsoleTab`). Never the old boot view writing the console into the
/// agent's own terminal (owner's shot 7625: vminitd's lines in Codex's tab).
export async function startWithBootView(name) {
  beginTransition(name, 'start');
  // The terminal is registered at once (synchronously) and lays itself out on its own: the start never waits for it —
  // a hidden tab's timers can be a minute late (Chrome's intensive throttling).
  if (!pageTerminals(name).some((t) => t.pending && !t.closed && !t.ended)) openPendingTerminal(name);
  await act({ action: 'start', sandbox: name });
}
export function rowLifecycle(s) {
  const tr = transitionOf(s.name);
  const busy = s.busy || s.phase === 'booting' || opRunningFor(s.name) || !!tr;
  const verbs = tr && tr.verbs ? tr.verbs : verbsFor(s.phase);
  const next = verbs.includes(NEXT_VERB[s.phase]) ? NEXT_VERB[s.phase] : verbs[0];
  const why = tr ? TRANSITION_LABEL[tr.action] : 'Wait until it settles';
  const b = next ? btn(VERBS[next][0], () => lifecycle(next, s.name), { small: true, quiet: true, title: busy ? why : VERBS[next][1] }) : null;
  if (b && busy) b.disabled = true;
  const rest = verbs.filter((v) => v !== next);
  const more = rest.length ? moreMenu('More for ' + s.name, rest.map((v) => ({ label: VERBS[v][0] + (DESTRUCTIVE[v] ? '…' : ''), icon: iconFor(VERBS[v][0]),
    desc: VERBS[v][1], danger: !!DESTRUCTIVE[v], disabled: busy, why, onSelect: () => lifecycle(v, s.name) })), { small: true }) : null;
  return h('div', { class: 'row-acts', 'data-lifecycle-for': s.name }, b, more ? more.el : null);
}
/// Sessions need a VM: running, or one a session request wakes (paused, asleep, hibernated) — never while off,
/// failed, booting, busy or while another operation on it runs (590 bug 2). Null: ready; else why not.
export function sessionsWhyNot(name, i) {
  const ready = ['running', 'paused', 'asleep', 'hibernated'].includes(i.phase) && !i.busy && !opRunningFor(name) && !transitionOf(name);
  return ready ? null : i.phase === 'off' || i.phase === 'failed' ? 'Start it first' : 'Wait until it is running';
}
export function lifecycleBar(s) {
  const tr = transitionOf(s.name);
  const busy = s.busy || s.phase === 'booting' || opRunningFor(s.name) || !!tr;
  const verbs = tr && tr.verbs ? tr.verbs : verbsFor(s.phase);
  const mk = (v) => {
    const b = btn(VERBS[v][0], () => lifecycle(v, s.name), { primary: !busy && PRIMARY_VERB[s.phase] === v, danger: v === 'shutdown',
      title: tr ? TRANSITION_LABEL[tr.action] : VERBS[v][1] });
    if (busy) b.disabled = true;
    return b;
  };
  const group = verbs.filter((v) => v !== 'shutdown');
  return h('span', { class: 'sbx-life', 'data-lifecycle-for': s.name },
    group.length ? h('span', { class: 'btn-group', role: 'group', 'aria-label': 'Lifecycle' }, group.map(mk)) : null,
    verbs.includes('shutdown') ? mk('shutdown') : null);
}
