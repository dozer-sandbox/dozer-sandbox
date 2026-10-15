// components/start-progress — the build panel (617; owner: "we shouldnt show the blank terminal area until the build is
// finished, and while the build completes, we should show the progress in that area", then the start sequence: "the
// build steps show in the area where the tabbed sessions will appear"). While a sandbox this page shows is STARTING and
// its VM is not powered on yet (no tab zero, Console), its terminal area shows the build instead of a tab strip:
//   · a large left-to-right bar for the whole build — each step weighted by this Mac's last build of the same recipe
//     (the preparation's own estimate), else by a fixed weight per kind of step; a download fills its share by bytes;
//     a step past its estimate creeps within its share; the bar never moves back;
//   · "Step N of M · the step · elapsed" under it, then the finished steps (✓ and times), and the raw output dimmed
//     under "Show details";
//   · a cached image has no preparation: no bar — the area waits for the VM (a moment), then Console takes over;
//   · a failed start keeps the area: the bar stopped and marked, the error, the log, Start again / Dismiss.
// The data is the start's own operation (`progress`, WebOpProgress) and the image's preparation (`state.preps`, SSE).
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { upcall } from '../core/hooks.js';
import { transitionOf } from '../core/operations.js';
import { sandboxImage } from '../core/sandboxes.js';
import { state } from '../core/state.js';
import { pageTerminals } from '../core/terminals.js';
import { btn } from './button.js';

const lifecycle = upcall('lifecycle');
const backToTrySetup = upcall('backToTrySetup');

let ticker = null;

function elapsed(since) {
  const s = Math.max(0, Math.round((Date.now() - new Date(since).getTime()) / 1000));
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}

/// The start of `name` this page should show: the running one, else a failed one not yet dismissed.
function startOf(name) {
  // 617: a try's page before its create returns — the start is under way from the person's point of view.
  const pend = state.pendingTry && state.pendingTry.name === name ? state.pendingTry : null;
  if (pend) return { id: 'pending-' + name, state: pend.error ? 'failed' : 'running', pending: true, progress: null, text: pend.error || '', startedAt: new Date(pend.at).toISOString() };
  const ops = [...state.ops.values()].filter((o) => o.sandbox === name && o.action === 'start');
  const running = ops.find((o) => o.state === 'running');
  if (running) return running;
  const last = ops[ops.length - 1];
  return last && last.state === 'failed' && !(state.startDismissed || new Set()).has(last.id) ? last : null;
}

/// The image's preparation this start is waiting on (joined, never started again — the host's single flight).
function prepOf(name, o) {
  const image = sandboxImage(name);
  const all = (state.preps || []).filter((p) => p.image === image);
  return all.find((p) => p.state === 'running' || p.state === 'cancelling')
    || all.find((p) => p.state === 'failed' && o && o.state === 'failed') || null;
}

/// Tab zero is there: the VM is on.
function consoleUp(name) { return pageTerminals(name).some((t) => t.mode === 'console'); }

/// 617: the header's word for a start — preparing while the image builds, booting once the VM is on.
export function startStage(name) {
  if (state.pendingTry && state.pendingTry.name === name) return 'Preparing…';
  const o = startOf(name);
  return o && o.state === 'running' && prepOf(name, o) && !consoleUp(name) ? 'Preparing…' : 'Booting…';
}

/// A step's fixed weight by what it does (when this Mac never built the recipe before).
function weightOf(label) {
  const l = String(label || '').toLowerCase();
  if (/download|pull|fetch/.test(l)) return 4;
  if (/install|baseline|npm|apt|bake|build|prepar|compil/.test(l)) return 6;
  if (/unpack|extract|flatten|copied|copy|clone/.test(l)) return 2;
  return 1;
}

