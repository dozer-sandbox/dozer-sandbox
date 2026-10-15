// components/pills — Pills: a phase, a status, a sandbox in transition.
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, PHASE_GLYPH } from '../dom/icons-2b30ba761d2d921b.js';
import { TRANSITION_LABEL, transitionOf } from '../core/operations-56949f5379c9806f.js';
import { state } from '../core/state-450cb6573a620304.js';
import { terminals } from '../core/terminals-933851e9be49078e.js';
import { startStage } from './start-progress-b16374ebc7173de4.js';
import { paintCover } from './terminal-626bae4b7cf1f181.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const paintTermEmpty = upcall('paintTermEmpty');

/// 603: a pill is a state — tinted, a glyph and the word (never colour alone); the glyph is the phase's own
/// (a dot while it runs, a spinner while under way).
function phaseGlyph(phase, busy) {
  if (busy || phase === 'booting') return h('span', { class: 'mini-spin', 'aria-hidden': 'true' });
  if (phase === 'running') return h('span', { class: 'dot ph-running', 'aria-hidden': 'true' });
  const g = phase === 'failed' ? 'x' : PHASE_GLYPH[phase];
  return g ? icon(g) : null;
}
export function phasePill(phase, label, busy) {
  return h('span', { class: 'pill ph-' + phase }, phaseGlyph(phase, busy), (label || phase) + (busy ? ' …' : ''));
}
const STATUS_GLYPH = { ok: 'check', warn: 'triangle-alert', fail: 'x', off: 'power' };
export function statusPill(s) { return h('span', { class: 'pill st-' + s }, STATUS_GLYPH[s] ? icon(STATUS_GLYPH[s]) : null, s); }
function transitionPill(t, name) {
  return h('span', { class: 'pill ph-busy', 'data-pill-for': name, 'data-transition': t.action },
    h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), ' ' + (t.action === 'start' ? startStage(name) : TRANSITION_LABEL[t.action]));   // 617: preparing, then booting
}
/// Put a sandbox into its transition where it is shown NOW — in place, no re-render: its pills say so
/// and its lifecycle buttons are disabled (nothing is swapped).
export function paintTransition(name) {
  const t = state.transitions.get(name);
  if (!t) return;
  for (const el of document.querySelectorAll('[data-lifecycle-for]')) {
    if (el.dataset.lifecycleFor !== name) continue;
    for (const b of el.querySelectorAll('button')) { b.disabled = true; b.title = TRANSITION_LABEL[t.action]; }
  }
  // 603: the ⋯ menu's Reset… and Remove… too.
  for (const b of document.querySelectorAll('[data-lifecycle-item]')) if (b.dataset.lifecycleItem === name) b.disabled = true;
  for (const el of document.querySelectorAll('[data-pill-for]')) if (el.dataset.pillFor === name) el.replaceWith(transitionPill(t, name));
  for (const x of terminals.values()) if (x.sandbox === name && x.saved) paintCover(x);
  if (state.view === 'sandbox' && state.param === name) paintTermEmpty();
}
/// The phase pill — or, in a transition, what is under way.
export function sandboxPill(s) {
  const tr = transitionOf(s.name);
  if (tr) return transitionPill(tr, s.name);
  const p = phasePill(s.phase, s.phaseLabel, s.busy);
  p.dataset.pillFor = s.name;
  return p;
}
