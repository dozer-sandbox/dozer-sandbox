// components/pills — Pills: a phase, a status, a sandbox in transition.
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, PHASE_GLYPH } from '../dom/icons-8392ebb8cb8879e3.js';
import { TRANSITION_LABEL, transitionOf } from '../core/operations-d824956fc29841f7.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { terminals } from '../core/terminals-fa5cf7fc28fdb48f.js';
import { paintCover } from './terminal-154bdbfa793b8202.js';
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
    h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), ' ' + TRANSITION_LABEL[t.action]);
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
