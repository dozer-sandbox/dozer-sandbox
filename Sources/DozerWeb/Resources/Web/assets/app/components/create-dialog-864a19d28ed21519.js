// components/create-dialog — The New sandbox form (a dialog): image, workspace, account, permissions.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-8392ebb8cb8879e3.js';
import { AGENT_NAMES } from '../core/agents-66154a04b9c4696c.js';
import { api } from '../core/api-1817573a49f0ab85.js';
import { actOrThrow } from '../core/operations-d824956fc29841f7.js';
import { setting } from '../core/settings-171e705abeccb983.js';
import { accountChooser } from './accounts-82ffc2d668ed27ac.js';
import { callout } from './callout-295f8e0570c7e239.js';
import { dialog } from './dialog-d48442e03113646f.js';
import { imagePicker, pickerNameHint } from './image-picker-cffe066c76f6fa60.js';
import { confirmWeb, isAgentModel, permissionSwitches } from './permissions-2d2cf511e6aa7261.js';
import { workspaceChooser } from './workspace-chooser-f6907863038dbeff.js';

export async function createDialog(quick = null) {
  let images = [], accounts = { accounts: [] }, bases = null;
  try { [images, accounts] = await Promise.all([api('images'), api('accounts')]); } catch (_) { /* defaults */ }
  try { bases = await api('bases'); } catch (_) { /* no catalogue: the picker shows what it can */ }
  const slot = h('div'), acctSlot = h('div'), imgSlot = h('div'), permSlot = h('div');
  let perms = { value: () => null };
  // 594 W28 (owner: "i dont think we should rebuild images without the user agreeing … better to warn"):
  // an out-of-date image is said here, with the choice — use it as it is (the default), or rebuild first.
  const imgNote = h('div', { class: 'callout warn compact img-choice', role: 'group', 'data-image-choice': '', hidden: true });
  let imgChoice = 'current';
  const renderImgNote = (name) => {
    const i = images.find((x) => x.name === name);
    imgChoice = 'current';
    if (!i || !i.baked || !i.standing) { imgNote.hidden = true; imgNote.replaceChildren(); return; }
    const missing = i.olderRecipe && !(i.olderRecipe.length === 1 && i.olderRecipe[0] === 'its recipe changed') ? ' (missing: ' + i.olderRecipe.join(', ') + ')' : '';
    const radio = (value, label, checked) => {
      const r = h('input', { type: 'radio', name: 'img-choice', value });
      r.checked = checked;
      r.addEventListener('change', () => { if (r.checked) imgChoice = value; });
      return h('label', { class: 'check' }, r, ' ', label);
    };
    imgNote.replaceChildren(icon('flame'), h('div', { class: 'c-body' },
      h('p', { class: 'img-choice-note c-title' }, 'The ' + name + ' image is out of date: ' + i.standing.replace(/ — rebuild when ready: .*$/, '') + '.'),
      radio('current', 'Use the current image' + missing, true),
      radio('rebuild', 'Rebuild it first (~2 min, needs network; existing sandboxes are NOT affected)', false)));
    imgNote.hidden = false;
  };
  const dlg = dialog('New sandbox','It is created off; Start boots it (the first start of an image not yet prepared prepares it — minutes, needs network).', [
    { name: 'sandbox', label: 'Name', placeholder: 'a-z 0-9 -', required: true },
    // 596 (B1): Agent × Base.
    { name: 'image', type: 'custom', el: imgSlot, get: () => {
      const why = picker.blocked();
      if (why) throw new Error(why);
      return picker.image();
    } },
    { name: 'dockerfile', type: 'custom', el: h('span', { hidden: true }), get: () => picker.dockerfile() },
    // 597 (P4): what the agent can do — preset from the base (and the Network choice).
    { name: 'permissions', type: 'custom', el: permSlot, get: () => perms.value() },
    { name: 'imageChoice', type: 'custom', el: imgNote, get: () => imgChoice },
    { name: 'network', label: 'Network', type: 'select', value: '',
      options: [['', 'default — the permissions below (Settings)'], ['agent', 'Standard permissions'], ['bake', 'bake — proxied, package registries only'],
        ['locked', 'Locked — its AI model only'], ['open', 'Open — everything, the web included (logged)'], ['nat', 'nat — a real interface (vmnet), not filtered'], ['none', 'none']] },
    // 594: only the accounts the image's agent can use; pi with none: the key right here.
    { name: 'account', type: 'custom', el: acctSlot, get: () => {
      if (!acct.ok()) throw new Error((AGENT_NAMES[agentOf()] || 'This agent') + ' needs an Anthropic API key — add one above.');
      return acct.get();
    } },
    { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: 'default (' + setting('defaults.cpus', 2) + ', Settings)' },
    { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: 'default (per image, Settings)' },
    // 594: Shared folder (the default: <projects_dir>/<name>, made when missing) | Isolated.
    { name: 'ws', type: 'custom', el: slot, get: () => chooser.get() },
  ], 'Create', async (v) => {
    const body = { action: 'create', sandbox: v.sandbox, image: v.image, ...v.ws };
    if (v.dockerfile) body.dockerfile = v.dockerfile;
    if (v.permissions) body.permissions = v.permissions;
    if (v.imageChoice === 'rebuild') body.rebuild = true;
    if (v.network) body.network = v.network;
    if (v.account) body.account = v.account;
    if (v.cpus) body.cpus = Number(v.cpus);
    if (v.memoryMiB) body.memoryMiB = Number(v.memoryMiB);
    await actOrThrow(body);
  });
  let chooser = null, acct = null;
  // 599c: Quick add could not decide this one — said at the top; the form below is pre-filled with its defaults.
  if (quick && quick.why) {
    const sub = dlg.querySelector('.dlg-body > p.sub');
    const note = callout('warn', { cls: 'notice quick-why', role: 'note', attrs: { 'data-quick-why': quick.kind || '' },
      icon: quick.kind === 'account' ? 'key-round' : 'flame', title: 'Quick add needs your choice', body: quick.why });
    if (sub) sub.after(note); else dlg.querySelector('.dlg-body').prepend(note);
  }
  const submit = dlg.querySelector('button[type="submit"]');
  const why = dlg.why;
  why.dataset.createWhy = '';
  why.setAttribute('aria-live', 'polite');
  const gate = () => {
    const w = picker.blocked();
    why.textContent = w || '';
    submit.disabled = !!w || (acct ? !acct.ok() : false);
  };
  const picker = imagePicker({ images, bases, value: (quick && quick.image) || setting('defaults.image', 'claude-code'),
    onChange: () => { if (chooser) chooser.imageChanged(); if (acct) acct.agentChanged(); renderImgNote(picker.image()); if (perms.baseChanged) perms.baseChanged(); gate(); },
    onDockerfile: (folder) => { if (chooser) chooser.suggest(folder); } });
  imgSlot.replaceWith(picker.el);
  chooser = workspaceChooser({ nameInput: dlg.inputs.sandbox, image: () => pickerNameHint(picker) });
  slot.replaceWith(chooser.el);
  const netProxied = () => !['nat', 'none'].includes(dlg.inputs.network.value);
  acct = accountChooser({ accounts, agent: () => (netProxied() ? picker.agent() : null), onChange: gate });
  acctSlot.replaceWith(acct.el);
  renderImgNote(picker.image());
  perms = newSandboxPermissions(bases, picker, dlg.inputs.network);
  permSlot.replaceWith(perms.el);
  gate();
  dlg.inputs.network.addEventListener('change', () => { acct.agentChanged(); perms.networkChanged(); });
}

