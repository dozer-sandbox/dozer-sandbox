// components/callout — The callout (603) — the ONE notice surface.
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';

// ── 603: the callout — the ONE notice surface (info · ok · warn · bad; inline, compact, or the page's banner
// strip). An icon, an optional title, the body, actions at the right, an optional dismiss.
const TONE_ICON = { info: 'info', ok: 'circle-check', warn: 'triangle-alert', bad: 'circle-x' };
/**
 * @typedef {'info' | 'ok' | 'warn' | 'bad'} CalloutTone
 * @typedef {object} CalloutOptions
 * @property {string | Node} [title]
 * @property {string | Node | Array<string | Node>} [body]
 * @property {Array<Node | null | false>} [actions]   buttons at the right (falsy ones skipped)
 * @property {boolean | ((el: HTMLElement) => void)} [dismiss]   a ✕ that removes it (or calls this)
 * @property {boolean} [compact]
 * @property {boolean} [banner]    in the page's banner strip
 * @property {string}  [cls]       extra classes (the old hooks stay on elements)
 * @property {string}  [bodyCls]
 * @property {string}  [role]      default: alert for bad, else status
 * @property {Object<string, string>} [attrs]   extra attributes (data-*)
 * @property {string}  [icon]      a Lucide name instead of the tone's
 * @property {Node}    [glyph]     a node instead of the icon
 */
/**
 * @param {CalloutTone} tone
 * @param {CalloutOptions} [opts]
 * @returns {HTMLDivElement}
 */
export function callout(tone, opts = {}) {
  tone = tone || 'info';
  const el = h('div', { class: ['callout', tone, opts.compact ? 'compact' : '', opts.banner ? 'banner' : '', opts.cls || ''].filter(Boolean).join(' '),
                         role: opts.role || (tone === 'bad' ? 'alert' : 'status'), ...(opts.attrs || {}) });
  const acts = [...(opts.actions || [])].filter(Boolean);
  if (opts.dismiss) {
    acts.push(h('button', { type: 'button', class: 'btn sm quiet icon-only b-x', title: 'Dismiss', 'aria-label': 'Dismiss',
      on: { click: (ev) => { ev.stopPropagation(); if (typeof opts.dismiss === 'function') opts.dismiss(el); else el.remove(); } } }, icon('x')));
  }
  el.append(opts.glyph || icon(opts.icon || TONE_ICON[tone]),
    h('div', { class: 'c-body' + (opts.bodyCls ? ' ' + opts.bodyCls : '') }, opts.title ? h('div', { class: 'c-title' }, opts.title) : null, opts.body),
    ...(acts.length ? [h('div', { class: 'c-acts' }, acts)] : []));   // (append writes a null as the text "null")
  return el;
}
