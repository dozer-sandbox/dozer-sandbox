// components/button — The one button family (603).
import { h } from '../dom/h.js';
import { icon, iconFor, withIcon } from '../dom/icons.js';

/// A button: its icon (opts.icon, else the label's — `iconFor`) and its text label. 603: one family —
/// opts.primary (one per view), quiet (dense places), danger; small (24 px) or lg (32 px); iconOnly (the
/// label becomes its aria-label and tooltip — only where the icon is unambiguous).
/**
 * @typedef {object} ButtonOptions
 * @property {boolean} [primary]   the view's one primary (the verb that moves things forward)
 * @property {boolean} [quiet]     a quiet button (dense places)
 * @property {boolean} [danger]    a destructive verb
 * @property {boolean} [small]     24 px
 * @property {boolean} [lg]        32 px
 * @property {boolean} [iconOnly]  the label becomes its aria-label and tooltip (only where the icon is unambiguous)
 * @property {string}  [icon]      a Lucide name (else `iconFor(label)`)
 * @property {string}  [title]     its tooltip
 */
/**
 * @param {string} label
 * @param {(ev: MouseEvent) => void} onClick
 * @param {ButtonOptions} [opts]
 * @returns {HTMLButtonElement}
 */
export function btn(label, onClick, opts = {}) {
  const cls = ['btn'];
  if (opts.primary) cls.push('primary');
  if (opts.danger) cls.push('danger');
  if (opts.quiet) cls.push('quiet');
  if (opts.small) cls.push('sm');
  if (opts.lg) cls.push('lg');
  if (opts.iconOnly) cls.push('icon-only');
  return h('button', { type: 'button', class: cls.join(' '), title: opts.title || (opts.iconOnly ? label : null), 'aria-label': opts.iconOnly ? label : null,
                       on: { click: (ev) => { ev.stopPropagation(); onClick(ev); } } },
    opts.iconOnly ? icon(opts.icon || iconFor(label)) : withIcon(opts.icon || iconFor(label), label));
}
