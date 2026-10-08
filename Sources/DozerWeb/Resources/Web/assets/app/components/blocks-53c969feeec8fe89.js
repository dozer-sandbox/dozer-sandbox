// components/blocks — Building blocks: card, table, panel, meter, chip, stat, the page index, a progress bar.
import { h } from '../dom/h-d909ae8eb40113fe.js';

/// 603 (E13): a long page's index — a sticky strip of its sections (with a figure each when given); a link scrolls.
export function pageIndex(items) {
  return h('nav', { class: 'page-index', 'aria-label': 'On this page' }, items.map(([id, label, figure]) =>
    h('a', { href: '#' + (location.hash.slice(1) || '/'), 'data-index': id, on: { click: (ev) => {
      ev.preventDefault();
      const t = document.getElementById(id);
      if (t) { t.scrollIntoView({ block: 'start', behavior: 'smooth' }); }
    } } }, label, figure ? h('span', { class: 'muted' }, ' ' + figure) : null)));
}

// ── building blocks ─────────────────────────────────────────────────────────
/// 603: a figure in a stats strip (one band, not separate cards).
export function card(k, v, n) { return h('div', { class: 'stat' }, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v), n ? h('div', { class: 'n', title: typeof n === 'string' ? n : null }, n) : null); }
export function table(head, rows, numeric = []) {
  if (!rows.length) return null;
  return h('table', null,
    h('thead', null, h('tr', null, head.map((c, i) => h('th', { class: numeric.includes(i) ? 'num' : null }, c)))),
    h('tbody', null, rows));
}
export function panel(content, emptyText) { return h('div', { class: 'panel' }, content || h('div', { class: 'empty' }, emptyText || 'Nothing here.')); }
export function meter(part, whole) {
  const pct = whole > 0 ? Math.max(0, Math.min(100, (part / whole) * 100)) : 0;
  const bar = h('span');
  bar.style.width = pct.toFixed(1) + '%';
  return h('div', { class: 'meter', title: pct.toFixed(0) + '% of the allocation' }, bar);
}
export function chip(k, v, attrs = {}) {
  return h(attrs.onClick ? 'button' : 'span', { class: 'chip-kv', type: attrs.onClick ? 'button' : null, title: attrs.title || null, ...(attrs.data || {}),
    on: attrs.onClick ? { click: attrs.onClick } : null }, h('span', { class: 'k' }, k), v);
}
/// A stat in a strip (it replaces separate cards).
export function stat(k, v, n) { return h('div', { class: 'stat' }, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v), n ? h('div', { class: 'n', title: n }, n) : null); }
export function determinate(fraction, cls, label) {
  const bar = h('div', { class: 'wiz-bar ' + (cls || ''), role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-label': label || null,
                         'aria-valuenow': (fraction * 100).toFixed(0), 'data-fraction': fraction.toFixed(3) });
  const fill = h('span');
  fill.style.width = (Math.max(0, Math.min(1, fraction)) * 100).toFixed(1) + '%';
  bar.append(fill);
  return bar;
}
