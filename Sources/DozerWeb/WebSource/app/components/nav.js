// components/nav — The sidebar: a child per sandbox (593), the rail, the Resources total.
import { upcall } from '../core/hooks.js';
import { $, h } from '../dom/h.js';
import { api } from '../core/api.js';
import { bytes } from '../core/format.js';
import { state } from '../core/state.js';
import { agentDot, paintAgentStatuses } from './agent-status.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const renderHostFoot = upcall('renderHostFoot');

// ── the nav: a child per sandbox (593) ──────────────────────────────────────
// From the overview (`ls` without session counts — never the guest's session holders), re-read on
// the stream's hello, on `changed`, and when an operation ends. Text only.
let navTimer = null;
export function refreshNav() {
  clearTimeout(navTimer);
  navTimer = setTimeout(async () => {
    try { state.overview = await api('overview'); renderNavSandboxes(); } catch (_) { /* the last list */ }
  }, 300);
}
export function renderNavSandboxes() {
  // 594 (owner: "add a link to Onboarding in the left nav"): a dot until this store is onboarded.
  if (state.overview) $('onb-dot').hidden = state.overview.onboarded !== false;
  renderHostFoot();
  const list = state.overview ? state.overview.sandboxes.slice().sort((a, b) => a.name.localeCompare(b.name)) : [];
  $('nav-count').textContent = state.overview ? String(list.length) : '';
  // 603: each sandbox under "All sandboxes", its phase as a dot whose shape says whether it holds RAM (and
  // its word for assistive tech and the tooltip); the one shown is the page's current item.
  $('nav-sandboxes').replaceChildren(...list.map((s) => {
    const here = !state.modal && state.view === 'sandbox' && state.param === s.name;
    return h('a', { href: '#/sandbox/' + s.name, class: 'nav-child child' + (here ? ' active' : ''), 'aria-current': here ? 'page' : null,
      role: 'listitem', 'data-sandbox': s.name, title: s.name + ' — ' + s.phaseLabel },
      h('span', { class: 'ph-dot ph-' + s.phase, role: 'img', 'aria-label': s.phaseLabel }), h('span', { class: 'nav-name' }, s.name),
      agentDot(s));                                  // 612: its most urgent agent, when one says something
  }));
  paintAgentStatuses();                              // 612: the chips on screen, and a notice per change
}
export function paintNav() {
  for (const a of document.querySelectorAll('#nav > a')) {
    // A sandbox's own page marks its child entry; New sandbox belongs to All sandboxes.
    // (603: an open wizard's entry — Onboarding, or All sandboxes for New sandbox — marks the nav under its modal.)
    const cur = state.modal === 'onboarding' ? 'onboarding' : state.modal === 'new' ? 'overview' : state.view;
    const on = a.dataset.view === cur;
    a.classList.toggle('active', on);
    if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
  renderNavSandboxes();
  navRail(false);
}
/// 603: below 980 px the sidebar is an icon rail; its toggle shows the whole sidebar over the page.
export function navRail(open) {
  document.body.classList.toggle('nav-open', !!open);
  $('nav-toggle').setAttribute('aria-expanded', open ? 'true' : 'false');
  $('nav-toggle').setAttribute('aria-label', open ? 'Hide the menu' : 'Show the menu');
}
export function paintResTotal(r) {
  const el = $('res-total');
  if (!el || !r) return;
  el.hidden = false;
  el.textContent = bytes(r.totalBytes);
  el.title = 'Dozer uses ' + bytes(r.totalBytes) + ' of disk' + (r.unattributedBytes ? ' — ' + bytes(r.unattributedBytes) + ' unattributed' : '');
  el.classList.toggle('bad', r.unattributedBytes !== 0);
}