/// 597 (P4): New Sandbox's switches — the default for the base (defaults.permissions), or the Network
/// choice's preset; changed by hand, they stay as set. Hidden for bake / nat / none and a template.
function newSandboxPermissions(bases, picker, network) {
  const el = h('div', { class: 'field perm-field', 'data-new-permissions': '' });
  if (!bases || !bases.permissions) return { el, value: () => null, baseChanged() {}, networkChanged() {} };
  let on = new Set(), touched = false;
  const baseKey = () => { const b = picker.base(); return b === null ? null : b; };
  const presetFor = (net, b) => net === 'locked' ? ['model'] : net === 'open' ? bases.permissions.map((r) => r.id).filter((x) => !isAgentModel(x))
    : net === 'agent' ? (bases.standard[b] || bases.standard[''] || [])
    : [...(bases.defaults[b] || bases.defaults[''] || []), ...(bases.github || [])];   // 599e: + the Access step's GitHub choice
  const visible = () => baseKey() !== null && !['bake', 'nat', 'none'].includes(network.value);
  const reset = () => { if (!touched) on = new Set(presetFor(network.value, baseKey() || '')); paint(); };
  const change = (id, v) => {
    const apply = () => {
      touched = true;
      const inst = bases.permissions.filter((r) => r.group === 'install').map((r) => r.id);
      for (const x of id === 'install' ? inst : [id]) { if (v) on.add(x); else on.delete(x); }
      paint();
    };
    if (id === 'web' && v) confirmWeb(async () => apply()); else apply();
  };
  function paint() {
    el.hidden = !visible();
    const std = new Set(bases.standard[baseKey() || ''] || []);
    const same = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
    const label = same(on, std) ? 'Standard' : same(on, new Set(['model'])) ? 'Locked' : same(on, new Set(bases.permissions.map((r) => r.id).filter((x) => !isAgentModel(x)))) ? 'Open' : 'Custom';
    el.replaceChildren(h('span', null, 'What the agent can do ', h('span', { class: 'tag', 'data-new-perm-preset': label }, label)),
      permissionSwitches(bases.permissions, on, change, { hosts: true, agent: picker.agent() }));
  }
  reset();
  return {
    el,
    value: () => (visible() ? [...on] : null),
    baseChanged: reset,
    networkChanged() { touched = false; reset(); },
  };
}
