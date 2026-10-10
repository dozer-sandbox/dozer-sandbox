// components/dialog — Dialogs: forms live outside the view, so a live refresh never wipes what is being typed.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, iconFor, withIcon } from '../dom/icons-75c107270d336b51.js';
import { actOrThrow } from '../core/operations-24912c84c13d7e09.js';

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
 * @property {string}  [confirmName]     the person types this name before submit is enabled
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
  if (opts.confirmName) {
    submit.disabled = true;
    why.textContent = 'Type the name to ' + submitLabel.split(' ')[0].toLowerCase() + ' it';
    const typed = h('input', { type: 'text', class: 'mono', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'type the name to confirm' });
    typed.addEventListener('input', () => { submit.disabled = typed.value !== opts.confirmName; why.hidden = !submit.disabled; });
    inputs.__confirm = typed;
    extra.before(h('label', { class: 'field' }, h('span', null, 'Type ', h('code', null, opts.confirmName), ' to confirm'), typed));
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
      if (!opts.confirmName || (inputs.__confirm && inputs.__confirm.value === opts.confirmName)) submit.disabled = false;
    }
  });
  d.addEventListener('close', () => d.remove());
  d.append(form);
  document.body.append(d);
  d.showModal();
  const first = form.querySelector('input,select,textarea');
  if (first) first.focus();
  return Object.assign(d, { inputs, why });
}

/// A destructive action: the person types the name; the request carries it as `confirm`.
export function confirmAction(title, text, name, body) {
  dialog(title, text, [], title, async () => {
    const op = await actOrThrow({ ...body, confirm: name });
    return op;
  }, { danger: true, confirmName: name });
}