/// The whole build's share done (0…1), never less than shown before for this preparation.
function fraction(o, p) {
  let f;
  if (p.remainingSeconds != null && p.seconds > 0) {
    // This Mac built the recipe before: the preparation's own estimate (its last run's step times).
    f = p.seconds / (p.seconds + Math.max(0, p.remainingSeconds));
  } else {
    const done = (p.steps || []).filter((s) => s.kind === 'step' || s.kind === 'failed').reduce((n, s) => n + weightOf(s.label), 0);
    const cur = p.step ? weightOf(p.step) : 0;
    const left = Math.max(0, (p.plannedSteps || 0) - (p.stepIndex || 0)) * 2;
    // Within the step under way: its download's bytes, else a slow creep (never reaching its end).
    const usual = p.stepUsualSeconds || (cur >= 6 ? 60 : cur >= 4 ? 20 : 5);
    const within = p.transferFraction != null ? p.transferFraction : 0.9 * (1 - Math.exp(-(p.stepSeconds || 0) / usual));
    const total = done + cur + left;
    f = total > 0 ? (done + cur * within) / total : 0;
  }
  f = Math.min(p.state === 'done' ? 1 : 0.98, Math.max(0, f));
  // Per preparation (the same across the start's operation and its transition): it never moves back.
  state.spBar = state.spBar && state.spBar.prep === p.id ? state.spBar : { prep: p.id, max: 0 };
  state.spBar.max = Math.max(state.spBar.max, f);
  return state.spBar.max;
}

/// A step in a few words: the plain wording, never the raw "step: …" label, without its parenthesised list.
function shortStep(s) {
  return String(s || '').replace(/^step:\s*/i, '').replace(/…$/, '').replace(/\s*\([^)]{24,}\)/g, '').trim();
}

/// 617: the try's page while its create runs (a moment), and a create that failed: what it says and Back to setup.
function pendingPanel(name, o) {
  if (o.state === 'failed') {
    return h('div', { class: 'start-progress', 'data-start-progress': name, 'data-start-failure': '', role: 'alert' },
      h('div', { class: 'sp-box' },
        h('h3', null, name + ' was not made'),
        h('div', { class: 'sp-failed' },
          h('p', null, o.text),
          h('div', { class: 'sp-acts' },
            btn('Back to setup', () => backToTrySetup(), { primary: true, small: true, icon: 'arrow-left' })))));
  }
  return h('div', { class: 'start-progress building', 'data-start-progress': name, 'data-start-pending': '', role: 'status', 'aria-live': 'polite' },
    h('div', { class: 'sp-box' },
      h('h3', null, 'Preparing ' + name),
      h('div', { class: 'sp-barbox' },
        h('progress', { class: 'sp-bar', max: '1', 'aria-label': 'The start of ' + name }),
        h('div', { class: 'sp-stepline' }, 'Preparing · ', h('span', { 'data-sp-elapsed': o.startedAt }, elapsed(o.startedAt)))),
      h('ol', { class: 'sp-steps' })));
}

function panelFor(name, o, p) {
  if (o.pending) return pendingPanel(name, o);
  const prog = o.progress || { steps: [], tail: [] };
  const failed = o.state === 'failed';
  const now = shortStep(prog.current || (p && p.step));
  const bar = p ? h('div', { class: 'sp-barbox' },
    h('progress', { class: 'sp-bar' + (failed ? ' failed' : ''), max: '1', value: String(fraction(o, p).toFixed(3)), 'data-sp-bar': '',
      'aria-label': 'The build of ' + name }),
    h('div', { class: 'sp-stepline', 'data-sp-stepline': '' },
      (p.stepIndex && p.plannedSteps ? 'Step ' + Math.min(p.stepIndex, p.plannedSteps) + ' of ' + p.plannedSteps : 'Preparing') +
      (now && !failed ? ' · ' + now : '') + ' · ',
      h('span', { 'data-sp-elapsed': p.startedAt || '' }, elapsed(p.startedAt || o.startedAt || Date.now())),
      p.transferLine && !failed ? ' · ' + p.transferLine : '')) : null;
  const steps = (prog.steps || []).map((s) => h('li', { class: 'sp-step' + (s.failed ? ' failed' : '') },
    icon(s.failed ? 'circle-x' : 'check'), h('span', null, s.text), s.seconds >= 0.1 ? h('span', { class: 'muted' }, s.seconds.toFixed(1) + ' s') : null));
  const current = !failed && prog.current ? h('li', { class: 'sp-step current', 'data-sp-current': '' },
    h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('span', { title: prog.current }, shortStep(prog.current) + '…'),
    h('span', { class: 'muted', 'data-sp-since': prog.since || '' }, prog.since ? elapsed(prog.since) : ''),
    prog.transfer ? h('span', { class: 'muted' }, prog.transfer) : null) : null;
  const raw = [...(p && p.output ? p.output : []), ...(prog.tail || [])].slice(-12);
  const details = raw.length ? h('details', { class: 'disclosure sp-details' }, h('summary', null, icon('chevron-down'), failed ? 'The log' : 'Show details'),
    h('pre', { class: 'sp-tail', 'data-sp-tail': '' }, raw.join('\n'))) : null;
  if (details && failed) details.open = true;
  const what = failed
    ? h('div', { class: 'sp-failed', role: 'alert' },
      h('p', null, h('strong', null, name + ' did not start: '), (p && p.error) || o.text || 'the start failed'),
      h('div', { class: 'sp-acts' },
        btn('Start again', () => { (state.startDismissed = state.startDismissed || new Set()).add(o.id); paintStartProgress(); lifecycle('start', name); }, { primary: true, small: true, icon: 'play' }),
        btn('Dismiss', () => { (state.startDismissed = state.startDismissed || new Set()).add(o.id); paintStartProgress(); }, { small: true, quiet: true })))
    : null;
  return h('div', { class: 'start-progress' + (p ? ' building' : ''), 'data-start-progress': name, role: 'status', 'aria-live': 'polite' },
    h('div', { class: 'sp-box' },
      h('h3', null, failed ? 'Starting ' + name + ' failed' : p ? 'Preparing ' + (p.image || 'its image') + ' for ' + name : 'Starting ' + name + '…'),
      bar,
      h('ol', { class: 'sp-steps' }, ...steps, current),
      details, what));
}

