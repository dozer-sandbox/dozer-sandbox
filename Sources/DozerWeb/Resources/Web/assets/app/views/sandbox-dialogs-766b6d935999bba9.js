// views/sandbox-dialogs — A sandbox page's dialogs: run detached, restore point, template, duplicate, policy, Open in Terminal.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { setButton } from '../dom/icons-8392ebb8cb8879e3.js';
import { AGENT_NAMES } from '../core/agents-66154a04b9c4696c.js';
import { api } from '../core/api-1817573a49f0ab85.js';
import { actOrThrow } from '../core/operations-d824956fc29841f7.js';
import { lines, splitArgs } from '../core/util-1195caf40612902f.js';
import { accountChooser } from '../components/accounts-b0f80747a1924e95.js';
import { dialog } from '../components/dialog-d48442e03113646f.js';
import { failureFor, toast } from '../components/notices-89b8886740537e92.js';
import { workspaceChooser } from '../components/workspace-chooser-d9e6b5ed4d23d130.js';

/// 603: a sandbox's terminal in the user's own terminal app (doz attach), from the bar, the strip or a session row.
export async function openInTerminal(name, session) {
  try {
    const r = await api('sandboxes/' + name + '/terminal', { method: 'POST', json: session ? { session } : {} });
    toast(r.message, false, 'square-terminal');
  } catch (e) { failureFor(name, e.message); }
}
export function runDetachedDialog(name) {
  dialog('Run a command in ' + name, 'A new session running the command — no shell in front (say bash -lc \'…\' for one). It runs inside the sandbox; attach to see it.',
    [{ name: 'session', label: 'Session name', placeholder: 'e.g. worker', required: true },
     { name: 'command', label: 'Command', placeholder: 'sleep 600', required: true }], 'Run', async (v) => {
      const argv = splitArgs(v.command);
      if (!argv.length) throw new Error('the command is empty');
      await actOrThrow({ action: 'open-session', sandbox: name, session: v.session, argv });
    });
}
export function takePointDialog(name, running) {
  dialog('Take a restore point of ' + name, running ? 'A running sandbox pauses for the clone (milliseconds); its copy gets e2fsck on the first boot from it.' : 'An instant APFS clone of the disks.',
    [{ name: 'point', label: 'Name', placeholder: 'default point-N' }, { name: 'note', label: 'Note' }], 'Take', async (v) => {
      const b = { action: 'point-take', sandbox: name };
      if (v.point) b.point = v.point;
      if (v.note) b.note = v.note;
      await actOrThrow(b);
    });
}

/// 593: Save as template — the ROOT disk only (never the state disk: logins and history stay out of a
/// disk meant to be shared). From the current disk (a live sandbox pauses for the clone) or a point.
export function templateDialog(name, d, pointID) {
  const sources = [['', 'the current disk' + (d.info.phase === 'off' ? '' : ' (it pauses for the clone: milliseconds)')],
    ...d.restorePoints.map((p) => [p.id, 'restore point ' + p.name])];
  dialog('Save ' + name + ' as a template',
    'A template is an image other sandboxes are created from. Everything installed or written on the ROOT disk is in it: files in /root, /etc, /usr, /opt, caches — so do not save a secret you put there. The agent’s state disk (its logins, history) is never included.', [
      { name: 'image', label: 'Template name', placeholder: 'a-z 0-9 -', required: true },
      { name: 'source', label: 'From', type: 'select', options: sources, value: pointID || '' },
      { name: 'note', label: 'Note', placeholder: 'what is in it' },
    ], 'Save template', async (v) => {
      const b = { action: 'template-create', sandbox: name, image: v.image };
      if (v.source) b.point = v.source;
      if (v.note) b.note = v.note;
      await actOrThrow(b);
    });
}

