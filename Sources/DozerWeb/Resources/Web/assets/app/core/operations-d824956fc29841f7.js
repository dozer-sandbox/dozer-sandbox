// core/operations — Operations: one typed action → one host operation; transitions; following them to their end.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { api } from './api-1817573a49f0ab85.js';
import { remeasure, scheduleResTotal } from './measure-d1b8f65758e1ac8f.js';
import { sandboxPhase, verbsFor } from './sandboxes-d24059f81c7268c1.js';
import { state } from './state-6efaa5d4aa08116b.js';
import { terminals } from './terminals-fa5cf7fc28fdb48f.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const failureFor = upcall('failureFor'), opFailed = upcall('opFailed'), paintCover = upcall('paintCover'),
  paintRowOps = upcall('paintRowOps'), paintTransition = upcall('paintTransition'), refresh = upcall('refresh'),
  refreshNav = upcall('refreshNav'), renderOps = upcall('renderOps'), toast = upcall('toast');

// ── actions ─────────────────────────────────────────────────────────────────
// One typed action → one host operation. Answers at once; progress arrives as SSE `op` events.
export async function act(body) {
  // No repeat of what is already under way (the server refuses it too — 409).
  const label = body.action + (body.sandbox ? ' ' + body.sandbox : '');
  if ([...state.ops.values()].some((o) => o.state === 'running' && o.label === label && o.action === body.action)) {
    toast(label + ' is already under way', false);
    return null;
  }
  beginTransition(body.sandbox, body.action);
  try {
    const op = await api('actions', { method: 'POST', json: body });
    trackOp(op);
    return op;
  } catch (e) {
    endTransition(body.sandbox, body.action);
    failureFor(body.sandbox, e.message || String(e));
    return null;
  }
}

// ── transitions (593 follow-up — owner: "when i clicked on the button to start the sandbox, it briefly
// flashed a button that it was "Shut Down" before the boot sequence"). The moment a lifecycle action is
// asked for, its sandbox is IN that transition on this page: the phase pill says so ("Booting…", with a
// spinner), every lifecycle button stays where it was but disabled — the set shown when it was clicked,
// never another phase's — and the boot view's cover says it is starting. It ends when the operation
// ends (or is refused); only then does the control bar show the new phase's buttons.
export const TRANSITION_LABEL = { start: 'Booting…', wake: 'Waking…', resume: 'Resuming…', pause: 'Pausing…', sleep: 'Going to sleep…',
                           hibernate: 'Hibernating…', shutdown: 'Shutting down…', reset: 'Resetting…', rm: 'Removing…' };
