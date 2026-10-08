// components/modal — The wizards' modal (603): a real dialog over the page under it.
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { MODAL_VIEWS } from '../core/router-2585451a20eecb0b.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { WIZ } from '../core/wizards-f3940647fbf5e4d3.js';
import { btn } from './button-8e61dd531eed2262.js';
import { callout } from './callout-295f8e0570c7e239.js';
import { dialog } from './dialog-d48442e03113646f.js';
import { paintNav } from './nav-3b52fa2a6a2a895b.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const viewNew = upcall('viewNew'), viewOnboarding = upcall('viewOnboarding'),
  wizardStopPolling = upcall('wizardStopPolling');

// ── 603: the wizards' modal ─────────────────────────────────────────────────
// A real dialog (role=dialog, aria-modal, labelled by the wizard's title): the rest of the page is inert while it
// is open, focus moves in and is kept there (Tab wraps), and returns to what opened it. ✕ or Escape (not inside a
// field or a list) closes it — after asking, when the person has made choices; the browser's Back closes it and
// KEEPS the choices (Forward, or the wizard's entry, resumes them).
const MODAL_INERT = ['side', 'banners', 'notice', 'view', 'sbx', 'grid'];
export function modalInert(on) {
  if (!on && state.uiOverlay) return;                  // the "doz ui stopped" overlay keeps everything inert
  for (const id of MODAL_INERT) { const el = id === 'side' ? document.querySelector('.side') : $(id); if (el) el.inert = on; }
}
export function openWizardModal(v, fromPage) {
  const was = state.modal;
  state.modal = v;
  if (!was) {
    const a = document.activeElement;
    state.modalOpener = a && a !== document.body && !$('wiz-modal').contains(a) ? a : null;
    // A live update may re-render the opener's section meanwhile: then its successor (same place, same name) gets focus.
    state.modalOpenerKey = state.modalOpener ? { sec: state.modalOpener.closest('section[id], aside[id], nav[id], .side'), name: accName(state.modalOpener) } : null;
    state.modalBack = !!fromPage;          // opened from a page of this tab: closing goes back in the history
    modalInert(true);
    $('wiz-modal').hidden = false;
    document.body.classList.add('modal-open');
  }
  paintNav();
  if (was !== v || !$('wm-box').firstChild) renderModal(true);
}
export function closeWizardModal() {
  if (!state.modal) return;
  if (state.modal === 'onboarding') wizardStopPolling();
  state.modal = null;
  $('wiz-modal').hidden = true;
  $('wm-box').replaceChildren();
  document.body.classList.remove('modal-open');
  modalInert(false);
  paintNav();
  const o = state.modalOpener, k = state.modalOpenerKey;
  state.modalOpener = null; state.modalOpenerKey = null;
  const usable = (e) => e && e.isConnected && !e.closest('[inert]') && e.getClientRects().length > 0;
  const heir = !usable(o) && k && k.sec && k.sec.isConnected && k.name
    ? [...k.sec.querySelectorAll('button, a[href], [tabindex]')].find((e) => usable(e) && accName(e) === k.name) : null;
  (usable(o) ? o : heir || $('main')).focus();
}
function accName(e) { return (e.getAttribute('aria-label') || e.textContent || '').replace(/\s+/g, ' ').trim(); }
export async function renderModal(first) {
  const v = state.modal;
  if (!v) return;
  let node;
  try { node = v === 'new' ? await viewNew() : await viewOnboarding(); } catch (e) {
    node = h('div', { class: 'wizard' }, wizHead(v === 'new' ? 'New sandbox' : 'Set up Dozer Sandbox', null, [], null),
      h('div', { class: 'wiz-card' }, h('div', { class: 'w-body' }, callout('bad', { cls: 'notice', title: 'This could not be read', body: e.message || String(e) }))));
  }
  if (state.modal !== v || state.signedOut) return;
  wizMount(node, first);
}
/// Put a wizard's node in the modal: the current step scrolled into the strip's view; focus on the step's first
/// field (or the dialog itself) when it opens or the step changes.
export function wizMount(node, focus) {
  const box = $('wm-box');
  box.replaceChildren(node);
  const strip = box.querySelector('.wm-steps ol');
  const cur = strip && strip.querySelector('li.current');
  if (cur) strip.scrollLeft = Math.max(0, cur.offsetLeft - (strip.clientWidth - cur.offsetWidth) / 2);
  if (!focus) return;
  const f = box.querySelector('.w-body input:not([type=hidden]):not([disabled]):not([type=radio]), .w-body select, .w-body textarea, .w-body button.base-card');
  (f || box).focus();
}
/// The modal's header: the title (its label), what the wizard offers there, ✕; the step strip under it.
export function wizHead(title, sub, actions, steps) {
  return h('header', { class: 'wm-head' },
    h('div', { class: 'wm-title-row' }, h('h1', { id: 'wm-title' }, title), h('span', { class: 'wm-gap' }), ...actions,
      ((b) => { b.dataset.wmClose = ''; return b; })(btn('Close', () => wizardCloseRequest(), { quiet: true, iconOnly: true, icon: 'x', title: 'Close (Esc)' }))),
    sub ? h('p', { class: 'sub wm-sub' }, sub) : null,
    steps ? h('nav', { class: 'wm-steps', 'aria-label': 'Steps' }, steps.compact, steps.list) : null);
}
/// Has the person chosen anything a close would lose? (A made sandbox, or a store already prepared, loses nothing.)
function wizDirty() {
  if (state.modal === 'new') {
    const nw = state.nw;
    return !!nw && !nw.tools && (nw.step > 0 || !!nw.form || nw.explicit.size > 0 || nw.path !== nw.initPath || nw.newName !== nw.initName || nw.mode !== nw.initMode);
  }
  if (state.modal === 'onboarding') { const w = state.wiz; return !!w && w.step > WIZ.checks && w.step < WIZ.preparing; }
  return false;
}
function wizardCloseRequest() {
  if (!state.modal) return;
  const leave = () => {
    if (state.modal === 'new') state.nw = null; else if (state.modal === 'onboarding') state.wiz = null;
    if (state.modalBack) history.back(); else location.replace(state.bgHash && !MODAL_VIEWS.has(state.bgHash.slice(2)) ? state.bgHash : '#/overview');
  };
  if (!wizDirty()) { leave(); return; }
  dialog(state.modal === 'new' ? 'Discard this new sandbox?' : 'Stop setting up?',
    state.modal === 'new' ? 'Nothing is written yet: closing forgets the choices made so far.'
      : 'Nothing is written yet: closing forgets the choices made so far. Onboarding can be run again from the sidebar.',
    [], 'Discard', async () => { leave(); }, { danger: true, icon: 'x' });
}
// Keyboard: Escape closes (asking first when needed) — never from inside a field, a list or a menu; Tab wraps.
$('wm-box').addEventListener('keydown', (ev) => {
  if (ev.key === 'Escape') {
    if (ev.defaultPrevented || ev.target.closest('input, select, textarea, [contenteditable], .menu')) return;
    ev.preventDefault();
    wizardCloseRequest();
    return;
  }
  if (ev.key !== 'Tab') return;
  const box = $('wm-box');
  const f = [...box.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), select:not([disabled]), textarea:not([disabled]), summary, [tabindex]:not([tabindex="-1"])')]
    .filter((e) => e.getClientRects().length > 0);
  if (!f.length) { ev.preventDefault(); box.focus(); return; }
  const first = f[0], last = f[f.length - 1], a = document.activeElement;
  if (ev.shiftKey && (a === first || a === box)) { ev.preventDefault(); last.focus(); }
  else if (!ev.shiftKey && a === last) { ev.preventDefault(); first.focus(); }
});
$('wm-scrim').addEventListener('click', () => { const b = $('wm-box'); (b.querySelector('[data-wm-close]') || b).focus(); });
