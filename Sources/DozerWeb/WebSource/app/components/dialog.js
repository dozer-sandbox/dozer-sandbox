// components/dialog — Dialogs: forms live outside the view, so a live refresh never wipes what is being typed.
import { h } from '../dom/h.js';
import { icon, iconFor, withIcon } from '../dom/icons.js';
import { actOrThrow } from '../core/operations.js';

// ── dialogs (forms live outside the view) ───────────────────────────────────
// fields: [{name, label, type: text|number|select|textarea|checkbox, options, value, placeholder, help, required}]
/**
 * @typedef {object} DialogField
 * @property {string} name
 * @property {string} [label]
 * @property {'text' | 'number' | 'select' | 'textarea' | 'checkbox' | 'password' | 'custom'} [type]   default text
 * @property {Array<string | [string, string]>} [options]   a select's values (or [value, label])
 * @property {string | number | boolean} [value]
 * @property {string} [placeholder]
 * @property {string} [help]
 * @property {boolean} [required]
 * @property {number} [min]
 * @property {number} [max]
 * @property {HTMLElement} [el]          a custom field's element
 * @property {() => unknown} [get]       a custom field's value
 * @typedef {object} DialogOptions
 * @property {boolean} [danger]          the submit button is destructive
 * @property {string}  [icon]            the submit button's icon (else `iconFor(submitLabel)`)
 * @property {string}  [confirmCheck]    617: the person ticks this sentence before submit is enabled (no typing)
 * @typedef {{ extra: HTMLElement, error: HTMLElement, submit: HTMLButtonElement }} DialogParts
 */
/**
 * @param {string} title
 * @param {string | null} intro
 * @param {DialogField[]} fields
 * @param {string} submitLabel
 * @param {(values: Object<string, any>, parts: DialogParts) => Promise<unknown>} onSubmit   'keep-open' keeps it open
 * @param {DialogOptions} [opts]
 * @returns {HTMLDialogElement & { inputs: Object<string, HTMLInputElement>, why: HTMLElement }}
 */
export function dialog(title, intro, fields, submitLabel, onSubmit, opts = {}) {
  const d = h('dialog', { class: 'dlg' });
  const form = h('form', { method: 'dialog' });
  const inputs = {};
  const customs = {};
  const rows = fields.map((f) => {
    // 594: a composite field (the workspace chooser) brings its own element and its value.
    if (f.type === 'custom') { customs[f.name] = f.get; return f.el; }
    let input;
    if (f.type === 'select') {
      input = h('select', { name: f.name }, f.options.map((o) => {
        const [v, l] = Array.isArray(o) ? o : [o, o];
        const opt = h('option', { value: v }, l);
        if (String(v) === String(f.value ?? '')) opt.selected = true;
        return opt;
      }));
    } else if (f.type === 'textarea') {
      input = h('textarea', { name: f.name, rows: 3, placeholder: f.placeholder || null, spellcheck: 'false' });
      input.value = f.value || '';
    } else if (f.type === 'checkbox') {
      input = h('input', { type: 'checkbox', name: f.name });
      input.checked = !!f.value;
    } else {
      input = h('input', { type: f.type || 'text', name: f.name, placeholder: f.placeholder || null, autocomplete: 'off', spellcheck: 'false',
                           min: f.min ?? null, max: f.max ?? null, required: f.required || null });
      input.value = f.value ?? '';
    }
    inputs[f.name] = input;
    return h('label', { class: 'field' + (f.type === 'checkbox' ? ' check' : '') },
      h('span', null, f.label), input, f.help ? h('small', null, f.help) : null);
  });
  const extra = h('div', { class: 'dlg-extra' });
  const submit = h('button', { type: 'submit', class: 'btn primary' + (opts.danger ? ' danger' : '') }, withIcon(opts.icon || iconFor(submitLabel), submitLabel));
  const cancel = h('button', { type: 'button', class: 'btn quiet', on: { click: () => d.close() } }, withIcon('x', 'Cancel'));
  const close = h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Close', 'aria-label': 'Close', on: { click: () => d.close() } }, icon('x'));
  // The action's own error: in the dialog, which stays open (603 E7).
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const why = h('span', { class: 'why' });
  form.append(h('div', { class: 'dlg-head' }, h('h2', { class: 'h-title' }, title), close),
    h('div', { class: 'dlg-body' }, intro ? h('p', { class: 'sub' }, intro) : null, ...rows, extra, error),
    h('div', { class: 'dlg-foot dlg-buttons' }, why, cancel, submit));
  // 617 (owner, on deleting a try: "i hate this" — typing the name): a box to tick instead.
  if (opts.confirmCheck) {
    submit.disabled = true;
    const box = h('input', { type: 'checkbox', 'data-confirm-check': '' });
    box.addEventListener('change', () => { submit.disabled = !box.checked; });
    inputs.__check = box;
    extra.before(h('label', { class: 'field check confirm-check' }, box, h('span', null, opts.confirmCheck)));
  }
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    error.textContent = '';
    const values = {};
    for (const [k, input] of Object.entries(inputs)) values[k] = input.type === 'checkbox' ? input.checked : input.value.trim();
    submit.disabled = true;
    try {
      for (const [k, get] of Object.entries(customs)) values[k] = get();
      const keep = await onSubmit(values, { extra, error, submit });
      if (keep !== 'keep-open') d.close();
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      if (!opts.confirmCheck || (inputs.__check && inputs.__check.checked)) submit.disabled = false;
    }
  });
  d.addEventListener('close', () => d.remove());
  d.append(form);
  document.body.append(d);
  d.showModal();
  const first = opts.confirmCheck ? cancel : form.querySelector('input,select,textarea');
  if (first) first.focus();
  return Object.assign(d, { inputs, why });
}

/// 617 (owner: "same simplified delete experience"): THE confirmation of a destructive action — a box to tick, never a
/// name to type. The sentence says what will happen ("Yes, reset demo"); the button waits for the tick; the request
/// still carries the name as `confirm`, as the host requires. Every destructive confirm uses it: Remove/Reset a
/// sandbox, Delete/Revert a restore point, Remove an account, an image or a template, Delete a try.
const CONFIRM_ICON = { remove: 'trash-2', delete: 'trash-2', reset: 'rotate-ccw', revert: 'history' };
export function confirmWithCheck(title, text, check, name, body, submitLabel) {
  const verb = (submitLabel || title).split(' ')[0];
  dialog(title, text, [], submitLabel || verb, async () => actOrThrow({ ...body, confirm: name }),
    { danger: true, confirmCheck: check, icon: CONFIRM_ICON[verb.toLowerCase()] || 'triangle-alert' });
}
/// The same, with the sentence made from the title: "Remove account work" → "Yes, remove account work".
export function confirmAction(title, text, name, body) {
  confirmWithCheck(title, text, 'Yes, ' + title.charAt(0).toLowerCase() + title.slice(1), name, body, title.split(' ')[0]);
}
