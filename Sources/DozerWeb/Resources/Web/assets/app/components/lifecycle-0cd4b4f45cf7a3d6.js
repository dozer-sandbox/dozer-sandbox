// components/lifecycle — Lifecycle controls: a row's next verb + ⋯, the sandbox page's bar, the boot view on Start.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { iconFor } from '../dom/icons-75c107270d336b51.js';
import { act, actOrThrow, beginTransition, TRANSITION_LABEL, transitionOf } from '../core/operations-c7eeae66c46d4582.js';
import { DESTRUCTIVE, NEXT_VERB, opRunningFor, PRIMARY_VERB, VERBS, verbsFor } from '../core/sandboxes-5eed88567d9ef0c0.js';
import { bootViewOnStart, saveSetting, setting } from '../core/settings-b82be35de3dd1806.js';
import { terminals } from '../core/terminals-fa5cf7fc28fdb48f.js';
import { btn } from './button-72d87e1085f00b4e.js';
import { confirmAction, dialog } from './dialog-eda31d5dbf8a6de4.js';
import { moreMenu } from './menus-08caea0a1297bf90.js';
import { pageFailure } from './notices-f4d7053b68a08d1e.js';
import { openTerminal } from './terminal-8b6eada450b3415a.js';

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
  else if (verb === 'start' && bootViewOnStart()) startWithBootView(name);
  else act({ action: verb, sandbox: name });
}
/// 591 — Start shows the boot: a terminal pane streams the host's steps and the kernel's console,
/// then becomes the image's own session (the UI process does the switch; the boot stays in the scrollback).
export async function startWithBootView(name) {
  // The terminal first: once the UI process shows it waiting on the shut-down sandbox, it is following
  // the host's events — then the start, so not one step is missed (a warm start takes half a second).
  // The transition starts at the click (the bar says "Booting…" at once), and the boot view's cover says
  // it is starting from its first paint — never "Sandbox shut down" while the start is being sent.
  beginTransition(name, 'start');
  const before = new Set(terminals.keys());
  openTerminal(name, null, 'interactive', undefined, { bootIntent: true });
  const t = [...terminals.values()].find((x) => !before.has(x.id));
  const end = Date.now() + 15000;
  while (t && Date.now() < end && !t.closed && !t.errorText && !(t.state && ['shutDown', 'failed', 'boot'].includes(t.state.cover.kind))) {
    await new Promise((r) => setTimeout(r, 100));
  }
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