/// Draw (or remove) the build panel over the terminal area of the sandbox this page shows. Cheap: called on every
/// operation and preparation event; a second ticker keeps the elapsed times moving.
export function paintStartProgress() {
  const root = document.getElementById('terminals');
  if (!root) return;
  const name = state.view === 'sandbox' ? state.param : null;
  let o = name ? startOf(name) : null;
  // The start was asked for (its transition, or the agent's terminal still waiting for it) but its operation is not —
  // or, for a moment, no longer — in the list (a stream snapshot older than the request): the panel stays, never a
  // blink of the empty area, until Console takes over.
  if (!o && name && !consoleUp(name) && ((transitionOf(name) || {}).action === 'start' || pageTerminals(name).some((t) => t.pending)))
    o = { id: 'start-' + name, state: 'running', progress: null, text: '' };
  // The VM is on: tab zero (Console) has the boot — the panel gives way (a failure stays, over it).
  if (o && o.state === 'running' && consoleUp(name)) o = null;
  const p = o ? prepOf(name, o) : null;
  paintStartPill(name);
  const have = root.querySelector(':scope > .start-progress');
  if (!o) {
    if (have) have.remove();
    root.classList.remove('starting');
    if (ticker) { clearInterval(ticker); ticker = null; }
    return;
  }
  const key = o.id + '|' + o.state + '|' + JSON.stringify(o.progress || null) + '|' + o.text + '|' + (p ? JSON.stringify([p.state, p.step, p.stepIndex, p.plannedSteps, p.transferLine, p.seconds, (p.output || []).length, p.error]) : '');
  if (!have || have.dataset.key !== key) {
    const el = panelFor(name, o, p);
    el.dataset.key = key;
    // Keep an open "Show details" open across redraws.
    if (have && have.querySelector('details[open]') && el.querySelector('details')) el.querySelector('details').open = true;
    if (have) have.replaceWith(el); else root.append(el);
  }
  root.classList.add('starting');
  if (!ticker && o.state === 'running') {
    ticker = setInterval(() => {
      for (const s of document.querySelectorAll('[data-sp-since], [data-sp-elapsed]')) {
        const v = s.dataset.spSince || s.dataset.spElapsed;
        if (v) s.textContent = elapsed(v);
      }
    }, 1000);
  }
}

/// The header's pill during a start: "Preparing…" while the image builds, "Booting…" once the VM is on.
function paintStartPill(name) {
  if (!name) return;
  for (const el of document.querySelectorAll('[data-pill-for][data-transition="start"]')) {
    if (el.dataset.pillFor !== name) continue;
    const word = startStage(name);
    const text = el.lastChild;
    if (text && text.nodeType === 3 && text.textContent.trim() !== word) text.textContent = ' ' + word;
  }
}