state.transitions = new Map();
state.trGen = 0;
export function beginTransition(name, action) {
  if (!name || !TRANSITION_LABEL[action]) return;
  const have = state.transitions.get(name);
  if (have && have.action === action) return;
  state.trGen++;
  state.transitions.set(name, { action, verbs: verbsFor(sandboxPhase(name)) });
  paintTransition(name);
}
/// `repaint`: the action failed or was refused — show what is true again at once. After a success the
/// refresh that follows repaints from the NEW state (repainting now would show the phase it just left).
function endTransition(name, action, repaint = true) {
  const t = name && state.transitions.get(name);
  if (!t || (action && t.action !== action)) return;
  state.trGen++;
  state.transitions.delete(name);
  for (const x of terminals.values()) {
    if (x.sandbox !== name) continue;
    if (x.bootIntent) { x.bootIntent = false; if (repaint) paintCover(x); } else if (x.saved && repaint) paintCover(x);
  }
}
/// This page's transition of the sandbox, or — an operation it did not start here (a reload, another
/// tab's) — the running lifecycle operation it knows of (then the buttons follow the phase).
export function transitionOf(name) {
  const t = state.transitions.get(name);
  if (t) return t;
  const o = [...state.ops.values()].find((x) => x.sandbox === name && x.state === 'running' && TRANSITION_LABEL[x.action]);
  return o ? { action: o.action, verbs: null } : null;
}
export function trackOp(op) {
  const before = state.ops.get(op.id);
  // 595: a fast operation's end (SSE) can arrive before the POST's own "running" answer — never
  // let the older news overwrite the end (it left the page thinking it still ran).
  if (before && before.state !== 'running' && op.state === 'running') return;
  state.ops.set(op.id, op);
  if (state.ops.size > 60) state.ops.delete(state.ops.keys().next().value);
  renderOps();
  paintRowOps();
  // A new operation: re-render, so its sandbox's buttons are disabled while it runs.
  // (Not for a removal: the page it would refetch is about to be gone.)
  if (!before && op.state === 'running' && op.action !== 'rm') refresh(false);
  if (op.state !== 'running' && (!before || before.state === 'running')) {
    endTransition(op.sandbox, op.action, op.state === 'failed');
    if (op.state === 'failed') opFailed(op);
    refreshNav();
    // 595: an operation's end may have changed the disks — measure again (the nav's total too).
    remeasure();
    scheduleResTotal();
    // The sandbox this page shows is gone: back to the list (route() refreshes) instead of a 404.
    if (op.state === 'done' && op.action === 'rm' && state.view === 'sandbox' && state.param === op.sandbox) { location.hash = '#/overview'; return; }
    refresh(false);
  }
}
// 593 (owner): Operations is its own page, not a block on top of every page. What the nav shows: the
// running count (with a spinner) and a red dot while a failure is unacknowledged — one that ended
// after the Operations page was last shown (or this page loaded). In-context progress stays: the
// overview row and the sandbox's control bar (`data-op-for`).
export function opEnded(o) { return new Date(o.startedAt).getTime() + (o.milliseconds || 0); }
export function prepRunning(p) { return p.state === 'running' || p.state === 'cancelling'; }
export async function loadPreparations() {
  try { state.preps = await api('preparations'); } catch (_) { /* the last list */ }
  renderOps();
}
/// Wait (briefly) for the operations this page started to end.
export async function waitOps(max = 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < max && [...state.ops.values()].some((o) => o.state === 'running' && o.action && o.action.startsWith('builder-'))) {
    await new Promise((r) => setTimeout(r, 400));
  }
}
export async function actOrThrow(body) {
  beginTransition(body.sandbox, body.action);
  let op;
  try { op = await api('actions', { method: 'POST', json: body }); } catch (e) { endTransition(body.sandbox, body.action); throw e; }
  trackOp(op);
  return op;
}

/// 605: the operations the server knows. A running one it reports ended goes through trackOp (its
/// sandbox's transition ends); a running one this page had that the server does not know any more (an
/// older doz ui kept no record) ends here as interrupted — never a forever-spinner.
export function adoptOperations(list) {
  const ids = new Set(list.map((o) => o.id));
  for (const o of list) {
    const b = state.ops.get(o.id);
    if (b && b.state === 'running' && o.state !== 'running') trackOp(o); else state.ops.set(o.id, o);
  }
  for (const o of [...state.ops.values()]) {
    if (o.state === 'running' && !ids.has(o.id)) {
      trackOp({ ...o, state: 'interrupted', interrupted: true, text: 'doz ui restarted while it ran; this page lost track of it',
                milliseconds: Date.now() - new Date(o.startedAt).getTime() });
    }
  }
  renderOps();
  paintRowOps();
}
/// Until the operation `id` this page started ends (its SSE end, or the answer) — or `max` ms.
export async function waitOp(id, max = 120000) {
  const t0 = Date.now();
  while (Date.now() - t0 < max) {
    const o = state.ops.get(id);
    if (o && o.state !== 'running') return o;
    await new Promise((r) => setTimeout(r, 150));
  }
  return state.ops.get(id) || null;
}
export async function waitForOp(op, seconds = 300) {
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) {
    const o = state.ops.get(op.id);
    if (o && o.state !== 'running') return o;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}
