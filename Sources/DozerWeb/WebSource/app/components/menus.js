// components/menus — Menus (603): a button that opens a menu (⋯ overflow, a split button's caret).
import { h } from '../dom/h.js';
import { icon, iconFor } from '../dom/icons.js';

// ── 603: menus — a button that opens a menu (⋯ overflow, a split button's caret). The menu is in the DOM
// (hidden) beside its button, so what it holds is findable; open, it is fixed to the viewport, placed below
// (or above) the button and kept on screen. Arrow keys, Home/End move; Escape (or Tab) closes and gives the
// focus back; a click outside closes. Items:
//   { label, icon, desc, danger, disabled, why, check, data: {k: v}, onSelect }  ·  { sep: true }  ·  { heading }
// A disabled item stays visible and says why (its `why` is its description line).
const menus = new Set();
function menuItemsNodes(items, close) {
  return items.filter(Boolean).map((it) => {
    if (it.sep) return h('div', { class: 'menu-sep', role: 'separator' });
    if (it.heading) return h('div', { class: 'menu-label' }, it.heading);
    const attrs = { type: 'button', role: 'menuitem', tabindex: '-1', class: 'menu-item' + (it.danger ? ' danger' : '') };
    for (const [k, v] of Object.entries(it.data || {})) attrs['data-' + k] = v;
    // The one-line description (or why it is disabled) is drawn by CSS from data-desc, so an item's text is
    // exactly its label; assistive tech gets it as the description.
    const desc = (it.disabled ? it.why : null) || it.desc || null;
    if (desc) { attrs['data-desc'] = desc; attrs['aria-description'] = desc; }
    const b = h('button', attrs, icon(it.icon || iconFor(it.label)), h('span', { class: 'mi-label' }, it.label),
      it.check ? h('span', { class: 'menu-check', 'aria-hidden': 'true' }, icon('check')) : null);
    if (it.check) b.setAttribute('aria-checked', 'true');
    if (it.disabled) b.disabled = true;
    b.addEventListener('click', (ev) => { ev.stopPropagation(); if (b.disabled) return; close(true); it.onSelect && it.onSelect(ev); });
    return b;
  });
}
/**
 * @typedef {object} MenuItem
 * @property {string} [label]
 * @property {string} [icon]        a Lucide name (else `iconFor(label)`)
 * @property {string} [desc]        its one-line description (drawn from data-desc)
 * @property {boolean} [danger]     destructive items last
 * @property {boolean} [disabled]
 * @property {string} [why]         why it is disabled (its description line)
 * @property {boolean} [check]      a checked item
 * @property {Object<string, string>} [data]   data-* attributes
 * @property {(ev: MouseEvent) => void} [onSelect]
 * @property {boolean} [sep]        a separator
 * @property {string} [heading]     a heading
 * @typedef {object} MenuOptions
 * @property {string} [label]       the menu's aria-label (else the trigger's)
 * @property {HTMLElement} [wrap]   the element the menu goes in (else a span around the trigger)
 * @property {'start' | 'end'} [align]
 * @property {() => void} [onOpen]
 * @property {() => void} [onClose]
 * @property {boolean} [small]      moreMenu: a 24 px ⋯
 * @property {Object<string, string>} [data]   moreMenu: the ⋯ button's data-*
 */
/**
 * @param {HTMLElement} trigger
 * @param {Array<MenuItem | null | false>} items
 * @param {MenuOptions} [opts]
 */
export function menuButton(trigger, items, opts = {}) {
  const menu = h('div', { class: 'menu', role: 'menu', hidden: true, 'aria-label': opts.label || trigger.getAttribute('aria-label') || trigger.textContent.trim() });
  const wrap = opts.wrap || h('span', { class: 'menu-wrap' });
  trigger.setAttribute('aria-haspopup', 'menu');
  trigger.setAttribute('aria-expanded', 'false');
  const ctl = { el: wrap, button: trigger, menu, open, close, setItems, isOpen: () => !menu.hidden };
  function place() {
    const r = trigger.getBoundingClientRect(), m = 8;
    menu.style.left = '0px'; menu.style.top = '0px';
    const w = menu.offsetWidth, hgt = menu.offsetHeight;
    let left = opts.align === 'end' ? r.right - w : r.left;
    if (left + w > innerWidth - m) left = r.right - w;
    left = Math.max(m, Math.min(left, innerWidth - w - m));
    let top = r.bottom + 4;
    if (top + hgt > innerHeight - m && r.top - 4 - hgt >= m) top = r.top - 4 - hgt;
    top = Math.max(m, Math.min(top, innerHeight - hgt - m));
    menu.style.left = Math.round(left) + 'px'; menu.style.top = Math.round(top) + 'px';
  }
  function items_() { return [...menu.querySelectorAll('.menu-item:not(:disabled)')]; }
  function open(focusFirst) {
    for (const o of menus) if (o !== ctl) o.close();
    menu.hidden = false;
    trigger.setAttribute('aria-expanded', 'true');
    place();
    if (focusFirst) { const f = items_()[0]; if (f) f.focus(); }
    if (opts.onOpen) opts.onOpen();
  }
  function close(refocus) {
    if (menu.hidden) return;
    menu.hidden = true;
    trigger.setAttribute('aria-expanded', 'false');
    if (refocus && trigger.isConnected) trigger.focus();
    if (opts.onClose) opts.onClose();
  }
  function setItems(list) { menu.replaceChildren(...menuItemsNodes(list, close)); if (!menu.hidden) place(); }
  trigger.addEventListener('click', (ev) => { ev.stopPropagation(); if (menu.hidden) open(ev.detail === 0); else close(false); });
  trigger.addEventListener('keydown', (ev) => { if (ev.key === 'ArrowDown') { ev.preventDefault(); open(true); } });
  menu.addEventListener('keydown', (ev) => {
    const list = items_(), i = list.indexOf(document.activeElement);
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') { ev.preventDefault(); const n = list.length; if (n) list[(i + (ev.key === 'ArrowDown' ? 1 : n - 1) + (i < 0 ? 1 : 0)) % n].focus(); }
    else if (ev.key === 'Home' || ev.key === 'End') { ev.preventDefault(); const f = ev.key === 'Home' ? list[0] : list[list.length - 1]; if (f) f.focus(); }
    else if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); close(true); }
    else if (ev.key === 'Tab') close(false);
  });
  menu.addEventListener('click', (ev) => ev.stopPropagation());
  setItems(items);
  if (!opts.wrap) wrap.append(trigger);
  wrap.append(menu);
  menus.add(ctl);
  return ctl;
}
/// The ⋯ button: an icon-only quiet button that opens `items`.
/**
 * The ⋯ overflow menu.
 * @param {string} label   its aria-label and tooltip
 * @param {Array<MenuItem | null | false>} items
 * @param {MenuOptions} [opts]
 */
export function moreMenu(label, items, opts = {}) {
  const b = h('button', { type: 'button', class: 'btn quiet icon-only' + (opts.small ? ' sm' : ''), 'aria-label': label, title: label }, icon('ellipsis'));
  if (opts.data) for (const [k, v] of Object.entries(opts.data)) b.dataset[k] = v;
  return menuButton(b, items, { align: 'end', ...opts });
}
document.addEventListener('click', () => { for (const m of menus) { if (!m.el.isConnected) menus.delete(m); else m.close(false); } });
window.addEventListener('resize', () => { for (const m of menus) m.close(false); });
document.addEventListener('scroll', (ev) => { for (const m of menus) if (!m.menu.contains(ev.target)) m.close(false); }, true);
