// components/prep-card — An image preparation's progress (594).
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { approx, dur } from '../core/format-b2e68384da8d2f36.js';
import { prepRunning } from '../core/operations-c7eeae66c46d4582.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { determinate } from './blocks-53c969feeec8fe89.js';
import { callout } from './callout-48fdacc012091bbe.js';

/// 594: the host's image preparations — whoever asked (doz onboard, the wizard, a start): they run in
/// the host, not in this page, so they show here even when started from a terminal.
export function prepProgressText(p) {
  if (p.error) return p.error;
  if (!prepRunning(p)) return p.state === 'done' ? 'ready' : p.state;
  if (p.transferLine) return p.transferLine;
  if (p.step) return p.step + ' · ' + Math.round(p.stepSeconds || 0) + ' s';
  return p.lines.length ? p.lines[p.lines.length - 1] : 'starting…';
}
export function prepCard(p, opts = {}) {
  const running = prepRunning(p);
  const n = p.stepIndex || 0, m = p.plannedSteps;
  const done = running ? Math.max(0, n - 1) : n;
  const overall = m ? h('div', { class: 'prep-overall', 'data-step': String(n), 'data-steps': String(m) },
    h('div', { class: 'prep-overall-line' },
      h('span', null, 'Step ' + n + ' of ' + m),
      h('span', { class: 'muted prep-estimate' }, running
        ? (p.remainingSeconds != null ? 'about ' + approx(p.remainingSeconds).slice(1) + ' left' : (p.estimateBasis || ''))
        : '')),
    determinate(done / m, 'prep-overall-bar', 'steps done')) : null;
  const current = running && p.step ? h('div', { class: 'prep-current' },
    h('div', { class: 'prep-step' }, h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), ' ', p.step,
      h('span', { class: 'muted' }, '  ' + dur(p.stepSeconds || 0) + (p.stepUsualSeconds != null ? ' · usually ' + approx(p.stepUsualSeconds) : ''))),
    h('div', { class: 'wiz-bar indeterminate prep-step-bar', 'aria-hidden': 'true' }, h('span'))) : null;
  const pulling = running && p.transferLine && (p.transferFraction == null || p.transferFraction < 1);
  const transfer = pulling ? h('div', { class: 'prep-transfer-block' },
    p.transferFraction != null ? determinate(p.transferFraction, 'prep-transfer-bar', 'downloaded') : null,
    h('div', { class: 'mono prep-transfer' }, p.transferLine)) : null;
  const tail = running && p.output.length ? h('div', { class: 'mono prep-output', 'data-tail': String(p.output.length) },
    p.output.map((l) => h('div', null, '│ ' + l))) : null;
  const items = p.steps.map((s) => h('li', { class: 'prep-done-' + s.kind },
    h('span', { class: 'op-state' }, s.kind === 'failed' ? '✕' : s.kind === 'transfer' ? '↓' : '✓'), ' ', s.label,
    h('span', { class: 'muted' }, s.kind === 'transfer' ? '' : ' — ' + dur(s.seconds) + (s.usualSeconds != null ? ' (last time ' + dur(s.usualSeconds) + ')' : '')),
    s.error ? h('div', { class: 'st-fail' }, s.error) : null,
    s.output ? h('div', { class: 'mono prep-output' }, s.output.map((l) => h('div', null, '│ ' + l))) : null));
  const key = 'prep-open-' + p.id;
  const details = items.length ? h('details', { class: 'prep-lines' },
    h('summary', null, 'Finished steps (' + p.steps.filter((s) => s.kind !== 'transfer').length + ')'),
    h('ul', { class: 'prep-steps' }, items)) : null;
  if (details) {
    const want = state[key] ?? !!opts.open;
    if (want) details.open = true;
    details.addEventListener('toggle', () => { state[key] = details.open; });
  }
  return h('div', { class: 'prep-card prep-' + p.state, 'data-prep': p.image },
    h('div', { class: 'prep-head' }, running ? h('span', { class: 'mini-spin', 'aria-hidden': 'true' }) : h('span', { class: 'op-state' }, p.state === 'done' ? '✓' : '✕'),
      h('strong', null, p.image), h('span', { class: 'muted' }, ' · ' + (running ? dur(p.seconds) + ' so far' : p.state + ' in ' + dur(p.seconds)) + ' · asked by ' + p.requestedBy.join(', '))),
    overall, current, transfer, tail,
    p.error && p.state !== 'cancelled' ? callout('bad', { compact: true, cls: 'notice', body: p.error }) : null,
    running && p.estimateBasis && p.remainingSeconds == null && !m ? h('div', { class: 'muted' }, p.estimateBasis) : null,
    details);
}
