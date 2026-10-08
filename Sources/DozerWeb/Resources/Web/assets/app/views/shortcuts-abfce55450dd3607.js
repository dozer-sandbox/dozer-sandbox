// views/shortcuts — Page shortcuts (603, owner decision 10): g s, /, ?.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { withIcon } from '../dom/icons-8392ebb8cb8879e3.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';

// ── 603: page shortcuts (owner decision 10 — only the guide's): g then s → Sandboxes, / → the Settings filter,
// ? → this list. Never while a terminal has the focus (its frame), nor in a field, a menu or a dialog.
const SHORTCUTS = [['g s', 'Sandboxes'], ['/', 'The Settings filter'], ['?', 'These shortcuts'], ['Esc', 'Close a menu or a dialog']];
let gPending = 0;
function shortcutsDialog() {
  const d = h('dialog', { class: 'dlg', 'aria-labelledby': 'sc-title' });
  const close = h('button', { type: 'button', class: 'btn quiet', on: { click: () => d.close() } }, withIcon('x', 'Close'));
  d.append(h('div', { class: 'dlg-head' }, h('h2', { class: 'h-title', id: 'sc-title' }, 'Keyboard shortcuts')),
    h('div', { class: 'dlg-body' }, h('dl', { class: 'facts' }, SHORTCUTS.flatMap(([k, what]) => [h('dt', null, k.split(' ').map((x) => h('kbd', null, x))), h('dd', null, what)])),
      h('p', { class: 'sub' }, 'Not while a terminal has the focus — there every key is the terminal’s. Tab moves between controls; arrow keys move within tabs, segmented controls and menus.')),
    h('div', { class: 'dlg-foot' }, close));
  d.addEventListener('close', () => d.remove());
  document.body.append(d);
  d.showModal();
  close.focus();
}
document.addEventListener('keydown', (ev) => {
  if (ev.defaultPrevented || ev.metaKey || ev.ctrlKey || ev.altKey || state.signedOut) return;
  const a = document.activeElement;
  if (a && (a.tagName === 'IFRAME' || a.closest('input, textarea, select, [contenteditable], dialog, .menu'))) return;
  if (document.querySelector('dialog[open]') || state.modal || document.body.classList.contains('ui-paused')) return;
  if (ev.key === 'g') { gPending = Date.now(); return; }
  if (ev.key === 's' && Date.now() - gPending < 1200) { gPending = 0; ev.preventDefault(); location.hash = '#/overview'; return; }
  gPending = 0;
  if (ev.key === '/') {
    ev.preventDefault();
    const focusFilter = () => { const f = document.querySelector('[data-settings-filter]'); if (f) { f.focus(); f.select(); return true; } return false; };
    if (!focusFilter()) { location.hash = '#/settings'; const t0 = Date.now(); const tick = () => { if (!focusFilter() && Date.now() - t0 < 4000) setTimeout(tick, 100); }; setTimeout(tick, 100); }
  } else if (ev.key === '?') { ev.preventDefault(); shortcutsDialog(); }
});