/// 593: Duplicate — a new sandbox from this one's disk (or a point) with overrides. The root disk is
/// an APFS clone; the state disk starts fresh unless the person opts in.
export function duplicateDialog(name, d, accounts, pointID) {
  const i = d.info;
  const sources = [['', 'the current disk' + (i.phase === 'off' ? '' : ' (it pauses for the clone: milliseconds)')],
    ...d.restorePoints.map((p) => [p.id, 'restore point ' + p.name])];
  const slot = h('div'), acctSlot = h('div');
  const dlg = dialog('Duplicate ' + name,
    'A new sandbox from ' + name + '’s root disk (an instant APFS clone). It is created off; Start boots it. Keys are not copied.', [
      { name: 'newName', label: 'New sandbox name', placeholder: 'a-z 0-9 -', required: true },
      // 596 (B1): the base and agent are the source's — shown, not changeable (the disk is a clone of its).
      { name: 'baseShown', type: 'custom', get: () => null, el: h('div', { class: 'field', 'data-duplicate-image': '' }, h('span', null, 'Image'),
        h('div', null, h('strong', null, i.imageTitle || i.image), ' ', h('span', { class: 'muted' }, '— ' + i.image + (i.dockerfile ? ', Dockerfile ' + i.dockerfile : '') + ' (the source’s; not changeable)'))) },
      { name: 'source', label: 'From', type: 'select', options: sources, value: pointID || '' },
      // 594: Shared folder (<projects_dir>/<new name> by default, made when missing) | Isolated.
      { name: 'ws', type: 'custom', el: slot, get: () => chooser.get() },
      { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: String(d.cpus) + ' (the same)' },
      { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: String(d.memoryMiB) + ' (the same)' },
      { name: 'network', label: 'Network', type: 'select', value: '',
        options: [['', i.network + ' (the same — its permissions and sites copied)'], ['agent', 'Standard permissions'], ['bake', 'bake'], ['locked', 'Locked — its AI model only'],
          ['open', 'Open — everything (logged)'], ['nat', 'nat'], ['none', 'none']] },
      // 594: only the accounts the agent can use ("the same" only when that one fits).
      { name: 'account', type: 'custom', el: acctSlot, get: () => {
        if (!acct.ok()) throw new Error((AGENT_NAMES[i.agent] || 'This agent') + ' needs an Anthropic API key — add one above.');
        return acct.get();
      } },
      { name: 'copyState', label: 'Copy the agent’s state disk too', type: 'checkbox',
        help: 'Off (the default): a fresh state disk. On: its logins and history are copied into the new sandbox.' },
    ], 'Duplicate', async (v) => {
      const b = { action: 'duplicate', sandbox: name, newName: v.newName, ...v.ws };
      if (v.source) b.point = v.source;
      if (v.cpus) b.cpus = Number(v.cpus);
      if (v.memoryMiB) b.memoryMiB = Number(v.memoryMiB);
      if (v.network) b.network = v.network;
      if (v.account) b.account = v.account;
      if (v.copyState) b.copyState = true;
      await actOrThrow(b);
    });
  const chooser = workspaceChooser({ nameInput: dlg.inputs.newName, image: () => i.image });
  slot.replaceWith(chooser.el);
  const submit = dlg.querySelector('button[type="submit"]');
  const acct = accountChooser({ accounts, agent: () => (['nat', 'none'].includes(dlg.inputs.network.value) ? null : i.agent),
    same: i.credentialProblem ? null : 'the same' + (i.account ? ' (' + i.account + ')' : ''), defaultValue: 'default',
    onChange: () => { submit.disabled = !acct.ok(); } });
  acctSlot.replaceWith(acct.el);
  submit.disabled = !acct.ok();
  dlg.inputs.network.addEventListener('change', () => acct.agentChanged());
}

/// Edit the policy in a dialog; Preview shows exactly what the host will do; Apply sends it.
export function policyDialog(name, policy) {
  dialog('Network policy of ' + name, 'The change is live (the next connection is judged by it) and kept for the next start. Preview first.', [
    { name: 'preset', label: 'Replace with a preset', type: 'select', value: '', options: [['', '— keep the rules —'], 'agent', 'bake', 'locked', 'open'] },
    { name: 'allow', label: 'Allow hosts', type: 'textarea', placeholder: 'example.com\n*.example.org\nhost:443', help: 'one per line: exact, *.domain, host:port or an IPv4 CIDR' },
    { name: 'deny', label: 'Deny hosts', type: 'textarea', placeholder: 'one per line' },
    { name: 'remove', label: 'Remove every rule for these hosts', type: 'textarea', placeholder: 'one per line' },
  ], 'Preview', async (v, ui) => {
    const edit = {};
    if (v.preset) edit.preset = v.preset;
    for (const k of ['allow', 'deny', 'remove']) if (lines(v[k]).length) edit[k] = lines(v[k]);
    if (!Object.keys(edit).length) throw new Error('nothing to change');
    if (ui.submit.dataset.previewed === JSON.stringify(edit)) {
      await actOrThrow({ action: 'net-policy', sandbox: name, ...edit });
      return;
    }
    const p = await api('sandboxes/' + name + '/network/preview', { method: 'POST', json: edit });
    ui.extra.replaceChildren(h('div', { class: 'diff' },
      h('div', { class: 'muted' }, (p.before.preset ? p.before.preset + ' preset' : 'custom') + ' → ' + (p.after.preset ? p.after.preset + ' preset' : 'custom') +
        ' · anything else: ' + p.after.defaultAction),
      p.changed ? null : h('div', null, 'No change.'),
      ...p.removed.map((r) => h('div', { class: 'del' }, '− ' + r)),
      ...p.added.map((r) => h('div', { class: 'add' }, '+ ' + r)),
      h('details', null, h('summary', null, 'The whole policy after (' + p.after.rules.length + ' rules, in order)'),
        h('ol', null, p.after.rules.map((r) => h('li', { class: r.action === 'allow' ? 'st-ok' : 'st-fail' }, r.label + (r.note ? ' — ' + r.note : '')))))));
    ui.submit.dataset.previewed = JSON.stringify(edit);
    setButton(ui.submit, p.changed ? 'Apply' : 'Apply anyway');
    return 'keep-open';
  });
}
