// dom/icons — Icons (593): Lucide symbols from the one generated sprite; one map says which icon a label gets.
import { h } from './h-d909ae8eb40113fe.js';

// ── icons (593): Lucide (lucide-static, ISC — vendored and pinned; one generated sprite, a same-origin
// asset). An icon is <svg class="icon"><use href="SPRITE#name"></svg>, made with createElementNS; its
// colour is the button's (stroke: currentColor, in app.css) and it is hidden from assistive tech —
// every button keeps its text (or its aria-label). One map says which icon a label gets.
export const SVG_NS = 'http://www.w3.org/2000/svg';
const SPRITE = (() => { const m = document.querySelector('meta[name="doz-icons"]'); return m ? m.getAttribute('content') : ''; })();
const ICON_FALLBACK = 'circle-dot';
/// 593 (owner): Sleep and Hibernate are told apart by a second glyph — Sleep keeps the machine in
/// memory (a CPU), Hibernate frees it and keeps the state on disk (a cylinder — storage). Used
/// wherever those states show.
const ICON_SLEEP = 'moon+cpu', ICON_HIBERNATE = 'moon+cylinder';
/// A phase (or a cover's kind) → its glyph, where it has one.
export const PHASE_GLYPH = { paused: 'pause', asleep: ICON_SLEEP, hibernated: ICON_HIBERNATE, off: 'power', shutDown: 'power' };
/// An operation's action → its glyph (the lifecycle verbs; the rest have none).
export const OP_GLYPH = { start: 'play', pause: 'pause', resume: 'play', sleep: ICON_SLEEP, hibernate: ICON_HIBERNATE, wake: 'sun',
                   shutdown: 'power', reset: 'rotate-ccw', rm: 'trash-2', duplicate: 'copy', 'template-create': 'layout-template' };
/// `name`, or a pair `a+b`: a glyph drawn as two icons side by side (both hidden, one tight group).
export function icon(name) {
  if (name.includes('+')) {
    const g = h('span', { class: 'icon-pair', 'aria-hidden': 'true', 'data-icon': name });
    for (const n of name.split('+')) g.append(icon(n));
    return g;
  }
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('class', 'icon');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.setAttribute('data-icon', name);
  const use = document.createElementNS(SVG_NS, 'use');
  use.setAttribute('href', SPRITE + '#' + name);
  svg.append(use);
  return svg;
}
/// A label's icon: the exact label, else its first word; the fallback is a visible "missing" (the probe fails on it).
const ICON_EXACT = {
  'open in terminal': 'square-terminal', 'set the default to none': 'ban', 'make default': 'star', 'save as template…': 'layout-template',
  'save template': 'layout-template', 'hide details': 'panel-right', 'details': 'panel-right', 'take a restore point…': 'camera', 'take': 'camera',
  'key policy…': 'key-round', 'account…': 'user-round', 'edit policy…': 'shield', 'terminal…': 'terminal', 'new shell': 'plus',
  'new sandbox': 'plus', 'run detached…': 'play', 'default': 'rotate-ccw', 'apply anyway': 'check', 'download csv': 'download',
  'shut down': 'power', 'sign out': 'log-out', 'unsplit': 'columns-2',
  // 594: the onboarding wizard.
  'get started': 'rocket', 'run onboarding again': 'rocket', 'check again': 'refresh-cw', 'next': 'arrow-right', 'back': 'arrow-left',
  'continue in the background': 'layers', 'skip': 'skip-forward', 'open sandboxes': 'box', 'prepare and continue': 'flame',
  'cancel preparation': 'x', 'create sandbox': 'plus', 'try again': 'refresh-cw', 'continue': 'arrow-right',
  'look again': 'refresh-cw', 'sign up': 'check',
};
const ICON_WORD = {
  start: 'play', pause: 'pause', resume: 'play', sleep: ICON_SLEEP, hibernate: ICON_HIBERNATE, wake: 'sun', reset: 'rotate-ccw', remove: 'trash-2', delete: 'trash-2',
  open: 'terminal', split: 'columns-2', duplicate: 'copy', revert: 'history', fork: 'git-fork', copy: 'clipboard', copied: 'check',
  select: 'clipboard', refresh: 'refresh-cw', create: 'plus', bake: 'flame', 're-bake': 'flame', verify: 'badge-check', watch: 'eye',
  set: 'check', use: 'check', run: 'play', save: 'layout-template', preview: 'eye', apply: 'check', cancel: 'x', paste: 'clipboard-paste',
  reconnect: 'refresh-cw', table: 'table', lineage: 'list-tree', shut: 'power', attach: 'link', close: 'x',
};
export function iconFor(label) {
  const l = String(label).trim().toLowerCase();
  return ICON_EXACT[l] || ICON_WORD[l.split(/\s+/)[0].replace(/[…:.,]+$/, '')] || ICON_FALLBACK;
}
/// A button's label with its icon in front (the label stays text).
export function withIcon(name, label) { return [icon(name), h('span', { class: 'btn-label' }, label)]; }
/// Put (or replace) the icon of an existing button, keeping its text (an icon-only button: its aria-label).
export function setButton(b, label, name) {
  if (b.classList.contains('icon-only')) { b.replaceChildren(icon(name || iconFor(label))); b.setAttribute('aria-label', label); b.title = b.title || label; return; }
  b.replaceChildren(...withIcon(name || iconFor(label), label));
}
